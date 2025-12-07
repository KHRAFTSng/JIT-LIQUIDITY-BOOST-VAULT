// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title ChainlinkFeedMock
 * @notice Mock Chainlink price feed for testing
 */
contract ChainlinkFeedMock is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _value;

    constructor(uint8 _d) {
        _decimals = _d;
    }

    /**
     * @notice Sets the price value for testing
     * @param answer The price value to set
     */
    function setValue(int256 answer) external {
        _value = answer;
    }

    /**
     * @notice Returns the latest round data
     */
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _value, block.timestamp, block.timestamp, 1);
    }

    /**
     * @notice Returns the decimals for the price feed
     */
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    // Required by AggregatorV3Interface but not used in this mock
    function description() external pure returns (string memory) {
        return "Mock Chainlink Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("Not implemented");
    }
}

