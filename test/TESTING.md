# Additional launch tests

The existing deployment, admission, launch, audit-regression and Robinhood-fork tests remain in place. These additions exercise the unchanged application contracts against the vendored Uniswap v4 PoolManager.

| File | Coverage |
| --- | --- |
| `LaunchFailures.t.sol` | Prelaunch guards, atomic failed launches and sales, invalid claims and proofs, claim-window boundaries, ownership separation, malformed payees, refused ETH transfers, split reentrancy, burn-bucket recovery and split rounding. |
| `HookFailures.t.sol` | Callback authentication, wrong currencies/fees/ranges, unavailable and malformed perps responses, low-gas fail-closed behavior, best-effort post-sweeps, engine bypass, migration with open positions, retired pools and protocol-fee rounding. |
| `PoolProperties.t.sol` | Checkpoint authorization, replay and caller isolation; fee-refund attribution; coin-only opening and negative tick rounding; buy/sell round trips; fee-migration conservation; creation and runtime opcode scans for all four application contracts. |
| `LaunchInvariant.t.sol` | Stateful custody and liquidity properties under mixed call sequences. |

## Revision against the fee-refund source

The source now keeps a 1,000 wei margin of each currency in the locked pool (the rounding cover for `lowerFee`'s move), books a refusing payee's share to it (`owed`), lets `recoverEth` cancel those books, keeps a release to the launch itself as held excess, refuses `renounceOwnership` and `releaseExcess` to the launch, caps `burnImd` on a thin pool, refuses `setPerpEngine` while positions are open, and skips the liquidation sweep for the launch's own sale. The tests of this round were updated to those semantics rather than rewritten:

- `PoolProperties.t.sol`: every payout leaves exactly the margin (or everything below it); the migration fuzz asserts the whole position moves to the unit when the margin is full, and coin conservation across a move; a move whose fees are below the margin pays nothing out (`test_MoveWithFeesBelowTheMarginKeepsThemAll`).
- `LaunchInvariant.t.sol`: the handler drives a toggleable refusing payee through `setPayees`, checks every split against the owed ledger, checks `recoverEth`'s cancellation rule, closes claims by every path (`endClaims`, burn, send, keep in the launch), and probes `NoRenounce` and `BadTo`. A fourth invariant keeps the owed total equal to the per-payee books, backed by held ETH beside the burn bucket, with the burn executor never booked and the owner unchanged.
- `LaunchFailures.t.sol`: a payee removed from the list keeps its books until recovery; a duplicate refusing payee books both parts exactly once and the books are never split to others.

The three low findings of that round (a split with nothing new never paid the books; a removed payee's books were only freed by cancelling all; a zero-fee $IMD pool blocked every burn) were answered by the source: `split` now offers the books alone when nothing new arrived, `setPayees` cancels the books of a payee it drops (the next split divides that ETH again), the thin-pool cap is gone and `burnImd` is the keeper's alone (`imdKeeper`, the owner until the timelock names one with `setImdKeeper`), with its `minImd` floor as the one price protection.

## Revision against the keeper and the cancel-on-drop source

Again the tests were updated to the semantics rather than rewritten:

- `LaunchFailures.t.sol`: before the launch, a stranger and the timelock are refused as `NotKeeper` before the empty bucket is looked at, the owner finds `NoEth`, and the owner cannot name a keeper. `test_RemovedPayeesBooksAreCancelledAndResplitKeptOnesAreNot` walks a refusing payee through a share change (books kept, offered alone with nothing new and refused again, not in the other payee's split), then its drop (`OwedCancelled`, books zero, the ETH divided among the new payees, the refuser never paid). `test_ListChangesWithoutDropsLeaveTheBooksAlone` sets the same list again and swaps the other payee: nothing cancels until recovery. The duplicate-payee test keeps both parts booked while the duplicate stays listed beside an accepting payee, then drops it and checks a single `OwedCancelled` of the full books (the second old entry finds nothing) before they are resplit.
- `LaunchInvariant.t.sol`: `setKeeper` is a new handler action (the timelock names an actor or zero; the team and actors are refused). `burnImd` pranks the current keeper, first checks that a stranger and the timelock are refused, then that a floor nobody can meet rolls the buy back whole (bucket and block slot untouched), then buys exactly `min(bucket, IMD_BUY_MAX)`. `configurePayees` asserts the drop cancels exactly the refuser's books and a kept refuser's books stand. `splitChecked` counts the books offered alone. A fifth invariant, `invariant_BurnIsTheKeepersAlone`, re-derives the keeper and probes a stranger and the timelock after every sequence, and the refused-shares invariant now also requires that nothing stays booked to a payee off the current list. The pinned sequence drives every new path and pins its counters.

One low finding is in `.imd-findings.json`: a listed payee with books that the timelock then names as the burn executor has its books stranded (split's executor branch runs before the books are read; setPayees keeps them because it is still listed) until `recoverEth`. It is reported, not asserted as correct.

The invariant handler targets 23 distinct actions, with extra weight on claiming. It uses three claimants, an ordinary trader, a refunding engine, the team and the timelock. It interleaves claims, transfers, burns, donations, buys, sells, checkpoints/refunds, fee collections, fee moves, burn buys, recovery, release and closure. Expected failures are checked explicitly. Unexpected handler reverts fail the campaign.

The five global invariants check:

- **Claims and custody:** independent per-claimant ghosts equal recorded claims; old-token custody plus releases equals claimed coins; launch coin custody backs the claim reserve, held excess and unsolicited donations; claim closure stays final.
- **Value conservation:** all ETH and token recipients are enumerated, balances conserve value, initial coin supply equals surviving supply plus accounted burns, and reserved IMD-buy ETH remains backed. Burn-executor receipts agree with successful buys.
- **Refused shares:** the owed total equals the per-payee books, is backed by held ETH beside the burn bucket, the burn executor is never booked, and the owner never changes.
- **Locked principal:** the actual v4 position equals recorded liquidity, meaningful principal cannot disappear during fee moves, the hook serves the current pool, and every retired pool remains empty.

Settings travel in Solidity comments: **256 invariant sequences of depth 80**, with `fail-on-revert = true`, and **1,000 cases for each new stateless fuzz test**. A deterministic mixed sequence checks that the handler successfully reaches claims, spot trades, refunds, collection and migration.

Run without network:

```sh
forge build --offline
forge test --offline
```

`RobinhoodFork.t.sol` now reports a real skip when `ROBINHOOD_RPC_URL` is absent. With that process environment variable set, its existing whole-launch integration runs against the deployed PoolManager, old token, Universal Router, pot bridge and IMD pool. No test calls `vm.setEnv`.

Offline limitations: the external legacy and IMD tokens use the existing ERC20 stand-ins; external-engine faults use a purpose-built mock. The offline suite does not emulate the old token's distributor restrictions or the bridge's cross-chain settlement. The existing live Robinhood fork test was also run successfully during this assignment, including distributor authorization, claims, router buys, fee distribution, the IMD burn buy, a move to 3.33% and the timelock's sale of held coins. No cross-chain bridge execution is claimed.

Application source, compiler settings and vendored dependencies are unchanged. No additional dependency is required.
