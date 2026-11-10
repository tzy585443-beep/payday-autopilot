// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { PaydayReactive } from "../src/PaydayReactive.sol";
import { PaydayExecutor } from "../src/PaydayExecutor.sol";
import { TestUSD } from "../src/TestUSD.sol";
import { MockSystem } from "./mocks/MockSystem.sol";

contract PaydayTest is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 constant ORIGIN = 84532; // Base Sepolia
    uint256 constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    address constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;

    MockSystem sys; // etched at 0x8888 (Reactive side)
    MockSystem proxy; // destination callback proxy
    TestUSD usd;
    PaydayReactive rc;
    PaydayExecutor ex;

    address user = address(0xA11CE);
    address employer = address(0xE11);
    address stranger = address(0xBAD);
    address savings = address(0x5AFE);
    address landlord = address(0x1A4D);

    function setUp() public {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM_ADDR));
        proxy = new MockSystem();
        usd = new TestUSD();
        vm.warp(1_800_000_000);

        vm.startPrank(user);
        rc = new PaydayReactive(ORIGIN, ORIGIN, address(usd), user, 100e6, employer, CRON100, 30 days);
        ex = new PaydayExecutor(IPayable(payable(address(proxy))), address(rc), address(usd), savings, 2000, 1_000e6);
        rc.setExecutor(address(ex));
        usd.approve(address(ex), type(uint256).max);
        ex.setRecurring(landlord, 900e6, 25 days);
        vm.stopPrank();
        usd.mint(employer, 100_000e6);
    }

    // ------------------------------------------------------------ helpers

    function _transferLog(address from, address to, uint256 amount, uint256 txh)
        internal
        view
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = ORIGIN;
        l.contractAddress = address(usd);
        l.topic0 = rc.TRANSFER_TOPIC_0();
        l.topic1 = uint256(uint160(from));
        l.topic2 = uint256(uint160(to));
        l.data = abi.encode(amount);
        l.opCode = 3;
        l.txHash = txh;
        l.logIndex = 0;
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory l) {
        l.chainId = block.chainid;
        l.contractAddress = CRON_SOURCE;
        l.topic0 = CRON100;
        l.data = abi.encode(block.number);
        l.opCode = 1;
    }

    /// pays the user on the "origin chain", then plays the network: react() + deliver the callback
    function _payday(address from, uint256 amount, uint256 txh) internal {
        vm.prank(from);
        usd.transfer(user, amount);
        IReactive.LogRecord memory l = _transferLog(from, user, amount, txh);
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function _relay() internal {
        // move the request recorded by the system contract onto the "destination proxy" and deliver it
        uint256 n = sys.reqCount();
        MockSystem.Req memory r = sys.req(n - 1);
        bytes memory p = r.payload;
        address s = r.sender;
        assembly {
            mstore(add(p, 36), s)
        }
        vm.prank(address(proxy));
        (bool ok,) = r.recipient.call{ gas: r.gasLimit }(p);
        assertTrue(ok, "callback reverted");
    }

    // ------------------------------------------------------------ tests

    function test_subscriptions() public view {
        assertEq(sys.activeSubs(address(rc)), 2); // Transfer(to=user) + Cron100
        (, uint256 c, address a, uint256 t0,, uint256 t2,,) = sys.subs(0);
        assertEq(c, ORIGIN);
        assertEq(a, address(usd));
        assertEq(t0, rc.TRANSFER_TOPIC_0());
        assertEq(t2, uint256(uint160(user)));
    }

    function test_fullLoop_paycheckIsSaved() public {
        _payday(employer, 3_000e6, 0x111);
        assertEq(sys.reqCount(), 1);
        MockSystem.Req memory r = sys.req(0);
        assertEq(r.chainId, ORIGIN);
        assertEq(r.recipient, address(ex));
        _relay();
        // 20% of 3000 = 600 -> savings
        assertEq(usd.balanceOf(savings), 600e6);
        assertEq(usd.balanceOf(user), 2_400e6);
        assertEq(ex.totalSaved(), 600e6);
        assertEq(rc.incomeEvents(), 1);
    }

    function test_ignoresDustAndStrangers() public {
        _payday(employer, 50e6, 0x1); // below min
        usd.mint(stranger, 10_000e6);
        _payday(stranger, 5_000e6, 0x2); // untrusted payer
        assertEq(sys.reqCount(), 0);
        assertEq(rc.ignoredEvents(), 2);
    }

    function test_anyPayerMode() public {
        vm.prank(user);
        rc.setRules(100e6, true, 30 days);
        usd.mint(stranger, 10_000e6);
        _payday(stranger, 1_000e6, 0x2);
        assertEq(sys.reqCount(), 1);
    }

    function test_dailyCap() public {
        _payday(employer, 4_000e6, 0x1); // wants 800
        _relay();
        _payday(employer, 4_000e6, 0x2); // wants 800, only 200 left in window
        _relay();
        assertEq(usd.balanceOf(savings), 1_000e6);
        _payday(employer, 4_000e6, 0x3); // cap reached -> skipped
        _relay();
        assertEq(usd.balanceOf(savings), 1_000e6);
        vm.warp(block.timestamp + 1 days);
        _payday(employer, 1_000e6, 0x4);
        _relay();
        assertEq(usd.balanceOf(savings), 1_200e6);
    }

    function test_replayProtection() public {
        _payday(employer, 1_000e6, 0x77);
        _relay();
        _relay(); // same request delivered twice
        assertEq(usd.balanceOf(savings), 200e6);
    }

    function test_recurringViaCron() public {
        usd.mint(user, 5_000e6);
        // tick before due -> nothing
        vm.prank(SYSTEM_ADDR);
        rc.react(_cronLog());
        assertEq(sys.reqCount(), 0);
        // 30 days later -> one payment
        vm.warp(block.timestamp + 30 days);
        vm.prank(SYSTEM_ADDR);
        rc.react(_cronLog());
        assertEq(sys.reqCount(), 1);
        _relay();
        assertEq(usd.balanceOf(landlord), 900e6);
        // further ticks the same day -> nothing
        vm.prank(SYSTEM_ADDR);
        rc.react(_cronLog());
        assertEq(sys.reqCount(), 1);
        assertEq(rc.recurringCount(), 1);
    }

    function test_executorRateLimitsRecurring() public {
        usd.mint(user, 5_000e6);
        vm.warp(block.timestamp + 30 days);
        vm.prank(SYSTEM_ADDR);
        rc.react(_cronLog());
        _relay();
        _relay(); // a duplicate delivery is blocked by minRecurringGap
        assertEq(usd.balanceOf(landlord), 900e6);
    }

    function test_insufficientAllowanceDoesNotRevert() public {
        vm.prank(user);
        usd.approve(address(ex), 0);
        _payday(employer, 1_000e6, 0x9);
        _relay(); // asserts callback itself did not revert
        assertEq(usd.balanceOf(savings), 0);
    }

    function test_reactOnlySystem() public {
        IReactive.LogRecord memory l = _transferLog(employer, user, 1_000e6, 1);
        vm.expectRevert();
        rc.react(l);
    }

    function test_callbackAuth() public {
        // direct call (not from proxy)
        vm.expectRevert();
        ex.onIncome(address(rc), employer, 1e6, 1, 0);
        // via proxy but from a different reactive contract
        vm.prank(address(proxy));
        vm.expectRevert();
        ex.onIncome(stranger, employer, 1e6, 1, 0);
    }

    function test_pauseResume() public {
        vm.prank(user);
        rc.pause();
        assertEq(sys.activeSubs(address(rc)), 0);
        _payday(employer, 1_000e6, 0x5);
        assertEq(sys.reqCount(), 0);
        vm.prank(user);
        rc.resume();
        assertEq(sys.activeSubs(address(rc)), 2);
    }

    function test_onlyOwnerControls() public {
        vm.startPrank(stranger);
        vm.expectRevert(PaydayReactive.NotOwner.selector);
        rc.setRules(0, true, 0);
        vm.expectRevert(PaydayExecutor.NotOwner.selector);
        ex.setSavingsRule(stranger, 10_000, 0);
        vm.expectRevert(PaydayReactive.NotOwner.selector);
        rc.withdraw(payable(stranger), 0);
        vm.stopPrank();
        vm.prank(user);
        vm.expectRevert(PaydayReactive.ExecutorAlreadySet.selector);
        rc.setExecutor(stranger);
    }

    function test_turningRecurringOffUnsubscribesCron() public {
        assertTrue(rc.cronSubscribed());
        vm.prank(user);
        rc.setRules(100e6, false, 0);
        assertFalse(rc.cronSubscribed());
        assertEq(sys.activeSubs(address(rc)), 1);
        vm.prank(user);
        rc.setRules(100e6, false, 7 days);
        assertTrue(rc.cronSubscribed());
        assertEq(sys.activeSubs(address(rc)), 2);
    }

    function testFuzz_savingsNeverExceedsBpsOrCap(uint256 amount) public {
        amount = bound(amount, 100e6, 50_000e6);
        _payday(employer, amount, 0xF);
        _relay();
        uint256 s = usd.balanceOf(savings);
        assertLe(s, (amount * 2000) / 10_000);
        assertLe(s, 1_000e6);
    }
}
