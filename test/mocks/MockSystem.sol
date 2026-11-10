// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";

/// @notice Minimal stand-in for Reactive Network's system contract (0x8888...8888) and for a callback proxy.
///         Records subscriptions and callback requests so tests can replay the network's behaviour.
contract MockSystem {
    struct Sub {
        address subscriber;
        uint256 chainId;
        address contract_;
        uint256 t0;
        uint256 t1;
        uint256 t2;
        uint256 t3;
        bool active;
    }

    struct Req {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] public subs;
    Req[] internal _reqs;
    mapping(address => uint256) public debt;

    event CallbackRequest(
        uint256 indexed chainId, address indexed sender, address indexed recipient, uint8 version, bytes configuration
    );

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subs.push(Sub(msg.sender, c, a, t0, t1, t2, t3, true));
    }

    function unsubscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        for (uint256 i; i < subs.length; i++) {
            Sub storage s = subs[i];
            if (
                s.active && s.subscriber == msg.sender && s.chainId == c && s.contract_ == a && s.t0 == t0
                    && s.t1 == t1 && s.t2 == t2 && s.t3 == t3
            ) s.active = false;
        }
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        _reqs.push(Req(msg.sender, c.chainId, c.recipient, c.gasLimit, c.payload));
        emit CallbackRequest(c.chainId, msg.sender, c.recipient, 0, abi.encode(c));
    }

    function subsCount() external view returns (uint256) {
        return subs.length;
    }

    function activeSubs(address who) external view returns (uint256 n) {
        for (uint256 i; i < subs.length; i++) {
            if (subs[i].active && subs[i].subscriber == who) n++;
        }
    }

    function reqCount() external view returns (uint256) {
        return _reqs.length;
    }

    function req(uint256 i) external view returns (Req memory) {
        return _reqs[i];
    }

    /// @notice Deliver callback `i` the way the network does: inject the requester into the first argument
    ///         and call the recipient from this contract (acting as the callback proxy).
    function deliver(uint256 i) external returns (bool ok, bytes memory ret) {
        Req memory r = _reqs[i];
        bytes memory p = r.payload;
        address s = r.sender;
        assembly {
            mstore(add(p, 36), s) // 32 (length) + 4 (selector)
        }
        (ok, ret) = r.recipient.call{ gas: r.gasLimit }(p);
    }

    /// @notice Play the network on Reactive side: call react() with msg.sender == this system contract.
    function trigger(address reactive, IReactive.LogRecord calldata l) external {
        IReactive(payable(reactive)).react(l);
    }

    function setDebt(address who, uint256 v) external {
        debt[who] = v;
    }

    receive() external payable { }
}
