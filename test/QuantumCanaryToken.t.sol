// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {QuantumCanaryToken} from "../src/QuantumCanaryToken.sol";

contract QuantumCanaryTokenTest is Test {
    QuantumCanaryToken internal token;
    address internal alice;
    address internal bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        token = new QuantumCanaryToken();
    }

    function test_exactLaunchSupplyBelongsEntirelyToDeployer() public view {
        assertEq(token.name(), "Quantum Canary");
        assertEq(token.symbol(), "CANARY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.balanceOf(alice), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_plainTransfersConserveFixedSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount, "no transfer tax");
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(bob), token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_delegatedTransferHonorsAllowanceAndHasNoFee() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 30 ether);
        vm.prank(bob);
        token.transferFrom(alice, address(this), 30 ether);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_insufficientBalanceAndInvalidRecipientRevert() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noMintOwnerPauseOrUpgradeInterface() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", alice),
            abi.encodeWithSignature("burn(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
