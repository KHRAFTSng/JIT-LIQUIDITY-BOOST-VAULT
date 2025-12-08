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

        // Step 1: Deploy Hook
        console.log("Step 1: Deploying JitLiquidityHook...");
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(POOL_MANAGER);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(JitLiquidityHook).creationCode,
            constructorArgs
        );

        vm.startBroadcast();
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

        vm.startBroadcast();
        weth.approve(address(PERMIT2), type(uint256).max);
        reth.approve(address(PERMIT2), type(uint256).max);
        weth.approve(address(SWAP_ROUTER), type(uint256).max);
        reth.approve(address(SWAP_ROUTER), type(uint256).max);
        weth.approve(address(POSITION_MANAGER), type(uint256).max);
        reth.approve(address(POSITION_MANAGER), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();

        console.log("Approvals set");
        console.log("");

        // Step 3: Fund test account (on fork)
        console.log("Step 3: Funding test account...");
        vm.deal(msg.sender, 1000 ether);
        // On fork, we'll use an account that should have tokens, or wrap ETH to WETH
        // For now, let's wrap some ETH to WETH if needed
        if (weth.balanceOf(msg.sender) < 100 ether) {
            vm.startBroadcast();
            // Wrap ETH to WETH - WETH has a deposit() function (no params)
            (bool success,) = WETH.call{value: 100 ether}("");
            require(success, "WETH wrap failed");
            vm.stopBroadcast();
        }
        console.log("WETH balance:", weth.balanceOf(msg.sender) / 1e18, "ETH");
        console.log("rETH balance:", reth.balanceOf(msg.sender) / 1e18, "ETH");
        console.log("Note: On fork, using existing token balances or wrapped ETH");
        console.log("");

        // Step 4: Deposit to vault
        console.log("Step 4: Depositing to vault...");
        uint256 depositAmount = 100 ether;
        vm.startBroadcast();
        vault.deposit(depositAmount, msg.sender);
        vm.stopBroadcast();

        console.log("Deposited", depositAmount / 1e18, "WETH to vault");
        console.log("Vault total assets:", vault.totalAssets() / 1e18, "ETH");
        console.log("Vault total supply:", vault.totalSupply() / 1e18, "shares");
        console.log("");

        // Step 5: Create pool and add liquidity
        console.log("Step 5: Creating pool and adding liquidity...");
        Currency currency0 = Currency.wrap(RETH);
        Currency currency1 = Currency.wrap(WETH);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        uint160 sqrtPrice = Constants.SQRT_PRICE_1_1; // 1:1 price
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        uint256 amount0 = 50 ether;
        uint256 amount1 = 50 ether;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        vm.startBroadcast();
        // Initialize pool (only takes poolKey and sqrtPrice)
        POSITION_MANAGER.initializePool(poolKey, sqrtPrice);

        // Add liquidity using modifyLiquidities
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0 + 1, amount1 + 1, msg.sender, Constants.ZERO_BYTES);
        params[1] = abi.encode(currency0, currency1);
        params[2] = abi.encode(currency0, msg.sender);
        params[3] = abi.encode(currency1, msg.sender);

        uint256 valueToPass = currency0.isAddressZero() ? amount0 + 1 : 0;
        POSITION_MANAGER.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 3600);
        vm.stopBroadcast();

        console.log("Pool initialized and liquidity added");
        console.log("Liquidity amount:", uint256(liquidity) / 1e18);
        console.log("");

        // Step 6: Check vault reserves before swap
        _logVaultState(vault, "before swap");

        // Step 7: Perform swap to trigger JIT liquidity
        console.log("Step 7: Performing swap to trigger JIT liquidity...");
        uint256 swapAmount = 10 ether;
        uint256 balanceBefore = reth.balanceOf(msg.sender);

        vm.startBroadcast();
        SWAP_ROUTER.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // rETH -> WETH
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: msg.sender,
            deadline: block.timestamp + 3600
        });
        vm.stopBroadcast();

        uint256 received = reth.balanceOf(msg.sender) - balanceBefore;
        console.log("Swap completed!");
        console.log("Swapped WETH:", swapAmount / 1e18);
        console.log("Received rETH:", received / 1e18);
        console.log("");

        // Step 8: Check vault state after swap
        _logVaultState(vault, "after swap");

        // Step 9: Check health factor
        _checkHealthFactor(vault);

        console.log("=== E2E Test Complete ===");
    }

    function _logVaultState(JitLiquidityVault vault, string memory stage) internal view {
        console.log("Vault state", stage);
        uint256 wethReserves = vault.getReserves(WETH) / 1e18;
        uint256 rethReserves = vault.getReserves(RETH) / 1e18;
        uint256 totalAssets = vault.totalAssets() / 1e18;
        console.log("WETH reserves:", wethReserves);
        console.log("rETH reserves:", rethReserves);
        console.log("Total assets:", totalAssets);
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
}

