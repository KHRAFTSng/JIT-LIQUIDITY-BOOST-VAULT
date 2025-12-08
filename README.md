# JIT Liquidity Boost Vault

**A protocol that leverages Just-In-Time liquidity hooks on Uniswap v4 for 1:1 asset pairs (stETH/ETH, rETH/ETH, and weETH/ETH) with Aave yield generation.**

## Overview

JIT Liquidity Boost Vault is a hybrid DeFi protocol combining Uniswap v4 hooks and Aave lending. The protocol provides Just-In-Time (JIT) liquidity using Uniswap v4 hooks for 1:1 asset pairs. Before a swap takes place, the protocol takes available liquidity from the vault and additionally borrows assets from Aave to amplify liquidity of the Uniswap v4 pool. The swap is then executed with this enhanced position, after which the liquidity is immediately removed and the Aave loan is repaid. Meanwhile, the vault deposits continue to generate passive yield on Aave.

This mechanism allows users to capture swap fees and lending rewards while enabling highly efficient, temporary liquidity provision.

## Key Features

- **ERC4626 Compatible Vault**: Standard interface for deposits and withdrawals
- **Just-In-Time Liquidity**: Adds liquidity just before swaps and removes it immediately after
- **Aave Integration**: Supplies assets to Aave V3 for passive yield generation
- **Multi-Asset Support**: Supports WETH, wstETH, rETH, and weETH
- **Chainlink Oracles**: Uses Chainlink price feeds for accurate asset valuation
- **Uniswap v4 Hooks**: Leverages Uniswap v4's hook system for seamless integration

## Architecture

### Core Components

1. **JitLiquidityVault** (`src/JitLiquidityVault.sol`)
   - ERC4626-compatible vault contract
   - Manages deposits and withdrawals
   - Supplies assets to Aave V3 for yield
   - Uses Chainlink oracles for price normalization

2. **JitLiquidityHook** (`src/JitLiquidityHook.sol`)
   - Uniswap v4 hook contract
   - Implements `beforeSwap` and `afterSwap` hooks
   - Adds JIT liquidity before swaps
   - Removes liquidity after swaps and returns to vault

### Supported Assets

- **WETH**: Wrapped Ethereum (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
- **wstETH**: Wrapped stETH from Lido (0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)
- **rETH**: Rocket Pool ETH (0xae78736Cd615f374D3085123A210448E74Fc6393)
- **weETH**: Ether.fi Wrapped eETH (0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee)

## How It Works

1. **Deposit**: Users deposit WETH into the vault, which automatically supplies it to Aave V3
2. **Swap Detection**: When a swap occurs on a supported Uniswap v4 pool, the hook detects it
3. **JIT Liquidity Addition**: Before the swap executes, the hook:
   - Calculates optimal liquidity amount based on swap size and vault reserves
   - Adds liquidity to the pool using assets from the vault
4. **Swap Execution**: The swap executes with enhanced liquidity depth
5. **Liquidity Removal**: After the swap, the hook:
   - Removes the JIT liquidity
   - Takes earned swap fees
   - Returns assets to the vault, which supplies them to Aave

## Development

### Prerequisites

- [Foundry](https://getfoundry.sh/) (stable version)
- Node.js and npm/yarn
- Anvil (included with Foundry)

### Setup

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test

# Run tests with verbosity
forge test -vvv
```

### Testing

For integration testing, you'll need to run a local Anvil fork:

```bash
# Start Anvil with mainnet fork
anvil --rpc-url https://eth.llamarpc.com

# In another terminal, run tests
forge test
```

### Deployment

Deploy the hook to a network:

```bash
# Deploy hook
forge script script/00_DeployHook.s.sol:DeployHookScript --rpc-url <RPC_URL> --broadcast --verify
```

### Running E2E Test on Fork

To run the end-to-end test on an Ethereum mainnet fork:

```bash
# Start Anvil fork
source .env
anvil --fork-url "$ETH_RPC_URL" --code-size-limit 40000

# In another terminal, run the E2E test
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ETH_FROM=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
forge script script/E2ETest.s.sol:E2ETestScript \
  --rpc-url http://127.0.0.1:8545 \
  --sender "$ETH_FROM" \
  --private-key "$PRIVATE_KEY" \
  --broadcast --legacy -vv
```

**Note:** The `--legacy` flag is required when running on forks to prevent transaction simulation failures.

## Project Structure

```
.
├── src/
│   ├── interfaces/
│   │   └── IAaveV3Pool.sol      # Aave V3 Pool interface
│   ├── JitLiquidityHook.sol     # Uniswap v4 hook implementation
│   └── JitLiquidityVault.sol    # ERC4626 vault contract
├── test/
│   ├── Mocks/
│   │   ├── ChainlinkFeedMock.sol
│   │   ├── MockRETH.sol
│   │   ├── MockWeETH.sol
│   │   └── MockWstETH.sol
│   ├── utils/
│   │   ├── Deployers.sol
│   │   └── libraries/
│   │       └── EasyPosm.sol
│   └── JitLiquidityIntegration.t.sol
├── script/
│   ├── base/
│   │   ├── BaseScript.sol
│   │   └── LiquidityHelpers.sol
│   └── 00_DeployHook.s.sol
└── lib/                          # Dependencies
```

## Security Considerations

- **Access Control**: Vault owner can withdraw from Aave (hook is set as owner)
- **Oracle Reliance**: Price feeds are critical for asset valuation
- **Smart Contract Risks**: This code has not been audited
- **Economic Risks**: Market conditions can affect JIT liquidity profitability

## License

MIT


