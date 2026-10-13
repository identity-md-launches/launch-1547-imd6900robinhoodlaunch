# Launch adaptation

The existing constructor already supports the contracts-only launch. The only production-code changes are the three
reproduced audit fixes in `src/IMD6900RobinhoodLaunch.sol`. The coin, hook and locked-pool sources, build configuration,
vendored dependencies, addresses, constructor signature and launch economics remain unchanged.

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

## Local verification results

- `forge build --sizes`: passed with the existing configuration. Launch runtime is **22,677 bytes**, an increase of
  145 bytes, leaving 1,899 bytes below EIP-170. Compiled creation code is 34,451 bytes (34,579 including the four
  constructor words), below EIP-3860. The other three production artifacts are unchanged and no library links remain.
- `forge test` and `forge test --offline`: passed. Foundry reports 59 passing tests: 58 local tests, including the
  256-run claims fuzz test, plus the existing fork test's early return when `ROBINHOOD_RPC_URL` is unset. No live fork
  execution is claimed.
- The supplied `Contracts.protected.t.sol` and `Proof_1e3202b54640.t.sol` were copied unchanged into scratch space and
  run locally: both passed. The protected harness used the exact constructor values above and a local CREATE2 factory.
  The project's creation/runtime forbidden-opcode scan also passed.
- The additional factory test measured 7,445,862 and 7,445,874 gas for deployments from two different factories/salts,
  below its 8,388,608-gas bound. These are factory-call execution measurements, excluding transaction intrinsic gas.
- Hash checks confirmed `foundry.toml` and all 82 vendored files were unchanged. `git diff --check` passed.
