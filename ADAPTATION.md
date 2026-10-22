# V1 compatibility adaptation and V2 handoff

This candidate supersedes the rejected mint/freeze/pause/bootstrap mechanics of
commit `028d37769edce6e38324182b8909392a9852af16` and the limited follow-up
`94d78364e3efcf5fa5c7ccf8f3727f2abf6b1085`. The owner explicitly requested the
IMD-compatible fixes while retaining the core V1 game and future V2 handoff.
Platform admission is pending. This document does not claim a public deployment.

## Preserved game rules

Ten crews, the 95/5 initial LP/airdrop allocation, fixed daily cutoffs, one VRF
outcome per round, nine eliminations, 75% loser conversion across survivors,
pro-rata treasure rewards, LP redistribution, bounded buybacks, team fees,
permissionless timeout recovery and the 30-day final claim window remain.
The game modules use ordinary CALL. There is no proxy or delegatecall route.

## Removed capabilities and their replacements

| IMD adaptation rule | Source change | Observable consequence |
| --- | --- | --- |
| No post-launch token minting | Every crew token mints its entire finite reserve once in its constructor. The hook releases separately tracked reserve for the existing conversions and LP reinforcements. No external mint selector exists. | ERC20 totalSupply includes the unused reserve. It is not circulating supply. Eligibility excludes all protocol custodians. Untouched reserve is burned when that crew exits or the game closes. |
| No holder freezes or confiscation | ERC20 transfers have no hook callback; only the token holder can burn its own balance. | Transfers remain possible at cutoff, after elimination and after finale. Dead crew tokens confer no new game rights. Official game pools still enforce the published round/alive rules. |
| Preserve cutoff ownership without freezing | Tokens record balance/supply history; the ledger reads strictly before each original scheduled cutoff. | A transfer or burn exactly at cutoff or after a known result cannot move or duplicate that round's entitlement. Token materialization waits during resolution; ETH claims remain available under their existing rules. |
| No owner pause | The pause state, selector and checks are removed. | The owner cannot halt live gameplay. Fixed cutoffs and deterministic VRF timeout recovery remain. |
| Constructor configuration without later initialization | Tokens, hook, ledger and dependencies receive final bindings in their constructors. Fixed CREATE child addresses break circular dependencies; the hook uses a mined CREATE2 address. Crew names/symbols are derived internally from crew ID, so deployed child constructors also use only static arguments. | No initialize/configure/bindAccounting/setExcluded selector is present in the new hook/token/ledger route. Later transactions create complete applications; the initial four factories alone do not mean the game is live. |
| Empty-chain constructor simulation | Constructors use only supplied values, hashes and pure address derivation. Live dependency checks run before seeding/use. | Factories and children can be constructed before dependent code exists. Missing/mismatched dependencies prevent economic activation. |

The reserve proof is in `src/game/MugiReserveMath.sol`: with initial allocation
I and M=int128.max, 10I+100M covers the bounded nine-round origin supply and
conversion rounding. Claims consume existing backing; they do not release a
second reserve allocation. Unused reserve can never be withdrawn or migrated.

## V1 to V2 remains possible

V2 is a separate implementation and admission/deployment task. V1 commits to a
nonzero reviewed receiver address in its constructor. The address can be planned
before the V2 contract is deployed, but cannot be changed after V1 creation.
After ordinary V1 finale, anyone can call `migrateToV2` with exactly that address
within the 30-day handoff window. The receiver must have deployed code and
implement `receiveV1Finale(uint8,address,uint256)`; funding is atomic.

If V2 is unavailable when the handoff window expires, anyone can execute the
terminal recovery path. Only unreserved protocol ETH and survivor inventory go
to the immutable community treasury; migration is permanently consumed. The
community destination must differ from the owner and team treasury. The sample
child configuration uses the separate community wallet explicitly authorized by
the user and leaves the V2 receiver unresolved until a reviewed contract address
is available. The separate wallet is controlled by the same operator; it is not
an independent governance or multisignature arrangement.
The four factory constructors require only the already specified owner address.

Before this handoff, finale removes the last V4 position, freezes final accounting
at its original cutoff and burns unused survivor reserve. Migration subtracts
reserved player ETH and team ETH, and subtracts earned-token escrow from survivor
inventory. Player token/ETH claims remain in V1 through their published window.
A rejecting receiver rolls back the migration flag and both asset transfers.
Emergency closure retains its player refund path and does not migrate to V2.

This is protocol-fund continuity, not an automatic 1:1 holder-token conversion.
V2 chooses and funds its own token supply. The current actual V2 receiver allows
V1 funds to arrive before its token is configured; activation is separate.

## Follow-up repair of the R2 source (from commit `b553ba7`)

The independent follow-up review of commit `b553ba7` (the R2 source that
addressed audit `573ea9d5…54f2`) reported two low findings and three
informational notes. Both low findings reproduced locally and are fixed here
with regression tests. Nothing else in `src/` changed; game, claims, reserve,
immutable-V2 and community rules are untouched. This adapted source is **not**
identical to `b553ba7`; the diff is limited to the files below.

| Finding | File | Change | Why |
| --- | --- | --- | --- |
| `71d0d1a9…` (low): V2 receiver could alias owner, team or community | `src/imd/MugiIMDGameHook.sol` constructor | Reverts `InvalidConfiguration` when `v2MigrationTarget` equals `owner`, `team` or `community`, mirroring the existing community gate. | Reproduced: a hook with `v2MigrationTarget == team/owner/community` deployed and `migrateToV2` would route unreserved finale assets to that wallet permissionlessly, the owner-selected-sink outcome the prior audit asked to remove. |
| `71d0d1a9…` (low), ownership-transfer corollary | `src/imd/MugiIMDGameHook.sol` `transferOwnership` | Also rejects the immutable `v2MigrationTarget` as a new owner, as it already rejected `communityTreasury`. | Keeps the owner/receiver separation after any ownership transfer, matching the "including after ownership transfer" rule for the community treasury. |
| Regression tests for both | `test/imd/MugiTerminalConfiguration.t.sol` | `testOwnerCannotBeV2Receiver`, `testTeamCannotBeV2Receiver`, `testCommunityCannotBeV2Receiver`, `testV2ReceiverCannotBecomeOwnerEvenAfterOwnershipTransfer`. | Each variant from the finding's reproduction now fails hook creation; the ownership path is covered before and after a transfer. |
| Fixture consequence | `test/imd/lifecycle/MugiGameHook.t.sol` and the lifecycle tests calling `migrateToV2` | The lifecycle base fixture used the test contract as both owner and V2 receiver, which the new gate rejects. The default receiver is now `ForwardingV2Receiver`, a test-only contract with its own address that forwards tokens and ETH to the test contract's recorder. Call sites use `_migrationTarget()`; one assertion now checks the receiver differs from the owner. | Test-only change; every existing balance and counter assertion is unchanged and passes. |
| `f223bf7c…` (low): gas-headroom test fails on current Foundry | `test/imd/MugiV1IMDDeploymentFactory.t.sol` | `testFactoryCreationBatchHasConservativeGasHeadroom` now deploys the four factories' exact initcode in manifest order through raw `CREATE2` in a test-only `RawCreationMeter` contract and meters gas inside the EVM. | Reproduced on Forge 1.8.3: `gasleft()` around `new` of a project artifact from a test-directory contract is not metered (26,942 gas for four creations), so the meter aborted. Raw CREATE2 is metered normally, is what the IMD project factory actually executes, and the result (12,296,955 gas, bound 14,824,595 < 16,777,216) agrees with the earlier local Anvil receipt of 14,187,986 gas. |
| Disclosure | `hook-constructor.json`, `docs/IMD_CONSTRUCTOR_DEPLOYMENT.md`, `README.md` | State the new constructor gate and ownership rule; point to the new evidence. | Keeps the child plan and deployment guide consistent with the code. |

Informational findings `8a8c8bda…` (deadline fallback routes to the operator's
second wallet), `2f6d28eb…` (hook creation blocked on the unresolved V2
receiver) and `a4181dd5…` (coverage statement) required no code change and are
restated as trust assumptions in the next section: the community wallet and the
future V2 receiver are operator-controlled addresses, not independent custody,
and the four-factory launch deploys no child and activates nothing.

Validation for this repair is under `docs/validation/v2-alias-gate/`.

## Explicit remaining trust and admission limits

- The constructor-pinned V2 receiver and community treasury must be reviewed
  before creating the child graph. Address inequality does not prove separate
  human control. No address can be substituted after the hook is created.
  V2 receiver code governs its later use of protocol funds; V1 does not promise
  individual holder redemption.
- Constructor inputs still select the external VRF coordinator/subscription,
  airdrop attestor and IMD verifier signer. No mock service is a launch parameter.
  Hook dependencies are fixed at construction; factory provenance and external
  service settings must be checked against the published deployment graph.
- Four manifest contracts create nineteen disclosed application descendants in
  later transactions. IMD must admit that application-creation flow and the
  official pool/claim timing rules. Do not infer admission from compilation or
  an accepted audit report.
- V2's present constructor/configuration path has not been adapted or admitted
  by this V1 change. The narrow handoff interface is preserved and tested.
- PoolManager custody is excluded from wallet reward snapshots, including
  third-party V4 LP balances. Ordinary contract wallets count at their address,
  but must be capable of invoking claims; no beneficiary look-through exists.
- There is no explorer source verification and no direct-deployment fallback.

See `docs/IMD_CONSTRUCTOR_DEPLOYMENT.md` for creation order and deterministic
bindings, and `docs/validation/compatible/VALIDATION.md` for current test evidence.
Earlier audit/validation documents describe their historical source pins only.

## Official rules checked

- [Contract adaptation](https://api.imd.fun/reads/skill/adapt-contract-project)
- [Contracts-only launch](https://api.imd.fun/reads/skill/evm-contracts-launch)

The no-initialization rule is addressed by constructor-complete children, not by
hiding descendants. Admission still needs IMD review of the disclosed graph.
