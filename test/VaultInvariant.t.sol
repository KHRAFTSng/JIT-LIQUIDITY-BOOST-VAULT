// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";
import {ChainlinkFeedMock} from "./Mocks/ChainlinkFeedMock.sol";
import {MockWstETH} from "./Mocks/MockWstETH.sol";

contract VaultHandler is Test {
    JitLiquidityVault public vault;
    MockERC20 public underlying;
    address public actor1;
    address public actor2;

    constructor(JitLiquidityVault _vault, MockERC20 _underlying) {
        vault = _vault;
        underlying = _underlying;
        actor1 = address(0xAAAA);
        actor2 = address(0xBBBB);
    }

    function deposit(uint96 rawAmount) external {
        uint256 amt = bound(uint256(rawAmount), 1e6, 5e21); // between 1e6 wei and 5k ETH-ish
        address actor = _actor();
        underlying.mint(actor, amt);
        vm.startPrank(actor);
        underlying.approve(address(vault), type(uint256).max);
        vault.deposit(amt, actor);
        vm.stopPrank();
    }

    function redeem(uint96 rawShares) external {
        address actor = _actor();
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        uint256 shares = bound(uint256(rawShares), 1, bal);
        vm.startPrank(actor);
        try vault.redeem(shares, actor, actor) {
            // success path ignored
        } catch {
            // swallow reverts to keep invariant run moving
        }
        vm.stopPrank();
    }

    function _actor() internal view returns (address) {
        return block.timestamp % 2 == 0 ? actor1 : actor2;
    }
}

contract VaultInvariantTest is StdInvariant, Test {
    // Production addresses the vault expects
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant T1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393; // rETH
    address constant T3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // weETH
    address constant AAVE = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    JitLiquidityVault vault;
    VaultHandler handler;
    MockERC20 underlying0;
    MockWstETH underlying1;
    MockERC20 underlying2;
    MockERC20 underlying3;
    MockAavePool pool;
    MockAToken a0;
    MockAToken a1;
    MockAToken a2;
    MockAToken a3;

    function setUp() public {
        // Deploy ERC20 mocks
        underlying0 = new MockERC20("WETH", "WETH", 18);
        underlying1 = new MockWstETH();
        underlying2 = new MockERC20("rETH", "rETH", 18);
        underlying3 = new MockERC20("weETH", "weETH", 18);

        // Deploy Aave pool mock + aTokens
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
        pool.setHealthFactor(2e18);

        // Etch token code to expected addresses
        vm.etch(T0, address(underlying0).code);
        vm.etch(T1, address(underlying1).code);
        vm.etch(T2, address(underlying2).code);
        vm.etch(T3, address(underlying3).code);

        // Mock Chainlink feeds (all 1:1)
        _setOracle(0x86392dC19c0b719886221c78AB11eb8Cf5c52812, 18, 1e18);
        _setOracle(0x536218f9E9Eb48863970252233c8F271f554C2d0, 18, 1e18);
        _setOracle(0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22, 18, 1e18);
        _setOracle(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, 8, 1e8);

        vault = new JitLiquidityVault(T0, "Vault", "VAULT");

        handler = new VaultHandler(vault, underlying0);
        targetContract(address(handler));
    }

    function invariant_totalAssetsNotLessThanSupply() public {
        assertGe(vault.totalAssets(), vault.totalSupply());
    }

    function invariant_healthFactorPositive() public {
        assertGt(vault.getHealthFactor(), 0);
    }

    function _setOracle(address oracleAddr, uint8 decimals_, int256 value_) internal {
        ChainlinkFeedMock oracle = new ChainlinkFeedMock(decimals_);
        vm.etch(oracleAddr, address(oracle).code);
        ChainlinkFeedMock(oracleAddr).setValue(value_);
    }
}

