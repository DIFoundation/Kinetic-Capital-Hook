# Kinetic Capital Hook
### A Flow-Based Liquidity Risk & Yield Primitive for Uniswap v4

> Kinetic Capital Hook is a Uniswap v4 hook that transforms static liquidity provision into a dynamic financial system where LP positions continuously adapt based on market volatility, impermanent loss exposure, and yield-bearing insurance capital.

---

> **We didn't reduce impermanent loss. We turned it into a market.**

---

## The Problem

Over 51% of Uniswap v3 LPs are unprofitable. A peer-reviewed study published on ScienceDirect in November 2025 formally introduced impermanent loss as a novel, DeFi-specific risk factor — meaning until recently, even academic finance had no proper model for it. The risk has been there since day one. The tools to see it, price it, or trade it have not.

LP positions in every AMM today share three fundamental weaknesses:

- **They are static.** Once you deposit, your risk profile is locked and invisible.
- **They are blind.** You don't know your real IL exposure until you exit — and by then, the loss is already realized.
- **They are monolithic.** Yield, risk, and protection are permanently bundled into one object you can't decompose or manage.

The market has tried to solve this with external insurance protocols, manual hedging via perps, and token emission subsidies. None of them work at the position level. None of them are native to the pool. None of them exist inside the AMM where the risk is actually created.

**Kinetic Capital Hook solves this from inside Uniswap v4 itself — using the hook architecture to intercept the LP lifecycle and restructure it entirely.**

---

## Why This Is Only Possible on Uniswap v4

Kinetic Capital Hook could not exist on v2 or v3. It is architecturally dependent on three specific innovations that Uniswap v4 introduces:

### 1. Hook Callbacks on LP Lifecycle Events
v4 hooks can intercept `beforeAddLiquidity` and `afterRemoveLiquidity` directly. This is what lets Kinetic capture the exact entry price, mint risk tokens, collect premiums, and compute realized IL at exit — all in the same transaction as the LP action, with no external bot or keeper required.

### 2. Singleton PoolManager + Flash Accounting
v4's singleton architecture means all pools share one contract. Kinetic exploits this so that vault interactions (depositing premiums into Aave/Morpho, settling IL payouts) can be batched within v4's flash accounting system — drastically reducing gas and enabling atomic settlement that would be impossible across separate pool contracts.

### 3. ERC-6909 Native Multi-Token Support
v4 natively supports ERC-6909 multi-token accounting inside the PoolManager. Kinetic uses this to represent `RISK-TOKEN` and `YIELD-CLAIM-TOKEN` as first-class position objects tracked by the protocol itself — not external contracts bolted on top.

Without these three primitives, you cannot decompose an LP position into tradable layers atomically. v4 makes it possible for the first time.

---

## The Core Idea

When an LP deposits into a Uniswap v4 pool with the Kinetic hook, their position is no longer a static share of a pool. It becomes **a decomposed financial instrument** — split into three distinct, independently useful layers:

| Layer | What It Represents | Form |
|---|---|---|
| **Yield Layer** | Swap fee income + vault yield | `YIELD-CLAIM-TOKEN` |
| **Risk Layer** | Impermanent loss exposure curve | `RISK-TOKEN` (ERC-6909) |
| **Protection Layer** | Insurance coverage funded by premiums | Vault-backed claim |

These layers can be held, transferred, traded, or hedged — independently of each other.

This is the primitive that is missing from DeFi today: **LP risk as a first-class financial object.**

---

## What Gets Created (Three Missing Markets)

### 1. A Risk Market
Impermanent loss exposure is tokenized into `RISK-TOKEN` — an instrument that represents the live delta between an LP's current position value and their equivalent hold value. This token can be:

- Bought by parties who want to speculate on pool volatility staying low
- Sold by LPs who want to offload their directional exposure
- Aggregated across positions to construct pool-level risk indices

For the first time, IL is not something that happens *to* you silently. It is something that can be **priced, transferred, and traded** — while you are still in the pool.

### 2. A Yield Smoothing Market
LP fee income is notoriously lumpy — most fees concentrate during high-volatility events, the exact same moments when IL is worst. Kinetic routes earned yield through an **ERC-4626 vault** (Aave / Morpho) that smooths distribution over time. LPs receive stable, predictable cash flows instead of volatile fee spikes clustered around market stress events.

### 3. An Insurance Capital Market
Premiums paid by LPs are not held as dead collateral. They are deployed into the yield vault immediately, compounding continuously. When an LP exits with IL above their coverage threshold, the vault pays the claim from this yield-bearing reserve. In calm markets, surplus premium is returned to LPs or recycled as additional yield.

Insurance capital that earns yield while it waits — no external subsidy, no protocol token, no governance vote required.

---

## Who Buys Risk Tokens? (The Counterparty Story)

The risk token market works because three distinct counterparty types have clear, concrete reasons to hold `RISK-TOKEN`:

**1. Volatility Desks and Structured Product Traders**
These are participants who run market-neutral books and want isolated exposure to DEX volatility without taking on directional price risk. `RISK-TOKEN` gives them a pure volatility instrument tied to real on-chain liquidity — something that does not exist anywhere today. They earn premium income when pools stay calm and absorb losses when IL spikes, exactly like selling options.

**2. Protocol Treasuries**
A DAO treasury that is long ETH anyway has a natural hedge argument for holding ETH/USDC pool risk tokens. If ETH moves sharply, their treasury gains on the ETH side and absorbs the risk token loss — it nets out. In return, they earn the premium stream in calm conditions. This is a yield strategy that protocols can run permissionlessly using their own treasury capital.

**3. Yield Aggregators and Vaults**
Protocols like Yearn or Beefy looking for novel yield sources can deploy into `RISK-TOKEN` positions as a premium-earning strategy. The risk profile is quantifiable, the instrument is on-chain, and the yield is real — not dependent on token emissions.

None of these counterparties need to understand DeFi deeply. They need a price, a risk curve, and a settlement mechanism. Kinetic provides all three.

---

## System Architecture

```
LP Deposit
    │
    ▼
KineticCapitalHook.sol          ← Uniswap v4 hook entrypoint
    │                             (beforeAddLiquidity / afterRemoveLiquidity / afterSwap)
    ▼
RiskEngine.sol                  ← decomposes position into yield / risk / protection
    │
    ├──────────────────────────┐
    ▼                          ▼
RiskToken.sol              YieldVault.sol (ERC-4626)
(ERC-6909)                     │
    │                          ├── deployed to Aave / Morpho
    ▼                          ▼
Risk Market                Insurance Capital Pool
(secondary trading)        (IL payout reserve + yield accrual)
         │                         │
         └──────────┬──────────────┘
                    ▼
            Settlement Engine
            (on LP exit: compute IL → pay claim or refund premium)
```

---

## How It Works: Step by Step

### Step 1 — LP Deposits Liquidity

The LP adds liquidity to an ETH/USDC pool. The hook intercepts `beforeAddLiquidity` and:

1. Records TWAP entry price as the IL computation baseline
2. Classifies current market regime via `VolatilityOracle.sol`
3. Calculates a volatility-adjusted insurance premium (see Economic Model below)
4. Mints to the LP:
   - `YIELD-CLAIM-TOKEN` — entitlement to swap fees and vault yield
   - `RISK-TOKEN` — the LP's live impermanent loss exposure
5. Forwards the premium to `YieldVault`, where it begins compounding immediately

The LP's position is now decomposed. They hold two instruments instead of one opaque share.

### Step 2 — Risk Tokens Enter the Market

The LP holds a `RISK-TOKEN` representing their live IL exposure curve. They have three choices:

- **Hold it** — maintain full IL exposure, receive vault protection on exit
- **Sell it** — transfer the exposure to a counterparty, pocket the sale price, lose coverage
- **Hedge it** — use the token as collateral or reference in external derivatives

Buyers of `RISK-TOKEN` are taking on the IL exposure in exchange for the settlement upside if the pool stays calm. They are, functionally, writing insurance on the LP's position.

This is a **decentralized volatility market running natively inside Uniswap v4** — no synthetic wrapper, no oracle dependency for pricing, no external protocol.

### Step 3 — Live IL Tracking and Regime Classification

Between deposit and withdrawal, `VolatilityOracle.sol` continuously classifies the market:

| Regime | Condition | Effect on System |
|---|---|---|
| Calm | Low realized vol, tight price range | Low premiums, tight risk token pricing |
| Normal | Baseline swap activity | Standard pricing, normal vault inflows |
| Elevated | High volatility, wide price swings | Premium surcharge, risk tokens reprice upward |
| Extreme | Market stress, rapid divergence | Solvency checks triggered, coverage caps enforced |

The hook updates risk token value in real time based on regime shifts — creating a **live, on-chain price feed for LP risk** that has never existed in DeFi before.

### Step 4 — LP Exits

On withdrawal, the hook intercepts `afterRemoveLiquidity` and runs settlement:

1. Computes realized IL using TWAP entry vs TWAP exit prices
2. Converts IL into basis point exposure
3. Compares IL against the LP's coverage threshold

**If IL > threshold:**
- Vault releases payout to LP, proportional to coverage tier
- `RISK-TOKEN` holders absorb the settled loss

**If IL < threshold:**
- LP receives unused premium back + accrued vault yield
- `RISK-TOKEN` holders keep their premium income

The LP is protected. The market settles. The vault replenishes from ongoing premium inflows.

---

## Economic Model

### Premium Pricing Formula

```
Premium (bps) = base_rate × volatility_multiplier × position_size_factor

Where:
  base_rate             = 50 bps (0.5% of position value, configurable)
  volatility_multiplier = 1.0× (Calm) | 1.5× (Normal) | 2.5× (Elevated) | 4.0× (Extreme)
  position_size_factor  = 1.0× (< $10k) | 0.9× ($10k–$100k) | 0.8× (> $100k)
```

A $10,000 position entering in Normal regime pays approximately **$75 in premium** upfront. That premium immediately enters the vault and starts earning Aave/Morpho yield — so the insurance reserve grows even before any claim is made.

### Coverage Tiers

| Tier | IL Threshold | Max Payout | Premium Rate |
|---|---|---|---|
| Basic | > 5% IL | Up to 50% of IL | 0.5× base |
| Standard | > 3% IL | Up to 75% of IL | 1.0× base |
| Full | > 1% IL | Up to 100% of IL | 2.0× base |

LPs choose their tier at deposit. Higher coverage costs more premium, which flows into a deeper vault.

### Vault Solvency Model

The vault enforces a minimum **110% collateralization ratio** at all times:

```
Solvency Ratio = Vault Assets / Total Outstanding Coverage

Target: ≥ 110%
Warning: < 110% → premium intake prioritized, new coverage capped
Critical: < 100% → emergency pause, no new positions accepted
```

In a worst-case correlated black swan event — where the entire pool IL triggers simultaneously — the vault's yield accrual from Aave/Morpho acts as a first buffer before touching principal. Coverage is pro-rated if the vault is insufficient, not zeroed out.

### Flow Summary

```
PREMIUM FLOW
LP pays premium → YieldVault → Aave/Morpho yield accrual
                                      │
                                      └──► IL payouts on LP exit

RISK FLOW
LP mints RISK-TOKEN → secondary market
                           │
              counterparties buy/sell volatility exposure
                           │
                    settles on LP exit against realized IL

YIELD FLOW
Swap fees → YIELD-CLAIM-TOKEN holders (smoothed over time)
Vault surplus yield → returned to LPs in calm regimes
```

---

## Technical Stack

### Smart Contracts

| Contract | Responsibility |
|---|---|
| `KineticCapitalHook.sol` | Uniswap v4 hook — intercepts LP lifecycle events |
| `RiskEngine.sol` | Decomposes LP position into yield / risk / protection layers |
| `RiskToken.sol` | ERC-6909 fractional risk exposure token |
| `YieldVault.sol` | ERC-4626 vault — premium compounding + IL reserve |
| `VolatilityOracle.sol` | Regime classification — drives dynamic premium pricing |

### Hook Callbacks

```solidity
beforeAddLiquidity      // capture TWAP entry, mint tokens, collect premium, classify regime
afterRemoveLiquidity    // compute realized IL, trigger vault payout or premium refund
afterSwap               // update vol accumulator, reprice risk tokens, update regime
```

### IL Computation

```
Realized IL = Hold Value − Exit Pool Value

Hold Value    = (entry_qty_A × exit_price_A) + (entry_qty_B × exit_price_B)
Pool Value    = current value of LP's share of pool at exit

IL in bps     = (Hold Value − Pool Value) / Hold Value × 10,000
```

TWAP-based pricing on both entry and exit prevents spot price oracle manipulation. The 30-minute TWAP window is configurable per pool based on liquidity depth.

---

## Security Design

| Threat Vector | Mitigation |
|---|---|
| Oracle price manipulation | TWAP-based IL computation — spot price not used for settlement |
| Vault insolvency | 110% solvency ratio enforced + pro-rata payout on undercollateralization |
| Reentrancy attacks | Checks-effects-interactions pattern across all vault and token interactions |
| Risk token inflation | Exposure caps per position — max coverage ceiling enforced at mint |
| Black swan correlated exit | Vault yield buffer absorbs first, pro-rata payout if breached, emergency pause at 100% |
| Premium siphoning | Premium forwarded directly to vault in same tx as `beforeAddLiquidity` — no intermediate custody |

---

## Why This Is Only Possible Now

The academic literature formally quantified IL as a DeFi risk factor for the first time in November 2025. The problem has existed since 2018 — the tools to address it at the protocol level have not. Three things converged in 2025/2026 to make Kinetic possible:

1. **Uniswap v4 hook architecture** — gives us `beforeAddLiquidity` and `afterRemoveLiquidity` callbacks for the first time
2. **ERC-4626 vault standard maturity** — Aave v3 and Morpho both fully support it, making yield routing simple and composable
3. **ERC-6909 multi-token standard** — v4 natively supports it, making risk tokenization a first-class primitive

This is not a theoretical product. It is a product that the infrastructure finally supports.

---

## Why This Wins

**For LPs:**
- Real-time visibility into actual IL exposure — not discovered post-exit
- Option to sell or hedge risk without exiting the pool
- Insurance premium compounds in the vault — they earn on their own protection capital
- Coverage activates automatically at exit — no claim filing, no governance vote

**For Traders and Protocols:**
- A native, quantifiable volatility instrument built on real DEX liquidity
- No synthetic wrappers, no external dependencies — pure v4 primitive
- Protocol treasuries can earn premium yield using capital they already hold

**For the Ecosystem:**
- IL stops being a hidden tax that silently extracts from uninformed LPs
- Deeper, more stable pools as LPs gain confidence in their risk profile
- A new DeFi asset class: tokenized, tradable DEX risk

---

## The Insight

Every derivatives market in traditional finance started the same way — someone took a risk that was previously invisible, gave it a price, and created an instrument around it.

Credit risk became credit default swaps.
Interest rate risk became interest rate swaps.
Equity volatility became options markets.

**Impermanent loss risk is next.**

IL has been bleeding LPs since 2018. It has no market, no price, no instrument. Kinetic Capital Hook is the infrastructure layer that makes LP risk legible, transferable, and marketable — entirely on-chain, native to the pool where the risk is born.

---

## Demo Day Flow

1. LP deposits 10 ETH + $25,000 USDC into ETH/USDC pool on testnet
2. Hook intercepts `beforeAddLiquidity` — classifies regime as *Normal*, charges $75 premium
3. Vault receives $75 → immediately deployed to Aave, starts earning yield
4. LP receives `YIELD-CLAIM-TOKEN` and `RISK-TOKEN`
5. Volatility desk wallet buys LP's `RISK-TOKEN` — taking on IL exposure for premium income
6. ETH price drops 40% — pool accumulates 18% IL on the LP's position
7. LP calls `removeLiquidity` — hook intercepts `afterRemoveLiquidity`
8. Hook computes: 18% IL > 3% Standard threshold → vault releases payout
9. LP is compensated. Risk token settles — volatility desk absorbs the delta they priced in
10. Pool remains liquid. Both parties knew their risk the entire time.

---

## Deployment

- **Network:** Unichain Sepolia Testnet
- **Hook Standard:** Uniswap v4 BaseHook
- **Vault Integration:** Aave v3 Testnet (Morpho as fallback)
- **Oracle:** Uniswap v4 TWAP + Chainlink price feed (cross-validation)
- **Token Standards:** ERC-6909 (risk/yield tokens), ERC-4626 (vault)

---

*Kinetic Capital Hook — DeFi Primitive · Uniswap v4 Hook · Risk Markets · Yield Infrastructure*
*Built for UHI9 Hookathon: Impermanent Loss & Yield Systems*

