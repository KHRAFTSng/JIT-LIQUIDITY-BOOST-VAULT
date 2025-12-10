# JIT Liquidity Boost Vault

[![Tests](https://img.shields.io/badge/tests-foundry-blue)](#tests)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](#license)
[![Stack](https://img.shields.io/badge/stack-Uniswap_v4%20%7C%20Aave_v3%20%7C%20ERC4626-purple)](#architecture)

## Description
JIT Liquidity Boost Vault combines Uniswap v4 hooks with an ERC4626 vault that supplies to Aave. The hook injects tight-range liquidity right before swaps on ETH-LST pairs (wstETH/ETH, rETH/ETH, weETH/ETH, WETH/ETH), then removes it immediately after, capturing fees while deposits earn Aave yield.

## Problem Statement
LST/ETH pools often face shallow liquidity exactly when swaps arrive, causing price impact and missed fee revenue. LPs also sit idle between swaps, leaving capital underutilized.

## Solution & Impact (incl. financial)
- **JIT depth on demand:** The hook adds liquidity only when swaps occur, reducing slippage and boosting fee capture.
- **Leverage with safety:** Up to 2x of vault reserves can be borrowed from Aave for temporary depth, then repaid post-swap.
- **Continuous yield:** Idle assets stay supplied on Aave, so capital earns even between swaps.
- **Financial impact:** More swap fees per unit of liquidity, lower slippage for traders, and improved capital efficiency for LPs. Vault APR is the combination of Aave supply yield plus periodic swap fee accrual from JIT events.

## Diagrams (flows)
- **User/LP flow:** Deposit → vault supplies to Aave → swap triggers hook → hook adds liquidity → swap executes → hook removes liquidity → repay borrow → excess resupplied to Aave.
- **Technical flow:** `beforeSwap` pulls/borrrows + mints position; `afterSwap` burns position, settles fees, repays, then re-supplies. See `JitLiquidityHook.sol` for caps and `JitLiquidityVault.sol` for accounting.

## Architecture & Components
- **JitLiquidityVault (`src/JitLiquidityVault.sol`)**: ERC4626 vault, Aave supply/borrow, Chainlink pricing, owns pool liquidity funds.
- **JitLiquidityHook (`src/JitLiquidityHook.sol`)**: Uniswap v4 hook implementing `beforeSwap`/`afterSwap`, computes caps, manages JIT add/remove liquidity, owns the vault.
- **Mocks & test utilities**: Under `test/Mocks` and `test/utils` for local/invariant/integration testing.
- **Supported assets**: WETH, wstETH, rETH, weETH (mainnet addresses baked into vault/hook).

## Installation & Setup
```bash
# Install Foundry (if needed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install

# Build
forge build
```

## Tests & Scripts
```bash
# Run all tests (69 total at time of writing)
forge test

# Verbose
forge test -vvv

# Coverage (target 100% on core suites; skip E2E to avoid stack depth)
forge coverage --ir-minimum --skip E2ETest

# Integration test (local hookmate stack, mocked)
forge test --match-path 'test/JitLiquidityIntegration.t.sol'
```

## End-to-End (fork) run
```bash
source .env
anvil --fork-url "$ETH_RPC_URL" --code-size-limit 40000

export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ETH_FROM=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266

forge script script/E2ETest.s.sol:E2ETestScript \
  --rpc-url http://127.0.0.1:8545 \
  --sender "$ETH_FROM" \
  --private-key "$PRIVATE_KEY" \
  --broadcast --legacy -vv
```

**Recent fork example (wei):**
- Hook: `0xc39Baf2bB37D56b72E86ca7d7f6305Bb2A77C0C0`, Vault: `0x2Ae7d00D548c76c0078130C36881b8930B355A26`
- Swap: 10,000,000,000,000,000 rETH → 9,943,657,362,539,014 WETH
- Post-swap vault: WETH `49,501,321,095,158,524,861` wei, rETH `8,671,419,267,218,658` wei, HF high.

## Project Structure
```
.
├── src/                     # Hook + vault
├── test/                    # Unit, integration, invariants, mocks
├── script/                  # Deploy & E2E scripts
└── lib/                     # Dependencies
```

## Roadmap
- Expand supported pools beyond ETH-LST pairs.
- Add configurable leverage caps per pool.
- Formal verification and external audit.
- Strategy toggles for fee reinvest vs. distribution.

## Security Considerations
- Access: hook is vault owner; Aave interactions gated by owner.
- Oracles: Chainlink feeds are relied upon for accounting; mock in tests.
- Economic: JIT profitability depends on fee tiers vs. gas/borrow costs.
- Audits: Not yet audited—use in production at your own risk.

## License
MIT


