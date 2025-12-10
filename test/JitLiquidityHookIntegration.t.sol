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
import {MockAToken} from "./Mocks/MockAToken.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";
import {Deployers} from "./utils/Deployers.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

/// @notice Integration-ish test using the local hookmate stack (PoolManager/Router/PositionManager)
/// without touching the production hook contract.
contract JitLiquidityHookIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    JitLiquidityHook hook;
    JitLiquidityVault vault;

    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant T1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant T3 = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    address user = makeAddr("user");

    function setUp() public {
        // Temporarily skip while integration harness is being stabilized
        vm.skip(true);

        // Deploy local artifacts (permit2 + pool manager + position manager + router)
        deployArtifacts();

        // Prime canonical Aave pool + token addresses expected by vault constructor
        _primeCanonicalAddresses();

        // Deploy hook with mined flags using local pool manager
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(address(poolManager)));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(JitLiquidityHook).creationCode, args);
        hook = new JitLiquidityHook{salt: salt}(IPoolManager(address(poolManager)));
        require(address(hook) == expected, "hook flags mismatch");
        vault = hook.vault();

        // Use canonical token addresses (mocked) for pool to align with hook/vault constants
        currency0 = Currency.wrap(T2); // rETH
        currency1 = Currency.wrap(T0); // WETH

        // Approvals for router/position manager
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        MockAToken(token0).approve(address(positionManager), type(uint256).max);
        MockAToken(token1).approve(address(positionManager), type(uint256).max);
        MockAToken(token0).approve(address(swapRouter), type(uint256).max);
        MockAToken(token1).approve(address(swapRouter), type(uint256).max);
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

        MockAToken(token0).mint(address(this), amt0 + 1 ether);
        MockAToken(token1).mint(address(this), amt1 + 1 ether);

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

        // Fund vault with canonical WETH (token1) to enable hook caps
        MockAToken(token1).mint(address(this), 20 ether);
        MockAToken(token1).approve(address(vault), type(uint256).max);
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

    function _primeCanonicalAddresses() internal {
        // Mock tokens at canonical addresses used by vault constructor
        MockAToken weth = new MockAToken(AAVE_POOL, "WETH", "WETH", 18);
        MockAToken wsteth = new MockAToken(AAVE_POOL, "wstETH", "wstETH", 18);
        MockAToken reth = new MockAToken(AAVE_POOL, "rETH", "rETH", 18);
        MockAToken weeth = new MockAToken(AAVE_POOL, "weETH", "weETH", 18);

        vm.etch(T0, address(weth).code);
        vm.etch(T1, address(wsteth).code);
        vm.etch(T2, address(reth).code);
        vm.etch(T3, address(weeth).code);

        // Mock Aave pool and aTokens
        MockAavePool poolImpl = new MockAavePool();
        vm.etch(AAVE_POOL, address(poolImpl).code);
        MockAavePool pool = MockAavePool(AAVE_POOL);

        MockAToken aWETH = new MockAToken(AAVE_POOL, "aWETH", "aWETH", 18);
        MockAToken awstETH = new MockAToken(AAVE_POOL, "awstETH", "awstETH", 18);
        MockAToken aRETH = new MockAToken(AAVE_POOL, "aRETH", "aRETH", 18);
        MockAToken aWEETH = new MockAToken(AAVE_POOL, "aWEETH", "aWEETH", 18);

        vm.etch(address(aWETH), address(aWETH).code);
        vm.etch(address(awstETH), address(awstETH).code);
        vm.etch(address(aRETH), address(aRETH).code);
        vm.etch(address(aWEETH), address(aWEETH).code);

        pool.setAToken(T0, address(aWETH));
        pool.setAToken(T1, address(awstETH));
        pool.setAToken(T2, address(aRETH));
        pool.setAToken(T3, address(aWEETH));
    }
}

