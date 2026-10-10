// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory tokenName, string memory tokenSymbol, uint256 supply) ERC20(tokenName, tokenSymbol) {
        _mint(msg.sender, supply);
    }
}
