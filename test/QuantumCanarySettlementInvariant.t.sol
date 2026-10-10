// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CanaryScenario} from "./helpers/CanaryScenario.sol";

contract CanarySettlementHandler is Test {
    QuantumCanarySettlementInvariantTest internal immutable suite;
    uint256 public totalExpectedFees;
    uint256 public batches;

    constructor(QuantumCanarySettlementInvariantTest suite_, uint256 initialFees) {
        suite = suite_;
        totalExpectedFees = initialFees;
    }

    function batch(uint256 amount, uint8 mode, bool payInside) external {
        totalExpectedFees += suite.performBatch(bound(amount, 1, 100 ether), mode, payInside);
        ++batches;
    }

    function payout(uint8 callerIndex) external {
        suite.performPayout(callerIndex);
    }

    function recipientBehavior(uint8 mode) external {
        suite.setRecipientBehavior(mode % 4);
    }

    function canaryReadBehavior(uint8 mode) external {
        suite.setReadBehavior(mode % 6);
    }

    function changeReportedDestination(uint8 callerIndex) external {
        suite.changeReportedDestination(callerIndex);
    }

    function attemptClaimTheft(uint256 amount, uint8 callerIndex) external {
        suite.attemptClaimTheft(amount, callerIndex);
    }
}

/// @dev Keep the observer untripped for this campaign so early retirement cannot turn most
/// random sequences into fee-free swaps. The original campaign covers irreversible retirement.
contract QuantumCanarySettlementInvariantTest is CanaryScenario {
    using StateLibrary for IPoolManager;

    CanarySettlementHandler internal handler;
    address[3] internal callers;
    uint256 internal conservedETH;

    function setUp() public override {
        super.setUp();
        callers = [makeAddr("keeper one"), makeAddr("keeper two"), makeAddr("keeper three")];
        receiver.configure(hook, 1);
        uint256 initialFees = _executeAndCheck(_singleSwap(2 ether, true, true), 1, "", true);
        assertGt(initialFees, 0, "start with live backed claims");
        handler = new CanarySettlementHandler(this, initialFees);
        conservedETH = address(this).balance + address(router).balance + address(manager).balance + bounty.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = CanarySettlementHandler.batch.selector;
        selectors[1] = CanarySettlementHandler.payout.selector;
        selectors[2] = CanarySettlementHandler.recipientBehavior.selector;
        selectors[3] = CanarySettlementHandler.canaryReadBehavior.selector;
        selectors[4] = CanarySettlementHandler.changeReportedDestination.selector;
        selectors[5] = CanarySettlementHandler.attemptClaimTheft.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    modifier onlyHandler() {
        require(msg.sender == address(handler), "only sequence handler");
        _;
    }

    function performBatch(uint256 amount, uint8 mode, bool payInside) external onlyHandler returns (uint256) {
        bool buy = mode & 1 == 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(-660);
        uint160 upper = TickMath.getSqrtPriceAtTick(60);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if ((buy && price == lower) || (!buy && price == upper)) buy = !buy;
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = SwapParams(buy, mode & 2 == 0 ? -int256(amount) : int256(amount), buy ? lower : upper);
        swaps[1] = SwapParams(!buy, mode & 4 == 0 ? -int256(amount) : int256(amount), buy ? upper : lower);
        return _executeAndCheck(swaps, payInside ? 7 : 1, abi.encode(mode), true);
    }

    function performPayout(uint8 callerIndex) external onlyHandler {
        uint256 claimsBefore = hook.accruedFees();
        uint256 bountyBefore = bounty.balance;
        vm.prank(callers[callerIndex % callers.length]);
        uint256 paid = hook.payout();
        assertEq(paid, bounty.balance - bountyBefore, "payout return value is the actual bounty payment");
        assertEq(hook.accruedFees() + paid, claimsBefore, "no claim disappears without a payment");
    }

    function setRecipientBehavior(uint8 mode) external onlyHandler {
        receiver.configure(hook, mode);
    }

    function setReadBehavior(uint8 mode) external onlyHandler {
        canary.setReadMode(mode);
    }

    function changeReportedDestination(uint8 callerIndex) external onlyHandler {
        canary.setDestination(callers[callerIndex % callers.length]);
    }

    function attemptClaimTheft(uint256 amount, uint8 callerIndex) external onlyHandler {
        uint256 balance = hook.accruedFees();
        if (balance == 0) return;
        address thief = callers[callerIndex % callers.length];
        amount = bound(amount, 1, balance);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        manager.transferFrom(address(hook), thief, 0, amount);
        assertEq(hook.accruedFees(), balance);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesRemainBackedAndExclusiveToTheCachedBounty() public view {
        assertEq(hook.accruedFees() + bounty.balance, handler.totalExpectedFees(), "independent per-trade fee ledger");
        assertGe(address(manager).balance, hook.accruedFees(), "every claim is backed after settlement");
        assertEq(hook.canaryAddress(), bounty);
        assertFalse(hook.retired(), "false or failed reads must not retire the hook");
        assertEq(
            conservedETH, address(this).balance + address(router).balance + address(manager).balance + bounty.balance
        );
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.totalSupply(),
            token.balanceOf(address(this)) + token.balanceOf(address(router)) + token.balanceOf(address(manager))
        );
        for (uint256 i; i < callers.length; ++i) {
            assertEq(callers[i].balance, 0, "caller cannot earn a payout or redirect the bounty");
            assertEq(manager.balanceOf(callers[i], 0), 0);
            assertEq(manager.allowance(address(hook), callers[i], 0), 0);
            assertFalse(manager.isOperator(address(hook), callers[i]));
        }
        _assertSettled();
    }

    /// @dev An accounting equality alone could pass with permanently stranded claims. Every
    /// random sequence must also end with a successful redemption and LP withdrawal.
    function afterInvariant() public {
        receiver.configure(hook, 0);
        uint256 claims = hook.accruedFees();
        vm.prank(callers[2]);
        assertEq(hook.payout(), claims, "all surviving claims remain redeemable");
        assertEq(hook.accruedFees(), 0);
        assertEq(bounty.balance, handler.totalExpectedFees());
        assertEq(hook.payout(), 0, "no double redemption");
        _liquidity(-600, -60, -int256(LIQUIDITY));
        _assertSettled();
        assertEq(
            conservedETH, address(this).balance + address(router).balance + address(manager).balance + bounty.balance
        );
    }
}
