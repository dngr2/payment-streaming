# StreamManager — pitch

**Pay people by the second, not by the invoice.**

StreamManager turns any ERC20 into a continuous payment rail. Lock a total, set a
start, an optional cliff, and an end — the recipient's balance accrues linearly and is
withdrawable at any moment. One contract runs unlimited concurrent, id-keyed streams.

## Who it's for

- **Payroll** — salaries that vest by the block; a leaver keeps only what they earned.
- **Grants** — time-based DAO funding that can be clawed back on cancel.
- **Vesting** — token vesting as a stream, with a cliff, no bespoke contract per grantee.

## The differentiator: the accounting is provably conservative

Continuous-payment contracts live or die on one property — money in must equal money
out at every point on the curve. This one is built around that property and holds a
stateful **funds-coverage invariant** to it: across a fuzz campaign of random
create / withdraw / cancel / top-up calls with time warps over many concurrent streams,
every stream satisfies `received == withdrawn + remaining + refunded + feeAtCreation`,
and the contract's balance always covers what it still owes. Concretely:

- A recipient can never withdraw more than was deposited, and no dust is stranded.
- Cliff + linear release is checked at the boundaries — before start, at the cliff edge,
  mid-stream, and after end. `Math.mulDiv` floor rounding means the recipient can never
  draw more than has accrued.
- Cancel splits exactly: the recipient gets what streamed, the sender gets the rest.
- Fee-on-transfer safe — principal is credited from tokens actually received.
- Reentrancy-guarded, checks-effects-interactions throughout.
- No admin path can move stream funds — the owner only sets a **bounded** fee (≤ 10%).

## Beyond the basics (v2)

- **Top-up** a live stream: add principal and extend the end time so the per-second rate
  stays constant — more runway, not a retroactive raise.
- **Batch create** many streams atomically in one transaction — a whole payroll run or
  grant cohort in a single tx.

## How it earns

A small, owner-configurable protocol fee is skimmed **once at stream creation** and
routed to the fee recipient. Bounded at 10% and enforced on-chain. Revenue scales
directly with streams created — payroll runs, grant rounds, vesting cohorts.

## Assurance

Foundry: 49 unit tests plus the `invariant_FundsConserved` funds-coverage invariant,
all green. Independent and unaudited — thoroughly tested and written defensively, but
review it yourself before putting funds at risk.
