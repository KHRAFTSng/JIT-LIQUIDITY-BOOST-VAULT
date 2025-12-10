// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {JitLiquidityHook} from "../src/JitLiquidityHook.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {MockV3Aggregator} from "chainlink-evm/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

contract MockWstETH is MockAToken {
    constructor() MockAToken(address(0), "wstETH", "wstETH", 18) {}

    function getStETHByWstETH(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function getWstETHByStETH(uint256 amount) external pure returns (uint256) {
        return amount;
    }
}

/**
 * @title JitLiquidityIntegrationTest
 * @notice Integration tests for JIT Liquidity Boost Vault
 */
contract JitLiquidityIntegrationTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    IPermit2 PERMIT2;
    IPoolManager POOL_MANAGER;
    IPositionManager POSITION_MANAGER;
    IUniswapV4Router04 SWAP_ROUTER;

    address user = makeAddr("user");

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    JitLiquidityVault vault;
    JitLiquidityHook hook;

    // Supported token addresses - Mainnet
    address t0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address t1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address t2 = 0xae78736Cd615f374D3085123A210448E74Fc6393; // rETH
    address t3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // weETH

    function setUp() public {
        // Deploy local hookmate stack (pool manager, router, position manager, permit2)
        deployArtifacts();
        PERMIT2 = permit2;
        POOL_MANAGER = poolManager;
        POSITION_MANAGER = positionManager;
        SWAP_ROUTER = swapRouter;

        // Prime mainnet-like token addresses and Aave pool with mocks the vault expects
        _primeAaveAndTokens();

        // Hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOL_MANAGER);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(JitLiquidityHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        hook = new JitLiquidityHook{salt: salt}(POOL_MANAGER);
        require(address(hook) == expected, "hook flags mismatch");
        vault = hook.vault();

        // Default pool tokens: rETH / WETH
        currency0 = Currency.wrap(t2);
        currency1 = Currency.wrap(t0);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
    }

    function setupApproves(address token) internal {
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        IERC20(token).approve(address(SWAP_ROUTER), type(uint256).max);

        PERMIT2.approve(token, address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token, address(POOL_MANAGER), type(uint160).max, type(uint48).max);
    }

    function testDeposit() public {
        vm.startPrank(user);
        MockAToken(t0).mint(user, 100 ether);
        IERC20(t0).approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, user);
        vm.stopPrank();

        assertApproxEqAbs(vault.totalAssets(), 10 ether, 3);
        assertEq(vault.totalSupply(), 10 ether);

        // Add additional assets to the vault and mock-supply to Aave
        MockAToken(t2).mint(address(vault), 10 ether);
        vm.prank(address(vault));
        vault.supplyToAave(t2);

        // Total assets should reflect supplied + on-hand WETH (~20 ether)
        assertGe(vault.totalAssets(), 20 ether);
        assertEq(vault.totalSupply(), 10 ether);

        // Test redeem
        vm.startPrank(user);
        vault.redeem(10 ether, address(0xdead), user);
        vm.stopPrank();

        console.log("Total assets after redeem:", vault.totalAssets());
    }

    function testSwap() public {
        setupApproves(t0);
        setupApproves(t2);
        POOL_MANAGER.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        MockAToken(t0).mint(address(this), 60 ether);
        MockAToken(t2).mint(address(this), 60 ether);

        // Provide full-range liquidity to the pool
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 1 ether;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        POSITION_MANAGER.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Deposit to vault
        MockAToken(t0).mint(address(this), 100 ether);
        IERC20(t0).approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, user);

        vm.startPrank(user);
        MockAToken(t2).mint(address(user), 50 ether);

        IERC20(t0).approve(address(vault), type(uint256).max);
        IERC20(t2).approve(address(vault), type(uint256).max);

        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(SWAP_ROUTER), type(uint256).max);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(SWAP_ROUTER), type(uint256).max);

        console.log("Before swap - Vault assets:");
        emit log_named_decimal_uint("   WETH balance", vault.getReserves(t0), 18);
        emit log_named_decimal_uint("   wstETH balance", vault.getReserves(t1), 18);
        emit log_named_decimal_uint("   rETH balance", vault.getReserves(t2), 18);
        emit log_named_decimal_uint("   weETH balance", vault.getReserves(t3), 18);
        emit log_named_decimal_uint("   Total Assets", vault.totalAssets(), 18);

        // Perform a swap from rETH to WETH
        uint256 amountIn = 50 ether;
        SWAP_ROUTER.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: user,
            deadline: block.timestamp + 1
        });

        console.log("After swap - Vault assets:");
        emit log_named_decimal_uint("   WETH balance", vault.getReserves(t0), 18);
        emit log_named_decimal_uint("   wstETH balance", vault.getReserves(t1), 18);
        emit log_named_decimal_uint("   rETH balance", vault.getReserves(t2), 18);
        emit log_named_decimal_uint("   weETH balance", vault.getReserves(t3), 18);
        emit log_named_decimal_uint("   Total Assets", vault.totalAssets(), 18);
    }

    function _primeAaveAndTokens() internal {
        // Deploy mock tokens at canonical addresses
        MockAToken weth = new MockAToken(address(0), "WETH", "WETH", 18);
        MockWstETH wsteth = new MockWstETH();
        MockAToken reth = new MockAToken(address(0), "rETH", "rETH", 18);
        MockAToken weeth = new MockAToken(address(0), "weETH", "weETH", 18);

        vm.etch(t0, address(weth).code);
        vm.etch(t1, address(wsteth).code);
        vm.etch(t2, address(reth).code);
        vm.etch(t3, address(weeth).code);

        // Mock Aave pool at canonical address and wire aTokens
        MockAavePool poolImpl = new MockAavePool();
        vm.etch(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, address(poolImpl).code);
        MockAavePool pool = MockAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

        MockAToken aWETH = new MockAToken(address(pool), "aWETH", "aWETH", 18);
        MockAToken awstETH = new MockAToken(address(pool), "awstETH", "awstETH", 18);
        MockAToken aRETH = new MockAToken(address(pool), "aRETH", "aRETH", 18);
        MockAToken aWEETH = new MockAToken(address(pool), "aWEETH", "aWEETH", 18);

        pool.setAToken(t0, address(aWETH));
        pool.setAToken(t1, address(awstETH));
        pool.setAToken(t2, address(aRETH));
        pool.setAToken(t3, address(aWEETH));

        // Mock Chainlink feeds used in vault accounting (18-decimal answers)
        _mockOracle(0x86392dC19c0b719886221c78AB11eb8Cf5c52812, 18, 1e18);
        _mockOracle(0x536218f9E9Eb48863970252233c8F271f554C2d0, 18, 1e18);
        _mockOracle(0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22, 18, 1e18);
        _mockOracle(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, 8, 3000e8);
    }

    function _mockOracle(address agg, uint8 decimals, int256 answer) internal {
        MockV3Aggregator oracle = new MockV3Aggregator(decimals, answer);
        vm.etch(agg, address(oracle).code);
        bytes memory ret = abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1));
        vm.mockCall(agg, abi.encodeWithSelector(MockV3Aggregator.latestRoundData.selector), ret);
    }
}

