// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {QuantumCanaryHook} from "../src/QuantumCanaryHook.sol";
import {IQuantumCanary} from "../src/IQuantumCanary.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Offline CREATE2 salt mining only. It neither deploys nor broadcasts transactions.
contract MineQuantumCanary is Script {
    address public constant MAINNET_CANARY = 0x626517225096671868609c1bBF9c1B416A4eFd9a;
    error InvalidDeploymentParameter();
    error SaltNotFound();

    /// @param create2Deployer The actual address executing CREATE2, supplied by the launch factory.
    /// @param manager The actual manager supplied by the launch, never a guessed literal.
    function run(address create2Deployer, IPoolManager manager)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        (salt, predicted) = find(create2Deployer, manager, IQuantumCanary(MAINNET_CANARY), 0, 200_000);
        console2.log("CREATE2 salt:");
        console2.logBytes32(salt);
        console2.log("Hook address:");
        console2.logAddress(predicted);
    }

    /// @notice Reusable with local fixtures; every deployment-dependent input is explicit.
    function find(address create2Deployer, IPoolManager manager, IQuantumCanary canary, uint256 start, uint256 attempts)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        if (create2Deployer == address(0) || address(manager) == address(0) || address(canary) == address(0)) {
            revert InvalidDeploymentParameter();
        }
        bytes32 hash = keccak256(abi.encodePacked(type(QuantumCanaryHook).creationCode, abi.encode(manager, canary)));
        for (uint256 i = start; i < start + attempts; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, hash)))));
            if (HookFlags.matches(predicted, 0x20cc)) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
