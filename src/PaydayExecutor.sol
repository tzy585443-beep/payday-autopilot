// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
}

/// @title PaydayExecutor — the "hands" of Payday Autopilot, deployed on the destination chain.
/// @notice Receives callbacks from exactly one PaydayReactive contract (through the chain's callback proxy) and
///         moves the owner's tokens according to the owner's rules. Funds never leave the owner's wallet until a
///         rule fires: the executor only holds an ERC-20 allowance, and every rule is capped on-chain.
///         - onIncome:    save `saveBps` of each paycheck to `savings`, capped per rolling 24h window
///         - onRecurring: pay `recurringAmount` to `payee`, at most once per `minRecurringGap` seconds
///         Timers use block.timestamp (never block counts), as required on 200ms-block chains like Base Sepolia.
contract PaydayExecutor is AbstractCallback {
    address public immutable owner; // the wallet owner; tokens are pulled from here
    IERC20Min public immutable token;

    // --- savings rule
    address public savings;
    uint16 public saveBps; // 1000 = 10%
    uint256 public maxSavePerDay; // cap per 24h window (0 = no cap)
    uint256 public windowStart;
    uint256 public savedInWindow;

    // --- recurring rule
    address public payee;
    uint256 public recurringAmount;
    uint256 public minRecurringGap; // defence-in-depth: executor-side rate limit in seconds
    uint256 public lastRecurringAt;

    // --- ledger
    uint256 public totalSaved;
    uint256 public totalPaid;
    uint256 public lastIncomeAt;
    mapping(bytes32 => bool) public processed; // origin (txHash, logIndex) -> handled (replay protection)

    event Saved(uint256 indexed originTxHash, address indexed payer, uint256 income, uint256 saved, uint256 totalSaved);
    event RecurringPaid(uint256 indexed period, address indexed payee, uint256 amount, uint256 totalPaid);
    event Skipped(bytes32 indexed key, string reason);
    event RulesUpdated(address savings, uint16 saveBps, uint256 maxSavePerDay);
    event RecurringUpdated(address payee, uint256 amount, uint256 minGap);

    error NotOwner();
    error BadBps();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPayable callbackProxy_,
        address reactive_,
        address token_,
        address savings_,
        uint16 saveBps_,
        uint256 maxSavePerDay_
    ) payable AbstractCallback(callbackProxy_, reactive_) {
        if (saveBps_ > 10_000) revert BadBps();
        owner = msg.sender;
        token = IERC20Min(token_);
        savings = savings_;
        saveBps = saveBps_;
        maxSavePerDay = maxSavePerDay_;
        emit RulesUpdated(savings_, saveBps_, maxSavePerDay_);
    }

    // ---------------------------------------------------------------- callbacks (Reactive Network only)

    /// @notice Called via the callback proxy when PaydayReactive detects income.
    /// @dev First argument is overwritten by the network with the requesting reactive contract's address.
    function onIncome(address rvm_, address payer_, uint256 amount_, uint256 originTxHash_, uint256 logIndex_)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm_)
    {
        bytes32 key = keccak256(abi.encode(originTxHash_, logIndex_));
        if (processed[key]) {
            emit Skipped(key, "duplicate");
            return;
        }
        processed[key] = true;
        lastIncomeAt = block.timestamp;

        uint256 want = (amount_ * saveBps) / 10_000;
        if (block.timestamp >= windowStart + 1 days) {
            windowStart = block.timestamp;
            savedInWindow = 0;
        }
        if (maxSavePerDay != 0 && savedInWindow + want > maxSavePerDay) {
            want = maxSavePerDay > savedInWindow ? maxSavePerDay - savedInWindow : 0;
        }
        if (want == 0) {
            emit Skipped(key, "daily cap reached");
            return;
        }
        if (!_pull(savings, want)) {
            emit Skipped(key, "transfer failed (allowance/balance)");
            return;
        }
        savedInWindow += want;
        totalSaved += want;
        emit Saved(originTxHash_, payer_, amount_, want, totalSaved);
    }

    /// @notice Called via the callback proxy when the recurring schedule on Reactive Network says a payment is due.
    function onRecurring(address rvm_, uint256 period_) external onlyServiceProvider onlyCallbackSender(rvm_) {
        bytes32 key = keccak256(abi.encode("recurring", period_));
        if (payee == address(0) || recurringAmount == 0) {
            emit Skipped(key, "recurring not configured");
            return;
        }
        if (lastRecurringAt != 0 && block.timestamp < lastRecurringAt + minRecurringGap) {
            emit Skipped(key, "too soon");
            return;
        }
        if (!_pull(payee, recurringAmount)) {
            emit Skipped(key, "transfer failed (allowance/balance)");
            return;
        }
        lastRecurringAt = block.timestamp;
        totalPaid += recurringAmount;
        emit RecurringPaid(period_, payee, recurringAmount, totalPaid);
    }

    // ---------------------------------------------------------------- owner controls

    function setSavingsRule(address savings_, uint16 saveBps_, uint256 maxSavePerDay_) external onlyOwner {
        if (saveBps_ > 10_000) revert BadBps();
        savings = savings_;
        saveBps = saveBps_;
        maxSavePerDay = maxSavePerDay_;
        emit RulesUpdated(savings_, saveBps_, maxSavePerDay_);
    }

    function setRecurring(address payee_, uint256 amount_, uint256 minGap_) external onlyOwner {
        payee = payee_;
        recurringAmount = amount_;
        minRecurringGap = minGap_;
        emit RecurringUpdated(payee_, amount_, minGap_);
    }

    function coverDebt() external {
        _coverDebt();
    }

    function withdraw(address payable to_, uint256 amount_) external onlyOwner {
        _pay(to_, amount_);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Never reverts: a reverting callback is still billed, so failures are reported as events instead.
    function _pull(address to_, uint256 amount_) internal returns (bool ok) {
        (bool success, bytes memory ret) =
            address(token).call(abi.encodeCall(IERC20Min.transferFrom, (owner, to_, amount_)));
        ok = success && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
