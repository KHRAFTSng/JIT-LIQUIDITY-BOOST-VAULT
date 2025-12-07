// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/**
 * @title MockRETH
 * @notice Mock contract for rETH (Rocket Pool ETH) token
 */
contract MockRETH is ERC20 {
    constructor() ERC20("Rocket Pool ETH", "rETH", 18) {}
}

