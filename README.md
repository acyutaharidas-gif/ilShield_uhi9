# ILShieldHook

> **A self-funded, on-chain mutual insurance system embedded directly inside a Uniswap v4 pool.**
> Every zeroForOne swap contributes a configurable premium to a shared reserve that automatically
> compensates LPs for impermanent loss when they exit — with a deductible, a lock period,
> proportional coverage, and a pro-rata cap that prevents reserve drain.

Built for **UHI9 — The Yield-Protected AMM** | Atrium Academy Hookathon | April–June 2026

---

## The Problem

Impermanent loss is the single biggest reason sophisticated capital avoids AMM liquidity provision.
Every existing "solution" shares the same flaw: it lives *outside* the pool. LPs must monitor
positions manually, approve separate contracts, interact with off-chain keepers, and trust external
price feeds. The feedback loop between trading activity and LP protection is entirely severed.

## The Solution

ILShieldHook embeds the entire insurance mechanism inside a Uniswap v4 hook. The pool *is* the
insurer. The more the pool is used, the more the reserve grows. LPs opt into insurance by passing
their address in `hookData` at deposit time — no external protocol, no separate claim transaction,
no oracle dependency.

```
LP adds liquidity    →  hook records entry price (both tokens), tick range, timestamp
Swaps happen         →  0.5% of each zeroForOne output → insurance reserve (on-chain, automatic)
LP removes liquidity →  hook calculates exact IL, checks 3 gates, pays out automatically
```

---

## Architecture

### Three hook callbacks

| Callback | What it does |
|---|---|
| `afterAddLiquidity` | Records LP entry: `sqrtPrice`, `amount0`, `amount1`, `liquidity`, `tickLower`, `tickUpper`, timestamp |
| `afterSwap` | Skims `premiumBps%` of every zeroForOne swap output via `poolManager.take()` → reserve |
| `afterRemoveLiquidity` | Computes IL, checks 3 gates, calculates payout, transfers token1 ERC20 to LP |

### Hook permissions

```
afterAddLiquidity         1 << 10 = 0x0400
afterRemoveLiquidity      1 << 8  = 0x0100
afterSwap                 1 << 6  = 0x0040
afterSwapReturnDelta      1 << 2  = 0x0004
Combined address suffix             0x0544
```

### Insurance parameters (per pool, pool owner configurable)

| Parameter | Default | Meaning |
|---|---|---|
| `premiumBps` | 50 (0.5%) | % of zeroForOne swap output skimmed per swap |
| `coveragePct` | 5000 (50%) | % of computed IL actually paid out |
| `deductibleBps` | 200 (2%) | Minimum IL before any payout triggers |
| `minLockSeconds` | 86400 | Seconds LP must stay deposited before insurance activates |

---

## How It Works

### 1 — Position Recording (`afterAddLiquidity`)

When an LP adds liquidity with `hookData = abi.encode(lpAddress)`, the hook records:

```solidity
positions[poolId][lp] = LPPosition({
    entrySqrtPriceX96: sqrtPriceX96,  // baseline for IL calculation
    entryAmount0: amt0,               // token0 deposited
    entryAmount1: amt1,               // token1 deposited
    entryLiquidity: liquidityDelta,   // tracks partial exits
    entryTimestamp: block.timestamp,  // for lock gate
    tickLower: params.tickLower,      // for concentrated IL formula
    tickUpper: params.tickUpper,
    active: true
});
```

**Insured value** is computed using *both* tokens at entry price:

```
insuredValue = entryAmount1 + entryAmount0 × (entrySqrtPrice / 2^96)²
```

This uses `FullMath.mulDiv` (two-step, 512-bit intermediates) to avoid overflow.
At price = 1:1, a 50/50 position has insuredValue ≈ 2 × entryAmount1 — twice what
a token1-only calculation would give.

### 2 — Premium Collection (`afterSwap`)

For every zeroForOne swap (token0 in → token1 out):

```
delta.amount1() > 0  →  grossOutput = delta.amount1()   (swapper's perspective)
premium = floor(grossOutput × premiumBps / 10000)
poolManager.take(currency1, address(hook), premium)       →  real ERC20 in hook's wallet
return int128(premium) as hookDeltaUnspecified            →  nets to zero in flash accounting
```

**Flash accounting:** returning `+premium` as `hookDeltaUnspecified` creates a credit for the
hook in PoolManager's internal accounting. `poolManager.take()` claims that credit as real ERC20.
Debit from `take()` + credit from return delta = net zero. The hook receives real token1 with no
unresolved debt.

Verified exact by test 11: `actualPremium == floor((received + actualPremium) × premiumBps / 10000)`

### 3 — IL Calculation (no oracle needed)

IL is computed from the pool's own `sqrtPriceX96` at entry vs exit, using the exact concentrated
liquidity formula derived from Uniswap's liquidity equations:

**Hold value** (what LP would have if they never provided liquidity):
```
V_hodl = (sb - s0) × s1² / (s0 × sb)  +  (s0 - sa)
```

**LP value** at current price (three regimes):
```
In-range   (sa ≤ s1 ≤ sb):  V_lp = 2·s1 − sa − s1²/sb
Below sa                  :  V_lp = (sb − sa) × s1² / (sa × sb)
Above sb                  :  V_lp = (sb − sa)
```

Where `sa = sqrtPriceAtTick(tickLower)`, `sb = sqrtPriceAtTick(tickUpper)`,
`s0 = entry sqrtPrice`, `s1 = current sqrtPrice` (all Q64.96 units).

```
ilBps = (1 − V_lp / V_hodl) × 10000
```

All multiplications use `FullMath.mulDiv`. The formula **reduces exactly to the standard
full-range formula** `1 − 2√k/(1+k)` when `tickLower = minUsableTick` and
`tickUpper = maxUsableTick` (verified in test 8, within 5 bps). Returns 0 for out-of-range
entries (no IL coverage applies when LP enters fully single-sided).

### 4 — Payout Gates and Formula

Three gates run from the memory copy of `pos` before any state mutation (CEI pattern):

```
Gate 1: block.timestamp ≥ pos.entryTimestamp + cfg.minLockSeconds
Gate 2: ilBps > cfg.deductibleBps
Gate 3: insuranceReserve[pid] > 0
```

If all three pass, payout is:

```
fullIL     = propInsuredValue × ilBps / 10000
covered    = fullIL × coveragePct / 10000
proRataCap = reserve × propInsuredValue / totalInsuredValue  ← prevents first-come drain
payout     = min(covered, proRataCap, reserve)
```

State is cleared **before** the ERC20 transfer (reentrancy guard). The `totalInsuredBefore`
snapshot is taken before any state mutation so the pro-rata cap uses the correct denominator.

### 5 — Partial Exits

If `removedLiquidity < entryLiquidity`, the hook pays out proportionally and keeps the
position active with reduced values:

```
propInsuredValue = fullInsuredValue × removedLiq / entryLiquidity
entryAmount0    -= proportionalAmt0
entryAmount1    -= proportionalAmt1
entryLiquidity  -= removedLiq
```

Subsequent partial exits accumulate correctly against the remaining position.

---

## Public Interface

| Function | Caller | Purpose |
|---|---|---|
| `initializePool(PoolKey)` | Pool creator | Registers pool, sets default config, records caller as `poolOwner` |
| `setPoolConfig(PoolKey, PoolConfig)` | Pool owner only | Updates insurance parameters |
| `fundReserve(PoolKey, amount)` | Anyone | Manually seeds/tops-up the reserve (requires prior `approve`) |
| `getPoolConfig(PoolId)` | Anyone | Returns full config struct (auto-getter returns tuple, not struct) |
| `computeILBps(s0, s1)` | Anyone | Full-range IL in basis points |
| `computeILBpsConcentrated(s0, s1, lo, hi)` | Anyone | Concentrated IL in basis points (all regimes) |
| `computeInsuredValue(amt0, amt1, sqrt)` | Anyone | Portfolio value in token1 terms (both tokens) |

---

## Running the Project

### Prerequisites
```bash
foundryup   # latest Foundry
```

### Install and test
```bash
git clone <your-repo>
cd il-shield-hook
forge install

# All 12 tests with output
forge test --match-contract ILShieldHookTest -vv

# Single test
forge test --match-test test_ILPayout_WhenPriceMoves -vvvv

# Build only
forge build
```

### Local Anvil demo
```bash
# Terminal 1 — start local chain
anvil --code-size-limit 40000

# Terminal 2 — deploy everything
forge script script/ILShield_Anvil.s.sol:ILShieldAnvilScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast -vvvv
```

The script deploys PoolManager, two mock ERC20 tokens, mines the correct CREATE2 salt for the
hook, deploys ILShieldHook, initializes the pool, and seeds the insurance reserve with 20 tokens.
All addresses are logged for frontend wiring.

---

## Test Coverage (12 tests)

```bash
forge test --match-contract ILShieldHookTest -vv
```

| # | Test | What it verifies |
|---|---|---|
| 1 | `test_ILPayout_WhenPriceMoves` | Full lifecycle: deposit → 30 swaps → 24h lock → exit → payout to LP, reserve decreases |
| 2 | `test_NoPayout_WhenBelowDeductible` | Tiny swap, IL < 2%: exit pays nothing, reserve unchanged |
| 3 | `test_NoPayout_WhenLockNotMet` | Large price move but exit before 24h: no payout, position cleared |
| 4 | `test_ProRata_TwoLPs_FairSplit` | Alice + Bob same size: equal payouts, combined ≤ reserve |
| 5 | `test_ILMath_SpotChecks` | Full-range: k=1→0bps, k=2→572bps, k=4→2000bps, symmetric |
| 6 | `test_FundReserve_AndGetConfig` | Manual reserve top-up, config struct getter |
| 7 | `test_PartialRemoval_PositionUpdated` | Remove 50%: position stays active with halved values |
| 8 | `test_ILMathConcentrated_FullRangeMatchesOriginal` | Concentrated formula = full-range at min/max ticks (±5 bps) |
| 9 | `test_ILMathConcentrated_AboveRange` | Narrow range [0.5×, 2×], price moves to 3×: IL > 50% |
| 10 | `test_ReserveGrows_FromSwapPremiums` | 10e18 zeroForOne swap: reserve increases |
| 11 | `test_AfterSwap_PremiumIsExact` | 5 swaps: `premium == floor(grossOutput × premiumBps / 10000)` exact, cumulative |
| 12 | `test_CannotOverwrite_ActivePosition` | Direct hook call with active LP address: reverts correctly |

---

## IL Spot-Check Reference

| Scenario | Price ratio (k) | IL (bps) | IL (%) |
|---|---|---|---|
| Unchanged | 1.0× | 0 | 0% |
| Price +10% | 1.1× | ~23 | 0.23% |
| Price doubles | 2.0× | 572 | 5.72% |
| Price 4× | 4.0× | 2000 | 20.00% |
| Price 10× | 10.0× | 4972 | 49.72% |
| Price halved | 0.5× | 572 | 5.72% (symmetric) |
| Narrow [0.5×,2×], exit at 3× | above range | ~7500 | ~75% |

---

## Design Decisions

**Why token1 as the reserve currency?**
All payouts are in token1. Premiums are collected in token1 (from zeroForOne swaps). This keeps
the reserve denomination consistent without any on-chain conversion. Phase 3 will collect token0
premiums from oneForZero swaps and convert via router.

**Why `computeInsuredValue` uses both tokens?**
Using only `entryAmount1` underestimates the LP's actual position value by roughly 50% for a
balanced 50/50 deposit. The correct insured value is `amt0 × price + amt1`. At price = 1:1,
this doubles the effective coverage.

**Why the pro-rata cap?**
Without it, the first LP to exit during a large price crash drains the entire reserve. The cap
ensures each LP's maximum claim equals `(their insuredValue / totalInsuredValue) × reserve`,
regardless of exit order. The `totalInsuredBefore` snapshot is taken before position updates
so the denominator is correct.

**Why gates before `_applyPositionUpdate`?**
All three gates read from a memory copy of `pos` (no storage access). State is mutated in
`_applyPositionUpdate`, which is called in every exit path — before any ERC20 transfer.
This is the CEI (Checks-Effects-Interactions) pattern. The only external call is the final
`IERC20Minimal.transfer()`, and by then all state has been settled.

**Why store `tickLower` and `tickUpper` in the position?**
The concentrated IL formula requires knowing the LP's price range. Storing them at deposit
time means no additional calldata is required at exit — the hook has everything it needs.

**Why `require(!positions[pid][lp].active)` instead of overwriting?**
Without this guard, any actor can pass any LP address in `hookData` and overwrite that LP's
tracked entry price and timestamp — destroying their insurance. The require prevents this at
the cost of one active position per LP per pool (LP must exit before adding a new insured
position). Production fix: track by `(poolId, tokenId)` instead of `(poolId, lpAddress)`.

---

## Known Limitations

**One insured position per LP per pool**
A `require(!positions[pid][lp].active)` guard prevents overwriting, which also means an LP
must exit before re-entering with a new insured position. Production: track by tokenId.

**One-sided premium collection (Phase 2)**
Premiums are only collected from zeroForOne swaps (token1 output). OneForZero swaps produce
token0 output, which would require on-chain conversion to token1. This is Phase 3.

**Reserve denominated in token1**
When token1 is the volatile asset (e.g., WETH in a USDC/WETH pool where USDC has a lower
address and becomes token0), payouts arrive in WETH. As WETH falls in price, the WETH-
denominated payout is worth less in USD terms. True stable-denominated coverage requires
knowing which currency is the stablecoin.

**slot0 price (same-block manipulation risk)**
IL is computed from `poolManager.getSlot0()` at the moment of exit. A sufficiently capitalised
actor could sandwich the exit transaction to inflate computed IL. Production fix: use a TWAP
oracle for exit price. The pro-rata cap bounds the maximum damage.

**ERC20 token1 only**
If `currency1` is native ETH (`address(0)`), the `IERC20Minimal.transfer()` call will revert.
Pools with native ETH as token1 are unsupported. Adding ETH support requires a payable hook
and a `call{value: payout}("")` branch.

**No payout for out-of-range entry**
`computeILBpsConcentrated` returns 0 if `s0 <= sa || s0 >= sb`. A position added when
price is already outside the tick range has no insurance coverage (entered single-sided,
standard IL formula does not apply).

---

## Future Work

- **Phase 3**: Collect token0 premiums from oneForZero swaps, convert to token1 via in-pool routing
- **Multi-position**: Track by `(poolId, tokenId)` to support multiple insured positions per LP
- **TWAP oracle**: Replace slot0 with a time-weighted price for manipulation resistance
- **Dynamic premiums**: Adjust `premiumBps` based on rolling pool volatility
- **Coverage tiers**: Multiple lock/deductible/coverage parameter sets within one pool
- **Cross-pool reserve sharing**: Pool correlated pairs (e.g., ETH/USDC + ETH/DAI) share one reserve
- **Governance**: Token-weighted voting on insurance parameters

---

## Partner Integrations

No partner integrations used.

All IL computation uses Uniswap v4 core libraries only: `TickMath`, `FullMath`, `StateLibrary`.
The reserve is denominated in the pool's native `currency1` ERC20. No Chainlink, no external
price feed, no TWAP oracle, no lending protocol.

---

## Security Notes

This contract is an MVP built for a hackathon and has not been formally audited.
Do not deploy with real funds without a full security review.

Known attack vectors and mitigations documented above (hookData DoS, slot0 manipulation,
extreme price overflow guard at sqrtKScaled > 1e30).