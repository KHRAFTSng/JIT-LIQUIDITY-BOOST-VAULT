// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {JitLiquidityHook} from "../src/JitLiquidityHook.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";

// Uniswap V3 Router interface for swapping
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title E2ETestScript
 * @notice End-to-end test script for JIT Liquidity Boost Vault
 * @dev Tests the full flow: deploy hook, create pool, add liquidity, deposit to vault, swap
 * @notice NOTE: This script uses Ethereum mainnet token addresses. For Unichain testing,
 *         you need to fork Ethereum mainnet, not Unichain, or update token addresses.
 */
contract E2ETestScript is Script {
    using CurrencyLibrary for Currency;

    // Unichain addresses - these should be the actual deployed addresses on Unichain
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IUniswapV4Router04 constant SWAP_ROUTER = IUniswapV4Router04(payable(0x00000000000044a361Ae3cAc094c9D1b14Eece97));

    // Token addresses - Mainnet (will work on fork)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    function run() external {
        _deployAndTest();
    }

    function _deployAndTest() internal {
        console.log("=== JIT Liquidity Boost Vault E2E Test ===");
        console.log("");

        // Configure broadcaster (use PRIVATE_KEY from .env; ensure it has balance)
        uint256 broadcasterKey = _getBroadcasterKey();
        address broadcaster = vm.addr(broadcasterKey);
        vm.deal(broadcaster, 1_000 ether);

        // Step 1: Deploy Hook
        console.log("Step 1: Deploying JitLiquidityHook...");
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(POOL_MANAGER);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(JitLiquidityHook).creationCode, constructorArgs);

        vm.startBroadcast(broadcasterKey);
        JitLiquidityHook hook = new JitLiquidityHook{salt: salt}(POOL_MANAGER);
        require(address(hook) == hookAddress, "Hook address mismatch");
        JitLiquidityVault vault = hook.vault();
        vm.stopBroadcast();

        console.log("Hook deployed at:", address(hook));
        console.log("Vault deployed at:", address(vault));
        console.log("");

        // Step 2: Setup tokens and approvals
        console.log("Step 2: Setting up tokens and approvals...");
        IERC20 weth = IERC20(WETH);
        IERC20 reth = IERC20(RETH);

        vm.startBroadcast(broadcasterKey);
        weth.approve(address(PERMIT2), type(uint256).max);
        reth.approve(address(PERMIT2), type(uint256).max);
        // Approve Permit2 for PositionManager with expiration
        PERMIT2.approve(address(weth), address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(reth), address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(weth), address(POOL_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(reth), address(POOL_MANAGER), type(uint160).max, type(uint48).max);
        weth.approve(address(SWAP_ROUTER), type(uint256).max);
        reth.approve(address(SWAP_ROUTER), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();

        console.log("Approvals set");
        console.log("");

        // Step 3: Fund test account (on fork)
        console.log("Step 3: Funding test account...");
        vm.deal(broadcaster, 1000 ether);
        // Wrap ETH to WETH
        vm.startBroadcast(broadcasterKey);
        (bool success,) = WETH.call{value: 100 ether}("");
        require(success, "WETH wrap failed");
        vm.stopBroadcast();

        // Acquire rETH by swapping WETH for rETH via Uniswap V3
        console.log("Acquiring rETH by swapping WETH...");
        uint256 rethNeeded = 50 ether;
        uint256 currentReth = reth.balanceOf(broadcaster);

        if (currentReth < rethNeeded) {
            // Use Uniswap V3 Router to swap WETH for rETH
            address uniswapV3Router = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Uniswap V3 Router

            // Approve router to spend WETH
            vm.startBroadcast(broadcasterKey);
            weth.approve(uniswapV3Router, type(uint256).max);

            // WETH/rETH pool fee tier (0.3% = 3000)
            uint24 fee = 3000;
            uint256 amountIn = 50 ether; // Swap more WETH to get enough rETH for both liquidity and swap test

            // Encode swap path: WETH -> rETH
            bytes memory path = abi.encodePacked(WETH, fee, RETH);

            // Perform exact input swap
            ISwapRouter(uniswapV3Router)
                .exactInput(
                    ISwapRouter.ExactInputParams({
                        path: path,
                        recipient: broadcaster,
                        deadline: block.timestamp + 3600,
                        amountIn: amountIn,
                        amountOutMinimum: 0 // Accept any amount out for testing
                    })
                );
            vm.stopBroadcast();

            console.log("Swapped", amountIn, "wei WETH for rETH");
        }

        console.log("WETH balance:", weth.balanceOf(broadcaster), "wei");
        console.log("rETH balance:", reth.balanceOf(broadcaster), "wei");
        console.log("");

        // Step 4: Deposit to vault (keep some WETH for liquidity)
        console.log("Step 4: Depositing to vault...");
        uint256 availableWeth = weth.balanceOf(broadcaster);
        uint256 wethForLiquidity = 5 ether; // Reserve 5 WETH for pool liquidity and swap gas
        uint256 depositAmount = availableWeth > wethForLiquidity ? availableWeth - wethForLiquidity : 0;

        if (depositAmount > 0) {
            vm.startBroadcast(broadcasterKey);
            vault.deposit(depositAmount, msg.sender);
            vm.stopBroadcast();
        }

        console.log("Deposited", depositAmount, "wei WETH to vault");
        console.log("Vault total assets:", vault.totalAssets(), "wei");
        console.log("Vault total supply:", vault.totalSupply(), "shares (wei decimals)");
        console.log("");

        // Step 5: Create pool and add liquidity
        console.log("Step 5: Creating pool and adding liquidity...");
        Currency currency0 = Currency.wrap(RETH);
        Currency currency1 = Currency.wrap(WETH);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        uint160 sqrtPrice = Constants.SQRT_PRICE_1_1; // 1:1 price
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        // Adjust amounts based on available tokens - need reasonable amounts for liquidity
        // Reserve some rETH for swap test later (at least 0.005 rETH)
        uint256 availableRethForPool = reth.balanceOf(broadcaster);
        uint256 rethReservedForSwap = 0.005 ether;
        uint256 amount0 = availableRethForPool > rethReservedForSwap ? availableRethForPool - rethReservedForSwap : 0; // Reserve rETH for swap
        uint256 availableWethForPool = weth.balanceOf(broadcaster);
        uint256 amount1 = availableWethForPool > 0.5 ether ? 0.5 ether : availableWethForPool; // Use 0.5 WETH

        // Ensure we have minimum amounts for liquidity (need at least 0.001 rETH)
        require(amount0 >= 0.001 ether && amount1 > 0, "Insufficient tokens for liquidity");

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );

        vm.startBroadcast(broadcasterKey);
        // Initialize pool (only takes poolKey and sqrtPrice)
        POSITION_MANAGER.initializePool(poolKey, sqrtPrice);

        // Add liquidity using modifyLiquidities
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, amount0 + 1, amount1 + 1, msg.sender, Constants.ZERO_BYTES
        );
        params[1] = abi.encode(currency0, currency1);
        params[2] = abi.encode(currency0, msg.sender);
        params[3] = abi.encode(currency1, msg.sender);

        uint256 valueToPass = currency0.isAddressZero() ? amount0 + 1 : 0;
        POSITION_MANAGER.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 3600);
        vm.stopBroadcast();

        console.log("Pool initialized and liquidity added");
        console.log("Liquidity amount (raw):", uint256(liquidity));
        console.log("");

        // Step 6: Check vault reserves before swap
        _logVaultState(vault, "before swap");

        // Step 7: Perform swap to trigger JIT liquidity
        console.log("Step 7: Performing swap to trigger JIT liquidity...");
        // Use a meaningful swap amount to trigger JIT liquidity
        // NOTE: Very small swaps (< 0.01 ETH) may not trigger JIT liquidity because:
        // 1. The hook caps liquidity to the swap output amount (stepOut)
        // 2. The tight liquidity band (2 ticks) may not fit very small amounts
        // 3. The liquidity calculation may round down to 0 for tiny amounts
        uint256 availableRethForSwap = reth.balanceOf(broadcaster);
        // Target 0.01 rETH swap; proceed with at least 0.005 rETH if available
        uint256 targetSwap = 0.01 ether;
        uint256 minSwap = 0.005 ether;
        uint256 swapAmount = availableRethForSwap >= targetSwap ? targetSwap : availableRethForSwap;

        if (swapAmount == 0) {
            console.log("Skipping swap - no rETH available (have:", availableRethForSwap, "wei rETH)");
            console.log("NOTE: Very small swaps may not trigger JIT liquidity due to tight liquidity bands");
            return;
        }

        if (swapAmount < minSwap) {
            console.log("WARNING: Swap amount is small (", swapAmount, "wei rETH). JIT liquidity may not be added.");
        }

        // Log vault state before swap for debugging
        uint256 vaultWethBefore = vault.getReserves(WETH);
        uint256 vaultRethBefore = vault.getReserves(RETH);

        uint256 wethBalanceBefore = weth.balanceOf(broadcaster);
        uint256 rethBalanceBefore = reth.balanceOf(broadcaster);

        console.log("Swap details:");
        console.log("  Available rETH:", availableRethForSwap, "wei");
        console.log("  Swap amount:", swapAmount, "wei rETH");
        console.log("  Vault WETH before:", vaultWethBefore, "wei");
        console.log("  Vault rETH before:", vaultRethBefore, "wei");

        // Re-approve if needed
        vm.startBroadcast(broadcasterKey);
        reth.approve(address(SWAP_ROUTER), type(uint256).max);

        SWAP_ROUTER.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // rETH -> WETH
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: broadcaster,
            deadline: block.timestamp + 3600
        });
        vm.stopBroadcast();

        uint256 wethAfter = weth.balanceOf(broadcaster);
        uint256 rethAfter = reth.balanceOf(broadcaster);
        uint256 wethReceived = wethAfter > wethBalanceBefore ? wethAfter - wethBalanceBefore : 0;
        uint256 rethSwapped = rethBalanceBefore > rethAfter ? rethBalanceBefore - rethAfter : 0;

        // Check vault state after swap
        uint256 vaultWethAfter = vault.getReserves(WETH);
        uint256 vaultRethAfter = vault.getReserves(RETH);

        console.log("Swap completed!");
        console.log("  Swapped rETH:", rethSwapped, "wei");
        console.log("  Received WETH:", wethReceived, "wei");

        int256 wethChange = int256(vaultWethAfter) - int256(vaultWethBefore);
        int256 rethChange = int256(vaultRethAfter) - int256(vaultRethBefore);

        console.log("  Vault WETH after:", vaultWethAfter, "wei");
        if (wethChange != 0) {
            console.log(
                "  Vault WETH change:",
                uint256(wethChange > 0 ? wethChange : -wethChange),
                "wei",
                wethChange > 0 ? "increase" : "decrease"
            );
        }
        console.log("  Vault rETH after:", vaultRethAfter, "wei");
        if (rethChange != 0) {
            console.log(
                "  Vault rETH change:",
                uint256(rethChange > 0 ? rethChange : -rethChange),
                "wei",
                rethChange > 0 ? "increase" : "decrease"
            );
        }
        console.log("");

        // Step 8: Check vault state after swap
        _logVaultState(vault, "after swap");

        // Step 9: Check health factor
        _checkHealthFactor(vault);

        console.log("=== E2E Test Complete ===");
    }

    function _logVaultState(JitLiquidityVault vault, string memory stage) internal view {
        console.log("Vault state", stage);
        uint256 wethReserves = vault.getReserves(WETH);
        uint256 rethReserves = vault.getReserves(RETH);
        uint256 totalAssets = vault.totalAssets();
        console.log("WETH reserves:", wethReserves, "wei");
        console.log("rETH reserves:", rethReserves, "wei");
        console.log("Total assets:", totalAssets, "wei");
        console.log("");
    }

    function _checkHealthFactor(JitLiquidityVault vault) internal view {
        console.log("Checking vault health factor...");
        uint256 healthFactor = vault.getHealthFactor();
        console.log("Health factor:", healthFactor);
        if (healthFactor > 1e18) {
            console.log("Vault is healthy!");
        } else {
            console.log("WARNING: Vault health factor is low!");
        }
        console.log("");
    }

    function _getBroadcasterKey() internal returns (uint256) {
        // Try env PRIVATE_KEY, otherwise fallback to default anvil key
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            return pk;
        } catch {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
    }
}

