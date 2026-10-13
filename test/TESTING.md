# Additional launch tests

The existing deployment, admission, launch, audit-regression and Robinhood-fork tests remain in place. These additions exercise the unchanged application contracts against the vendored Uniswap v4 PoolManager.

| File | Coverage |
| --- | --- |
| `LaunchFailures.t.sol` | Prelaunch guards, atomic failed launches and sales, invalid claims and proofs, claim-window boundaries, ownership separation, malformed payees, refused ETH transfers, split reentrancy, burn-bucket recovery and split rounding. |
| `HookFailures.t.sol` | Callback authentication, wrong currencies/fees/ranges, unavailable and malformed perps responses, low-gas fail-closed behavior, best-effort post-sweeps, engine bypass, migration with open positions, retired pools and protocol-fee rounding. |
| `PoolProperties.t.sol` | Checkpoint authorization, replay and caller isolation; fee-refund attribution; coin-only opening and negative tick rounding; buy/sell round trips; fee-migration conservation; creation and runtime opcode scans for all four application contracts. |
| `LaunchInvariant.t.sol` | Stateful custody and liquidity properties under mixed call sequences. |

The invariant handler targets 20 distinct actions, with extra weight on claiming. It uses three claimants, an ordinary trader, a refunding engine, the team and the timelock. It interleaves claims, transfers, burns, donations, buys, sells, checkpoints/refunds, fee collections, fee moves, burn buys, recovery, release and closure. Expected failures are checked explicitly. Unexpected handler reverts fail the campaign.

The three global invariants check:

- **Claims and custody:** independent per-claimant ghosts equal recorded claims; old-token custody plus releases equals claimed coins; launch coin custody backs the claim reserve, held excess and unsolicited donations; claim closure stays final.
- **Value conservation:** all ETH and token recipients are enumerated, balances conserve value, initial coin supply equals surviving supply plus accounted burns, and reserved IMD-buy ETH remains backed. Burn-executor receipts agree with successful buys.
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
