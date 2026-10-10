// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuantumCanaryTestBase} from "./QuantumCanaryHook.t.sol";
import {MineQuantumCanary} from "../script/MineQuantumCanary.s.sol";

contract MineQuantumCanaryTest is QuantumCanaryTestBase {
    function test_minerPredictsTheActuallyDeployedHook() public {
        MineQuantumCanary miner = new MineQuantumCanary();
        (, address predicted) = miner.find(address(this), manager, canary, 0, 200_000);
        assertEq(predicted, address(hook));
    }
}
