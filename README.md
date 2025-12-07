*JIT LIQUIDITY BOOST VAULT*

Project Description
JIT LiquidityBoost Vault is a capital-efficient liquidity protocol that combines Uniswap v4 Just-In-Time (JIT) hooks with Aave flash borrowing to maximize returns for passive LPs. When a swap is about to execute on LST/ETH pairs (stETH/ETH, rETH/ETH, weETH/ETH), the hook temporarily amplifies pool liquidity by:

Pulling vault deposits that are earning Aave yield
Flash borrowing additional assets from Aave to 10x the liquidity depth
Capturing concentrated swap fees from the enhanced position
Immediately removing liquidity and repaying the loan
Redepositing to Aave to continue earning lending yield

This creates a "best of both worlds" strategy where LPs earn:

✅ Passive Aave yield (3-5% APR) when pools are idle
✅ Concentrated swap fees (10-50 bps per trade) via JIT liquidity bursts
✅ Leverage multiplier (5-10x) on fee capture through Aave borrowing

Result: LP capital works twice as hard, earning lending yield 24/7 while opportunistically capturing high-value swap fees through leveraged JIT positions.
