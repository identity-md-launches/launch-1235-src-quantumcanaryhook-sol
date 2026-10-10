// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {QuantumCanaryHook} from "../src/QuantumCanaryHook.sol";
import {QuantumCanaryToken} from "../src/QuantumCanaryToken.sol";
import {IQuantumCanary} from "../src/IQuantumCanary.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockCanary, ToggleReceiver} from "./mocks/MockCanary.sol";
import {QuantumCanary} from "./mocks/QuantumCanaryObserver.sol";

/// @dev Uses the real vendored PoolManager and AMM math, not a manager mock.
abstract contract QuantumCanaryTestBase is Test {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint256 internal constant LIQUIDITY = 100_000 ether;
    IPoolManager internal manager;
    QuantumCanaryHook internal hook;
    QuantumCanaryToken internal token;
    MockCanary internal canary;
    PoolKey internal key;
    address internal bounty;
    uint256 internal claimsBeforeRouterSettlement;
    bool internal payoutAfterSettlement;
    bool internal drainBountyBeforeRouterPayout;

    function setUp() public virtual {
        vm.deal(address(this), 10_000_000 ether);
        bounty = makeAddr("unknown-private-key canary (local fixture)");
        token = new QuantumCanaryToken();
        _deploy(false, bounty);
    }

    receive() external payable {}

    function _deploy(bool tokenOnly, address destination) internal {
        manager = IPoolManager(address(new PoolManager(address(this))));
        canary = new MockCanary(destination);
        hook = _mine(manager, canary);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        _liquidity(-600, tokenOnly ? int24(-60) : int24(600), int256(LIQUIDITY));
    }

    function _mine(IPoolManager target, IQuantumCanary oracle) internal returns (QuantumCanaryHook deployed) {
        bytes memory init = abi.encodePacked(type(QuantumCanaryHook).creationCode, abi.encode(target, oracle));
        bytes32 hash = keccak256(init);
        for (uint256 i; i < 200_000; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (HookFlags.matches(predicted, 0x20cc)) {
                deployed = new QuantumCanaryHook{salt: bytes32(i)}(target, oracle);
                assertEq(address(deployed), predicted);
                return deployed;
            }
        }
        revert("no CREATE2 salt");
    }

    function _liquidity(int24 lower, int24 upper, int256 amount) internal returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(false, ModifyLiquidityParams(lower, upper, amount, bytes32(0)))), (BalanceDelta)
        );
    }

    function _swap(bool buy, bool exactInput, uint256 amount, uint160 limit) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams(buy, exactInput ? -int256(amount) : int256(amount), limit);
        return abi.decode(manager.unlock(abi.encode(true, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        bool swapping = abi.decode(data, (bool));
        BalanceDelta delta;
        if (swapping) {
            (, SwapParams memory params) = abi.decode(data, (bool, SwapParams));
            delta = manager.swap(key, params, "arbitrary hookData is ignored");
            claimsBeforeRouterSettlement = hook.accruedFees();
        } else {
            (, ModifyLiquidityParams memory params) = abi.decode(data, (bool, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        if (swapping && payoutAfterSettlement) {
            // Models a bounty drained after the swap's callbacks ran but before the router's payout.
            if (drainBountyBeforeRouterPayout) vm.deal(bounty, 0);
            hook.payout();
        }
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0, "unsettled ETH hook debt");
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0, "unsettled token hook debt");
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(-int256(amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                token.transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        }
    }

    /// @dev Measures value conservation independently of the fee implementation's formulas.
    function _checkSwap(bool buy, bool exactInput, uint256 amount, uint160 limit)
        internal
        returns (BalanceDelta delta, uint256 fee)
    {
        uint256 bountyBefore = hook.canaryAddress().balance;
        uint256 claimsBefore = hook.accruedFees();
        uint256 userETH = address(this).balance;
        uint256 userTokens = token.balanceOf(address(this));
        uint256 poolETH = address(manager).balance;
        uint256 poolTokens = token.balanceOf(address(manager));
        delta = _swap(buy, exactInput, amount, limit);
        uint256 paid = hook.canaryAddress().balance - bountyBefore;
        fee = paid + hook.accruedFees() - claimsBefore;
        if (buy) {
            uint256 spent = userETH - address(this).balance;
            assertEq(spent, uint256(-int256(delta.amount0())));
            assertEq(fee, hook.retired() ? 0 : spent / 100, "buy: 1% of total ETH paid");
            assertEq(address(manager).balance + paid, poolETH + spent, "ETH conservation");
            assertEq(token.balanceOf(address(this)) - userTokens, uint256(int256(delta.amount1())));
            assertEq(poolTokens - token.balanceOf(address(manager)), uint256(int256(delta.amount1())), "no token fee");
        } else {
            uint256 received = address(this).balance - userETH;
            assertEq(received, uint256(int256(delta.amount0())));
            assertEq(fee, hook.retired() ? 0 : (received + fee) / 100, "sell: 1% of gross ETH output");
            assertEq(address(manager).balance + paid + received, poolETH, "ETH conservation");
            assertEq(userTokens - token.balanceOf(address(this)), uint256(-int256(delta.amount1())));
            assertEq(token.balanceOf(address(manager)) - poolTokens, uint256(-int256(delta.amount1())), "no token fee");
        }
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(manager.allowance(address(hook), address(this), 0), 0);
        assertFalse(manager.isOperator(address(hook), address(this)));
    }

    function _wideLimit(bool buy) internal pure returns (uint160) {
        return buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}

contract QuantumCanaryHookTest is QuantumCanaryTestBase {
    using StateLibrary for IPoolManager;

    function test_exactInputBuyPaysExactlyOnePercent() public {
        (BalanceDelta d, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(d.amount0(), -1 ether);
        assertEq(fee, 0.01 ether);
        assertEq(bounty.balance, fee);
        assertEq(hook.accruedFees(), 0);
    }

    function test_exactOutputBuyPaysExactlyOnePercent() public {
        (BalanceDelta d, uint256 fee) = _checkSwap(true, false, 1 ether, _wideLimit(true));
        assertEq(d.amount1(), 1 ether);
        assertGt(fee, 0);
        assertEq(bounty.balance, fee);
    }

    function test_exactInputSellPaysExactlyOnePercent() public {
        (BalanceDelta d, uint256 fee) = _checkSwap(false, true, 1 ether, _wideLimit(false));
        assertEq(d.amount1(), -1 ether);
        assertGt(fee, 0);
        assertEq(bounty.balance, fee);
    }

    function test_exactOutputSellPreservesNetOutput() public {
        (BalanceDelta d, uint256 fee) = _checkSwap(false, false, 1 ether, _wideLimit(false));
        assertEq(d.amount0(), 1 ether);
        assertEq(fee, uint256(1 ether) / 99);
        assertEq(bounty.balance, fee);
    }

    function test_partialFillsAllFourModesChargeOnlyTheFilledETH() public {
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            uint160 limit = TickMath.getSqrtPriceAtTick(buy ? int24(-60) : int24(60));
            (BalanceDelta d, uint256 fee) = _checkSwap(buy, exactInput, 1_000 ether, limit);
            assertGt(fee, 0);
            int128 specified = buy == exactInput ? d.amount0() : d.amount1();
            assertLt(uint256(specified < 0 ? -int256(specified) : int256(specified)), 1_000 ether);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, limit);
            vm.revertToState(snap);
        }
    }

    function test_freshTokenOnlyPoolAccruesThenAnyonePays() public {
        _deploy(true, bounty);
        assertEq(address(manager).balance, 0, "genuinely token-only manager");
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(claimsBeforeRouterSettlement, fee);
        assertEq(hook.accruedFees(), fee);
        assertEq(bounty.balance, 0);
        address stranger = makeAddr("permissionless caller");
        vm.prank(stranger);
        assertEq(hook.payout(), fee);
        assertEq(bounty.balance, fee);
        assertEq(hook.accruedFees(), 0);
        assertEq(stranger.balance, 0);
        assertEq(hook.payout(), 0, "idempotent payout");
    }

    function test_payoutInsideRouterUnlockAfterSettlement() public {
        _deploy(true, bounty);
        payoutAfterSettlement = true;
        (, uint256 fee) = _checkSwap(true, false, 1 ether, _wideLimit(true));
        assertGt(claimsBeforeRouterSettlement, 0);
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, fee);
    }

    function test_laterSwapAutomaticallyPaysEarlierClaims() public {
        _deploy(true, bounty);
        (, uint256 firstFee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(hook.accruedFees(), firstFee);
        (, uint256 secondFee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, firstFee + secondFee);
    }

    function test_freshTokenOnlyPoolSupportsAllFourModes() public {
        _deploy(true, bounty);
        _checkSwap(true, true, 2 ether, _wideLimit(true));
        _checkSwap(true, false, 0.1 ether, _wideLimit(true));
        _checkSwap(false, true, 0.1 ether, _wideLimit(false));
        _checkSwap(false, false, 0.1 ether, _wideLimit(false));
        hook.payout();
        assertEq(hook.accruedFees(), 0);
        assertGt(bounty.balance, 0);
    }

    function test_claimsCannotBeTransferredByAnyoneElse() public {
        _deploy(true, bounty);
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        address thief = makeAddr("claim thief");
        vm.prank(thief);
        vm.expectRevert();
        manager.transferFrom(address(hook), thief, 0, fee);
        assertEq(hook.accruedFees(), fee);
        assertEq(manager.balanceOf(thief, 0), 0);
        vm.prank(thief);
        hook.payout();
        assertEq(bounty.balance, fee);
        assertEq(thief.balance, 0);
    }

    function test_partialPayoutPreservesRemainingClaims() public {
        _deploy(true, bounty);
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        uint256 backedBalance = address(manager).balance;
        // Artificially model a manager with less liquid ETH than this hook's claims.
        vm.deal(address(manager), fee / 2);
        assertEq(hook.payout(), fee / 2);
        assertEq(hook.accruedFees(), fee - fee / 2);
        assertEq(bounty.balance, fee / 2);
        assertEq(hook.payout(), 0);
        vm.deal(address(manager), backedBalance - fee / 2);
        assertEq(hook.payout(), fee - fee / 2);
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, fee);
    }

    function test_tripDoesNotStrandPreviouslyAccruedFees() public {
        _deploy(true, bounty);
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        canary.setTripped(true);
        (, uint256 nextFee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(nextFee, 0);
        assertTrue(hook.retired());
        hook.payout();
        assertEq(bounty.balance, fee);
        assertEq(hook.accruedFees(), 0);
    }

    function test_noAdministrativeOrWithdrawalInterfaceExists() public {
        bytes[9] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("setFee(uint256)", 0),
            abi.encodeWithSignature("setRecipient(address)", address(this)),
            abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("approve(address,uint256)", address(this), type(uint256).max)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
        (bool acceptsETH,) = address(hook).call{value: 1}("");
        assertFalse(acceptsETH);
    }

    function test_weiRoundingBoundariesDoNotOvercharge() public {
        uint256[8] memory amounts = [uint256(1), 98, 99, 100, 101, 198, 199, 200];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 mode; mode < 4; ++mode) {
                _checkSwap(mode < 2, mode % 2 == 0, amounts[i], _wideLimit(mode < 2));
            }
        }
    }

    function test_failedPayoutDoesNotRevertAnySwapMode() public {
        ToggleReceiver receiver = new ToggleReceiver();
        _deploy(false, address(receiver));
        receiver.configure(hook, 1);
        uint256 sum;
        for (uint256 mode; mode < 4; ++mode) {
            (, uint256 fee) = _checkSwap(mode < 2, mode % 2 == 0, 1 ether, _wideLimit(mode < 2));
            sum += fee;
        }
        assertEq(hook.accruedFees(), sum);
        assertEq(hook.payout(), 0);
        assertEq(hook.accruedFees(), sum, "failed burn and transfer rolled back");
        receiver.configure(hook, 0);
        assertEq(hook.payout(), sum);
        assertEq(address(receiver).balance, sum);
        assertEq(hook.accruedFees(), 0);
    }

    function test_gasExhaustingRecipientDoesNotBlockSwap() public {
        ToggleReceiver receiver = new ToggleReceiver();
        _deploy(false, address(receiver));
        receiver.configure(hook, 2);
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(hook.accruedFees(), fee);
        receiver.configure(hook, 0);
        assertEq(hook.payout(), fee);
    }

    function test_recipientCannotReenterPayout() public {
        ToggleReceiver receiver = new ToggleReceiver();
        _deploy(false, address(receiver));
        receiver.configure(hook, 3);
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(address(receiver).balance, fee);
        assertEq(receiver.reentrantPaid(), 0);
        assertEq(hook.accruedFees(), 0);
    }

    /// @dev The protected floor CREATE2-deploys the attested creation code, with the launch's literal
    /// observer baked in, on a chain where nothing lives at that address.
    function test_attestedCreationCodeDeploysWithNoCodeAtTheLaunchObserver() public {
        address observer = hook.LAUNCH_OBSERVER();
        assertEq(observer.code.length, 0, "fixture: empty chain");
        QuantumCanaryHook deployed = _mine(manager, IQuantumCanary(observer));
        assertEq(address(deployed.quantumCanary()), observer);
        assertEq(deployed.canaryAddress(), hook.LAUNCH_CANARY_ADDRESS());
        assertFalse(deployed.retired());
    }

    /// @dev The fallback constant is not a guess: the observer's own source derives it from its seed phrase.
    function test_launchDestinationMatchesTheObserverSourceDerivation() public {
        QuantumCanary observer = new QuantumCanary(1 ether);
        assertEq(observer.canaryAddress(), hook.LAUNCH_CANARY_ADDRESS());
        QuantumCanaryHook deployed = _mine(manager, IQuantumCanary(address(observer)));
        assertEq(deployed.canaryAddress(), hook.LAUNCH_CANARY_ADDRESS(), "read answer agrees with the constant");
    }

    function test_constructorRejectsUnknownEmptyOrBrokenObservers() public {
        address unknownEmpty = makeAddr("observer with no code that is not the launch observer");
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, IQuantumCanary(unknownEmpty));

        MockCanary broken = new MockCanary(bounty);
        vm.mockCallRevert(address(broken), abi.encodeCall(IQuantumCanary.canaryAddress, ()), "unavailable");
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, IQuantumCanary(address(broken)));
        vm.clearMockedCalls();

        MockCanary silent = new MockCanary(bounty);
        vm.mockCall(address(silent), abi.encodeCall(IQuantumCanary.canaryAddress, ()), "");
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, IQuantumCanary(address(silent)));
        vm.clearMockedCalls();

        MockCanary zero = new MockCanary(address(0));
        vm.expectRevert(QuantumCanaryHook.InvalidAddress.selector);
        new QuantumCanaryHook(manager, IQuantumCanary(address(zero)));
    }

    /// @dev The live observer's alarm is a balance predicate, not a latch: paying the bounty can clear
    /// it. A trip must be latched before the hook's own transfer, on the standalone payout path.
    function test_payoutLatchesTheTripBeforeItsRefillClearsTheLiveAlarm() public {
        QuantumCanary observer = _deployWithLiveObserver();
        _swap(true, true, 100 ether, _wideLimit(true));
        assertEq(hook.accruedFees(), 1 ether, "token-only manager: claims pending");

        vm.deal(bounty, 0);
        assertTrue(observer.isTripped());
        assertEq(hook.payout(), 1 ether);
        assertFalse(observer.isTripped(), "the refill cleared the live alarm");
        assertTrue(hook.retired(), "but the trip was latched first");

        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(fee, 0);
        assertEq(bounty.balance, 1 ether);
    }

    /// @dev Same race on the in-unlock path: a router calling payout() after settling its input.
    function test_payoutInsideRouterUnlockAlsoLatchesTheTripFirst() public {
        QuantumCanary observer = _deployWithLiveObserver();
        // Token-only manager: afterSwap cannot pay, so 1 ETH of claims is pending when the router,
        // having settled its input, finds the bounty drained and calls payout() inside its unlock.
        payoutAfterSettlement = true;
        drainBountyBeforeRouterPayout = true;
        _swap(true, true, 100 ether, _wideLimit(true));
        assertTrue(hook.retired(), "latched by the in-unlock payout, after both swap callbacks saw no trip");
        assertFalse(observer.isTripped(), "the refill cleared the live alarm");
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, 1 ether);
        drainBountyBeforeRouterPayout = false;
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(fee, 0);
    }

    function _deployWithLiveObserver() internal returns (QuantumCanary observer) {
        observer = new QuantumCanary(1 ether);
        bounty = observer.canaryAddress();
        vm.deal(bounty, 1 ether);
        observer.poke();
        assertFalse(observer.isTripped());
        manager = IPoolManager(address(new PoolManager(address(this))));
        hook = _mine(manager, IQuantumCanary(address(observer)));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        _liquidity(-600, -60, int256(LIQUIDITY));
        assertEq(address(manager).balance, 0);
    }

    /// @dev Core accepts the most negative exact-input budget as "buy up to the price limit".
    function test_minimumSignedExactInputBuyFillsToThePriceLimit() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-60);
        uint256 ethBefore = address(this).balance;
        BalanceDelta d =
            abi.decode(manager.unlock(abi.encode(true, SwapParams(true, type(int256).min, limit))), (BalanceDelta));
        uint256 spent = ethBefore - address(this).balance;
        assertEq(spent, uint256(-int256(d.amount0())));
        assertGt(spent, 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        assertEq(bounty.balance + hook.accruedFees(), spent / 100, "1% of the ETH actually paid");
    }

    /// @dev Core accepts a saturating exact-output request as "sell up to the price limit". Core's own
    /// checked addition of the hook delta needs the request to leave room for the fee itself.
    function test_saturatingExactOutputSellFillsToThePriceLimit() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(60);
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = abi.decode(
            manager.unlock(abi.encode(true, SwapParams(false, type(int256).max - 1e30, limit))), (BalanceDelta)
        );
        uint256 received = address(this).balance - ethBefore;
        assertEq(received, uint256(int256(d.amount0())));
        assertGt(received, 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        uint256 fee = bounty.balance + hook.accruedFees();
        assertEq(fee, (received + fee) / 100, "1% of the gross ETH actually received");
    }

    function test_immutableDestinationEvenIfMockChangesItsAnswer() public {
        address thief = makeAddr("thief");
        canary.setDestination(thief);
        (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(hook.canaryAddress(), bounty);
        assertEq(bounty.balance, fee);
        assertEq(thief.balance, 0);
    }

    function test_retirementIsPermanentAllFourModesAreUntouched() public {
        canary.setTripped(true);
        for (uint256 mode; mode < 4; ++mode) {
            (BalanceDelta d, uint256 fee) = _checkSwap(mode < 2, mode % 2 == 0, 1 ether, _wideLimit(mode < 2));
            assertEq(fee, 0);
            assertEq(
                mode < 2 == (mode % 2 == 0) ? d.amount0() : d.amount1(),
                mode % 2 == 0 ? -int128(1 ether) : int128(1 ether)
            );
        }
        assertTrue(hook.retired());
        canary.setTripped(false);
        canary.setReadMode(1);
        (, uint256 feeAfter) = _checkSwap(true, true, 1 ether, _wideLimit(true));
        assertEq(feeAfter, 0);
        assertEq(bounty.balance, 0);
    }

    function test_badTripReadsNeverBlockSwapsAndDoNotRetire() public {
        for (uint256 mode = 1; mode <= 5; ++mode) {
            canary.setReadMode(mode);
            (, uint256 fee) = _checkSwap(true, true, 1 ether, _wideLimit(true));
            assertEq(fee, 0.01 ether);
            assertFalse(hook.retired());
        }
    }

    function test_callbacksAndSelfHelpersRejectUnauthorizedCallers() public {
        SwapParams memory params = SwapParams(true, -1 ether, _wideLimit(true));
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(QuantumCanaryHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(QuantumCanaryHook.OnlySelf.selector);
        hook.redeemUnlocked();
        vm.expectRevert(QuantumCanaryHook.OnlySelf.selector);
        hook.quotePoolSwap(key, params);
        vm.prank(address(manager));
        vm.expectRevert(QuantumCanaryHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_declaredPermissionsExactlyMatchMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(HookFlags.flagsOf(address(hook)), hook.HOOK_FLAGS());
    }

    function test_runtimeHasNoDelegatecallSelfdestructOrCallcode() public view {
        _checkRuntime(address(hook).code);
        _checkRuntime(address(token).code);
    }

    function _checkRuntime(bytes memory runtime) internal pure {
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xff && opcode != 0xf2);
        }
    }

    function test_policyPoolInitializesAndBadPoolsAreRefused() public {
        PoolKey memory bad = key;
        bad.fee = 3_000;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.fee = 12_500;
        bad.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.tickSpacing = 60;
        bad.currency0 = Currency.wrap(makeAddr("ERC20 pair"));
        bad.currency1 = Currency.wrap(address(type(uint160).max));
        vm.expectRevert();
        manager.initialize(bad, Q96);
    }

    function test_badPriceLimitRevertsWithoutAccruingFees() public {
        SwapParams memory params = SwapParams(true, -1 ether, Q96 + 1);
        vm.expectRevert();
        manager.unlock(abi.encode(true, params));
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allFourModesConserveValue(uint256 size, bool buy, bool exactInput) public {
        size = bound(size, 100, 10 ether);
        (BalanceDelta d,) = _checkSwap(buy, exactInput, size, _wideLimit(buy));
        int128 specified = buy == exactInput ? d.amount0() : d.amount1();
        assertEq(specified, exactInput ? -int256(size) : int256(size));
        hook.payout();
        assertEq(hook.accruedFees(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialFills(uint256 size, bool buy, bool exactInput, uint24 tickDistance) public {
        size = bound(size, 1, 1_000 ether);
        tickDistance = uint24(bound(tickDistance, 1, 300));
        int24 tick = buy ? -int24(tickDistance) : int24(tickDistance);
        _checkSwap(buy, exactInput, size, TickMath.getSqrtPriceAtTick(tick));
    }
}
