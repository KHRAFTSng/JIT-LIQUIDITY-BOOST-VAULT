// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/SwapMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";

import {JitLiquidityHookHarness} from "./JitLiquidityHookCaps.t.sol";
import {JitLiquidityVault} from "../src/JitLiquidityVault.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockAToken} from "./Mocks/MockAToken.sol";
import {MockAavePool} from "./Mocks/MockAavePool.sol";

contract CapsHandler is Test {
    using PoolIdLibrary for PoolKey;

    address public immutable poolManagerAddr;
    JitLiquidityHookHarness public immutable hook;

    uint256 public lastCap0;
    uint256 public lastCap1;
    uint256 public lastStepOut;
    uint256 public lastRes0;
    uint256 public lastRes1;
    bool public lastZeroForOne;

    address constant T0 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant T2 = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    constructor(address _pm, JitLiquidityHookHarness _hook) {
        poolManagerAddr = _pm;
        hook = _hook;
    }

    function callCaps(uint128 liq, uint256 reserves0, uint256 reserves1, bool zeroForOne, int256 amountSpecified) public {
        // Avoid pathological values that overflow SwapMath
        reserves0 = reserves0 % 50 ether;
        reserves1 = reserves1 % 50 ether;
        uint256 bounded = uint256(amountSpecified >= 0 ? amountSpecified : -amountSpecified);
        bounded = 1 ether + (bounded % 5 ether);
        int256 amt = amountSpecified >= 0 ? int256(bounded) : -int256(bounded);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(T2),
            currency1: Currency.wrap(T0),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: amt, sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1});
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))));
        bytes32 slot = bytes32(uint256(stateSlot) + 3);
        vm.mockCall(
            poolManagerAddr, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)")), slot), abi.encode(bytes32(uint256(liq)))
        );
        vm.mockCall(address(hook.vault()), abi.encodeWithSelector(JitLiquidityVault.getReserves.selector, T2), abi.encode(reserves0));
        vm.mockCall(address(hook.vault()), abi.encodeWithSelector(JitLiquidityVault.getReserves.selector, T0), abi.encode(reserves1));

        (lastCap0, lastCap1) = hook.exposeCalculateCaps(key, params, sqrtP);
        (,, lastStepOut,) = SwapMath.computeSwapStep(
            sqrtP,
            params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            liq,
            params.amountSpecified,
            key.fee
        );
        lastRes0 = reserves0;
        lastRes1 = reserves1;
        lastZeroForOne = zeroForOne;
    }
}

contract JitLiquidityHookCapsInvariant is StdInvariant, Test {
    address poolManagerAddr = address(0x2345);
    JitLiquidityHookHarness hook;
    CapsHandler handler;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    function setUp() public {
        _primeExternalAddresses();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(poolManagerAddr));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(JitLiquidityHookHarness).creationCode, args);
        hook = new JitLiquidityHookHarness{salt: salt}(IPoolManager(poolManagerAddr));
        require(address(hook) == expected, "bad hook address");
        handler = new CapsHandler(poolManagerAddr, hook);
        targetContract(address(handler));
    }

    function _primeExternalAddresses() internal {
        MockAToken weth = new MockAToken(AAVE_POOL, "WETH", "WETH", 18);
        MockAToken reth = new MockAToken(AAVE_POOL, "rETH", "rETH", 18);
        MockAToken wsteth = new MockAToken(AAVE_POOL, "wstETH", "wstETH", 18);
        MockAToken weeth = new MockAToken(AAVE_POOL, "weETH", "weETH", 18);

        vm.etch(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, address(weth).code);
        vm.etch(0xae78736Cd615f374D3085123A210448E74Fc6393, address(reth).code);
        vm.etch(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, address(wsteth).code);
        vm.etch(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee, address(weeth).code);

        MockAavePool poolImpl = new MockAavePool();
        vm.etch(AAVE_POOL, address(poolImpl).code);
        MockAavePool pool = MockAavePool(AAVE_POOL);

        MockAToken aWETH = new MockAToken(AAVE_POOL, "aWETH", "aWETH", 18);
        MockAToken awstETH = new MockAToken(AAVE_POOL, "awstETH", "awstETH", 18);
        MockAToken areth = new MockAToken(AAVE_POOL, "areth", "areth", 18);
        MockAToken aweeth = new MockAToken(AAVE_POOL, "aweETH", "aweETH", 18);

        vm.etch(address(aWETH), address(aWETH).code);
        vm.etch(address(awstETH), address(awstETH).code);
        vm.etch(address(areth), address(areth).code);
        vm.etch(address(aweeth), address(aweeth).code);

        pool.setAToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, address(aWETH));
        pool.setAToken(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, address(awstETH));
        pool.setAToken(0xae78736Cd615f374D3085123A210448E74Fc6393, address(areth));
        pool.setAToken(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee, address(aweeth));
    }

    function invariant_capsNotAboveLeverage() public {
        uint256 leverage = hook.LEVERAGE_BPS();
        assertLe(handler.lastCap0(), (handler.lastRes0() * leverage) / 10_000);
        assertLe(handler.lastCap1(), (handler.lastRes1() * leverage) / 10_000);
    }

    function invariant_capsRespectStepOut() public {
        if (handler.lastStepOut() == 0) {
            if (handler.lastZeroForOne()) {
                assertEq(handler.lastCap1(), 0);
            } else {
                assertEq(handler.lastCap0(), 0);
            }
            return;
        }
        // Only one side is capped by stepOut depending on swap direction; ensure neither exceeds it wildly.
        assertLe(handler.lastCap0(), handler.lastStepOut() + (handler.lastRes0() * hook.LEVERAGE_BPS()) / 10_000);
        assertLe(handler.lastCap1(), handler.lastStepOut() + (handler.lastRes1() * hook.LEVERAGE_BPS()) / 10_000);
    }
}

