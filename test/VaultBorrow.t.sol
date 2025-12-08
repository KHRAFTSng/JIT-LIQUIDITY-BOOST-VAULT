// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract VaultBorrowTest is Test {
    // Match production addresses so the vault constants work
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant T1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant T3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant AAVE = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    MockAavePool pool;
    MockERC20 underlying0;
    MockERC20 underlying1;
    MockERC20 underlying2;
    MockERC20 underlying3;
    MockAToken a0;
    MockAToken a1;
    MockAToken a2;
    MockAToken a3;
    JitLiquidityVault vault;

    function setUp() public {
        // Deploy mocks
        underlying0 = new MockERC20("WETH", "WETH", 18);
        underlying1 = new MockERC20("wstETH", "wstETH", 18);
        underlying2 = new MockERC20("rETH", "rETH", 18);
        underlying3 = new MockERC20("weETH", "weETH", 18);

        MockAavePool poolDeployed = new MockAavePool();
        vm.etch(AAVE, address(poolDeployed).code);
        pool = MockAavePool(AAVE);

        a0 = new MockAToken(AAVE, "aWETH", "aWETH", 18);
        a1 = new MockAToken(AAVE, "awstETH", "awstETH", 18);
        a2 = new MockAToken(AAVE, "arETH", "arETH", 18);
        a3 = new MockAToken(AAVE, "aweETH", "aweETH", 18);

        pool.setAToken(T0, address(a0));
        pool.setAToken(T1, address(a1));
        pool.setAToken(T2, address(a2));
        pool.setAToken(T3, address(a3));

        // Etch mock code to the production addresses used by the vault
        vm.etch(T0, address(underlying0).code);
        vm.etch(T1, address(underlying1).code);
        vm.etch(T2, address(underlying2).code);
        vm.etch(T3, address(underlying3).code);

        // Approve Aave pool to pull underlying during supplies/repays
        underlying0.approve(AAVE, type(uint256).max);
        underlying1.approve(AAVE, type(uint256).max);
        underlying2.approve(AAVE, type(uint256).max);
        underlying3.approve(AAVE, type(uint256).max);

        vault = new JitLiquidityVault(T0, "Vault", "VAULT");
    }

    function testBorrowAndRepay() public {
        // Mint collateral to vault and deposit as aToken via supplyToAave
        MockERC20(T0).mint(address(vault), 10 ether);
        vm.prank(address(this));
        vault.supplyToAave(T0);

        // Borrow 5 ETH against collateral
        vm.prank(address(this));
        vault.borrowFromAave(T0, 5 ether);
        assertEq(MockERC20(T0).balanceOf(address(vault)), 5 ether);

        // Repay 3 ETH
        MockERC20(T0).approve(address(vault), type(uint256).max);
        vm.prank(address(this));
        vault.repayToAave(T0, 3 ether);
        assertEq(MockERC20(T0).balanceOf(address(vault)), 2 ether);
    }

    function testHealthFactor() public {
        pool.setHealthFactor(180e16); // 1.8
        uint256 hf = vault.getHealthFactor();
        assertEq(hf, 180e16);
    }
}

