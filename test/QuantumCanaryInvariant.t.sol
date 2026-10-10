// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {QuantumCanaryTestBase} from "./QuantumCanaryHook.t.sol";
import {ToggleReceiver} from "./mocks/MockCanary.sol";
import {QuantumCanaryToken} from "../src/QuantumCanaryToken.sol";

contract CanaryHandler is Test {
    QuantumCanaryInvariantTest public immutable suite;
    uint256 public totalFees;
    uint256 public swaps;
    bool public hasRetired;

    constructor(QuantumCanaryInvariantTest target) {
        suite = target;
    }

    function swap(uint256 amount, bool buy, bool exactInput) external {
        amount = bound(amount, 100, 1 ether);
        totalFees += suite.performSwap(amount, buy, exactInput);
        ++swaps;
        _observeRetirement();
    }

    function retryPayout() external {
        suite.retryPayout();
    }

    function recipientBehavior(uint8 mode) external {
        suite.recipientBehavior(mode % 4);
    }

    function trip(bool tripped) external {
        suite.trip(tripped);
    }

    function canaryReadBehavior(uint8 mode) external {
        suite.canaryReadBehavior(mode % 6);
    }

    function _observeRetirement() private {
        bool current = suite.isRetired();
        if (hasRetired) assertTrue(current, "retirement cannot be reversed");
        hasRetired = hasRetired || current;
    }
}

contract QuantumCanaryInvariantTest is QuantumCanaryTestBase {
    CanaryHandler internal handler;
    ToggleReceiver internal receiver;
    uint256 internal initialETH;

    function setUp() public override {
        vm.deal(address(this), 10_000_000 ether);
        token = new QuantumCanaryToken();
        receiver = new ToggleReceiver();
        _deploy(false, address(receiver));
        receiver.configure(hook, 0);
        handler = new CanaryHandler(this);
        initialETH = address(this).balance + address(manager).balance + address(receiver).balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CanaryHandler.swap.selector;
        selectors[1] = CanaryHandler.retryPayout.selector;
        selectors[2] = CanaryHandler.recipientBehavior.selector;
        selectors[3] = CanaryHandler.trip.selector;
        selectors[4] = CanaryHandler.canaryReadBehavior.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    modifier onlyHandler() {
        require(msg.sender == address(handler), "only invariant handler");
        _;
    }

    function performSwap(uint256 amount, bool buy, bool exactInput) external onlyHandler returns (uint256 fee) {
        (, fee) = _checkSwap(buy, exactInput, amount, _wideLimit(buy));
    }

    function retryPayout() external onlyHandler {
        hook.payout();
    }

    function recipientBehavior(uint256 mode) external onlyHandler {
        receiver.configure(hook, mode);
    }

    function trip(bool tripped) external onlyHandler {
        canary.setTripped(tripped);
    }

    function canaryReadBehavior(uint256 mode) external onlyHandler {
        canary.setReadMode(mode);
    }

    function isRetired() external view returns (bool) {
        return hook.retired();
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesCanOnlyBeClaimsOrETHAtTheImmutableBounty() public view {
        assertEq(handler.totalFees(), hook.accruedFees() + address(receiver).balance);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.totalSupply(), token.balanceOf(address(this)) + token.balanceOf(address(manager)));
        assertEq(initialETH, address(this).balance + address(manager).balance + address(receiver).balance);
        if (handler.hasRetired()) assertTrue(hook.retired());
    }
}
