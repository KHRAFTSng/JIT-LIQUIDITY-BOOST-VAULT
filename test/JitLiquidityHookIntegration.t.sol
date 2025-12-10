// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {JitLiquidityHook} from "../src/JitLiquidityHook.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "./utils/Deployers.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

/// @notice Integration-ish test using the local hookmate stack (PoolManager/Router/PositionManager)
/// without touching the production hook contract.
contract JitLiquidityHookIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    JitLiquidityHook hook;
    JitLiquidityVault vault;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    address user = makeAddr("user");

    function setUp() public {
        // Deploy local artifacts (permit2 + pool manager + position manager + router)
        deployArtifacts();

        // Deploy hook with mined flags using local pool manager
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(address(poolManager)));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(JitLiquidityHook).creationCode, args);
        hook = new JitLiquidityHook{salt: salt}(IPoolManager(address(poolManager)));
        require(address(hook) == expected, "hook flags mismatch");
        vault = hook.vault();

        // Deploy two mock tokens and set as currencies
        (currency0, currency1) = deployCurrencyPair();

        // Approvals for router/position manager
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        MockERC20(token0).approve(address(positionManager), type(uint256).max);
        MockERC20(token1).approve(address(positionManager), type(uint256).max);
        MockERC20(token0).approve(address(swapRouter), type(uint256).max);
        MockERC20(token1).approve(address(swapRouter), type(uint256).max);
        permit2.approve(token0, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(token1, address(positionManager), type(uint160).max, type(uint48).max);

        // Prepare pool key with hook
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Mint baseline liquidity
        uint128 baseLiq = 1 ether;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(poolKey.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(poolKey.tickSpacing)),
            baseLiq
        );

        MockERC20(token0).mint(address(this), amt0 + 1 ether);
        MockERC20(token1).mint(address(this), amt1 + 1 ether);

        // Use EasyPosm helper to mint liquidity via modifyLiquidities
        EasyPosm.mint(
            positionManager,
            poolKey,
            TickMath.minUsableTick(poolKey.tickSpacing),
            TickMath.maxUsableTick(poolKey.tickSpacing),
            baseLiq,
            amt0 + 1,
            amt1 + 1,
            address(this),
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );

        // Fund vault with token1 (treat as WETH side) to enable hook caps
        MockERC20(token1).mint(address(this), 20 ether);
        MockERC20(token1).approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, address(this));
    }

    function testHookPermissionsRemainSwapOnly() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.afterSwap);
        assertFalse(
            p.beforeInitialize || p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity
                || p.beforeRemoveLiquidity || p.afterRemoveLiquidity
        );
    }
}

