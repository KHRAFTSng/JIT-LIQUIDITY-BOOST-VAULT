// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";
import {MockWstETH} from "./Mocks/MockWstETH.sol";
import {ChainlinkFeedMock} from "./Mocks/ChainlinkFeedMock.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";

contract VaultRedemptionsTest is Test {
    // Production addresses the vault expects
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant T1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393; // rETH
    address constant T3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // weETH
    address constant AAVE = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    MockERC20 underlying0;
    MockAavePool pool;
    MockAToken a0;
    MockWstETH underlying1;
    MockERC20 underlying2;
    MockERC20 underlying3;
    MockAToken a1;
    MockAToken a2;
    MockAToken a3;
    JitLiquidityVault vault;

    address user = makeAddr("user");

    function setUp() public {
        underlying0 = new MockERC20("WETH", "WETH", 18);
        underlying1 = new MockWstETH();
        underlying2 = new MockERC20("rETH", "rETH", 18);
        underlying3 = new MockERC20("weETH", "weETH", 18);

        MockAavePool poolDeployed = new MockAavePool();
        pool = MockAavePool(AAVE);
        vm.etch(AAVE, address(poolDeployed).code);

        a0 = new MockAToken(AAVE, "aWETH", "aWETH", 18);
        a1 = new MockAToken(AAVE, "awstETH", "awstETH", 18);
        a2 = new MockAToken(AAVE, "arETH", "arETH", 18);
        a3 = new MockAToken(AAVE, "aweETH", "aweETH", 18);
        pool.setAToken(T0, address(a0));
        pool.setAToken(T1, address(a1));
        pool.setAToken(T2, address(a2));
        pool.setAToken(T3, address(a3));

        vm.etch(T0, address(underlying0).code);
        vm.etch(T1, address(underlying1).code);
        vm.etch(T2, address(underlying2).code);
        vm.etch(T3, address(underlying3).code);

        // Mock Chainlink feeds used by the vault (set all to 1e18)
        ChainlinkFeedMock stethOracle = new ChainlinkFeedMock(18);
        vm.etch(0x86392dC19c0b719886221c78AB11eb8Cf5c52812, address(stethOracle).code);
        ChainlinkFeedMock(0x86392dC19c0b719886221c78AB11eb8Cf5c52812).setValue(1e18);

        ChainlinkFeedMock rethOracle = new ChainlinkFeedMock(18);
        vm.etch(0x536218f9E9Eb48863970252233c8F271f554C2d0, address(rethOracle).code);
        ChainlinkFeedMock(0x536218f9E9Eb48863970252233c8F271f554C2d0).setValue(1e18);

        ChainlinkFeedMock weethOracle = new ChainlinkFeedMock(18);
        vm.etch(0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22, address(weethOracle).code);
        ChainlinkFeedMock(0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22).setValue(1e18);

        ChainlinkFeedMock ethUsdOracle = new ChainlinkFeedMock(8);
        vm.etch(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, address(ethUsdOracle).code);
        ChainlinkFeedMock(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419).setValue(1e8);

        vault = new JitLiquidityVault(T0, "Vault", "VAULT");
    }

    function testWithdrawBurnsSharesAndTransfers() public {
        MockERC20(T0).mint(user, 10 ether);
        vm.startPrank(user);
        MockERC20(T0).approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, user);
        vm.stopPrank();

        // Ensure pool holds underlying and vault holds aTokens to cover withdrawal
        MockERC20(T0).mint(AAVE, 10 ether);
        vm.startPrank(AAVE);
        a0.mint(address(vault), 10 ether);
        vm.stopPrank();

        uint256 sharesPreview = vault.previewWithdraw(4 ether);
        assertGt(sharesPreview, 0);
    }

    function testRedeemRoundingRevertsZeroAssets() public {
        vm.expectRevert("ZERO_ASSETS");
        vault.redeem(0, user, user);
    }
}

