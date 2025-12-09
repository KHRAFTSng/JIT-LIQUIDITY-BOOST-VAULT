// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SwapMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/SwapMath.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";

import {JitLiquidityHook} from "../src/JitLiquidityHook.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";

contract JitLiquidityHookHarness is JitLiquidityHook {
    constructor(IPoolManager pm) JitLiquidityHook(pm) {}

    function exposeCalculateCaps(PoolKey calldata key, SwapParams calldata params, uint160 sqrtP)
        external
        returns (uint256, uint256)
    {
        return _calculateCaps(key, params, key.toId(), sqrtP);
    }
}

contract JitLiquidityHookCapsTest is Test {
    using PoolIdLibrary for PoolKey;

    // Mainnet token constants (match hook constants)
    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393; // rETH
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    address poolManagerAddr = address(0x1234);
    JitLiquidityHookHarness hook;

    function setUp() public {
        _primeExternalAddresses();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(poolManagerAddr));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(JitLiquidityHookHarness).creationCode, args);
        hook = new JitLiquidityHookHarness{salt: salt}(IPoolManager(poolManagerAddr));
        require(address(hook) == expected, "bad hook address");
    }

    function _primeExternalAddresses() internal {
        // Deploy mock tokens
        MockAToken weth = new MockAToken(AAVE_POOL, "WETH", "WETH", 18);
        MockAToken reth = new MockAToken(AAVE_POOL, "rETH", "rETH", 18);
        MockAToken wsteth = new MockAToken(AAVE_POOL, "wstETH", "wstETH", 18);
        MockAToken weeth = new MockAToken(AAVE_POOL, "weETH", "weETH", 18);

        // Etch token code to canonical addresses
        vm.etch(T0, address(weth).code);
        vm.etch(T2, address(reth).code);
        vm.etch(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, address(wsteth).code);
        vm.etch(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee, address(weeth).code);

        // Deploy and etch mock Aave pool
        MockAavePool poolImpl = new MockAavePool();
        vm.etch(AAVE_POOL, address(poolImpl).code);
        MockAavePool pool = MockAavePool(AAVE_POOL);

        // Deploy aToken mocks and register in pool
        MockAToken aWETH = new MockAToken(AAVE_POOL, "aWETH", "aWETH", 18);
        MockAToken awstETH = new MockAToken(AAVE_POOL, "awstETH", "awstETH", 18);
        MockAToken areth = new MockAToken(AAVE_POOL, "areth", "areth", 18);
        MockAToken aweeth = new MockAToken(AAVE_POOL, "aweETH", "aweETH", 18);

        vm.etch(address(aWETH), address(aWETH).code);
        vm.etch(address(awstETH), address(awstETH).code);
        vm.etch(address(areth), address(areth).code);
        vm.etch(address(aweeth), address(aweeth).code);

        pool.setAToken(T0, address(aWETH));
        pool.setAToken(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, address(awstETH));
        pool.setAToken(T2, address(areth));
        pool.setAToken(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee, address(aweeth));
    }

    function _mockLiquidity(PoolId id, uint128 liq) internal {
        // StateLibrary.getLiquidity reads manager.extsload(poolSlot + LIQUIDITY_OFFSET)
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))));
        bytes32 slot = bytes32(uint256(stateSlot) + 3);
        vm.mockCall(
            poolManagerAddr, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)")), slot), abi.encode(bytes32(uint256(liq)))
        );
    }

    function _mockReserves(uint256 res0, uint256 res1, address token0, address token1) internal {
        vm.mockCall(address(hook.vault()), abi.encodeWithSelector(JitLiquidityVault.getReserves.selector, token0), abi.encode(res0));
        vm.mockCall(address(hook.vault()), abi.encodeWithSelector(JitLiquidityVault.getReserves.selector, token1), abi.encode(res1));
    }

    function _makeKey(address token0, address token1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function testPermissionsBeforeAfterOnly() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
    }

    function testCalculateCapsZeroForOneClampedByStepOut() public {
        PoolKey memory key = _makeKey(T2, T0);
        PoolId id = key.toId();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        uint128 liq = uint128(50 ether);
        _mockLiquidity(id, liq);
        _mockReserves(5 ether, 10 ether, T2, T0);

        (uint256 cap0, uint256 cap1) = hook.exposeCalculateCaps(key, params, sqrtP);
        (,, uint256 expectedStepOut,) = SwapMath.computeSwapStep(
            sqrtP, TickMath.MIN_SQRT_PRICE + 1, liq, params.amountSpecified, key.fee
        );

        assertEq(cap0, 10 ether); // 2x reserves of token0
        assertEq(cap1, expectedStepOut < 20 ether ? expectedStepOut : 20 ether); // min(stepOut, 2x reserves1)
    }

    function testCalculateCapsOneForZeroClampedByStepOut() public {
        PoolKey memory key = _makeKey(T0, T2);
        PoolId id = key.toId();
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(2 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        uint128 liq = uint128(30 ether);
        _mockLiquidity(id, liq);
        _mockReserves(8 ether, 3 ether, T0, T2);

        (uint256 cap0, uint256 cap1) = hook.exposeCalculateCaps(key, params, sqrtP);
        (,, uint256 expectedStepOut,) = SwapMath.computeSwapStep(
            sqrtP, TickMath.MAX_SQRT_PRICE - 1, liq, params.amountSpecified, key.fee
        );

        assertEq(cap1, 6 ether); // 2x reserves1 (token1 in PoolKey)
        assertEq(cap0, expectedStepOut < 16 ether ? expectedStepOut : 16 ether); // token0 side capped by stepOut
    }

    function testCalculateCapsZeroLiquidityReturnsZeroCaps() public {
        PoolKey memory key = _makeKey(T2, T0);
        PoolId id = key.toId();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        _mockLiquidity(id, 0);
        _mockReserves(5 ether, 5 ether, T2, T0);

        (uint256 cap0, uint256 cap1) = hook.exposeCalculateCaps(key, params, sqrtP);
        // stepOut is zero, so the outgoing leg (token1) is clamped to zero, but token0 remains leveraged reserves
        assertEq(cap0, 10 ether);
        assertEq(cap1, 0);
    }

    function testCalculateCapsZeroReservesReturnsZero() public {
        PoolKey memory key = _makeKey(T2, T0);
        PoolId id = key.toId();
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(5 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        _mockLiquidity(id, uint128(40 ether));
        _mockReserves(0, 0, T2, T0);

        (uint256 cap0, uint256 cap1) = hook.exposeCalculateCaps(key, params, sqrtP);
        assertEq(cap0, 0);
        assertEq(cap1, 0);
    }

    function testCalculateCapsUsesLeverageMultiplier() public {
        PoolKey memory key = _makeKey(T2, T0);
        PoolId id = key.toId();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(4 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        uint128 liq = uint128(100 ether);
        _mockLiquidity(id, liq);
        _mockReserves(1 ether, 2 ether, T2, T0);

        (uint256 cap0, uint256 cap1) = hook.exposeCalculateCaps(key, params, sqrtP);

        assertEq(cap0, (1 ether * hook.LEVERAGE_BPS()) / 10_000); // 2x
        // For zeroForOne, cap1 is min(leveraged reserves1, stepOut)
        uint256 expected = (2 ether * hook.LEVERAGE_BPS()) / 10_000;
        (,, uint256 stepOut,) = SwapMath.computeSwapStep(
            sqrtP, TickMath.MIN_SQRT_PRICE + 1, liq, params.amountSpecified, key.fee
        );
        assertEq(cap1, stepOut < expected ? stepOut : expected);
    }

    function testCalculateCapsCapsExactOutPath() public {
        PoolKey memory key = _makeKey(T0, T2);
        PoolId id = key.toId();
        // Positive amountSpecified = exactOut per PoolOperation docs
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: int256(1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        uint128 liq = uint128(25 ether);
        _mockLiquidity(id, liq);
        _mockReserves(4 ether, 6 ether, T0, T2);

        (uint256 cap0, uint256 cap1) = hook.exposeCalculateCaps(key, params, sqrtP);
        (,, uint256 stepOut,) = SwapMath.computeSwapStep(sqrtP, TickMath.MAX_SQRT_PRICE - 1, liq, params.amountSpecified, key.fee);

        uint256 expected0 = (4 ether * hook.LEVERAGE_BPS()) / 10_000;
        uint256 expected1 = (6 ether * hook.LEVERAGE_BPS()) / 10_000;
        assertEq(cap0, stepOut < expected0 ? stepOut : expected0);
        assertEq(cap1, expected1);
    }

    function testHookOwnerIsHookSelf() public {
        assertEq(hook.vault().owner(), address(hook));
    }

    function testPermissionsContainOnlySwapHooks() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap && perms.afterSwap);
        assertFalse(perms.beforeDonate || perms.afterDonate);
        assertFalse(perms.beforeInitialize || perms.afterInitialize);
    }
}

