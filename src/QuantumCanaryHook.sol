// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IQuantumCanary} from "./IQuantumCanary.sol";

/// @notice Ownerless native-ETH fee hook with an immutable, exclusive bounty destination.
/// @dev Buy fee = floor(total ETH paid / 100); sell fee = floor(gross ETH output / 100).
///      ETH-specified swaps use a reverting core quote to account for partial fills.
contract QuantumCanaryHook is IUnlockCallback {
    using SafeCast for int256;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IQuantumCanary public immutable quantumCanary;
    address public immutable canaryAddress;

    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant HOOK_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    // External dependency gas is bounded so a broken canary or recipient cannot consume swap gas.
    uint256 private constant TRIP_READ_GAS = 30_000;
    uint256 private constant AUTO_PAYOUT_GAS = 120_000;
    // Transient storage is scoped to this contract; it has no inherited storage or delegatecalls.
    bytes32 private constant FEE_SLOT = bytes32(uint256(1));
    bytes32 private constant PAYING_SLOT = bytes32(uint256(2));

    bool public retired;

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidAddress();
    error UnsupportedPool();
    error PayoutInProgress();
    error UnexpectedUnlock();
    error QuotedETH(int128 delta);
    error QuoteDidNotRevert();

    event FeeAccrued(bytes32 indexed poolId, uint256 ethAmount);
    event BountyPaid(address indexed destination, uint256 ethAmount);
    event Retired();

    constructor(IPoolManager manager, IQuantumCanary canary) {
        if (address(manager) == address(0) || address(canary) == address(0)) revert InvalidAddress();
        poolManager = manager;
        quantumCanary = canary;
        address destination = canary.canaryAddress();
        if (destination == address(0) || destination == address(this) || destination == address(manager)) {
            revert InvalidAddress();
        }
        canaryAddress = destination;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (_load(PAYING_SLOT) != 0) revert PayoutInProgress();
        _store(FEE_SLOT, 0);

        // The genuine core does not make any mutable external call between these two callbacks.
        // Check here as well as afterSwap: ETH-specified deltas must be fixed before the swap.
        _observeTrip();
        uint256 fee = 0;
        if (!retired && _ethIsSpecified(params)) {
            SwapParams memory quotedParams = params;
            if (params.zeroForOne) {
                // Exact-input ETH buy: reserve 1% of the user's maximum total payment.
                uint256 budget = uint256(-params.amountSpecified);
                uint256 reserved = budget / 100;
                quotedParams.amountSpecified += int256(reserved);
                uint256 used = uint256(-int256(_quoteETH(key, quotedParams)));
                fee = _min(reserved, used / 99);
            } else {
                // Exact-output ETH sell: requested output is NET of the bounty fee.
                uint256 reserved = uint256(params.amountSpecified) / 99;
                quotedParams.amountSpecified += int256(reserved);
                uint256 gross = uint256(int256(_quoteETH(key, quotedParams)));
                fee = _min(reserved, gross / 100);
            }
            _store(FEE_SLOT, fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int256(fee).toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        _observeTrip();
        uint256 fee = _load(FEE_SLOT);
        _store(FEE_SLOT, 0);
        int128 returnDelta = 0;
        if (!retired && !_ethIsSpecified(params)) {
            int128 ethDelta = delta.amount0();
            fee = params.zeroForOne ? uint256(-int256(ethDelta)) / 99 : uint256(int256(ethDelta)) / 100;
            returnDelta = int256(fee).toInt128();
        }
        if (fee != 0) {
            // This debit is cancelled by v4's positive ETH hook delta after the callback.
            // Minting claims never requires the router's ETH to have arrived already.
            poolManager.mint(address(this), 0, fee);
            emit FeeAccrued(PoolId.unwrap(key.toId()), fee);
        }
        _tryPayout();
        return (IHooks.afterSwap.selector, returnDelta);
    }

    /// @notice Claim balance in native ETH (ERC-6909 token id zero).
    function accruedFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), 0);
    }

    /// @notice Anyone can retry payment. Failure leaves the claims intact and returns zero.
    /// @dev Also works inside an existing manager unlock, without requesting a nested unlock.
    function payout() external returns (uint256 paid) {
        if (_load(PAYING_SLOT) != 0) return 0;
        uint256 beforeClaims = accruedFees();
        if (beforeClaims == 0 || address(poolManager).balance == 0) return 0;
        if (poolManager.isUnlocked()) {
            _tryPayout();
        } else {
            _store(PAYING_SLOT, 1);
            try poolManager.unlock("") {} catch {}
            _store(PAYING_SLOT, 0);
        }
        paid = beforeClaims - accruedFees();
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (_load(PAYING_SLOT) == 0) revert UnexpectedUnlock();
        _redeem();
        return "";
    }

    /// @dev Self-call boundary rolls back BOTH burn and take when the recipient rejects ETH.
    function redeemUnlocked() external onlySelf {
        if (_load(PAYING_SLOT) != 0) revert PayoutInProgress();
        _store(PAYING_SLOT, 1);
        _redeem();
        _store(PAYING_SLOT, 0);
    }

    function _redeem() private {
        uint256 amount = _min(accruedFees(), address(poolManager).balance);
        amount = _min(amount, uint256(uint128(type(int128).max)));
        if (amount == 0) return;
        poolManager.burn(address(this), 0, amount);
        // The ONLY outward asset transfer in this hook. No caller supplies its recipient.
        poolManager.take(Currency.wrap(address(0)), canaryAddress, amount);
        emit BountyPaid(canaryAddress, amount);
    }

    function _tryPayout() private {
        if (address(poolManager).balance == 0 || accruedFees() == 0) return;
        // Preserve callback/manager accounting gas when a recipient consumes its entire budget.
        if (gasleft() < AUTO_PAYOUT_GAS + 50_000) return;
        // No return-data allocation: even a recipient returning huge revert data is isolated.
        bytes memory data = abi.encodeCall(this.redeemUnlocked, ());
        address self = address(this);
        uint256 gasLimit = AUTO_PAYOUT_GAS;
        assembly ("memory-safe") {
            pop(call(gasLimit, self, 0, add(data, 32), mload(data), 0, 0))
        }
    }

    /// @dev No oracle state is changed. The revert rolls back core state, deltas and swap logs.
    ///      Core skips hook callbacks when msg.sender is the hook itself.
    function quotePoolSwap(PoolKey calldata key, SwapParams calldata params) external onlySelf {
        BalanceDelta quote = poolManager.swap(key, params, "");
        revert QuotedETH(quote.amount0());
    }

    function _quoteETH(PoolKey calldata key, SwapParams memory params) private returns (int128) {
        try this.quotePoolSwap(key, params) {
            revert QuoteDidNotRevert();
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == QuotedETH.selector) {
                int128 result;
                assembly ("memory-safe") {
                    result := mload(add(reason, 36))
                }
                return result;
            }
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _observeTrip() private {
        if (retired) return;
        address canary = address(quantumCanary);
        bytes memory data = abi.encodeCall(IQuantumCanary.isTripped, ());
        uint256 gasLimit = TRIP_READ_GAS;
        bool tripped;
        assembly ("memory-safe") {
            let out := mload(0x40)
            mstore(out, 0)
            let success := staticcall(gasLimit, canary, add(data, 32), mload(data), out, 32)
            tripped := and(and(success, eq(returndatasize(), 32)), eq(mload(out), 1))
        }
        if (tripped) {
            retired = true;
            emit Retired();
        }
    }

    function _checkPool(PoolKey calldata key) private view {
        if (
            !key.currency0.isAddressZero() || key.currency1.isAddressZero() || key.fee != POOL_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert UnsupportedPool();
    }

    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
