// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {QuantumCanaryHook} from "../../src/QuantumCanaryHook.sol";
import {QuantumCanaryToken} from "../../src/QuantumCanaryToken.sol";
import {QuantumCanaryTestBase} from "../QuantumCanaryHook.t.sol";
import {ToggleReceiver} from "../mocks/MockCanary.sol";

/// @dev Prefunded test-only router. Settles the net debt after a whole batch, as v4 allows.
/// Flags: 1 = settle, 2 = payout before settlement, 4 = payout after settlement.
contract CanaryBatchRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    QuantumCanaryHook public immutable hook;
    QuantumCanaryToken public immutable token;
    uint256 public paidBeforeSettlement;
    uint256 public paidAfterSettlement;

    constructor(IPoolManager manager_, QuantumCanaryHook hook_, QuantumCanaryToken token_) {
        manager = manager_;
        hook = hook_;
        token = token_;
    }

    receive() external payable {}

    function execute(PoolKey memory key, SwapParams[] memory swaps, uint8 flags, bytes memory hookData)
        external
        returns (BalanceDelta[] memory)
    {
        return abi.decode(manager.unlock(abi.encode(key, swaps, flags, hookData)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "test router: only manager");
        (PoolKey memory key, SwapParams[] memory swaps, uint8 flags, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams[], uint8, bytes));
        BalanceDelta[] memory deltas = new BalanceDelta[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            deltas[i] = manager.swap(key, swaps[i], hookData);
        }
        paidBeforeSettlement = flags & 2 != 0 ? hook.payout() : 0;
        if (flags & 1 != 0) {
            _settle(key.currency0);
            _settle(key.currency1);
        }
        paidAfterSettlement = flags & 4 != 0 ? hook.payout() : 0;
        return abi.encode(deltas);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: uint256(-delta)}();
            } else {
                require(token.transfer(address(manager), uint256(-delta)));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }
}

contract CanaryClaimBurnAttacker is IUnlockCallback {
    IPoolManager internal immutable manager;
    QuantumCanaryHook internal immutable hook;

    constructor(IPoolManager manager_, QuantumCanaryHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function steal(uint256 amount) external {
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 amount = abi.decode(data, (uint256));
        manager.burn(address(hook), 0, amount);
        manager.take(Currency.wrap(address(0)), address(this), amount);
        return "";
    }

    receive() external payable {}
}

abstract contract CanaryScenario is QuantumCanaryTestBase {
    using TransientStateLibrary for IPoolManager;

    ToggleReceiver internal receiver;
    CanaryBatchRouter internal router;

    function setUp() public virtual override {
        vm.deal(address(this), 10_000_000 ether);
        token = new QuantumCanaryToken();
        receiver = new ToggleReceiver();
        bounty = address(receiver);
        _deploy(true, bounty);
        receiver.configure(hook, 0);
        router = new CanaryBatchRouter(manager, hook, token);
        vm.deal(address(router), 1_000_000 ether);
        token.transfer(address(router), 1_000_000 ether);
    }

    /// @dev Compute the expected bounty using the real AMM's Swap event and the actual user
    /// delta, not FeeAccrued or hook balances. Reverted quote logs have the hook as sender.
    function _executeAndCheck(SwapParams[] memory swaps, uint8 flags, bytes memory hookData, bool feesEnabled)
        internal
        returns (uint256 expectedFee)
    {
        uint256 obligationsBefore = hook.accruedFees() + bounty.balance;
        uint256 ethBefore = address(router).balance;
        uint256 tokensBefore = token.balanceOf(address(router));
        vm.recordLogs();
        BalanceDelta[] memory deltas = router.execute(key, swaps, flags, hookData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        expectedFee = _expectedFeesFromLogs(swaps, deltas, logs, feesEnabled);
        int256 ethDelta;
        int256 tokenDelta;
        for (uint256 i; i < deltas.length; ++i) {
            ethDelta += deltas[i].amount0();
            tokenDelta += deltas[i].amount1();
        }
        assertEq(int256(address(router).balance) - int256(ethBefore), ethDelta, "net native settlement");
        assertEq(int256(token.balanceOf(address(router))) - int256(tokensBefore), tokenDelta, "net token settlement");
        assertEq(
            hook.accruedFees() + bounty.balance, obligationsBefore + expectedFee, "claims plus bounty conservation"
        );
        _assertSettled();
    }

    function _expectedFeesFromLogs(
        SwapParams[] memory swaps,
        BalanceDelta[] memory deltas,
        Vm.Log[] memory logs,
        bool feesEnabled
    ) private view returns (uint256 expectedFee) {
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        uint256 index;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(manager) || entry.topics[0] != swapTopic) continue;
            if (address(uint160(uint256(entry.topics[2]))) != address(router)) continue;
            assertEq(entry.topics[1], PoolId.unwrap(key.toId()));
            (int128 coreETH, int128 coreToken,,,,) =
                abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            BalanceDelta delta = deltas[index];
            uint256 fee = feesEnabled
                ? (swaps[index].zeroForOne ? uint256(-int256(delta.amount0())) : uint256(int256(coreETH))) / 100
                : 0;
            assertEq(delta.amount0(), int256(coreETH) - int256(fee), "1% ETH fee per executed swap");
            assertEq(delta.amount1(), coreToken, "no CANARY fee in a batch");
            expectedFee += fee;
            ++index;
        }
        assertEq(index, swaps.length, "every swap must execute");
    }

    function _singleSwap(uint256 amount, bool buy, bool exactInput) internal pure returns (SwapParams[] memory swaps) {
        swaps = new SwapParams[](1);
        swaps[0] = SwapParams(buy, exactInput ? -int256(amount) : int256(amount), _wideLimit(buy));
    }

    function _assertSettled() internal view {
        assertFalse(manager.isUnlocked(), "unlock must close");
        assertEq(manager.getNonzeroDeltaCount(), 0, "no residual debt from quote or payout");
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
    }
}
