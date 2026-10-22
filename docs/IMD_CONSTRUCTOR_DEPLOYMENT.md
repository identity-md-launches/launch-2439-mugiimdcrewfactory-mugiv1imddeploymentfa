# Constructor-complete deployment graph

This candidate changes the prior postdeployment initialization architecture. Every application receives its initial owner and fixed token and module bindings in its constructor. There is no application `initialize`, `configure`, `bindAccounting`, or dependency-replacement call. Pool seeding, registration, launching and trading remain ordinary application operations after creation. This engineering design is subject to IMD's explicit admission review; it is not evidence that IMD has approved or deployed it.

The contracts-only manifest lists exactly four full-code factories. Each constructor has one static `address owner` argument, is nonpayable, makes no dependency calls or code-existence checks, and creates no children:

| Manifest artifact | Subsequent application creations |
| --- | --- |
| `MugiIMDCrewFactory` | Ten crew tokens, ordinary CREATE nonces 1 through 10 |
| `MugiV1IMDDeploymentFactory` | Router, VRF adapter, IMD verifier, airdrop at CREATE nonces 1 through 4; the hook afterward by CREATE2 |
| `MugiIMDAccountingFactory` | Ledger, buyback budgets, price oracle at CREATE nonces 1 through 3 |
| `MugiIMDEngineFactory` | V4 engine at CREATE nonce 1 |

All **19 descendant contracts** are part of the submitted application and must be reviewed. A four-entry IMD registry record records the factories only. It does not mean those 19 descendants already exist or are individually indexed. Child deployment requires five additional owner transactions with no attached ETH value; transaction gas is still required. Seeding pools later requires separate liquidity funding. Do not describe the entire graph as one IMD deployment transaction.

## Deterministic planning

1. Compile the exact approved source with the pinned Foundry settings. Predict or read the four factory addresses. Their constructor inputs contain no future hook address or hook *initcode* hash, so they are independent of the future graph. The main factory constructor pins the hash and length of the hook's **raw creation code**, excluding its constructor arguments; these are source-derived and not cyclic.
2. Call `predictCrewSet()`, the two `predictModules()` views, and `predictEngine()`. The same ordinary CREATE formula is available in `MugiIMDDeploymentAddresses`. Every factory is single-season and owner-only; no caller can consume a child nonce before the authorized creation operation.
3. Obtain the approved community treasury (distinct from owner/team) and pin the reviewed nonzero V2 receiver address before creating the hook. The hook constructor also rejects a V2 receiver equal to the owner, team treasury or community treasury, and `transferOwnership` rejects both the community treasury and the V2 receiver as a new owner. The community wallet is specified in `hook-constructor.json`; the V2 receiver remains unresolved. No child activation is authorized by this factory deployment. Encode the hook's flat, static 14-field `Configuration`: owner, manager, team, community, V2 destination, initial allocation, ledger, engine, budgets, prices, VRF adapter, IMD verifier, airdrop, crew factory. Ten token addresses are derived internally from the crew factory and fixed nonces 1..10. Concatenate that tuple with the exact compiled hook creation code.
4. Compute the full initcode hash and mine a CREATE2 salt under the main deployment factory such that the hook address ends in the required permission bits `(address & 0x3fff) == 0x2aec`.
5. Check every planned reciprocal binding, source hash, token allocation, service address, authority and nonce before the first child deployment. A successful one-season creation cannot be reset to a different graph. Failed calls revert their creations, commitments and CREATE nonces atomically.

## Child deployment transactions

The owner creates the graph with the complete, already reviewed arguments:

1. Main factory `deployModules(salt, fullHookInitCodeHash, moduleConfiguration)` creates the four service modules at the predicted ordinary CREATE addresses. It records the immutable-for-this-deployment full hook commitment as part of this creation operation. This does not configure an existing application.
2. Crew factory `deployCrewSet(predictedHook, initialSupply)` creates all ten fixed-cap, freely transferable tokens. Their entire constructor reserve belongs to the predicted hook. The initial allocation is distinct from that reserve cap.
3. Engine factory `deployForHook(predictedHook, manager)` creates the immutable engine.
4. Accounting factory `deployForHook(ledgerConfiguration)` creates the complete ledger and its two companion modules. The ledger tuple contains hook, token0..token9, airdrop, engine, team, community and manager.
5. Main factory `deployHook(exactInitCode)` creates the hook last. It verifies the committed complete hash, the constructor-pinned raw creation-code hash, exact static argument length, required own-module bindings, owner, manager, initial supply, crew-factory binding and the existence of the accounting/execution modules. It accepts no alternative runtime, proxy or delegatecall program.

The constructors deliberately accept future dependency addresses without calling them. The hook also validates reciprocal immutable bindings before the first economic operation. After creation no binding can be replaced. An incomplete or incorrectly planned graph is a deployment error, not a reason to add a privileged initializer.

## Validation and limits

`forge test --match-contract MugiV1IMDDeploymentFactoryTest -vv` checks actual CREATE/CREATE2 predictions, constructor-complete bindings, owner-only and one-shot creation, failure rollback, bytecode commitments, reserve exclusion, EIP-170/EIP-3860 limits, seeding and launch. Its gas checks explicitly require measured CREATE gas to cover the `200 × deployed runtime bytes` code-deposit component, add conservative initcode metering, intrinsic calldata costs and overhead, and fail if instrumentation omits code deposit. The four-factory local bound includes an explicit ABI/registry allowance; it is not an exact IMD transaction estimate. The earlier 144-test result, artifact sizes and reproduction commands are recorded in [compatible validation](validation/compatible/VALIDATION.md); changed tests must be rerun. Local gas checks are not a substitute for an `eth_estimateGas` and actual receipt rehearsal of the exact IMD call on a pinned local fork.

`MUGI_IMD_MAINNET_FORK_RPC=<read-only-rpc> MUGI_IMD_MAINNET_FORK_BLOCK=<pinned-block> forge test --match-contract MugiIMDProjectFactoryForkTest -vv` exercises the real IMD policy-27 factory and registry on a local fork, then creates the complete child graph and seeds the ten real V4 pools. Missing RPC is reported as skipped. This test does not prove remote IMD admission, payment, production deployment, VRF fulfillment, oracle availability or explorer indexing.

No explorer source verification is requested or performed. The manifest and request must disclose the descendant creation transactions, the fixed constructor premint reserve, freely transferable post-elimination tokens, cutoff-based reward accounting, absence of an owner trading pause, and the preserved V2 handoff. None of these changes should be described as a policy exception.
