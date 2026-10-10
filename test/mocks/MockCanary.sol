// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQuantumCanary} from "../../src/IQuantumCanary.sol";
import {QuantumCanaryHook} from "../../src/QuantumCanaryHook.sol";

contract MockCanary is IQuantumCanary {
    address public override canaryAddress;
    bool public tripped;
    uint256 public readMode;

    constructor(address destination) {
        canaryAddress = destination;
    }

    function setTripped(bool value) external {
        tripped = value;
    }

    function setReadMode(uint256 mode) external {
        readMode = mode;
    }

    function setDestination(address destination) external {
        canaryAddress = destination;
    }

    function isTripped() external view returns (bool) {
        if (readMode == 1) revert("broken canary");
        if (readMode == 2) {
            assembly ("memory-safe") { return(0, 1) }
        }
        if (readMode == 3) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (readMode == 4) {
            assembly ("memory-safe") { invalid() }
        }
        if (readMode == 5) {
            assembly ("memory-safe") { return(0, 0x10000) }
        }
        return tripped;
    }
}

contract ToggleReceiver {
    uint256 public mode;
    QuantumCanaryHook public hook;
    uint256 public reentrantPaid;

    function configure(QuantumCanaryHook target, uint256 newMode) external {
        hook = target;
        mode = newMode;
    }

    receive() external payable {
        if (mode == 1) revert("reject ETH");
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) reentrantPaid = hook.payout();
    }
}
