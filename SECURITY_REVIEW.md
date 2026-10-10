# Local adversarial review

This is a review of the delivered implementation and integration tests, not an independent audit or a release authorization.

## Authority and finality

The hook has no human-authorized action. Manager callbacks verify the immutable manager; quote and unlocked-redemption helpers verify a self-call. Those restrictions protect accounting, not an administrative role. Only `payout()` is an open asset-moving entry point, and it cannot accept a recipient. Constructor-derived dependencies and destination have no setter. The fee is constant. The runtime tests scan for DELEGATECALL, CALLCODE, SELFDESTRUCT and the deployment-size limit, matching the supplied protected check's scan.

The only outgoing asset transfer is `poolManager.take(Currency.wrap(address(0)), canaryAddress, amount)`. The hook cannot transfer or approve CANARY, cannot transfer claims to a caller, and never appoints a claim operator. A theft test attempts ERC-6909 `transferFrom` against the hook and confirms that the caller cannot obtain its claims. A changing mock observer cannot alter the snapshotted destination.

## Delta accounting and NoOp exposure

Every fee-bearing callback mints exactly its positive returned ETH delta as claims. Minting debits the hook, and core's returned delta credits it; redemption's burn and take cancel each other. The router settles the remaining user delta. Integration callbacks assert that both hook currency debts are zero at unlock completion, and real PoolManager rejects any residual debt.

`beforeSwapReturnDelta` never consumes an entire positive-size exact-input budget: its fee is at most `floor(budget/100)`. It cannot switch the swap type or retain CANARY. Quotes revert immediately, including all nested manager state and accounting changes. The real trade runs in the outer call. Tests cover partial fills in all modes with real price limits, fuzz sizes/limits, and check fee economics independently from the callback's calculation.

The pool must use native ETH as currency0, fee 12,500, spacing 60 and this hook. Dynamic and unsupported pools are rejected. The hook deliberately supports every pool meeting these terms; it has no first-pool registration that an attacker could seize.

## External calls and payout isolation

The observer's `isTripped` call is static, bounded to 30,000 gas, and copies at most 32 return bytes. Only an exact ABI true result retires the hook. Revert, invalid boolean, short data, oversized data and gas-exhaustion tests confirm that broken reads retain fees without blocking swaps.

Automatic payout runs in a gas-bounded self-call, and skips an attempt when insufficient callback gas remains. Redemption burns before transferring and uses a transient payout guard. Recipient rejection rolls back both manager operations. Tests exercise rejecting and gas-exhausting receivers and payout reentry. Callback reentry during payout is refused inside the isolated payout call. Claims survive failure and can be paid by anybody later, with no caller compensation or authority.

The hook checks the trip before ETH-specified deltas as well as in `afterSwap`. This depends on the supplied observer's documented balance/high-water-mark predicate and genuine PoolManager behavior: neither executes a mutable call between those checks. A malicious replacement observer whose answer depends on pool price, gas, or caller context is outside the declared immutable-mainnet dependency assumption. Paying the bounty happens after the trip read. Retirement is latched locally, so subsequent refills and failed reads cannot restore fees.

## Conservation and boundaries

Unit/fuzz tests independently check buyer fee = floor(total ETH paid / 100), seller fee = floor(gross ETH received / 100), unchanged CANARY transfer amounts, ETH conservation, preserved exact-output amounts, and whole-wei rounding around 99/100 boundaries. Claim redemption caps each burn/take to the manager's available ETH and maximum int128 accounting amount. Artificially reducing manager liquidity verifies partial redemption and preservation of the remainder. Core validation failures leave both fees and bounty balances unchanged.

The 128-by-64 stateful campaign includes irreversible trip observation, reverted/malformed reads, rejecting/reentrant recipients, and payouts interleaved with every swap mode. It checks that cumulative fees equal claim balances plus bounty receipts, token supply remains fixed, and native ETH is conserved among the swapper, manager and bounty.

## Remaining release work and limitations

- Verify the exact intended mainnet PoolManager and factory integration, including native settlement, user slippage checks, refunds and the policy-derived opening price. The fork rehearsal exercises the live canary with a local real manager, not the launch factory or its production router.
- Verify source/bytecode and factory supply distribution at launch. The token mints to the deployer; the external launch factory performs the 90/10 split and requester-zero allocation.
- Record funding with the canary's permissionless `poke()` so its high-water mark can arm the alarm. A trip that clears before the hook observes it cannot be latched retroactively. Monitor the bounty balance, nonce and transactions as well as the observer.
- Obtain independent contributor review before release. Slither, Mythril and formal verification were not run in this environment. No claim is made that tests are an audit.
- Permissionless payout has no gas subsidy or keeper reward. If no later swap pays claims automatically, someone must pay gas for `payout()`.
- Unsolicited ERC-20 transfers and forced ETH cannot be prevented, and have no rescue path. They are not swap fees and should never be sent to the hook.
