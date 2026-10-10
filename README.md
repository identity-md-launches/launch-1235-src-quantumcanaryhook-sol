# Quantum Canary

QuantumCanaryHook sends **100% of its flat 1% ETH swap fee to the Quantum Canary bounty**. No human can redirect or withdraw that fee. There is no owner, administrator, fee setter, pause, upgrade, or withdrawal function. Once the canary reports a trip, the hook permanently stops charging fees.

The existing observer contract is on Ethereum mainnet at [`0x626517225096671868609c1bBF9c1B416A4eFd9a`](https://etherscan.io/address/0x626517225096671868609c1bBF9c1B416A4eFd9a). Its `canaryAddress()` supplies the destination, `0x379C0A5704C211f26eadd26e670246E242Af9e7E`, whose secp256k1 private key is unknown under the canary's cryptographic assumptions. Bounty ETH goes directly to that address, rather than to the observer contract. The hook reads the destination exactly once during construction and cannot change it.

**The requester keeps 0% of the token supply at launch.** QuantumCanaryToken is a plain ERC-20 named **Quantum Canary**, symbol **CANARY**, with 18 decimals and exactly **1,000,000,000 tokens**. It mints the entire fixed supply once to its deployer, the launch factory. The factory is responsible for sending 90% to the pool and 10% to the launch's Merkle distributor. Neither the requester nor this hook has a reserved allocation. Buying tokens later is an ordinary transfer; the token has no transfer tax or further minting path.

## Fee economics

ETH is always currency0 because the pair is native ETH. CANARY is currency1. The hook charges ETH exclusively, including on exact-output swaps. The separate pool LP fee is **12,500 / 1,000,000 = 1.25%**, with tick spacing **60**. The hook neither overrides nor distributes that LP fee.

All fee arithmetic rounds down to whole wei. Define `P` as the total ETH the buyer pays, including the hook fee, and `G` as a seller's gross ETH output before the hook fee. The invariants are:

```text
buy:  bounty fee = floor(P / 100)
sell: bounty fee = floor(G / 100), seller receives G - fee
```

Thus an exact-input buy of 1 ETH sends 0.01 ETH to the bounty and supplies 0.99 ETH to the AMM, which applies its own LP fee. An exact-output sell requesting 1 ETH receives that full 1 ETH net; the AMM must supply enough additional ETH to fund the bounty.

| Swap mode | ETH side | Delta mechanism | Fee for a full fill |
| --- | --- | --- | --- |
| Buy, exact ETH input `B` | Specified input | Positive specified `beforeSwap` delta | `floor(B / 100)` |
| Buy, exact CANARY output | Unspecified input | Positive `afterSwap` delta | `floor(E / 99)`, where `E` is AMM ETH input including LP fees |
| Sell, exact CANARY input | Unspecified output | Positive `afterSwap` delta | `floor(G / 100)` |
| Sell, exact net ETH output `N` | Specified output | Positive specified `beforeSwap` delta | `floor(N / 99)` |

The `/99` gross-up makes the fee 1% of the appropriate total ETH side. Taking 1% of AMM input and then adding it to a buyer's bill would instead charge less than 1% of their total payment.

### Price limits and partial fills

v4 fixes the specified delta before executing the trade, and `afterSwap` can change only the unspecified currency. A fee based solely on the requested amount would overcharge an ETH-specified swap that stops at its price limit.

For these two modes the hook first performs a **reverting quote against the same PoolManager and pool**. Core skips callbacks on a swap initiated by the hook itself. The helper immediately reverts with the quoted ETH delta, rolling back prices, liquidity, protocol fees, transient debts, and logs. Nothing is transferred. The outer swap then runs normally with a fee determined from the actual fill capacity:

- Exact-input buy: reserve `floor(B/100)`, quote AMM input `B - reserve`, and charge the smaller of the reserve and `floor(quoted ETH input / 99)`.
- Exact-output sell: reserve `floor(N/99)`, quote gross output `N + reserve`, and charge the smaller of the reserve and `floor(quoted gross ETH output / 100)`.

The real swap respects the caller's original price limit. When it hits that limit, only the ETH actually traded is charged. Unused input remains with the router and follows its normal refund policy. The quote adds AMM computation cost to the two ETH-specified modes; it does not substitute another pool or price source. Once retired, the hook skips quotes and returns zero deltas.

Saturating requests are accepted the way core accepts them: an exact-input budget of `type(int256).min` or an exact-output request near `type(int256).max` means "trade up to the price limit". The hook computes the magnitude without signed overflow and caps the quote request at core's `int128` fill limit, which a larger request could never exceed anyway. Core's own checked arithmetic still needs an exact-output request to leave room for the fee delta.

## Settlement and permissionless payout

Every fee is initially minted as an ERC-6909 native ETH claim owned by the hook in the PoolManager, token id **0**. This works even when a fresh, token-only pool holds no ETH and its router settles the swap input after the callbacks.

At the end of `afterSwap`, the hook attempts to burn claims and call `PoolManager.take(native ETH, canaryAddress, amount)`. This is its only outward asset-transfer path. It pays as much as the manager's current ETH balance can cover, bounded by v4's signed accounting limit. No claims are approved to operators or transferred to callers.

Automatic redemption uses a separate self-call with a gas budget and preserves accounting gas. A rejecting or gas-consuming recipient rolls back both the burn and the transfer inside that call. **A failed payout never reverts the swap.** Claims remain for a later attempt. Successful fee-bearing transactions leave the hook with only native ETH claims, never CANARY or an ETH balance.

Anyone can call `payout()` with no arguments. It unlocks the manager when necessary, burns available claims, and pays the same immutable destination. It also works when a router calls it inside an existing unlock after settling input. It returns the amount paid, or zero when no payment succeeds. There is no caller reward or configurable recipient. A new pool's first buy may leave claims until a later swap or `payout()`; anyone can complete that payment after the transaction settles.

Ordinary ETH transfers to the hook are rejected. Do not send it tokens or force ETH into it: unsolicited assets cannot be rescued or redirected. Donations should go directly to its `canaryAddress()`.

## Retirement and monitoring

`afterSwap` reads `isTripped()` using a bounded `staticcall`. Reverts, exhausted call gas, malformed return data, and invalid booleans are treated as not tripped and cannot block swaps. The hook also checks before a swap because ETH-specified fee deltas must be known there. The genuine PoolManager makes no mutable external call between these two callbacks, so the genuine observer's balance-based answer cannot change in that interval.

The observer's `isTripped()` is a live balance predicate, not a latch: a refill of the bounty clears it. Because the hook's own payout is such a refill, **every payout path reads the trip before it burns or transfers anything**: the automatic payout at the end of a swap, a standalone `payout()`, and a `payout()` made by a router inside its own unlock. A drained bounty is therefore latched as retired by whichever hook action comes first, and the hook's transfer can never hide it. Pending claims are still paid to the bounty after retirement.

The first true observation sets `retired` permanently. A later refill of the bounty, a false response, or an unavailable observer cannot restore fees. Swaps still use the normal pool LP fee. Previously accrued claims remain payable to the bounty after retirement.

**Monitoring responsibility:** the existing [observer implementation](https://github.com/identity-md-launches/launch-1213-src-quantumcanary-sol/blob/main/src/QuantumCanary.sol) requires its recorded high-water mark to reach `thresholdWei` before `isTripped()` can report a below-threshold balance. Anyone should call its existing permissionless `poke()` after funding reaches the threshold, and periodically thereafter. This hook reads the observer; it does not call `poke()`. Read `thresholdWei()` and `highWaterMark()` on chain rather than assuming it is armed. A refill by a third party can still clear the live alarm before any hook action observes it; monitoring bounty transactions and nonce remains useful. No keeper is privileged, and no keeper key controls fee funds.

## Deployment parameters

| Contract | Constructor arguments |
| --- | --- |
| QuantumCanaryToken | None; deploy from the launch factory |
| QuantumCanaryHook | `IPoolManager manager`, `IQuantumCanary canary` |

For this launch, `canary` is `0x626517225096671868609c1bBF9c1B416A4eFd9a` on Ethereum, chain id **1**. The launch supplies its actual PoolManager as a constructor argument; no manager address is hardcoded. Both dependencies and the derived destination are immutable.

The constructor reads `canaryAddress()` once with a guarded `staticcall`. When the observer has code, its answer must be a nonzero address or deployment reverts; on mainnet that answer is `0x379C0A5704C211f26eadd26e670246E242Af9e7E`. When the observer has **no code**, as on the empty chain where the launch's protected checks rehearse the attested creation code, the hook does not revert: for the launch observer only, it falls back to the constant `LAUNCH_CANARY_ADDRESS`, the same value. That constant is not a guess: the observer's source derives the address deterministically from its fixed seed phrase, and `test_launchDestinationMatchesTheObserverSourceDerivation` deploys a verbatim copy of that source offline and checks the derivation against the constant. Any other address without code is refused, so a mistyped observer cannot deploy silently.

Enabled permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. All other permissions are false. Their low-address-bit mask is **`0x20cc`**. The constructor checks its own address bits against `getHookPermissions()`, and every implemented manager callback rejects other callers. Disabled callbacks and unknown selectors revert.

Deploy the hook with CREATE2 using a salt mined for the **actual CREATE2 deployer**, exact creation bytecode, compiler settings, and encoded constructor arguments. `script/MineQuantumCanary.s.sol` finds a salt without deploying or broadcasting:

```text
forge script script/MineQuantumCanary.s.sol:MineQuantumCanary \
  --sig "run(address,address)" <actual-create2-factory> <actual-pool-manager>
```

Its `find(...)` function also accepts an explicit canary and search range for offline/local tooling. Rebuild and mine again whenever bytecode or constructor arguments change.

The launch factory deploys the token and hook, splits the supply, and initializes the pool atomically. `beforeInitialize` accepts native ETH pools with nonzero token currency, fee 12,500, tick spacing 60, and this hook. It does not restrict the initializer or pin the launch token to a guessed address. Consequently, other pools with those same policy terms can also use the hook and fund the same bounty. The factory computes the actual opening price from its 10 ETH opening market-cap policy and deployed token; tests use a 1:1 fixture price, not the launch's final price. The manifest belongs to the subsequent launch step; none is authored here.

The deployer must verify the actual manager and observer code, destination, pool terms, address flags, and reproducible bytecode before submitting transactions. It must also verify the factory's supply split and router settlement/refund/slippage handling. Explorer verification, launch simulation, independent review, and permissionless monitoring remain operational responsibilities; this project broadcasts no transactions and controls no funded wallet.

## Reproduce the checks

Dependencies are ordinary vendored files in `lib/`, with their licenses and exact upstream revisions recorded in each `REVISION`. There are no submodules or dependency downloads at build time. Foundry pins Solidity **0.8.26**, Cancun EVM, optimization, and `bytecode_hash = "none"`. Neither FFI nor filesystem permissions are enabled.

```sh
forge build
forge test
forge fmt --check
```

The offline suite uses a real local v4 PoolManager and AMM math. It exercises all four swap modes; funded and token-only managers; complete and partial fills; exact wei rounding; payout retry, partial payout and failure; hostile recipients; guarded trip reads; irreversible retirement; initialization policy; callback access control; claim theft attempts; fixed supply; and opcode/permission checks. Fuzz tests run 1,000 cases per property. The stateful invariant campaign mixes swaps, recipient failures, payout retries, trip changes and malformed reads for 128 sequences of 64 calls, checking that fees are either claims or bounty ETH and that token/ETH conservation holds.

The two optional mainnet tests skip cleanly without a fork and do not read or modify environment variables. A recorded rehearsal at block **26,161,866** uses the live observer and a newly deployed local real PoolManager:

```sh
forge test --match-contract QuantumCanaryMainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26161866 -vv
```

The mainnet destination read for that rehearsal was `0x379C0A5704C211f26eadd26e670246E242Af9e7E`, which equals the hook's offline fallback constant; both come from the same seed-phrase derivation in the observer's source. The fork test asserts that the live answer and the hook's immutable destination agree.

See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for the local adversarial review and its limits.
