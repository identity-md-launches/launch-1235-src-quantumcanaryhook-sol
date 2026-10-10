// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {QuantumCanaryTestBase} from "./QuantumCanaryHook.t.sol";

/// @dev Compare against an ordinary v4 pool with the same starting state. In particular, a
/// reverting quote must not execute the trade twice, grow LP fees twice or leave tick changes.
contract QuantumCanaryDifferentialTest is QuantumCanaryTestBase {
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FEE_EVENT = keccak256("FeeAccrued(bytes32,uint256)");
    bytes32 internal constant PAID_EVENT = keccak256("BountyPaid(address,uint256)");

    function setUp() public override {
        super.setUp();
        _liquidity(-1200, -900, int256(LIQUIDITY / 2));
        _liquidity(900, 1200, int256(LIQUIDITY / 2));
        PoolKey memory original = key;
        key.hooks = IHooks(address(0));
        manager.initialize(key, Q96);
        _liquidity(-600, 600, int256(LIQUIDITY));
        _liquidity(-1200, -900, int256(LIQUIDITY / 2));
        _liquidity(900, 1200, int256(LIQUIDITY / 2));
        key = original;
        manager.setProtocolFeeController(address(this));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quotesAndFeesMatchUnhookedPool(
        uint256 amount,
        bool buy,
        bool exactInput,
        uint24 distance,
        uint16 protocolRate
    ) public {
        amount = bound(amount, 1, 10_000 ether);
        distance = uint24(bound(distance, 1, 1800));
        protocolRate = uint16(bound(protocolRate, 0, 1000));
        _setProtocolFee(protocolRate);
        _compareSwap(amount, buy, exactInput, _limit(buy, distance), true);
    }

    function test_exhaustionAcrossLiquidityGapsInEveryMode() public {
        _setProtocolFee(1000);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            bool buy = mode < 2;
            (BalanceDelta delta, uint256 fee) = _compareSwap(10_000 ether, buy, mode % 2 == 0, _limit(buy, 1500), true);
            assertGt(fee, 0);
            assertLt(_abs(buy == (mode % 2 == 0) ? delta.amount0() : delta.amount1()), 10_000 ether);
            assertEq(manager.getLiquidity(key.toId()), 0, "all three ranges crossed");
            vm.revertToState(snapshot);
        }
    }

    function test_noLiquidityMeansNoTradeAndNoBountyFee() public {
        _removeAllLiquidity();
        PoolKey memory original = key;
        key.hooks = IHooks(address(0));
        _removeAllLiquidity();
        key = original;
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            (BalanceDelta delta, uint256 fee) =
                _compareSwap(1 ether, mode < 2, mode % 2 == 0, _limit(mode < 2, 1500), true);
            assertEq(BalanceDelta.unwrap(delta), 0, "empty pool must not consume input");
            assertEq(fee, 0, "unfilled request must not pay a hook fee");
            vm.revertToState(snapshot);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_retiredSwapsExactlyMatchUnhookedPool(uint256 amount, bool buy, bool exactInput) public {
        amount = bound(amount, 1, 10_000 ether);
        canary.setTripped(true);
        _setProtocolFee(777);
        _compareSwap(amount, buy, exactInput, _limit(buy, 1500), false);
        assertTrue(hook.retired(), "the first true observation must latch retirement");
        // Refill / reset of the observer cannot reactivate the hook or its quoting path.
        canary.setTripped(false);
        canary.setReadMode(1);
        _compareSwap(amount, !buy, !exactInput, _limit(!buy, 1500), false);
        assertTrue(hook.retired());
    }

    function test_roundTripsAcrossTickBoundariesDoNotLeakQuoteState() public {
        _setProtocolFee(999);
        for (uint256 i; i < 8; ++i) {
            bool buy = i % 2 == 0;
            _compareSwap(4000 ether, buy, i % 4 < 2, _limit(buy, 1500), true);
        }
    }

    function _setProtocolFee(uint24 rate) internal {
        uint24 packed = rate | (rate << 12);
        manager.setProtocolFee(key, packed);
        PoolKey memory referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.setProtocolFee(referenceKey, packed);
    }

    function _compareSwap(uint256 amount, bool buy, bool exactInput, uint160 limit, bool feesEnabled)
        internal
        returns (BalanceDelta actual, uint256 fee)
    {
        uint256 obligationsBefore = hook.accruedFees() + bounty.balance;
        uint256[2] memory protocolBefore = _protocolBalances();
        vm.recordLogs();
        actual = _swap(buy, exactInput, amount, limit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        fee = hook.accruedFees() + bounty.balance - obligationsBefore;
        uint256[2] memory protocolAfter = _protocolBalances();
        _assertEvents(logs, actual, fee);

        // The observed hook fee adjusts only the ETH-specified amount supplied to the AMM.
        // The fee is checked independently below against the actual ETH side of the trade.
        uint256 coreAmount = amount;
        if (buy == exactInput) coreAmount = exactInput ? amount - fee : amount + fee;
        PoolKey memory original = key;
        key.hooks = IHooks(address(0));
        BalanceDelta referenceDelta = _swap(buy, exactInput, coreAmount, limit);
        bytes32 referenceState = _stateDigest(key);
        key = original;

        assertEq(actual.amount0(), int256(referenceDelta.amount0()) - int256(fee), "only ETH may fund bounty");
        assertEq(actual.amount1(), referenceDelta.amount1(), "CANARY delta must match the ordinary pool");
        uint256 expectedFee = feesEnabled ? (buy ? _abs(actual.amount0()) : _abs(referenceDelta.amount0())) / 100 : 0;
        assertEq(fee, expectedFee, "flat 1% of the actual ETH side");
        assertEq(_stateDigest(key), referenceState, "quote must roll back all pool state and LP fee growth");
        uint256[2] memory protocolFinal = _protocolBalances();
        for (uint256 i; i < 2; ++i) {
            assertEq(
                protocolAfter[i] - protocolBefore[i], protocolFinal[i] - protocolAfter[i], "protocol fee charged once"
            );
        }
        hook.payout();
        assertEq(hook.accruedFees(), 0, "all earned fees are redeemable");
        assertEq(bounty.balance, obligationsBefore + fee, "all fees reach only the immutable bounty");
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function _assertEvents(Vm.Log[] memory logs, BalanceDelta actual, uint256 fee) internal view {
        uint256 swaps;
        uint256 accrued;
        uint256 paid;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == address(manager) && entry.topics[0] == SWAP_EVENT) {
                // recordLogs also captures logs from reverted subcalls, unlike a transaction
                // receipt. Quote rollback is checked with the complete state digest below.
                if (address(uint160(uint256(entry.topics[2]))) == address(hook)) continue;
                ++swaps;
                assertEq(entry.topics[1], PoolId.unwrap(key.toId()));
                assertEq(address(uint160(uint256(entry.topics[2]))), address(this));
                (int128 eth, int128 canaryAmount,,,,) =
                    abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(int256(eth) - int256(fee), actual.amount0());
                assertEq(canaryAmount, actual.amount1());
            } else if (entry.emitter == address(hook) && entry.topics[0] == FEE_EVENT) {
                assertEq(entry.topics[1], PoolId.unwrap(key.toId()));
                accrued += abi.decode(entry.data, (uint256));
            } else if (entry.emitter == address(hook) && entry.topics[0] == PAID_EVENT) {
                assertEq(address(uint160(uint256(entry.topics[1]))), bounty);
                paid += abi.decode(entry.data, (uint256));
            }
        }
        assertEq(swaps, 1, "one executed swap from the router");
        assertEq(accrued, fee, "accrual events must describe real claims");
        assertEq(paid, fee, "funded pool must attempt automatic payout");
    }

    function _stateDigest(PoolKey memory pool) internal view returns (bytes32 digest) {
        PoolId id = pool.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(id);
        digest = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(id)));
        int24[6] memory ticks = [int24(-1200), -900, -600, 600, 900, 1200];
        for (uint256 i; i < ticks.length; ++i) {
            (uint128 gross, int128 net, uint256 outside0, uint256 outside1) = manager.getTickInfo(id, ticks[i]);
            digest = keccak256(abi.encode(digest, gross, net, outside0, outside1));
        }
    }

    function _protocolBalances() internal view returns (uint256[2] memory balances) {
        balances[0] = manager.protocolFeesAccrued(key.currency0);
        balances[1] = manager.protocolFeesAccrued(key.currency1);
    }

    function _removeAllLiquidity() internal {
        _liquidity(-600, 600, -int256(LIQUIDITY));
        _liquidity(-1200, -900, -int256(LIQUIDITY / 2));
        _liquidity(900, 1200, -int256(LIQUIDITY / 2));
    }

    function _limit(bool buy, uint24 distance) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(buy ? -int24(distance) : int24(distance));
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return uint256(value < 0 ? -int256(value) : int256(value));
    }
}
