# Architecture Documentation

## System Overview

The JIT Liquidity Boost Vault is a two-component system:

1. **Vault Contract**: Manages user deposits and Aave integrations
2. **Hook Contract**: Provides JIT liquidity on Uniswap v4 pools

## Component Interaction Flow

```
User Deposit → Vault → Aave V3 (Yield Generation)
                        ↓
                    Available for JIT
                        ↓
Swap Detected → Hook → Withdraw from Vault → Add Liquidity → Swap → Remove Liquidity → Return to Vault
```

## Detailed Component Descriptions

### JitLiquidityVault

**Responsibilities:**
- Accept ERC4626-compatible deposits
- Supply assets to Aave V3 for yield
- Normalize asset values using Chainlink oracles
- Handle proportional withdrawals across all asset types

**Key Functions:**
- `deposit()`: User deposits WETH
- `withdraw()`: User withdraws assets
- `supplyToAave()`: Supply tokens to Aave
- `withdrawFromAave()`: Withdraw tokens from Aave (hook only)
- `totalAssets()`: Calculate total value in ETH terms

### JitLiquidityHook

**Responsibilities:**
- Monitor swaps on Uniswap v4 pools
- Add JIT liquidity before swaps
- Remove liquidity after swaps
- Transfer earnings back to vault

**Key Functions:**
- `_beforeSwap()`: Add liquidity before swap
- `_afterSwap()`: Remove liquidity after swap
- `_calculateCaps()`: Determine liquidity limits
- `_addJITsettleAmounts()`: Add liquidity and settle

## Security Considerations

1. **Access Control**: Only hook can withdraw from vault
2. **Oracle Reliability**: Chainlink feeds must be monitored
3. **Slippage Protection**: Tight liquidity bands may experience slippage
4. **Reentrancy**: Uses Uniswap v4's built-in protections

