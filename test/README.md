# Contributor test additions

The additional suites use the vendored, real Uniswap v4 PoolManager and the actual
QuantumCanaryHook and QuantumCanaryToken. Hook deployments use CREATE2 with the
required permission bits. Only the canary observer and bounty recipient are test
doubles. No new dependency, RPC, environment mutation, or configuration is needed.

| Suite | What it checks |
| --- | --- |
| `QuantumCanaryDifferential.t.sol` | Compares all swap modes against an unhooked pool with identical liquidity and fees. Covers partial fills, disconnected liquidity ranges, exhausted/empty pools, protocol fees, retirement, actual trade deltas, LP fee growth, tick state, and bounty events. |
| `QuantumCanaryAdversarial.t.sol` | Nets multiple swaps before settlement on a fresh token-only manager; checks atomic rollback on failed settlement, rejected claim burns, spoofed callback callers, malformed/reverting oracle reads, pool guards, invalid constructors, permanent retirement, and failed payouts both inside and outside an unlock. |
| `QuantumCanarySettlementInvariant.t.sol` | Runs 256 sequences of 80 randomized actions. Tracks a fee ledger derived from core swap deltas, native backing for claims, fixed token supply, destination immutability, and settled manager debts. Mixes batches, payout callers, failed oracle reads, rejecting/reentrant recipients, and claim-theft attempts. Ends every sequence by redeeming all claims and withdrawing the LP position. |

The new invariant campaign deliberately leaves the observer untripped, so fees
remain active throughout the random sequence. The existing invariant suite covers
trip/reset sequences. Fuzz counts are set in the test files (1,000 runs per new
property), and unexpected handler reverts fail the invariant campaign.

The comparison pools share a manager but have distinct pool IDs. They receive
identical liquidity and protocol-fee settings; each underlying AMM trade must
produce identical price, tick, liquidity, fee growth, and protocol fees. This checks
that the hook's reverting quotes do not execute a second trade. Foundry's
`recordLogs` includes reverted subcalls, so quote events are distinguished by their
sender; state equality establishes rollback rather than assuming recorder output
is a transaction receipt.

Run the delivered tests offline, keeping generated artifacts outside the repository:

```sh
forge build --out /tmp/quantum-canary-out --cache-path /tmp/quantum-canary-cache
forge test --out /tmp/quantum-canary-out --cache-path /tmp/quantum-canary-cache
```

The existing mainnet fork rehearsal skips without fork state. These offline tests
do not establish the live observer's bytecode or the external factory's supply
distribution.

An extreme signed-input arithmetic failure is reported separately in
`.imd-findings.json`, with a self-contained Foundry reproduction. Its source was
run under `test/scratch/` and failed on the current implementation. It is excluded
from the delivered passing suite; no test asserts that failure is correct.
