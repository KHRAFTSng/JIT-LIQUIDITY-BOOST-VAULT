// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockAToken} from "./MockAToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAavePool {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    mapping(address => address) public aTokens;
    mapping(address => mapping(address => uint256)) public variableDebt;
    uint256 public healthFactor = 2e18;

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    function setHealthFactor(uint256 hf) external {
        healthFactor = hf;
    }

    function getReserveData(address asset) external view returns (ReserveData memory data) {
        data.aTokenAddress = aTokens[asset];
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        address aToken = aTokens[asset];
        MockAToken(aToken).mint(onBehalfOf, amount);
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        address aToken = aTokens[asset];
        MockAToken(aToken).burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        variableDebt[asset][onBehalfOf] += amount;
        IERC20(asset).transfer(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        uint256 debt = variableDebt[asset][onBehalfOf];
        if (amount > debt) amount = debt;
        variableDebt[asset][onBehalfOf] -= amount;
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function getUserAccountData(address) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 _healthFactor
    ) {
        return (0, 0, 0, 0, 0, healthFactor);
    }
}

