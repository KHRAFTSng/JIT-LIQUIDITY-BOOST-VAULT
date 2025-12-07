// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/**
 * @title MockWeETH
 * @notice Mock contract for weETH (Ether.fi Wrapped eETH) token
 */
contract MockWeETH is ERC20 {
    constructor() ERC20("Wrapped eETH", "weETH", 18) {}
}

