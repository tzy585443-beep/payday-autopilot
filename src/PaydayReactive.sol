// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title PaydayReactive — the "brain" of Payday Autopilot, deployed on Reactive Network (Lasna / mainnet).
/// @notice Watches your wallet on an origin chain. When income lands (an ERC-20 Transfer *to* you from a payer you
///         trust, at or above a minimum size), it asks the network to call `PaydayExecutor.onIncome()` on the
///         destination chain, which moves your chosen percentage into savings ("pay yourself first").
///         Optionally it also listens to Reactive's built-in CRON ticks and fires a recurring payment
///         (rent, allowance, subscription, DCA) whenever the configured wall-clock interval has elapsed.
///         No bot, no server, no keeper: Reactive Network delivers the events and posts the callbacks.
contract PaydayReactive is AbstractReactive {
    // ---------------------------------------------------------------- constants

    /// @dev keccak256("Transfer(address,address,uint256)")
    uint256 public constant TRANSFER_TOPIC_0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @dev Legacy system contract that emits the network's CRON events (see docs: Subscribing To CRON Events).
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;

    // ---------------------------------------------------------------- immutables

    address public immutable owner;
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    /// @notice ERC-20 whose incoming transfers count as income (e.g. USDC on the origin chain).
    address public immutable incomeToken;
    /// @notice The wallet being watched (the person whose paycheck this is).
    address public immutable wallet;
    /// @notice CRON topic used for recurring payments, or 0 if recurring payments are disabled.
    uint256 public immutable cronTopic;

    // ---------------------------------------------------------------- config / state

    address public executor; // PaydayExecutor on the destination chain (set once after it's deployed)
    uint64 public callbackGasLimit = 500_000;

    uint256 public minIncome; // transfers below this are ignored (filters dust / refunds)
    bool public anyPayer; // if true, every incoming transfer >= minIncome counts as income
    mapping(address => bool) public trustedPayer;

    uint256 public recurringInterval; // seconds between recurring payments (0 = recurring off)
    uint256 public nextRecurringAt; // unix timestamp the next recurring payment becomes due
    uint256 public recurringCount; // how many recurring callbacks have been requested

    bool public paused;
    bool public cronSubscribed;

    // stats, handy for the dashboard / judges
    uint256 public incomeEvents;
    uint256 public ignoredEvents;

    // ---------------------------------------------------------------- events

    event ExecutorSet(address indexed executor);
    event IncomeDetected(address indexed payer, uint256 amount, uint256 originTxHash, uint256 logIndex);
    event IncomeIgnored(address indexed from, uint256 amount, uint8 reason); // 1 = below min, 2 = untrusted payer
    event RecurringTriggered(uint256 indexed period, uint256 dueAt, uint256 firedAt);
    event ConfigUpdated(uint256 minIncome, bool anyPayer, uint256 recurringInterval);
    event PayerUpdated(address indexed payer, bool trusted);
    event Paused(bool paused);

    error NotOwner();
    error ExecutorAlreadySet();
    error ExecutorNotSet();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param originChainId_ chain where income arrives (e.g. 84532 Base Sepolia)
    /// @param destinationChainId_ chain where the executor lives (usually the same chain)
    /// @param incomeToken_ ERC-20 token to watch
    /// @param wallet_ wallet whose incoming transfers are watched
    /// @param minIncome_ minimum transfer size to count as income
    /// @param firstPayer_ a trusted payer (employer, client) — pass address(0) to accept any payer
    /// @param cronTopic_ CRON topic for recurring payments (e.g. Cron100), or 0 to disable
    /// @param recurringInterval_ seconds between recurring payments (ignored if cronTopic_ == 0)
    constructor(
        uint256 originChainId_,
        uint256 destinationChainId_,
        address incomeToken_,
        address wallet_,
        uint256 minIncome_,
        address firstPayer_,
        uint256 cronTopic_,
        uint256 recurringInterval_
    ) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        incomeToken = incomeToken_;
        wallet = wallet_;
        minIncome = minIncome_;
        cronTopic = cronTopic_;
        if (firstPayer_ == address(0)) {
            anyPayer = true;
        } else {
            trustedPayer[firstPayer_] = true;
            emit PayerUpdated(firstPayer_, true);
        }
        if (cronTopic_ != 0 && recurringInterval_ != 0) {
            recurringInterval = recurringInterval_;
            nextRecurringAt = block.timestamp + recurringInterval_;
        }
        _subscribeAll();
    }

    // ---------------------------------------------------------------- reactive entry point

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (paused || executor == address(0)) return; // never revert as a filter: reverts are still billed

        if (
            log_.topic0 == TRANSFER_TOPIC_0 && log_.chainId == originChainId
                && log_.contractAddress == incomeToken && log_.opCode == 3
                && address(uint160(log_.topic2)) == wallet
        ) {
            _handleIncome(log_);
        } else if (cronTopic != 0 && log_.topic0 == cronTopic && log_.contractAddress == CRON_SOURCE) {
            _handleCron();
        }
    }

    function _handleIncome(LogRecord calldata log_) internal {
        address payer = address(uint160(log_.topic1));
        uint256 amount = abi.decode(log_.data, (uint256));

        if (amount < minIncome) {
            ignoredEvents++;
            emit IncomeIgnored(payer, amount, 1);
            return;
        }
        if (!anyPayer && !trustedPayer[payer]) {
            ignoredEvents++;
            emit IncomeIgnored(payer, amount, 2);
            return;
        }

        incomeEvents++;
        emit IncomeDetected(payer, amount, log_.txHash, log_.logIndex);
        _callback(
            abi.encodeWithSignature(
                "onIncome(address,address,uint256,uint256,uint256)",
                address(0), // replaced by Reactive Network with this contract's address
                payer,
                amount,
                log_.txHash,
                log_.logIndex
            )
        );
    }

    function _handleCron() internal {
        if (recurringInterval == 0 || block.timestamp < nextRecurringAt) return;
        uint256 due = nextRecurringAt;
        // catch up without firing a burst: next due time is strictly in the future
        uint256 next = due + recurringInterval;
        if (next <= block.timestamp) next = block.timestamp + recurringInterval;
        nextRecurringAt = next;
        uint256 period = ++recurringCount;
        emit RecurringTriggered(period, due, block.timestamp);
        _callback(abi.encodeWithSignature("onRecurring(address,uint256)", address(0), period));
    }

    function _callback(bytes memory payload_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: executor,
                gasLimit: callbackGasLimit,
                payload: payload_
            })
        );
    }

    // ---------------------------------------------------------------- owner controls

    /// @notice Wire the destination executor (deploy order: reactive -> executor(reactive) -> setExecutor).
    function setExecutor(address executor_) external onlyOwner {
        if (executor != address(0)) revert ExecutorAlreadySet();
        executor = executor_;
        emit ExecutorSet(executor_);
    }

    function setRules(uint256 minIncome_, bool anyPayer_, uint256 recurringInterval_) external onlyOwner {
        minIncome = minIncome_;
        anyPayer = anyPayer_;
        if (recurringInterval_ != recurringInterval) {
            recurringInterval = recurringInterval_;
            nextRecurringAt = recurringInterval_ == 0 ? 0 : block.timestamp + recurringInterval_;
            // CRON ticks are billed even when nothing is due, so only stay subscribed while recurring is on.
            if (!paused) _syncCron();
        }
        emit ConfigUpdated(minIncome_, anyPayer_, recurringInterval_);
    }

    function setPayer(address payer_, bool trusted_) external onlyOwner {
        trustedPayer[payer_] = trusted_;
        emit PayerUpdated(payer_, trusted_);
    }

    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        callbackGasLimit = gasLimit_;
    }

    /// @notice Stop listening (and stop paying for CRON ticks). Resume re-subscribes after settling debt.
    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        _unsubscribeAll();
        emit Paused(true);
    }

    function resume() external payable onlyOwner {
        if (!paused) return;
        paused = false;
        _coverDebt();
        _subscribeAll();
        emit Paused(false);
    }

    /// @notice Anyone may top the contract up and settle its debt to the system contract.
    function coverDebt() external {
        _coverDebt();
    }

    function withdraw(address payable to_, uint256 amount_) external onlyOwner {
        _pay(to_, amount_);
    }

    // ---------------------------------------------------------------- subscriptions

    function _subscribeAll() internal {
        // Only transfers *to* the wallet: topic2 == wallet. Everything else never reaches us (and costs nothing).
        SYSTEM.subscribe(
            originChainId, incomeToken, TRANSFER_TOPIC_0, REACTIVE_IGNORE, uint256(uint160(wallet)), REACTIVE_IGNORE
        );
        _syncCron();
    }

    function _unsubscribeAll() internal {
        SYSTEM.unsubscribe(
            originChainId, incomeToken, TRANSFER_TOPIC_0, REACTIVE_IGNORE, uint256(uint160(wallet)), REACTIVE_IGNORE
        );
        if (cronSubscribed) {
            cronSubscribed = false;
            SYSTEM.unsubscribe(block.chainid, CRON_SOURCE, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @dev Keeps the CRON subscription in line with whether recurring payments are switched on.
    function _syncCron() internal {
        bool want = cronTopic != 0 && recurringInterval != 0;
        if (want && !cronSubscribed) {
            cronSubscribed = true;
            SYSTEM.subscribe(block.chainid, CRON_SOURCE, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else if (!want && cronSubscribed) {
            cronSubscribed = false;
            SYSTEM.unsubscribe(block.chainid, CRON_SOURCE, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }
}
