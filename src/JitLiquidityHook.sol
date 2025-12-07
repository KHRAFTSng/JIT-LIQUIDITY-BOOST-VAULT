// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/SwapMath.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "lib/uniswap-hooks/src/utils/CurrencySettler.sol";

import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {console} from "forge-std/console.sol";

import {JitLiquidityVault} from "./JitLiquidityVault.sol";

/**
 * @title JitLiquidityHook
 * @notice Uniswap v4 hook that provides Just-In-Time liquidity using vault assets
 * @dev Adds liquidity before swaps and removes it after, capturing swap fees
 */
contract JitLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // Supported token addresses - Mainnet
    // WETH
    address constant t0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // wstETH (Lido Wrapped stETH)
    address constant t1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    // rETH (Rocket Pool ETH)
    address constant t2 = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    // weETH (Ether.fi Wrapped eETH)
    address constant t3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    // Transient storage for JIT liquidity parameters
    int24 transient tickUpper;
    int24 transient tickLower;
    uint128 transient liquidityDelta;

    JitLiquidityVault public immutable vault;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        JitLiquidityVault newVault = new JitLiquidityVault(t0, "JIT Liquidity Boost Vault", "JIT-VAULT");
        // Transfer ownership to this hook so it can withdraw from vault
        // Note: This requires adding a transferOwnership function to the vault
        vault = newVault;
    }

    /**
     * @notice Gets the lower usable tick aligned to tick spacing
     * @param tick The current tick
     * @param tickSpacing The tick spacing for the pool
     * @return The lower usable tick
     */
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }

    /**
     * @notice Gets the upper usable tick aligned to tick spacing
     * @param tick The current tick
     * @param tickSpacing The tick spacing for the pool
     * @return The upper usable tick
     */
    function getUpperUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        // If the tick is not perfectly aligned, move up to the next interval
        if (tick % tickSpacing != 0) {
            intervals++;
        }
        return intervals * tickSpacing;
    }

    /**
     * @notice Returns the hook permissions
     * @return permissions The hook permissions struct
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Hook called before a swap to add JIT liquidity
     * @param sender The address initiating the swap
     * @param key The pool key
     * @param params The swap parameters
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return delta The before swap delta
     * @return feeForHook The fee for the hook
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Validate tokens are supported
        {
            address token0 = Currency.unwrap(key.currency0);
            address token1 = Currency.unwrap(key.currency1);
            // Only allow swaps between WETH, WSTETH, rETH, and weETH
            if (token0 != t0 && token0 != t1 && token0 != t2 && token0 != t3) {
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            if (token1 != t0 && token1 != t1 && token1 != t2 && token1 != t3) {
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
        }

        PoolId id = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);

        // Calculate a tight JIT liquidity band around current price
        tickLower = getLowerUsableTick(TickMath.getTickAtSqrtPrice(sqrtP), key.tickSpacing);
        tickLower -= key.tickSpacing;
        tickUpper = tickLower + key.tickSpacing;

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate liquidity caps based on swap amount and vault reserves
        (uint256 cap0, uint256 cap1) = _calculateCaps(key, params, id, sqrtP);

        // Early exit if vault has nothing useful
        if (cap0 == 0 && cap1 == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate maximum liquidity that fits the caps at current price
        liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, cap0, cap1);

        if (liquidityDelta == 0) {
            // Not enough funds (or band too tight), skip JIT
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Add JIT liquidity and settle amounts
        _addJITsettleAmounts(key, hookData);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Calculates the maximum liquidity caps based on swap size and vault reserves
     * @param key The pool key
     * @param params The swap parameters
     * @param id The pool ID
     * @param sqrtP The current sqrt price
     * @return cap0 The cap for token0
     * @return cap1 The cap for token1
     */
    function _calculateCaps(PoolKey calldata key, SwapParams calldata params, PoolId id, uint160 sqrtP)
        internal
        returns (uint256, uint256)
    {
        (,, uint256 stepOut,) = SwapMath.computeSwapStep(
            sqrtP,
            params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            poolManager.getLiquidity(id),
            params.amountSpecified,
            key.fee
        );
        
        // Get vault reserves for both tokens
        uint256 cap0 = vault.getReserves(Currency.unwrap(key.currency0));
        uint256 cap1 = vault.getReserves(Currency.unwrap(key.currency1));
        
        // Cap based on swap output to avoid over-adding liquidity
        if (params.zeroForOne) {
            // Pool will pay out token1; don't try to supply more than stepOut from vault1
            if (cap1 > stepOut) cap1 = stepOut;
        } else {
            // Pool will pay out token0
            if (cap0 > stepOut) cap0 = stepOut;
        }

        return (cap0, cap1);
    }

    /**
     * @notice Adds JIT liquidity and settles required amounts from vault
     * @param key The pool key
     * @param hookData Additional hook data
     */
    function _addJITsettleAmounts(PoolKey calldata key, bytes calldata hookData) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: 0
            }),
            hookData
        );

        int256 d0 = delta.amount0();
        int256 d1 = delta.amount1();

        // Settle negative deltas (amounts owed to the pool)
        if (d0 < 0) {
            uint256 owe0 = uint256(-d0);
            // Withdraw from vault and settle to pool
            // The vault owner should be set to this hook contract
            vault.withdrawFromAave(Currency.unwrap(key.currency0), owe0);
            key.currency0.settle(poolManager, address(this), owe0, false);
        }
        if (d1 < 0) {
            uint256 owe1 = uint256(-d1);
            // Withdraw from vault and settle to pool
            vault.withdrawFromAave(Currency.unwrap(key.currency1), owe1);
            key.currency1.settle(poolManager, address(this), owe1, false);
        }
    }

    /**
     * @notice Hook called after a swap to remove JIT liquidity and return to vault
     * @param sender The address initiating the swap
     * @param key The pool key
     * @param params The swap parameters
     * @param delta The swap balance delta
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return hookDelta The hook delta
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (liquidityDelta == 0) {
            // No JIT liquidity was added, nothing to do
            return (BaseHook.afterSwap.selector, 0);
        }

        // Remove JIT liquidity
        (BalanceDelta _delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityDelta)),
                salt: 0
            }),
            hookData
        );
        
        int256 delta0 = _delta.amount0();
        int256 delta1 = _delta.amount1();

        // Take positive deltas (earned amounts) and return to vault
        if (delta0 > 0) {
            key.currency0.take(poolManager, address(vault), uint256(delta0), false);
            vault.supplyToAave(Currency.unwrap(key.currency0));
        }
        if (delta1 > 0) {
            key.currency1.take(poolManager, address(vault), uint256(delta1), false);
            vault.supplyToAave(Currency.unwrap(key.currency1));
        }

        return (BaseHook.afterSwap.selector, 0);
    }
}

