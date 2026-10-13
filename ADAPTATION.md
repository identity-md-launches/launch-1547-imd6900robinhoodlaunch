# Launch adaptation

The existing constructor already supports the contracts-only launch. The production-code changes are the three
reproduced audit fixes in `src/IMD6900RobinhoodLaunch.sol` (first round) and the independent review's reproduced
findings (the revision, listed last). The coin's source, the build configuration, the vendored dependencies, the
addresses, the launch's constructor signature, the hook's constructor and permissions, the 4.44% static fee and the
launch economics remain unchanged.

## Deployment handoff

Deploy only `IMD6900RobinhoodLaunch` on chain 4663 with these four nonpayable constructor arguments, in order:

| Argument | Value |
| --- | --- |
| `owner_` | `0x35da9c0303507ddf708e87f2568eddf12c47a059` |
| `poolManager_` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `imdstr_` | `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F` |
| `timelock_` | `0x16D3f65B708883DF042d98E1C7a49B32A33E2A14` |

The constructor creates only `IMD6900LockedPool`, with no calls to pre-existing contracts and no salt mining. Ownership
goes to the supplied team wallet, never the factory. The existing later `createHook(salt)` and owner-only `launch()`
steps remain intact, including hook permissions, timelock ownership, and the coin's mandatory `0x6900` prefix.

Compiler settings remain solc 0.8.26, via IR, optimizer 200 runs, Cancun, metadata bytecode hash `none`. No manifest,
deployment, signature or broadcast was produced. Programmable's existing script must build its exact-source bundle
from this revised source; an artifact or attestation for the pre-audit launch bytecode is not interchangeable. The
scripts still derive hook and coin salts from the deployed launch's address and init-code hashes.

## Reproduced findings and fixes

### Burn batching — `d7faa1b3073d9ebefc020cfcff0d4945ed5ec80e7ef1e4083e00fff4a359d321`

Reproduced with the real vendored PoolManager, the default ETH/IMD key, full-range liquidity `2e20`, and an initial
price of 261 IMD/ETH. A 150 ETH coin buy plus the opening buy funded a `0.6784764 ETH` burn bucket. A 10 ETH front-run,
eight attempted burn calls, and a back-run increased the attacker's 100 ETH balance to `100.309950164318461594 ETH`.
The single-burn control ended at `99.912966340529872311 ETH`.

`burnImd` now permits one successful buy, at most the existing `IMD_BUY_MAX` of 0.1 ETH, per EVM `block.number` across
all callers. `nextImdBurnBlock` exposes the next permitted block and `BurnRateLimited` rejects additional buys. The
limit also applies when a small bucket is emptied and refilled within the same block. Reverting transactions do not
consume the allowance. The initial value allows the first burn even at block zero.

This is the audit's bounded-spend mitigation, not a new price oracle. It prevents draining a whole accumulated bucket
inside one sandwich; it does not guarantee execution prices or eliminate single-buy or multi-block MEV. Blocks that
expose the same EVM `block.number` share the allowance, regardless of timestamp or RPC block height. Existing `minImd`
checks remain available and the timelock retains control of the selected IMD pool.

### Unspent burn ETH — `1e3202b5464046f31fa14c403311f785346a62eac0c8feedb6434c9db7654fb9`

Reproduced using an initialized IMD pool with no liquidity, as in the supplied proof. Before the fix, `burnImd(0)`
reduced the bucket by 0.1 ETH without spending ETH or buying IMD. That ETH then became eligible for the fee split.

The PoolManager callback now rejects an IMD burn buy with `IncompleteImdBuy` unless the actual ETH input equals the
requested spend. Empty and partially filled buys revert atomically, preserving the bucket, ETH, pool price, burn
totals and block allowance. This chooses the audit's full-fill-or-revert remedy. The opening coin buy and `sellHeld`
retain their existing partial-fill behavior; the new check applies only to the IMD burn operation.

### Aggregate claim reserve — `a53739e05c5dd0a911ab540aa9dc596579cd20ec71ace59ad0dd332011f0ada9`

Reproduced with valid leaves for 40M and 20M coins but a separately configured total reserve of 50M. Before the fix,
both claims succeeded, taking 10M coins from the timelock's excess and allowing `claimedTotal` to exceed `claimTotal`.

`claim` now rejects any amount greater than the remaining total reserve with the existing `OverClaim` error, in
addition to enforcing the holder's leaf allowance. The check precedes accounting updates and token transfers. An
inconsistent root therefore cannot consume held excess or underflow the reserve. Holders can still claim exactly the
remaining reserve; early closure, post-deadline release and the timelock's sale remain usable.

### Informational coverage — `c8e1ba5708274f7c1c2ac5ea30a235d989a5686d335dd855e3d66f65ea5ebfaf`

This was a coverage/size observation, not an actionable defect. The original 44 local tests passed, and the original
runtime size reproduced at 22,532 bytes. No actionable finding was dismissed as non-reproducible.

`ROBINHOOD_RPC_URL` is unset in this environment, so the existing fork test returns before exercising chain state.
The supplied live dependency addresses, pot bridge's ETH acceptance, burn executor's bridging behavior and actual IMD
pool state were not independently verified here. They were preserved exactly as requested. The perps engine is not
part of this repository; its existing local mocks do not constitute an audit of that engine. No Slither or Mythril
run is claimed.

## Tests and documentation

- `test/LaunchAudit.t.sol`: regressions for all three findings, the single-burn economic control, shared caller/block
  limit, refilled buckets, block-zero and remainder handling, rollback on slippage and empty/partial fills, retry after
  liquidity returns, exact-reserve claims, both closure paths, and fuzzed claim ordering/amounts. The original source
  failed the three primary regression tests before it was changed.
- `test/LaunchAdmission.t.sol`: zero-value CREATE2 factory deployment with the exact supplied constructor arguments,
  code-less dependencies, team/timelock ownership, exactly one child, no automatic hook or coin deployment, runtime
  and initcode size limits, and gas bounds across different factory addresses and salts.
- `README.md`: documents the corrected burn limit, incomplete-fill behavior and regression coverage.

## Revision: the independent review's findings

Each was reproduced on the accepted tree before anything changed (the four supplied proofs all failed on it; the others
were reproduced with the review's own steps). All regressions are in `test/LaunchReview.t.sol`.

### Refused payee shares re-split — `4891b788d800` (medium, proof)

`split()` paid a refusing payee's part with a `call` and only logged the failure, so the ETH stayed unbooked and the
next split treated it as new fees: 10% of it went to the burn bucket each time. `src/IMD6900RobinhoodLaunch.sol`:
a failed part is now booked to its payee (`owed(payee)`, `owedTotal`), excluded from what later splits divide like
`imdBucket`, and offered again to a listed payee with its new share (cleared only when the transfer succeeds).
`recoverEth` (the timelock's escape hatch for exactly this case) cancels every booking, by epoch, only when it takes
beyond the unbooked ETH, and shrinks the burn bucket only after that. A delisted payee's booking waits for the timelock
(`recoverEth`, or listing it again); no separate pay-out entry point was added, to stay under the runtime size limit.

### lowerFee re-derived the liquidity from rounded amounts — `959b71d4fb20` (medium, proof)

`src/IMD6900LockedPool.sol`: `_move` puts the stored liquidity back unchanged and computes what v4 takes for it the
way `Pool.modifyLiquidity` rounds (`_amountsFor`, rounded up by tick). The shortfall is at most a wei per currency
(a floor against a ceiling of the same value); it is covered by the old pool's earned fees, which come out in the same
delta, or by a margin the pool now keeps: `MARGIN` (1,000 wei of each currency) stays behind at every `collect` /
`_payOutHeld` and out of the opening's rounding dust (`open`). Only if nothing is earned and nothing is kept does the
liquidity fall to what the amounts hold, as before. Consequences: `Collected` reports what was paid out (the margin
excluded), the launch's excess at the opening is 1,000 wei of coin smaller, and
`test_HarvestSplitsTheEthAndBurnsTheCoin` now allows the split's own wei of rounding dust (the fee amount is no longer
an exact multiple of 10,000 wei); that assertion encoded a coincidence, not a rule.

### A liquidation sweep nested inside the launch's refund window — `a8a1088f7ba1` (medium, proof)

`src/IMD6900Hook.sol`: `_sweep` skips the launch's own swaps (sender == the locked pool's `launcher()`), as it skips
the engine's. Nothing can then earn the position fees between the launch's `feeCheckpoint` and `feeRefund`, which
isolates both cases the review merged (a refunding engine's nested checkpoint moving the sale's refund, and a
non-refunding engine's fees landing in the sale's refund with the `paid - back` underflow). The sale (`sellHeld`, the
timelock, rare) therefore liquidates nothing itself; what it sinks, the next trade's pre-trade sweep closes. The
`paid - back` guard was not added: with the sweep gone, only the PoolManager and this hook run between the pair, so
the refund cannot exceed the swap's own fee, and a guard nothing can reach cannot be tested. Nest-aware checkpoints
were the alternative; they would not have covered the non-refunding case without the hook bracketing every sweep.

### The engine could be unwired with positions open — `8d3fd3ae881f` (medium)

`src/IMD6900Hook.sol`: `setPerpEngine` refuses (`PerpsOpen`) to unwire or replace an engine that reports
`openCount() != 0` (wiring the same engine again is no change), so `lowerFee`'s guard cannot be stepped around by the
same timelock. An engine that cannot report (no code, reverts, short return) stays replaceable: that is the hook's
documented way out of a broken engine, and a mistaken address must not brick perps for good. The locked pool's own
guard still counts an engine that cannot say as holding positions. Trade-off accepted: an honest engine whose
positions can never close keeps both its wiring and the fee fixed, which is what the brief's rule asks for.

### The $IMD buy could be sandwiched on a thin pool — `bbf57e19fc03` (medium)

`src/IMD6900RobinhoodLaunch.sol`: `burnImd` sizes each buy to the pool, at most `IMD_BUY_MAX` and no more than the
pool's fee fraction of the ETH its in-range liquidity stands for (`L * 2^96 / sqrtP * fee / 1e6`), so the buy's own
price impact stays under the fee a sandwich pays twice over, whatever `minImd` the caller passes. With the review's
pool (2e19 full-range liquidity) each buy is about 0.0124 ETH and front-runs of 0.05, 0.1, 0.3 and 1 ETH all lose;
with the earlier audit's 2e20 pool the full 0.1 ETH still goes through. A pool with no in-range liquidity keeps the
existing `IncompleteImdBuy` path. No oracle, TWAP or keeper role was added; a thin pool drains the bucket over more
blocks. The per-block cap from the first round stays.

### Advisory findings, all reproduced and fixed

- `9907b6c0017b` (renounce): `renounceOwnership` now reverts `NoRenounce` in the launch, as in the hook.
- `937f1074b052` (release to self): `releaseExcess` refuses `to == this` (`BadTo`); `releaseUnclaimed` with
  `to == this` adds the reserve to `excessHeld`, as `launch()` and `endClaims` keep it.
- `8166dd84de84` (open's downcast): `open` reverts `BadPrice` when the opening liquidity would not fit `uint128`.
- `71be5da8ba32` (trust assumptions): not a defect. Recorded for the requester to confirm: the owner (a single team
  wallet) chooses `launch(excessTo)` and `releaseUnclaimed(to)`; the timelock may `endClaims` any time after the
  launch, repoint `setImdPool` to any pool anyone's `burnImd` then trades on, and wire any engine with `setPerpEngine`
  (a refunded caller in the locked pool, called with nearly all remaining gas on every trader's swap).

Runtime size after the revision: `IMD6900RobinhoodLaunch` is **24,215 bytes**, 361 bytes under EIP-170 (the hook's
creation code it embeds grew with its two changes); the locked pool's creation code is only in the launch's initcode
(36,582 bytes, under EIP-3860). Any further growth of the launch or the hook must stay within that margin.

## Local verification results

- `forge build --sizes`: passed with the existing configuration. Launch runtime is **24,215 bytes**, 361 bytes
  below EIP-170; creation code 36,582 bytes, below EIP-3860. No library links remain.
- `forge test --offline`: passed, 72 tests (59 from before plus the 13 revision regressions), the 256-run claims
  fuzz test included, plus the fork test's early return when `ROBINHOOD_RPC_URL` is unset. No live fork execution is
  claimed.
- The four supplied proofs (`Proof_4891b788d800`, `Proof_959b71d4fb20`, `Proof_a8a1088f7ba1`, `Proof_1e3202b54640`)
  were copied unchanged into scratch space and run one at a time against the final tree: all four pass (the first three
  failed on the starting tree). The protected `Contracts.protected.t.sol` harness was exercised in the first round; the
  project's own admission tests (`test_PassesTheAdmissionScan`, `test_FitsOneTransaction`, `test_DeploysOnAFreshChain`,
  `LaunchAdmission.t.sol`) pass on the final tree. This machine caps memory at 1.5 GB, so via-IR compiles of more than
  about ten test files at once are killed; the suite compiles and runs within it as committed.
- The additional factory test measured 7,445,862 and 7,445,874 gas for deployments from two different factories/salts,
  below its 8,388,608-gas bound. These are factory-call execution measurements, excluding transaction intrinsic gas.
- Hash checks confirmed `foundry.toml` and all 82 vendored files were unchanged. `git diff --check` passed.
