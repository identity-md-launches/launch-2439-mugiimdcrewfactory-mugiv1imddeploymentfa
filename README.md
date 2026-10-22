# Mugi V1 IMD compatibility candidate

This source implements the authorized V1 compatibility redesign: constructor-only
finite token reserves, unrestricted wallet transfers with historical cutoff
accounting, no owner pause, and constructor-bound game dependencies. The core
nine-elimination game and future V2 protocol-fund handoff remain.

Read [ADAPTATION.md](ADAPTATION.md) for the exact changes, reserve supply effect,
preserved core rules and remaining trust/admission limits. Read
[the deployment graph](docs/IMD_CONSTRUCTOR_DEPLOYMENT.md) before preparing an IMD
launch. The four owner-bound factories and all nineteen descendants are disclosed.
The four-factory launch alone does not seed or activate the game.

```sh
forge build
forge test
python3 scripts/check-compatible-artifacts.py
```

Fork suites require `MUGI_IMD_MAINNET_FORK_RPC` and optionally
`MUGI_IMD_MAINNET_FORK_BLOCK`. Without the RPC they skip; local test success is
not a public deployment. Compiler settings and dependencies remain unchanged:
Solidity 0.8.26, Cancun, optimizer 200, via IR, bytecode hash none.

Current validation (follow-up repair of `b553ba7`): **153 V1 tests passed, 0 failed, 2 mainnet-fork
tests skipped without an RPC** on Forge 1.8.3 with the verifier fuzz seed. See
[docs/validation/v2-alias-gate/VALIDATION.md](docs/validation/v2-alias-gate/VALIDATION.md).
The earlier R2 evidence (152 tests including the fork suites on Foundry 1.5.1, plus one
separate actual-V2 integration test) is under
[docs/validation/compatible/VALIDATION.md](docs/validation/compatible/VALIDATION.md) and
applies to commit `b553ba7`; the hook constructor gate and the gas meter changed since.

Source admission remains pending. This R2 revision addresses the three blocking medium findings from paid job `0c8421fb-4f6d-4650-8c90-d9fd7d7a79c5` against commit `9901dc71030df5818e4b307df1c5c43506346c12`; see [the findings response](docs/IMD_COMPATIBLE_R2_RESPONSE.md). Earlier paid job
`6a953f2f-d28d-46cc-91a4-f348efed5c10` reviewed rejected source
`028d37769edce6e38324182b8909392a9852af16`, not this redesign. Historical reports
under `docs/validation` apply only to their recorded source pins.

V2 remains separate. Normal finale retires unused reserve and keeps player ETH
and token escrow in V1. A one-time V2 handoff sends only available protocol assets;
players can still claim in V1 during its 30-day window. V2 receives these funds
through its existing `receiveV1Finale` interface and launches independently.
No automatic holder-token swap is introduced.

No credentials/private RPC URLs belong in this repository. No explorer source
verification or public deployment is claimed by these documents.
