# ILShield Hook

> **A self-funded, on-chain mutual insurance system embedded directly in a Uniswap v4 pool.**
> Every swap contributes a configurable premium to a shared reserve that compensates LPs for
> impermanent loss when they exit — with tiered coverage, a deductible, a lock period,
> and mathematically correct IL calculation for both full-range and concentrated positions.

Built for **UHI9 — The Yield-Protected AMM** Hookathon (April–June 2026).

---

## The Problem

Impermanent loss is the single biggest reason sophisticated capital avoids providing AMM
liquidity. Existing "solutions" (external insurance protocols, IL derivatives, yield farming
subsidies) all share the same flaw: they live *outside* the pool. LPs must monitor, manually
claim, approve separate contracts, and trust off-chain keepers. The feedback loop between
trading activity and LP protection is entirely severed.

## The Solution

ILShield embeds the entire insurance mechanism inside a Uniswap v4 hook. The pool itself
becomes the insurer. The more the pool is used, the more the reserve grows. LPs opt into
insurance by passing their address in `hookData` at deposit time — no external protocol,
no separate claim transaction, no oracle dependency.

```
LP adds liquidity  →  hook records entry price, amounts, tick range
Swaps happen       →  0.5% of each output goes to the insurance reserve  (Phase 2)
LP removes liquidity →  hook calculates exact IL, checks gates, pays out automatically
```

---

## Architecture

### Phases

| Phase | Status | Description |
|-------|--------|-------------|
| **Phase 1** | ✅ Implemented & tested | Manual reserve seeding via `fundReserve()`. All insurance logic, gates, and payouts fully functional. |
| **Phase 2** | ✅ Implemented (afterSwap) | Automatic reserve collection: 0.5% of zeroForOne swap output is collected via `poolManager.take()` and credited to the reserve. |
| **Phase 3** | 🔲 Future | Bidirectional collection — collect token0 premiums from oneForZero swaps and convert to token1 via router. |

### Insurance Parameters (per pool, configurable by pool owner)

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `premiumBps` | 50 (0.5%) | Fraction of swap output reserved per swap |
| `coveragePct` | 5000 (50%) | Fraction of computed IL that is paid out |
| `deductibleBps` | 200 (2%) | Minimum IL before any payout is triggered |
| `minLockSeconds` | 86400 (24h) | Minimum time between deposit and exit |

---

## How It Works

### Position Recording (`afterAddLiquidity`)

When an LP adds liquidity and passes their address in `hookData`, the hook records:
- Entry pool price (`entrySqrtPriceX96`) — used as the IL baseline
- Token amounts deposited (`entryAmount0`, `entryAmount1`)
- Tick range (`tickLower`, `tickUpper`) — for accurate concentrated IL math
- Liquidity units (`entryLiquidity`) — for proportional partial exits
- Timestamp — for the lock period gate
- Total insured value in token1 terms (`computeInsuredValue`)

### Premium Collection (`afterSwap`)

For every zeroForOne swap, the hook intercepts a fraction of the token1 output:

```solidity
// For a zeroForOne swap producing outputAmount of token1:
uint256 premium = (outputAmount * premiumBps) / 10000;
poolManager.take(key.currency1, address(this), premium);
insuranceReserve[pid] += premium;
return (selector, int128(int256(premium)));   // positive: hook takes from output
```

The `hookDeltaUnspecified` return reduces the swapper's effective output by `premium` and
zeroes out the hook's delta with the PoolManager (verified against Uniswap v4 official docs).

### IL Calculation (no external oracle)

IL is computed from the pool's own `sqrtPrice` at entry vs exit, using the exact concentrated
liquidity formula derived from Uniswap's liquidity equations:

```
Normalised by L/Q96 (Q96 = 2^96):

V_hodl(s1) = (sb - s0) × s1² / (s0 × sb)  +  (s0 - sa)

V_lp(s1):
  in-range  (sa ≤ s1 ≤ sb) : 2·s1  − sa − s1²/sb
  below sa                  : (sb − sa) × s1² / (sa × sb)
  above sb                  : (sb − sa)

ilBps = (1 − V_lp / V_hodl) × 10000
```

Where `sa` = `sqrtPriceAtTick(tickLower)`, `sb` = `sqrtPriceAtTick(tickUpper)`,
`s0` = entry price, `s1` = current price (all X96 units).

This formula **reduces exactly to the standard full-range formula** `1 − 2√k/(1+k)`
when `tickLower = minUsableTick` and `tickUpper = maxUsableTick` (verified in tests).
All multiplications use `FullMath.mulDiv` (512-bit intermediates, no overflow).

### Payout Gates

Three conditions must pass before any token1 is transferred to the LP:

1. **Lock gate** — `block.timestamp ≥ entryTimestamp + minLockSeconds`
2. **Deductible gate** — `ilBps > deductibleBps` (2% default)
3. **Reserve gate** — `insuranceReserve[pid] > 0`

### Payout Formula

```
fullIL       = propInsuredValue × ilBps / 10000
covered      = fullIL × coveragePct / 10000
proRataCap   = reserve × propInsuredValue / totalInsuredValue   ← prevents drain
payout       = min(covered, proRataCap, reserve)
```

The **pro-rata cap** is the key fairness mechanism: no single LP can claim more than
their proportional share of the reserve, regardless of exit order.

### Partial Exits

LPs can partially remove liquidity. The hook scales insurance proportionally:
`propInsuredValue = fullInsuredValue × removedLiquidity / entryLiquidity`.
The position remains active with reduced values; subsequent partial exits accumulate correctly.

---

## Contract Interface

### Public Functions

| Function | Who calls | Purpose |
|----------|-----------|---------|
| `initializePool(PoolKey)` | Pool creator | Registers pool and sets default insurance config |
| `setPoolConfig(PoolKey, PoolConfig)` | Pool owner | Updates insurance parameters |
| `fundReserve(PoolKey, amount)` | Anyone | Manually seeds the reserve (Phase 1 / top-up) |
| `getPoolConfig(PoolId)` | Anyone | Returns full config struct |
| `computeILBpsConcentrated(s0, s1, lo, hi)` | Anyone | Returns IL in basis points (concentrated formula) |
| `computeILBps(s0, s1)` | Anyone | Returns IL in basis points (full-range formula, kept for compatibility) |
| `computeInsuredValue(amt0, amt1, sqrt)` | Anyone | Returns portfolio value in token1 terms |

### Hook Permissions

```
afterAddLiquidity         (1 << 10 = 0x0400)
afterRemoveLiquidity      (1 << 8  = 0x0100)
afterSwap                 (1 << 6  = 0x0040)
afterSwapReturnDelta      (1 << 2  = 0x0004)
Combined:                             0x0544
```

### Test Deployment Address Pattern

```solidity
address hookAddr = address(
    uint160(
        Hooks.AFTER_ADD_LIQUIDITY_FLAG   |
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
        Hooks.AFTER_SWAP_FLAG            |
        Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    ) ^ (0x4444 << 144)
);
```

---

## Test Coverage

Run all tests:
```bash
forge test --match-contract ILShieldHookTest -vv
```

| # | Test | What it verifies |
|---|------|-----------------|
| 1 | `test_ILPayout_WhenPriceMoves` | Full lifecycle: position recorded → price moved 30 swaps → lock elapsed → payout issued → reserve decreased |
| 2 | `test_NoPayout_WhenBelowDeductible` | No payout when IL < 2% deductible threshold |
| 3 | `test_NoPayout_WhenLockNotMet` | No payout when exiting before 24h lock; position still cleared |
| 4 | `test_ProRata_TwoLPs_FairSplit` | Two equal-size LPs receive equal payouts; combined payout ≤ reserve |
| 5 | `test_ILMath_SpotChecks` | Full-range formula: k=1→0bps, k=2→572bps, k=4→2000bps, symmetric |
| 6 | `test_FundReserve_AndGetConfig` | Manual reserve top-up; config getter returns correct struct |
| 7 | `test_PartialRemoval_PositionUpdated` | Partial exit: position remains active with proportionally reduced values |
| 8 | `test_ILMathConcentrated_FullRangeMatchesOriginal` | Concentrated formula = full-range formula for min/max ticks (within 5bps) |
| 9 | `test_ILMathConcentrated_AboveRange` | Above-range IL is large (>50%) for a narrow 0.5x–2x range |

---

## Running the Project

### Prerequisites
```bash
foundryup          # latest Foundry
```

### Clone and install
```bash
git clone <your-repo>
cd il-shield-hook
forge install
```

### Run tests
```bash
# All tests with logs
forge test --match-contract ILShieldHookTest -vv

# Verbose (full traces)
forge test --match-contract ILShieldHookTest -vvvv

# Single test
forge test --match-test test_ILPayout_WhenPriceMoves -vv
```

### Build
```bash
forge build
```

---

## IL Math: Spot Check Reference

| Scenario | k (price ratio) | IL (bps) | IL (%) |
|----------|-----------------|----------|--------|
| Unchanged | 1.0× | 0 | 0% |
| Price +10% | 1.1× | ~23 | 0.23% |
| Price doubles | 2.0× | 572 | 5.72% |
| Price 4× | 4.0× | 2000 | 20.0% |
| Price 10× | 10.0× | 4972 | 49.7% |
| Price halved | 0.5× | 572 | 5.72% (symmetric) |

For a narrow concentrated position [0.5×, 2×] with price going to 3× (above range): IL ≈ 75.85%

---

## Partner Integrations

No partner integrations. All IL math uses Uniswap v4 core libraries only (`TickMath`,
`FullMath`, `StateLibrary`). The reserve is denominated in the pool's native `currency1` — no
external price feed, no Chainlink, no TWAP oracle.

---

## Known Limitations

**hookData authorization (design tradeoff)**
LP addresses are passed via `hookData` — the standard Uniswap v4 pattern for passing caller
context through the PositionManager. The `require(!positions[pid][lp].active)` guard prevents
position overwrite, but a 1-wei griefing tx can occupy an LP's slot. Production fix: track
positions by `(poolId, tokenId)` instead of `(poolId, lpAddress)`.

**One-sided premium collection**
Phase 2 only collects premiums from zeroForOne swaps (token1 output). OneForZero swaps
generate token0 output, which would require on-chain conversion to token1. This is Phase 3.

**IL formula uses entry pool price, not position midpoint**
`entrySqrtPriceX96` is the pool price at deposit time. For a concentrated position added
at a price far from the tick range's geometric mean, the IL formula is a reasonable approximation
but not exact. For full-range positions (the most common case), it is exact.

**No payout for out-of-range entries**
`computeILBpsConcentrated` returns 0 if `s0 <= sa || s0 >= sb` (LP entered out of range).
A position entered entirely above or below the current price has no insurance coverage.

---

## Design Decisions

**Why token1 as the reserve currency?**
All payouts are in token1, which is the "quote" token in a Uniswap pair (e.g., USDC in
ETH/USDC). This makes IL coverage predictable and denominated in the stable-er asset.

**Why `computeInsuredValue` uses both tokens?**
The original design tracked only `entryAmount1` as the insured value. This undercounted
by ignoring the token0 contribution. At price = 1:1, a 50/50 position has 2× the insured
value of a token1-only position. The correct formula is `amt0 × price + amt1`.

**Why the pro-rata cap?**
Without it, the first LP to exit during a large price crash drains the entire reserve.
The cap ensures each LP's maximum claim is proportional to their share of total insured
value at the time of exit.

**Why gates before `_applyPositionUpdate`?**
The Checks-Effects-Interactions pattern. Position state is cleared (or partially reduced)
before any external ERC20 transfer, preventing reentrancy double-claims.

---

## Future Work

- **Phase 3**: Collect token0 premiums from oneForZero swaps, swap via in-pool routing
- **Multi-position**: Track by `(poolId, tokenId)` to support multiple positions per LP address
- **Dynamic premiums**: Adjust `premiumBps` based on pool volatility or utilisation
- **Coverage tiers**: Multiple tiers with different lock/deductible/coverage parameters
- **Cross-pool hedging**: Share reserve across correlated pairs (e.g., ETH/USDC + ETH/DAI)
- **Governance**: Token-weighted voting on insurance parameters

---

## Security Notes

This contract is an MVP built for a hackathon. It has not been audited.

Known attack vectors documented:
- hookData DoS (see Known Limitations)
- Reserve drainage via uncapped IL (mitigated by pro-rata cap)
- Out-of-range entry (returns 0 IL, no payout)
- Overflow in extreme price scenarios (FullMath protects most cases; theoretical overflow
  at MAX_SQRT_PRICE with max uint128 amounts — not reachable in practice)