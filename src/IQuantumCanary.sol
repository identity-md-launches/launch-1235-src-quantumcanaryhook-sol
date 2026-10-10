// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IQuantumCanary {
    function canaryAddress() external view returns (address);
    function isTripped() external view returns (bool);
}
