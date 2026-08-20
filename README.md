# StreamManager — continuous token payment streams

A single Solidity contract that multiplexes many id-keyed ERC20 payment streams
(Sablier-style). Money is released to the recipient continuously over time rather
than in a lump sum. Built for **payroll, grants, and vesting-as-a-stream**.

Clean-room implementation on OpenZeppelin v5 (`SafeERC20`, `ReentrancyGuard`,
`Ownable`, `Math.mulDiv`). Foundry-tested (unit + invariant).

## The model: linear release with an optional cliff

Each stream releases its principal linearly from `startTime` to `endTime`:

```
streamedAmount(t) =
    0                                   if t < startTime
    0                                   if cliff set and t < cliffTime
    deposit                             if t >= endTime
    deposit * (t - startTime) / (endTime - startTime)   otherwise
```

- The curve is **linear from start to end**. A cliff does not change the slope; it
  only suppresses withdrawals until `cliffTime`, at which point the withdrawable
  balance jumps to the linear-from-start value (it "catches up").
- `withdrawableAmount = streamedAmount − withdrawn`.
- The division uses `Math.mulDiv` (full-precision, floor rounding), so the recipient
  can never withdraw more than has actually accrued.

## Cancel semantics

A stream may be created `cancelable` or not.

- **Cancelable**: the sender *or* the recipient can `cancel`. Balances settle
  immediately — the recipient is paid the streamed-but-unwithdrawn amount
  (`streamed − withdrawn`) and the sender is refunded the unstreamed remainder
  (`deposit − streamed`). The stream then holds nothing and is `Canceled`.
- **Non-cancelable**: `cancel` reverts. Funds are locked to the schedule.

No admin path can seize or redirect stream funds. The owner can only configure the
protocol fee (bounded) and fee recipient.

## Per-stream protocol fee

At creation the sender deposits `totalAmount`. The contract credits the principal
from tokens **actually received** (fee-on-transfer safe), then skims a bounded
protocol fee to the `feeRecipient`:

```
received  = balanceAfter − balanceBefore      // fee-on-transfer safe
fee       = received * feeBps / 10_000        // feeBps <= 1000 (10% hard cap)
principal = received − fee                     // the streamed deposit
```

The fee is taken **once, at creation** — never on withdrawal or cancel.

## Status lifecycle

`Pending → Streaming → Settled → Depleted`, or `Canceled` at any point.

## Test

```bash
forge test        # unit + invariant suites
forge test -vvv   # verbose
```

Highlights:
- Exact linear arithmetic at multiple mid-points, at the cliff edge, and after end.
- Partial/max withdraw, over-withdraw and unauthorized-withdraw reverts.
- Mid-stream cancel splits exactly; post-cancel withdrawals blocked; non-cancelable reverts.
- Fee-on-transfer token: principal credited from actual received; accounting conserved.
- Protocol fee skimmed correctly; malformed params revert.
- **Funds-conservation invariant** over a bounded create/withdraw/cancel/warp campaign:
  for every stream `deposited == withdrawn + remaining + returnedToSender + fee`, and the
  contract's token balance always covers outstanding obligations.

## License

MIT
