# StreamManager — continuous ERC20 payment streams

One Solidity contract that pays money out continuously over time instead of in a
lump sum. Lock a total, set a start, an optional cliff, and an end; the recipient's
balance then accrues by the second and is withdrawable at any moment. A single
contract runs unlimited concurrent, id-keyed streams. Built for **payroll, grants,
and vesting-as-a-stream**.

Clean-room implementation on OpenZeppelin v5 (`SafeERC20`, `ReentrancyGuard`,
`Ownable`, `Math.mulDiv`, `SafeCast`), Solidity 0.8.26, Foundry.

## The edge: the accounting is provably conservative

Continuous-payment contracts live or die on one property — the money in must always
equal the money out, at every point on the curve, forever. This one is built around
that property and holds a stateful invariant to it.

- **Funds-coverage invariant.** A fuzz campaign drives a random sequence of
  create / withdraw / cancel / top-up calls with time warps across many concurrent
  streams, and after every step asserts, for each stream:
  `received == withdrawn + remaining + refunded + feeAtCreation` (with
  `deposit == received − feeAtCreation`). The contract's token balance is asserted
  to always cover the sum of outstanding obligations — exactly for a normal token,
  and never below for a fee-on-transfer one. **A recipient can never withdraw more
  than was deposited, and no dust is left stranded.**
- **Cliff + linear math verified at the boundaries.** The release curve is checked
  at `t < start`, at the cliff edge (withdrawable jumps to the linear-from-start
  value and "catches up"), at multiple mid-points, and at/after `end`. Division is
  `Math.mulDiv` (full-precision, floor rounding), so the recipient can never
  withdraw more than has actually accrued.
- **Cancel splits streamed-vs-unstreamed exactly.** On cancel the recipient is paid
  `streamed − withdrawn` and the sender is refunded `deposit − streamed`; the two
  sum to the outstanding balance with nothing left over and nothing lost.
- **Fee-on-transfer safe.** Principal is credited from tokens *actually received*
  (`balanceAfter − balanceBefore`), not from the requested amount, so a
  deflationary token can never leave a stream under-funded.
- **Reentrancy safe.** Every value-moving function is `nonReentrant` and follows
  checks-effects-interactions — storage is settled before any token transfer.
- **No admin path to stream funds.** The owner can only set the fee recipient and a
  fee bounded at 10% (`MAX_FEE_BPS = 1_000`, enforced on-chain). There is no
  function by which the owner can move, freeze, or seize a stream's principal.

## The release model

Each stream releases its principal linearly from `startTime` to `endTime`:

```
streamedAmount(t) =
    0                                                   if t < startTime
    0                                                   if cliff set and t < cliffTime
    deposit                                             if t >= endTime
    deposit * (t - startTime) / (endTime - startTime)   otherwise
```

A cliff does not change the slope — it only suppresses withdrawals until
`cliffTime`, after which the withdrawable balance equals the linear-from-start value.
`withdrawableAmount = streamedAmount − withdrawn`. Once canceled, the streamed figure
is frozen at the cancel point.

Status lifecycle: `Pending → Streaming → Settled → Depleted`, or `Canceled` at any point.

## Features

- **Create** a linear stream with an optional cliff, cancelable or not.
- **Withdraw** any amount up to the withdrawable balance, or `withdrawMax`. Callable
  by the recipient or an approved withdrawer.
- **Cancel** (sender or recipient, cancelable streams only) with the exact split above.
- **`topUp(streamId, addedAmount)` (v2)** — the sender adds principal to a live
  (non-ended, non-canceled) stream. The end time is extended to hold the per-second
  rate constant (`newDuration = oldDuration * newDeposit / oldDeposit`), so a top-up
  buys more time rather than granting a retroactive raise; the already-streamed figure
  is unchanged at the moment of top-up. Fee-on-transfer safe; pays the same bounded fee.
- **`createStreamBatch(CreateParams[])` (v2)** — create many streams atomically in one
  transaction; any failing element reverts the whole batch.
- **Recipient management** — `transferRecipient` moves stream ownership (and clears any
  approval); `approveWithdrawer` delegates withdrawal without transferring ownership.
- **Per-stream protocol fee** — a bounded fee is skimmed **once, at creation** (never on
  withdrawal or cancel), from tokens actually received.

## Security & testing

Foundry, all green:

- **49 unit tests** — exact linear arithmetic at mid-points, the cliff edge, and after
  end; partial / max withdraw; over-withdraw, unauthorized-withdraw and post-cancel
  reverts; mid-stream cancel split; fee-on-transfer conservation; fee skimming;
  malformed-parameter reverts; and the v2 `topUp` (rate-preserving) and batch-create paths.
- **1 stateful invariant** — `invariant_FundsConserved`, the funds-coverage invariant
  described above, run over a bounded fuzz campaign. It passes green; it is slow
  (~12 min locally), so it is run on its own:

```bash
forge test --no-match-contract Invariant   # the 49 unit tests, fast
forge test --match-contract  Invariant     # the funds-coverage invariant (slow)
```

A line-by-line review of the `streamedAmount` math, the cancel split, withdraw bounds,
fee-on-transfer conservation and reentrancy found no exploitable bug. During that pass,
individual pieces of the streamed-math and cancel-split were mutated by hand and
confirmed to break a test — a spot check that the suite catches the arithmetic it
claims to, not a full mutation-testing run.

Indicative gas from `forge test --gas-report` (median): `createStream` ~188k,
`withdraw` ~76k, `cancel` ~86k, `topUp` ~50k.

## Usage

```solidity
// Approve first: token.approve(address(mgr), totalAmount);

// A 1-year salary stream with a 90-day cliff, cancelable.
uint256 id = mgr.createStream(
    employee,                          // recipient
    address(token),                    // ERC20 to stream
    120_000e18,                        // totalAmount pulled from the sender (pre-fee)
    uint40(block.timestamp),           // startTime
    uint40(block.timestamp + 90 days), // cliffTime (0 for no cliff)
    uint40(block.timestamp + 365 days),// endTime
    true                               // cancelable
);

// Recipient collects what has accrued, any time.
uint256 got = mgr.withdrawMax(id);           // or mgr.withdraw(id, amount);

// Sender adds budget mid-stream; end time extends, per-second rate held constant.
uint40 newEnd = mgr.topUp(id, 30_000e18);

// Either party ends it early: recipient keeps what streamed, sender is refunded the rest.
mgr.cancel(id);
```

## License

MIT. See [LICENSE](LICENSE).

Honest note: this is an independent, unaudited implementation. It is thoroughly
unit- and invariant-tested and written defensively, but it has not had a third-party
security audit. Review it yourself before putting funds at risk.
