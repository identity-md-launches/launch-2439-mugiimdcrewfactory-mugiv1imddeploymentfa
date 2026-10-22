# Tests-only regression review

Final offline validation on Forge 1.8.3: **172 passed, 0 failed, 2 optional fork
suites skipped**, across 26 suites, with the specified verifier fuzz seed.
The 19 added tests include five invariant campaigns and 49,152 randomized calls
with zero unexpected handler reverts. `forge build` and formatting checks pass.

Production source pin: `2907a8fec35bd79bde8f699ec8502bb5d644a3a4`.
This assignment adds tests and local validation evidence only. No existing source,
test, manifest, compiler setting or dependency was changed. The pin identifies
unchanged production source; the new tests are additional working-tree files.

The comparison baseline is `9901dc71030df5818e4b307df1c5c43506346c12`, reviewed by
job `0c8421fb-4f6d-4650-8c90-d9fd7d7a79c5`, accepted report
`573ea9d5650bafcdc892589b64157aecbe9239f7efb89fa37b3d9bed699654f2`.
`evidence/audited-source-delta.patch` records the exact production-source delta
from that baseline to this submitted pin. Only `MugiIMDGameHook.sol` differs:
nonzero, separated immutable destinations; ownership-transfer separation;
permissionless exact-target migration before a separately retained deadline; and
permissionless community fallback at that deadline. Report acceptance is not a
clean audit or application admission.

## New executable coverage

| Suite | Calls and properties |
| --- | --- |
| `MugiManifestConstructorsTest` | The manifest's actual owner and order, with all four raw CREATE2 creations inside one call. State-diff recording checks exactly four creations, no descendant creation, dependency calls or external-code inspection in constructors. Checks full runtimes, size limits, nonce-one factories, raw hook code commitment and absent descendants. Rejects nonzero constructor value and zero owners; retries valid construction afterward. |
| `MugiFinaleCustodyInvariantTest` | Five actors independently claim ETH and partial/all tokens, transfer/burn wallet balances, withdraw team fees, advance through deadline boundaries, attempt wrong-target/rejecting/reentrant handoffs, fallback and sweep in random order. Preserves each actor's opening earned rights, exact ETH conservation, finite token supply, escrow backing, frozen eligibility, one-shot migration and claim expiry. |
| `MugiEmergencyCustodyInvariantTest` | The same actions from emergency closure after three eliminations. Protects both old and emergency rewards and verifies that neither migration nor ordinary-finale fallback becomes available. |
| `MugiSeasonAccountingInvariantTest` | Real local PoolManager, production router, ten production tokens, hook, ledger, engine, budget controller and price oracle. Random buy/sell, impossible slippage, wallet transfers/burns, partial/all claims, fee collection, airdrop retirement, VRF delivery and bounded settlement. Checks tracked ETH and token conservation, finite reserves, excluded custody, exact aggregate virtual backing, fees held as PoolManager claims, closed positions and budget totals. |
| `MugiAirdropAccountingInvariantTest` | Twenty actors register, launch, claim using correct/wrong-purpose attestations, repeat calls, cross expiry and retire inventory. Checks unique registration state, one claim per wallet, payout caps, token custody and burns limited to the airdrop's own inventory. |
| `MugiBudgetAccountingInvariantTest` | Random signed-plan fixture approval, nonce replay, authorization, partial accounting, invalid accounting, outsider calls, cadence and plan expiry. Checks allocations sum to the original budget and per-crew spending matches independent counters. A deterministic sequence spends above the equal allocation before fallback and verifies already-spent amounts survive redistribution. |
| `MugiAirdropAuthorizationTest` | Account/crew/social/deadline/contract signature binding, social and wallet reuse, inclusive signature deadlines, rejected token-payment rollback and retry, claim replay, the seven-day launch boundary, and fuzzed cohorts crossing the per-account cap and shared 5% allocation boundary. |

The five invariant campaigns use explicit selector targeting, bounded inputs,
128 runs and depths of 64 or 96, with unexpected handler reverts treated as
failures. Together they execute 49,152 randomized calls. Scripted tests also
require successful nonzero payouts and exercise nine complete eliminations,
rejection/retry, fallback and expiry, so phase guards cannot make the coverage
entirely vacuous. Valid claims must pay their expected amounts, not merely return
without reverting. Expected failing calls check rejection and preserved state.

## Harness and evidence limits

The season fixtures reuse the existing `MugiGameTestBase`: a real local
PoolManager and production contracts, a test-only VRF provider, locally signed
airdrop attestations and `deployCodeTo` for the correctly flagged hook address.
The constructor suite separately exercises actual CREATE2 factory deployment.
The budget suite uses a verifier fixture to isolate budget arithmetic; the
existing verifier suite checks signatures, domain separation and evidence policy.
All fixture identities and keys are local test data, never live child settings.

Wallet transfers remain available during cutoff, elimination and terminal
states. Official-pool swaps and token-reward materialization retain their
published phase/cutoff gates. PoolManager custody, including third-party V4
custody, remains excluded from holder eligibility; these tests do not invent
beneficiary look-through. Constructor `totalSupply` includes the unused finite
reserve and is not circulating supply.

The supplied validation directories were inspected as historical evidence. The
recorded actual-V2 integration uses the earlier raw hook code hash
`0x7161ccaa791cb35a95cb47bcdb62910259125bfa3766f76e37d178db68f108d2` and V2 sources
from a separate workspace. Those V2 sources and a reviewed live receiver are not
present in this application. That integration is not reported as rerun against
the current pin. New receiver tests establish interface/custody behavior only.

The live hook plan still has a null V2 receiver and unresolved service/graph
settings. Those require subsequent review before child creation and activation;
the four factory constructors need only the specified owner. The community
recipient `0x973d5993Be7021882f72da0babCF884e77F76bBb` is a distinct wallet of the
same operator, not independent community governance or custody.

Admission outcome: **not established by this tests-only assignment**. Independent
audit and platform admission remain separate requirements. No public deployment,
IMD launch record, deployed factory addresses or transaction receipts were
produced. No children were publicly deployed or pools seeded, and no explorer
source verification was submitted. Historical Anvil receipts are local proof.

## Reproduce offline

Compiler settings remain Solidity 0.8.26, Cancun, optimizer 200, viaIR and
`bytecode_hash = "none"`. No new dependencies are required.

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x94beb01116dd215d8a6e482289327c93cc7086aa45891bb2b169349f49b492c8 \
  forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The output/cache overrides keep local artifacts in disposable scratch space;
plain `forge build` and `forge test` select the same compiler and test suite.
`evidence/validation.json` records the final local results, source identity and
per-test results for the additions. Local check results carry no independent
audit or deployment authority. Existing RPC-dependent fork suites are reported
as skipped when their RPC settings are absent.
