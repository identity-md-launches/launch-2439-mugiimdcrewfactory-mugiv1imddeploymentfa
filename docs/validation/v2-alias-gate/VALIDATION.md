# Follow-up repair validation — 2026-10-22

Source basis: commit `b553ba7` (the R2 compatible source) plus the narrow repair
described in `ADAPTATION.md` under "Follow-up repair of the R2 source". The
adapted source is not identical to `b553ba7`. `src-test-diff.patch` is the exact
`git diff b553ba7 -- src test` of this repair; the only production file changed
is `src/imd/MugiIMDGameHook.sol` (constructor alias gate for the V2 receiver and
the matching `transferOwnership` rule).

## Result

`forge test` with `FOUNDRY_FUZZ_SEED=0x94beb01116dd215d8a6e482289327c93cc7086aa45891bb2b169349f49b492c8`:
**153 passed, 0 failed, 2 skipped across 19 suites**. The two skips are the
mainnet-fork suites, which skip without `MUGI_IMD_MAINNET_FORK_RPC`; this
machine had no RPC. `full-suite.json` is the raw `forge test --json` output,
`test-results.json` the parsed per-test list and `validation-summary.json` the
summary with toolchain and artifact facts.

Toolchain: Forge 1.8.3, Solidity 0.8.26, Cancun, optimizer 200, via IR,
bytecode hash none. `foundry.toml`, `remappings`, `lib/` and lockfiles are
unchanged from `b553ba7`.

## Reproduce

```sh
forge build
FOUNDRY_FUZZ_SEED=0x94beb01116dd215d8a6e482289327c93cc7086aa45891bb2b169349f49b492c8 forge test
python3 -I scripts/check-compatible-artifacts.py
```

## Findings reproduced and closed

- `71d0d1a9…aced` (low). Before the repair, a hook configured with
  `v2MigrationTarget` equal to the team, owner or community address deployed
  successfully. After the repair `MugiIMDGameHook`'s constructor reverts
  `InvalidConfiguration` for all three, so `MugiV1IMDDeploymentFactory.deployHook`
  reverts `DeploymentFailed` and no hook exists. `transferOwnership` also rejects
  the V2 receiver, before and after an ownership transfer. Tests:
  `testOwnerCannotBeV2Receiver`, `testTeamCannotBeV2Receiver`,
  `testCommunityCannotBeV2Receiver`,
  `testV2ReceiverCannotBecomeOwnerEvenAfterOwnershipTransfer` in
  `test/imd/MugiTerminalConfiguration.t.sol`.
- `f223bf7c…4017` (low). On Forge 1.8.3 the previous `gasleft()` meter around
  `_newFactories()` reported 26,942 gas for four creations and aborted, because
  `new` of a project artifact from a test-directory contract is not metered. The
  rewritten `testFactoryCreationBatchHasConservativeGasHeadroom` deploys the
  exact four initcodes in manifest order through raw `CREATE2` inside a
  test-only `RawCreationMeter` and measures inside the EVM:

  | Measure | Gas |
  | --- | --- |
  | Four raw CREATE2 creations including code deposit | 12,296,955 |
  | Runtime code-deposit component (200 gas/byte, 60,375 bytes) | 12,075,000 |
  | Conservative independent-transaction bound | 14,824,595 |
  | Prior local Anvil `launchContracts` receipt (`b553ba7`) | 14,187,986 |
  | Transaction gas cap | 16,777,216 |

  The meter still fails explicitly if a runner omits the code-deposit component.

## Informational findings restated, no code change

- `8a8c8bda…52ce`: if the pinned V2 receiver never gains code, `migrateToV2`
  reverts for the 30-day window and `fallbackFinaleToCommunity` then sends only
  unreserved protocol ETH and survivor inventory to the immutable community
  treasury, and expired claims later go there too. The community wallet
  `0x973d5993Be7021882f72da0babCF884e77F76bBb` is a second wallet of the same
  operator; address inequality is a key-level separation, not independent custody.
- `2f6d28eb…c224`: hook creation is blocked until a reviewed nonzero V2
  receiver (now also distinct from owner, team and community) is committed. The
  four-factory launch deploys no child and activates nothing.
- `a4181dd5…3eba`: coverage statement; fork tests and the live IMD factory
  were not reached here either.

## Artifacts

`artifact-review.json` is the output of the project's read-only artifact
checker on this build: 75 compiled source identities match, all deployed
constructors are nonpayable and static with at most 16 words, sizes pass and no
forbidden capability selector exists. Raw hook creation code hash
`0x53dae9ddbc8d673f9489f01afbd240331231d723e052e2ecf82b82fa68852b64`
(runtime 23,635 bytes; 26,079 bytes with the complete configuration). Factory
runtimes are unchanged at 7,180 / 21,064 / 18,963 / 13,168 bytes;
`MugiV1IMDDeploymentFactory` initcode is 47,002 bytes including the owner
argument because it embeds the repaired hook creation code it pins.

## Not established here

No deployment, launch record, factory addresses, transaction receipts or
explorer verification exist. These are local proofs on an unfunded machine, not
deployed state. Remote IMD admission and the independent audit remain pending.
