# StreamManager — pitch

**Pay people by the second, not by the invoice.**

StreamManager turns any ERC20 into a continuous payment rail. Lock a total amount,
set a start, an optional cliff, and an end — the recipient's balance then accrues
linearly and is withdrawable at any moment. One contract runs unlimited concurrent
streams, id-keyed.

**Who it's for**
- **Payroll** — salaries that vest by the block; leavers keep only what they earned.
- **Grants** — milestone or time-based funding a DAO can claw back on cancel.
- **Vesting** — token vesting as a stream, with a cliff, no custom contract per grantee.

**Why it's safe**
- Fee-on-transfer safe deposits (principal credited from tokens actually received).
- Reentrancy-guarded, checks-effects-interactions throughout.
- No admin can touch stream funds — the owner only sets a **bounded** fee (≤ 10%).
- Cancel refunds are exact: recipient gets what streamed, sender gets the rest.

**How it earns**
- A small, owner-configurable protocol fee is skimmed **once at stream creation** and
  routed to the fee recipient. Bounded at 10% and enforced on-chain. Revenue scales
  directly with streams created — payroll runs, grant rounds, vesting cohorts.

Foundry-tested end to end, including a funds-conservation invariant proving the
contract never creates or loses tokens across create/withdraw/cancel.
