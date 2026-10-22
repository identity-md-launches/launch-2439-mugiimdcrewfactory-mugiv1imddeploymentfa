// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// IMD modular regression adapted from v1/test/game/MugiGameHookMainnetFork.t.sol.
// Exercises CALL-module custody with the same season/accounting assertions.

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {MugiIMDV4Engine as MugiV4Engine} from "../../../src/imd/modules/MugiIMDV4Engine.sol";
import {MugiIMDPriceOracle as MugiPriceOracle} from "../../../src/imd/modules/MugiIMDPriceOracle.sol";
import {MugiIMDBuybacks as MugiBuybacks} from "../../../src/imd/modules/MugiIMDBuybacks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Local fork execution only: new game assets interact with Ethereum's deployed PoolManager.
contract MugiGameHookMainnetForkTest is MugiGameTestBase {
    // Official Ethereum deployment: https://developers.uniswap.org/docs/protocols/v4/deployments
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function setUp() public {
        string memory endpoint = vm.envOr("ETHEREUM_MAINNET_RPC_URL", string(""));
        if (bytes(endpoint).length == 0) { vm.skip(true); return; }
        uint256 forkBlock = vm.envOr("MUGI_V4_FORK_BLOCK", uint256(0));
        // Public fallback serves recent state. Set a block with an archive RPC for a pinned replay.
        if (forkBlock == 0) {
            vm.createSelectFork(endpoint);
        } else {
            vm.createSelectFork(endpoint, forkBlock);
        }
        emit log_named_uint("Ethereum fork block", block.number);
        assertEq(block.chainid, 1);
        assertGt(MAINNET_POOL_MANAGER.code.length, 0);
        _setup(IPoolManager(MAINNET_POOL_MANAGER));
    }

    function testMainnetPoolManagerSupportsGameFeesSettlementAndBuyBurn() public {
        assertEq(address(manager), MAINNET_POOL_MANAGER);
        BalanceDelta bought = _swap(ALICE, 0, true, -int256(1 ether));
        assertGt(bought.amount1(), 0);
        _swap(ALICE, 0, false, -int256(100 ether));
        assertGt(game.treasure(0), 0);
        _round(0);
        assertEq(game.positionLiquidity(0), 0);
        (, uint256 reward,) = game.previewAccount(BOB);
        assertGt(reward, 0);
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), reward);
        uint256 beforeSupply = MugiCrewToken(crew[1]).totalSupply();
        MugiBuybacks.Budget memory budget = game.roundBudget(1);
        game.executeBuyback(1, 1, (budget.allocation[1] + 99) / 100);
        assertLt(MugiCrewToken(crew[1]).totalSupply(), beforeSupply);
        _assertSolvent();
    }

    function testMainnetPoolManagerFullSeasonFinale() public {
        _fundTreasure(0);
        for (uint8 round; round < 9; ++round) _round(0);
        assertEq(game.aliveMask(), uint16(1 << 9));
        (, uint256 earlierReward,) = game.previewAccount(BOB);
        assertGt(earlierReward, 0);
        vm.warp(game.nextCutoff());
        game.finalize();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Finalized));
        vm.prank(ALICE);
        uint256 received = game.claimEth(payable(ALICE));
        assertEq(received, 0, "final LP principal is reserved for V2");
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), earlierReward);
        (uint256[10] memory aliceClaims,,) = game.previewAccount(ALICE);
        assertGt(aliceClaims[9], 0);
        vm.prank(ALICE);
        uint256[10] memory aliceReceived = game.claimTokens();
        assertEq(aliceReceived[9], aliceClaims[9]);
        uint256 pendingEth = address(game).balance - game.teamEth() - game.reservedPlayerEth();
        uint256 backing = game.escrowBacking(9);
        uint256 pendingTokens = MugiCrewToken(crew[9]).balanceOf(address(game)) - backing;
        assertGt(pendingEth, 0);
        assertGt(pendingTokens, 0);
        assertEq(migratedEth, 0, "finalization waits for the owner to bind V2");
        game.migrateToV2(_migrationTarget());
        assertEq(migratedEth, pendingEth);
        assertEq(migratedTokens, pendingTokens);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), backing);
        (uint256[10] memory bobClaims,,) = game.previewAccount(BOB);
        vm.prank(BOB);
        uint256[10] memory bobReceived = game.claimTokens();
        assertEq(bobReceived[9], bobClaims[9]);
        assertEq(game.escrowBacking(9), backing - bobClaims[9]);
        _assertSolvent();
    }
}
