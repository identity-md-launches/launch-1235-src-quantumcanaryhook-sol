// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {QuantumCanaryToken} from "../src/QuantumCanaryToken.sol";
import {IQuantumCanary} from "../src/IQuantumCanary.sol";
import {QuantumCanaryTestBase} from "./QuantumCanaryHook.t.sol";

interface ICanaryObserver is IQuantumCanary {
    function poke() external;
    function thresholdWei() external view returns (uint256);
}

/// @notice Optional rehearsal with the actual deployed canary and a local real v4 manager.
/// @dev No RPC or environment access in test code. Default offline execution skips cleanly.
contract QuantumCanaryMainnetForkTest is QuantumCanaryTestBase {
    address internal constant LIVE_CANARY = 0x626517225096671868609c1bBF9c1B416A4eFd9a;

    function setUp() public override {
        if (LIVE_CANARY.code.length == 0) {
            vm.skip(true);
            return;
        }
        vm.deal(address(this), 10_000_000 ether);
        token = new QuantumCanaryToken();
        manager = IPoolManager(address(new PoolManager(address(this))));
        // Foundry's fork fixtures may pre-fund newly created accounts by one wei.
        vm.deal(address(manager), 0);
        hook = _mine(manager, IQuantumCanary(LIVE_CANARY));
        bounty = IQuantumCanary(LIVE_CANARY).canaryAddress();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        _liquidity(-600, -60, int256(LIQUIDITY));
    }

    function testFork_liveDestinationAllFourModesAndPayout() public {
        assertEq(address(hook.quantumCanary()), LIVE_CANARY);
        assertEq(hook.canaryAddress(), IQuantumCanary(LIVE_CANARY).canaryAddress());
        assertEq(address(manager).balance, 0);
        _checkSwap(true, true, 2 ether, _wideLimit(true));
        _checkSwap(true, false, 0.1 ether, _wideLimit(true));
        _checkSwap(false, true, 0.1 ether, _wideLimit(false));
        _checkSwap(false, false, 0.1 ether, _wideLimit(false));
        hook.payout();
        assertEq(hook.accruedFees(), 0);
    }

    function testFork_liveAlarmRetiresHookPermanently() public {
        ICanaryObserver observer = ICanaryObserver(LIVE_CANARY);
        vm.deal(bounty, observer.thresholdWei() * 2);
        observer.poke();
        vm.deal(bounty, 0);
        assertTrue(observer.isTripped());
        _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertTrue(hook.retired());
        assertEq(hook.accruedFees(), 0);
        vm.deal(bounty, observer.thresholdWei() * 2);
        _checkSwap(true, false, 0.1 ether, _wideLimit(true));
        assertTrue(hook.retired());
        assertEq(hook.accruedFees(), 0);
    }
}
