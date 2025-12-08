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

/**
 * @title JitLiquidityIntegrationTest
 * @notice Integration tests for JIT Liquidity Boost Vault
 */
contract JitLiquidityIntegrationTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IUniswapV4Router04 constant SWAP_ROUTER = IUniswapV4Router04(payable(0x00000000000044a361Ae3cAc094c9D1b14Eece97));

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
        // Fork mainnet for integration testing
        // use: anvil --rpc-url https://eth.llamarpc.com
        vm.createSelectFork("http://127.0.0.1:8545");

        // Hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOL_MANAGER);
        (, bytes32 salt) = HookMiner.find(
            address(this),
            /*CREATE2_FACTORY*/ flags,
            type(JitLiquidityHook).creationCode,
            constructorArgs
        );

        // Deploy the hook using CREATE2
        hook = new JitLiquidityHook{salt: salt}(POOL_MANAGER);
        vault = hook.vault();
    }

    function setupApproves(address token) internal {
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        IERC20(token).approve(address(SWAP_ROUTER), type(uint256).max);

        PERMIT2.approve(token, address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token, address(POOL_MANAGER), type(uint160).max, type(uint48).max);
    }

    function testDeposit() public {
        vm.startPrank(user);
        deal(t0, user, 100 ether);
        IERC20(t0).approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, user);
        vm.stopPrank();

        assertApproxEqAbs(vault.totalAssets(), 10 ether, 3);
        assertEq(vault.totalSupply(), 10 ether);

        // Add additional assets to the vault
        deal(t2, address(vault), 10 ether);
        vm.prank(address(vault));
        vault.supplyToAave(t2);

        // Total assets should be greater than 20 ether
        assertGt(vault.totalAssets(), 20 ether);
        assertEq(vault.totalSupply(), 10 ether);

        // Test redeem
        vm.startPrank(user);
        vault.redeem(10 ether, address(0xdead), user);
        vm.stopPrank();

        console.log("Total assets after redeem:", vault.totalAssets());
    }

    function testSwap() public {
        currency0 = Currency.wrap(t2); // rETH
        currency1 = Currency.wrap(t0); // WETH

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();

        setupApproves(t0);
        setupApproves(t2);
        POOL_MANAGER.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        deal(t0, address(this), 60 ether);
        deal(t2, address(this), 60 ether);

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
        deal(t0, address(this), 100 ether);
        IERC20(t0).approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, user);

        vm.startPrank(user);
        deal(t2, address(user), 50 ether);

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
}

