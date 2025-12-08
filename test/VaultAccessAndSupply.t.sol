// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";

/**
 * @title VaultAccessAndSupplyTest
 * @notice Unit tests focused on access control and Aave supply/borrow flows.
 * @dev Uses production token/pool addresses but etches mocks to those addresses.
 */
contract VaultAccessAndSupplyTest is Test {
    // Production addresses the vault expects
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant T1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393; // rETH
    address constant T3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // weETH
    address constant AAVE = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    MockERC20 underlying0;
    MockERC20 underlying1;
    MockERC20 underlying2;
    MockERC20 underlying3;
    MockAavePool pool;
    MockAToken a0;
    MockAToken a1;
    MockAToken a2;
    MockAToken a3;
    JitLiquidityVault vault;

    address hook = makeAddr("hook");
    address user = makeAddr("user");

    function setUp() public {
        // Deploy ERC20 mocks
        underlying0 = new MockERC20("WETH", "WETH", 18);
        underlying1 = new MockERC20("wstETH", "wstETH", 18);
        underlying2 = new MockERC20("rETH", "rETH", 18);
        underlying3 = new MockERC20("weETH", "weETH", 18);

        // Deploy Aave pool mock + aTokens
        MockAavePool poolDeployed = new MockAavePool();
        a0 = new MockAToken(AAVE, "aWETH", "aWETH", 18);
        a1 = new MockAToken(AAVE, "awstETH", "awstETH", 18);
        a2 = new MockAToken(AAVE, "arETH", "arETH", 18);
        a3 = new MockAToken(AAVE, "aweETH", "aweETH", 18);

        // Etch mock code to the production addresses expected by the vault
        vm.etch(T0, address(underlying0).code);
        vm.etch(T1, address(underlying1).code);
        vm.etch(T2, address(underlying2).code);
        vm.etch(T3, address(underlying3).code);
        vm.etch(AAVE, address(poolDeployed).code);
        pool = MockAavePool(AAVE);
        pool.setAToken(T0, address(a0));
        pool.setAToken(T1, address(a1));
        pool.setAToken(T2, address(a2));
        pool.setAToken(T3, address(a3));

        // Deploy vault (owner = this contract, will hand over to hook for owner-only ops)
        vault = new JitLiquidityVault(T0, "Vault", "VAULT");
        vault.transferOwnership(hook);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Access                                   */
    /* -------------------------------------------------------------------------- */

    function testBorrowOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("only owner");
        vault.borrowFromAave(T0, 1 ether);
    }

    function testRepayOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("only owner");
        vault.repayToAave(T0, 1 ether);
    }

    function testWithdrawFromAaveOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("only owner");
        vault.withdrawFromAave(T0, 1 ether);
    }

    function testTransferOwnership() public {
        vm.prank(hook);
        vault.transferOwnership(user);
        vm.prank(hook);
        vm.expectRevert("only owner");
        vault.borrowFromAave(T0, 1 ether);
    }

    /* -------------------------------------------------------------------------- */
    /*                             Supply / Borrow flows                          */
    /* -------------------------------------------------------------------------- */

    function testSupplyToAaveNoBalanceNoRevert() public {
        vm.prank(hook);
        vault.supplyToAave(T0);
        assertEq(a0.balanceOf(address(vault)), 0);
    }

    function testSupplyToAaveWithBalance() public {
        // Fund vault with WETH and supply
        MockERC20(T0).mint(address(vault), 5 ether);
        vm.prank(hook);
        vault.supplyToAave(T0);
        assertEq(a0.balanceOf(address(vault)), 5 ether);
        assertEq(MockERC20(T0).balanceOf(address(vault)), 0);
    }

    function testAfterDepositSuppliesWeth() public {
        // User deposits; afterDeposit should push WETH into Aave
        MockERC20(T0).mint(user, 4 ether);
        vm.startPrank(user);
        MockERC20(T0).approve(address(vault), type(uint256).max);
        vault.deposit(4 ether, user);
        vm.stopPrank();

        assertEq(a0.balanceOf(address(vault)), 4 ether);
        assertEq(MockERC20(T0).balanceOf(address(vault)), 0);
    }

    function testBorrowZeroNoOp() public {
        vm.prank(hook);
        vault.borrowFromAave(T0, 0);
        assertEq(pool.variableDebt(T0, address(vault)), 0);
    }

    function testBorrowUnknownTokenReverts() public {
        vm.prank(hook);
        vm.expectRevert("Unknown token");
        vault.borrowFromAave(address(0xdead), 1);
    }

    function testRepayUnknownTokenReverts() public {
        vm.prank(hook);
        vm.expectRevert("Unknown token");
        vault.repayToAave(address(0xdead), 1);
    }

    function testWithdrawUnknownTokenReverts() public {
        vm.prank(hook);
        vm.expectRevert("Unknown token");
        vault.withdrawFromAave(address(0xdead), 1);
    }

    function testBorrowAndRepayFullCycle() public {
        // Pre-supply collateral
        MockERC20(T0).mint(address(vault), 8 ether);
        vm.prank(hook);
        vault.supplyToAave(T0);
        assertEq(a0.balanceOf(address(vault)), 8 ether);

        // Borrow 3 ether
        vm.prank(hook);
        vault.borrowFromAave(T0, 3 ether);
        assertEq(MockERC20(T0).balanceOf(address(vault)), 3 ether);
        assertEq(pool.variableDebt(T0, address(vault)), 3 ether);

        // Repay 2 ether
        vm.prank(hook);
        vault.repayToAave(T0, 2 ether);
        assertEq(pool.variableDebt(T0, address(vault)), 1 ether);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Health factor                             */
    /* -------------------------------------------------------------------------- */

    function testHealthFactorReflectsPool() public {
        pool.setHealthFactor(150e16); // 1.5
        assertEq(vault.getHealthFactor(), 150e16);
    }
}

