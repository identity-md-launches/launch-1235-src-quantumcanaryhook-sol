// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {QuantumCanaryHook} from "../src/QuantumCanaryHook.sol";
import {IQuantumCanary} from "../src/IQuantumCanary.sol";
import {CanaryScenario, CanaryClaimBurnAttacker} from "./helpers/CanaryScenario.sol";

contract CallerDestinationCanary is IQuantumCanary {
    function canaryAddress() external view returns (address) {
        return msg.sender;
    }

    function isTripped() external pure returns (bool) {
        return false;
    }
}

contract QuantumCanaryAdversarialTest is CanaryScenario {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_allFourModesCanBeNettedInOneFreshManagerUnlock() public {
        assertEq(address(manager).balance, 0);
        SwapParams[] memory swaps = new SwapParams[](4);
        swaps[0] = SwapParams(true, -2 ether, _wideLimit(true));
        swaps[1] = SwapParams(true, 0.1 ether, _wideLimit(true));
        swaps[2] = SwapParams(false, -0.1 ether, _wideLimit(false));
        swaps[3] = SwapParams(false, 0.1 ether, _wideLimit(false));
        uint256 fee = _executeAndCheck(swaps, 7, abi.encode(address(this), uint256(0)), true);
        assertGt(fee, 0);
        assertEq(router.paidBeforeSettlement(), 0, "ETH has not arrived during any callback");
        assertEq(router.paidAfterSettlement(), fee, "any router can redeem inside its unlock");
        assertEq(bounty.balance, fee);
        assertEq(hook.accruedFees(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transientFeesDoNotLeakBetweenBatchModes(uint256 amount, bytes32 untrustedData) public {
        amount = bound(amount, 1000, 1 ether);
        SwapParams[] memory swaps = new SwapParams[](4);
        swaps[0] = SwapParams(true, -int256(2 * amount), _wideLimit(true));
        swaps[1] = SwapParams(false, -int256(amount / 4), _wideLimit(false));
        swaps[2] = SwapParams(true, int256(amount / 4), _wideLimit(true));
        swaps[3] = SwapParams(false, int256(amount / 4), _wideLimit(false));
        uint256 fee = _executeAndCheck(swaps, 1, abi.encode(untrustedData), true);
        assertEq(hook.accruedFees(), fee, "all callbacks precede native settlement");
        address caller = makeAddr("batch payout caller");
        vm.prank(caller);
        assertEq(hook.payout(), fee);
        assertEq(caller.balance, 0);
        assertEq(bounty.balance, fee);
    }

    function test_unsettledSwapRollsBackBountyPaymentAndPoolState() public {
        uint256 fee = _executeAndCheck(_singleSwap(2 ether, true, true), 1, "", true);
        assertEq(hook.accruedFees(), fee);
        bytes32 beforeState = _accountingDigest();
        SwapParams[] memory swaps = _singleSwap(1 ether, true, true);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.execute(key, swaps, 0, "");
        assertEq(_accountingDigest(), beforeState, "failed settlement must undo automatic payment and swap");
        _assertSettled();
        assertEq(hook.payout(), fee, "the rolled-back burn must leave claims redeemable");
        _executeAndCheck(swaps, 5, "", true);
    }

    function test_unsettledTripObservationDoesNotPersistOrDestroyOldClaims() public {
        uint256 fee = _executeAndCheck(_singleSwap(2 ether, true, true), 1, "", true);
        canary.setTripped(true);
        bytes32 beforeState = _accountingDigest();
        SwapParams[] memory swaps = _singleSwap(1 ether, true, true);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.execute(key, swaps, 0, "");
        assertEq(_accountingDigest(), beforeState);
        assertFalse(hook.retired(), "reverted transaction cannot latch a trip");
        _executeAndCheck(swaps, 5, "", false);
        assertTrue(hook.retired());
        assertEq(bounty.balance, fee, "pre-trip claims still belong to the bounty");
    }

    function test_failedSecondSwapRollsBackFirstAndClearsTransientAccounting() public {
        _executeAndCheck(_singleSwap(2 ether, true, true), 1, "", true);
        bytes32 beforeState = _accountingDigest();
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = SwapParams(true, -1 ether, _wideLimit(true));
        swaps[1] = SwapParams(false, 0, _wideLimit(false));
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.execute(key, swaps, 5, "");
        assertEq(_accountingDigest(), beforeState);
        _assertSettled();
        _executeAndCheck(_singleSwap(1 ether, false, true), 5, "", true);
    }

    function test_zeroAmountNeverAccruesOrRetires() public {
        canary.setTripped(true);
        for (uint256 mode; mode < 4; ++mode) {
            SwapParams[] memory swaps = _singleSwap(0, mode < 2, mode % 2 == 0);
            bytes32 beforeState = _accountingDigest();
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
            router.execute(key, swaps, 1, "");
            assertEq(_accountingDigest(), beforeState);
        }
        assertFalse(hook.retired());
    }

    function test_claimBurnCannotBeUsedToStealBountyDuringUnlock() public {
        uint256 fee = _executeAndCheck(_singleSwap(2 ether, true, true), 1, "", true);
        CanaryClaimBurnAttacker attacker = new CanaryClaimBurnAttacker(manager, hook);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        attacker.steal(fee);
        assertEq(hook.accruedFees(), fee);
        assertEq(address(attacker).balance, 0);
        assertFalse(manager.isOperator(address(hook), address(attacker)));
        assertEq(manager.allowance(address(hook), address(attacker), 0), 0);
        assertEq(hook.payout(), fee);
        assertEq(bounty.balance, fee);
        _assertSettled();
    }

    function test_revertingRecipientPreservesClaimsAcrossLockedAndUnlockedPayouts() public {
        receiver.configure(hook, 1);
        uint256 total = _executeAndCheck(_singleSwap(2 ether, true, true), 7, "", true);
        assertEq(router.paidAfterSettlement(), 0);
        for (uint256 mode; mode < 4; ++mode) {
            total += _executeAndCheck(_singleSwap(0.1 ether, mode < 2, mode % 2 == 0), 7, "", true);
            assertEq(router.paidBeforeSettlement(), 0);
            assertEq(router.paidAfterSettlement(), 0);
            assertEq(hook.payout(), 0);
            assertEq(hook.accruedFees(), total);
        }
        assertEq(bounty.balance, 0);
        receiver.configure(hook, 0);
        assertEq(hook.payout(), total);
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, total);
    }

    function test_tripEmitsRetirementAndOracleIsNeverReadAgain() public {
        _executeAndCheck(_singleSwap(2 ether, true, true), 1, "", true);
        canary.setTripped(true);
        vm.expectEmit(false, false, false, true, address(hook));
        emit QuantumCanaryHook.Retired();
        _executeAndCheck(_singleSwap(1 ether, true, false), 5, "", false);
        canary.setTripped(false);
        vm.expectCall(address(canary), abi.encodeCall(IQuantumCanary.isTripped, ()), uint64(0));
        for (uint256 mode; mode < 4; ++mode) {
            _executeAndCheck(_singleSwap(0.1 ether, mode < 2, mode % 2 == 0), 5, "", false);
        }
        assertTrue(hook.retired());
    }

    function test_failedCanaryReadsKeepAllFourModesLiveAndFeeBearing() public {
        _executeAndCheck(_singleSwap(2 ether, true, true), 5, "", true);
        for (uint256 readMode = 1; readMode <= 5; ++readMode) {
            canary.setReadMode(readMode);
            for (uint256 mode; mode < 4; ++mode) {
                uint256 fee = _executeAndCheck(_singleSwap(0.01 ether, mode < 2, mode % 2 == 0), 5, "", true);
                assertGt(fee, 0);
                assertFalse(hook.retired());
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_spoofedManagerSenderDoesNotAuthorizeCallbacks(address caller, bytes32 data) public {
        vm.assume(caller != address(manager) && caller != address(hook) && caller != address(vm));
        SwapParams memory params = SwapParams(true, -1 ether, _wideLimit(true));
        bytes32 beforeState = _accountingDigest();
        vm.startPrank(caller);
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(manager), key, Q96);
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(manager), key, params, abi.encode(data));
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.afterSwap(address(manager), key, params, BalanceDelta.wrap(type(int256).max), abi.encode(data));
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(data));
        vm.expectRevert(QuantumCanaryHook.OnlySelf.selector);
        hook.redeemUnlocked();
        vm.expectRevert(QuantumCanaryHook.OnlySelf.selector);
        hook.quotePoolSwap(key, params);
        vm.stopPrank();
        assertEq(_accountingDigest(), beforeState);
    }

    function test_allEnabledCallbacksEnforceEveryPoolGuard() public {
        for (uint256 field; field < 5; ++field) {
            PoolKey memory invalid = key;
            if (field == 0) invalid.currency0 = Currency.wrap(address(token));
            if (field == 1) invalid.currency1 = Currency.wrap(address(0));
            if (field == 2) invalid.fee = 0x800000;
            if (field == 3) invalid.tickSpacing = 1;
            if (field == 4) invalid.hooks = IHooks(address(this));
            SwapParams memory params = SwapParams(true, -1 ether, _wideLimit(true));
            vm.startPrank(address(manager));
            vm.expectRevert(QuantumCanaryHook.UnsupportedPool.selector);
            hook.beforeInitialize(address(this), invalid, Q96);
            vm.expectRevert(QuantumCanaryHook.UnsupportedPool.selector);
            hook.beforeSwap(address(this), invalid, params, "");
            vm.expectRevert(QuantumCanaryHook.UnsupportedPool.selector);
            hook.afterSwap(address(this), invalid, params, BalanceDelta.wrap(0), "");
            vm.stopPrank();
        }
        _executeAndCheck(_singleSwap(1 ether, true, true), 5, "", true);
    }

    function test_constructorRejectsMissingDependenciesAndUnpayableDestinations() public {
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(IPoolManager(address(0)), canary);
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, IQuantumCanary(address(0)));
        canary.setDestination(address(0));
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, canary);
        canary.setDestination(address(manager));
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, canary);
        CallerDestinationCanary selfDestination = new CallerDestinationCanary();
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, selfDestination);
    }

    function test_constructorBubblesMissingDestinationInsteadOfInventingOne() public {
        vm.mockCallRevert(address(canary), abi.encodeCall(IQuantumCanary.canaryAddress, ()), "unavailable destination");
        vm.expectRevert(bytes("unavailable destination"));
        new QuantumCanaryHook(manager, canary);
    }

    function test_constructorRefusesAnAddressWithWrongPermissionBits() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != hook.HOOK_FLAGS());
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new QuantumCanaryHook(manager, canary);
    }

    function _accountingDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 feeGrowth0, uint256 feeGrowth1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                feeGrowth0,
                feeGrowth1,
                address(manager).balance,
                token.balanceOf(address(manager)),
                address(router).balance,
                token.balanceOf(address(router)),
                bounty.balance,
                hook.accruedFees(),
                hook.retired()
            )
        );
    }
}
