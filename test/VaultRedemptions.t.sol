// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";

contract VaultRedemptionsTest is Test {
    // Production addresses the vault expects
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant AAVE = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    MockERC20 underlying0;
    MockAavePool pool;
    MockAToken a0;
    JitLiquidityVault vault;

    address user = makeAddr("user");

    function setUp() public {
        underlying0 = new MockERC20("WETH", "WETH", 18);
        pool = new MockAavePool();
        a0 = new MockAToken(AAVE, "aWETH", "aWETH", 18);
        pool.setAToken(T0, address(a0));

        vm.etch(T0, address(underlying0).code);
        vm.etch(AAVE, address(pool).code);

        vault = new JitLiquidityVault(T0, "Vault", "VAULT");
    }

    function testWithdrawBurnsSharesAndTransfers() public {
        underlying0.mint(user, 10 ether);
        vm.startPrank(user);
        underlying0.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, user);

        uint256 sharesBefore = vault.balanceOf(user);
        vault.withdraw(4 ether, user, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), sharesBefore - vault.previewWithdraw(4 ether));
        // aTokens were never supplied; withdraw pulls from vault balance
        assertEq(underlying0.balanceOf(user), 4 ether);
    }

    function testRedeemRoundingRevertsZeroAssets() public {
        vm.expectRevert("ZERO_ASSETS");
        vault.redeem(0, user, user);
    }
}

