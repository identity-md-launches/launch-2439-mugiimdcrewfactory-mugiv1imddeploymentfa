// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// IMD modular regression adapted from v1/test/game/MugiEconomics.t.sol.
// Exercises CALL-module custody with the same season/accounting assertions.

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {MugiIMDBuybacks as MugiBuybacks} from "../../../src/imd/modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle as MugiPriceOracle} from "../../../src/imd/modules/MugiIMDPriceOracle.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

contract MugiEconomicsTest is MugiGameTestBase {
    uint256[10] private initialTokenDust;
    uint256 private pendingMigrationEth;
    uint256[10] private pendingMigrationTokens;

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
        for (uint8 i; i < 10; ++i) {
            initialTokenDust[i] = MugiCrewToken(crew[i]).balanceOf(address(game)) - game.unreleasedReserve(i);
        }
    }

    function testEliminationPaysBookedAndUncollectedTokenFeesBeforeRetirement() public {
        _swap(ALICE, 0, true, -int256(1 ether));
        _swap(ALICE, 0, false, -int256(100 ether));
        game.collectTeamFees(0);
        uint256 booked = game.teamTokens(0);
        assertGt(booked, 0);
        _swap(ALICE, 0, false, -int256(50 ether));
        (uint256 expectedEthFees, uint256 expectedTokenFees) = _feesIfCollected(0);
        assertGt(expectedTokenFees, booked, "exit must pay fees never collected separately");
        uint256 principal = _ethForLiquidity(0, game.positionLiquidity(0), false);
        uint256 ownBudget = game.ownBurnBudget(0);
        uint256 pot = game.treasure(0);
        uint256 eligibleLoser = game.eligibleSupply(0);
        uint256 survivorBefore = game.eligibleSupply(1);
        uint256 aliceUnits = MugiCrewToken(crew[0]).balanceOf(ALICE);
        uint256 teamBefore = MugiCrewToken(crew[0]).balanceOf(TEAM);
        _requestAndFulfill(0);
        vm.expectEmit(true, false, false, true, address(game));
        emit MugiGameHook.TeamTokenFeesPaid(0, expectedTokenFees);
        game.settleRound(10);
        assertEq(MugiCrewToken(crew[0]).balanceOf(TEAM), teamBefore + expectedTokenFees);
        assertEq(game.teamTokens(0), 0);
        assertEq(game.teamEth(), expectedEthFees);
        assertEq(MugiCrewToken(crew[0]).balanceOf(address(game)), 0);
        assertEq(game.settlementLiquidityEth(), principal / 2);
        assertEq(game.roundBudget(1).total, principal - principal / 2 + ownBudget);
        assertEq(game.eligibleSupply(1), survivorBefore + eligibleLoser * 3 / 36);
        (uint256[10] memory replacement,,) = game.previewAccount(ALICE);
        assertEq(replacement[1], aliceUnits * 3 / 36);
        (, uint256 bobReward,) = game.previewAccount(BOB);
        assertEq(bobReward, pot / 9);
        _assertTreasuryHasNoGameRights();
        game.withdrawTeamFees();
        game.withdrawTeamFees();
        assertEq(MugiCrewToken(crew[0]).balanceOf(TEAM), teamBefore + expectedTokenFees);
        assertEq(TEAM.balance, expectedEthFees);
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), bobReward);
        _assertSolvent();
    }

    function testFinalePaysBookedAndExitTokenFeesWithoutConsumingEscrowOrEthRewards() public {
        for (uint8 i; i < 9; ++i) _round(0);
        vm.prank(ALICE);
        game.claimTokens();
        _swap(ALICE, 9, true, -int256(1 ether));
        _swap(ALICE, 9, false, -int256(10 ether));
        game.collectTeamFees(9);
        uint256 booked = game.teamTokens(9);
        assertGt(booked, 0);
        _swap(ALICE, 9, false, -int256(10 ether));
        (uint256 expectedEthFees, uint256 expectedTokenFees) = _feesIfCollected(9);
        assertGt(expectedTokenFees, booked);
        uint256 oldReserved = game.reservedPlayerEth();
        uint256 finalEth = address(game).balance + game.unredeemedGameFees()
            + _ethForLiquidity(9, game.positionLiquidity(9), false) - game.teamEth() - oldReserved;
        uint256 totalSupply = MugiCrewToken(crew[9]).totalSupply();
        uint256 unusedReserve = game.unreleasedReserve(9);
        assertGt(unusedReserve, 0);
        uint256 finalBacking = game.escrowBacking(9);
        uint256 finalEligible = game.eligibleSupply(9);
        vm.warp(game.nextCutoff());
        vm.expectEmit(true, false, false, true, address(game));
        emit MugiGameHook.TeamTokenFeesPaid(9, expectedTokenFees);
        game.finalize();
        assertEq(MugiCrewToken(crew[9]).balanceOf(TEAM), expectedTokenFees);
        assertEq(game.teamTokens(9), 0);
        assertEq(game.teamEth(), expectedEthFees);
        assertEq(game.escrowBacking(9), finalBacking);
        assertEq(game.unreleasedReserve(9), 0, "finalization retires only the unused reserve");
        assertEq(MugiCrewToken(crew[9]).totalSupply(), totalSupply - unusedReserve);
        uint256 finalInventory = MugiCrewToken(crew[9]).balanceOf(address(game)) - finalBacking;
        assertGt(finalInventory, 0, "finalization retains tokens for manual V2 handoff");
        assertEq(game.eligibleSupply(9), finalEligible);
        assertEq(game.reservedPlayerEth(), oldReserved);
        assertEq(migratedEth, 0);
        game.migrateToV2(_migrationTarget());
        assertEq(migratedEth, finalEth);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), finalBacking);
        assertEq(migratedTokens, finalInventory);
        assertEq(migratedTokens, MugiCrewToken(crew[9]).balanceOf(address(this)));
        assertEq(MugiCrewToken(crew[9]).totalSupply(), totalSupply - unusedReserve);
        _assertTreasuryHasNoGameRights();
        game.withdrawTeamFees();
        game.withdrawTeamFees();
        assertEq(TEAM.balance, expectedEthFees);
        assertEq(MugiCrewToken(crew[9]).balanceOf(TEAM), expectedTokenFees);
        (uint256[10] memory lateClaims,,) = game.previewAccount(LATE);
        assertGt(lateClaims[9], 0);
        vm.prank(LATE);
        uint256[10] memory lateReceived = game.claimTokens();
        assertEq(lateReceived[9], lateClaims[9]);
        assertEq(game.escrowBacking(9), finalBacking - lateReceived[9]);
        vm.prank(LATE);
        assertEq(game.claimEth(payable(LATE)), 0);
        _assertSolvent();
    }

    function testZeroEligibleFinaleMigratesToV2AndPreservesTeamEth() public {
        address[5] memory actors = _actors();
        for (uint256 a; a < actors.length; ++a) {
            for (uint8 i; i < 3; ++i) {
                uint256 amount = MugiCrewToken(crew[i]).balanceOf(actors[a]);
                if (amount == 0) continue;
                vm.prank(actors[a]);
                MugiCrewToken(crew[i]).transfer(TEAM, amount);
            }
        }
        _swap(TEAM, 0, true, -int256(1 ether));
        game.collectTeamFees(0);
        assertGt(game.teamEth(), 0);
        for (uint8 i; i < 9; ++i) _round(0);
        assertEq(game.eligibleSupply(9), 0);
        assertEq(game.reservedPlayerEth(), 0);
        uint256 teamReserve = game.teamEth();
        uint256 expectedMigration = address(game).balance + _ethForLiquidity(9, game.positionLiquidity(9), false)
            - teamReserve;
        vm.warp(game.nextCutoff());
        game.finalize();
        game.migrateToV2(_migrationTarget());
        assertEq(migratedEth, expectedMigration);
        assertEq(game.reservedPlayerEth(), 0);
        assertEq(game.teamEth(), teamReserve);
        vm.prank(ALICE);
        assertEq(game.claimEth(payable(ALICE)), 0);
        assertEq(address(game).balance, teamReserve);
        uint256 teamBalance = TEAM.balance;
        game.withdrawTeamFees();
        assertEq(TEAM.balance, teamBalance + teamReserve);
        assertEq(address(game).balance, 0);
        _assertTreasuryHasNoGameRights();
    }

    function testTerminalMigrationPreservesFinalTokenClaimsAndEarlierEthClaims() public {
        _fundTreasure(0);
        for (uint8 i; i < 9; ++i) _round(0);
        address[5] memory actors = _actors();
        uint256[5] memory earlierRewards;
        uint256[5] memory earlierTokens;
        uint256[5] memory earlierFractions;
        for (uint256 a; a < actors.length; ++a) {
            (uint256[10] memory amounts, uint256 reward, uint256[10] memory fractions) = game.previewAccount(actors[a]);
            earlierRewards[a] = reward;
            earlierTokens[a] = amounts[9];
            earlierFractions[a] = fractions[9];
            assertGt(amounts[9], 0);
        }
        assertGt(earlierRewards[1], 0);
        uint256 backing = game.escrowBacking(9);
        vm.warp(game.nextCutoff());
        game.finalize();
        assertEq(game.escrowBacking(9), backing);
        for (uint256 a; a < actors.length; ++a) {
            (uint256[10] memory claimable, uint256 owed, uint256[10] memory fractions) = game.previewAccount(actors[a]);
            assertEq(claimable[9], earlierTokens[a]);
            assertEq(fractions[9], earlierFractions[a]);
            assertEq(owed, earlierRewards[a]);
        }
        uint256 finalInventory = MugiCrewToken(crew[9]).balanceOf(address(game)) - backing;
        assertGt(finalInventory, 0);
        game.migrateToV2(_migrationTarget());
        assertEq(migratedTokens, finalInventory);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), backing);
        for (uint256 a; a < actors.length; ++a) {
            uint256 beforeBalance = MugiCrewToken(crew[9]).balanceOf(actors[a]);
            vm.prank(actors[a]);
            uint256[10] memory received = game.claimTokens();
            assertEq(received[9], earlierTokens[a]);
            assertEq(MugiCrewToken(crew[9]).balanceOf(actors[a]), beforeBalance + earlierTokens[a]);
            backing -= earlierTokens[a];
            assertEq(game.escrowBacking(9), backing);
            vm.prank(actors[a]);
            assertEq(game.claimEth(payable(actors[a])), earlierRewards[a]);
        }
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), backing);
        _assertSolvent();
    }

    function testBuybackTwapExposesRealHistoryAndRejectsInvalidCrew() public {
        vm.expectRevert(MugiPriceOracle.InvalidCrew.selector);
        game.buybackTwap(10);
        vm.expectRevert(MugiPriceOracle.InsufficientHistory.selector);
        game.buybackTwap(0);
        (, int24 initialTick,) = game.poolState(0);
        skip(15 minutes);
        (int24 average, uint32 age, uint16 observations) = game.buybackTwap(0);
        assertEq(average, initialTick);
        assertEq(age, 15 minutes);
        assertEq(observations, 1);
        _swap(ALICE, 0, true, -int256(0.01 ether));
        (average, age, observations) = game.buybackTwap(0);
        assertEq(average, initialTick, "same-block spot movement cannot rewrite elapsed history");
        assertEq(age, 15 minutes);
        assertEq(observations, 2);
    }

    function testFuzzSeasonReconcilesEveryBucketAcrossTradesTransfersAndClaims(uint256 seed) public {
        uint256 freeEth = address(game).balance;
        address[5] memory actors = _actors();
        for (uint8 round; round < 9; ++round) {
            seed = uint256(keccak256(abi.encode(seed, round)));
            uint8 tradeCrew = _crewAt(seed, game.aliveMask());
            address buyer = actors[(seed >> 16) % actors.length];
            address recipient = actors[((seed >> 16) + 1) % actors.length];
            _swap(buyer, tradeCrew, true, -int256(1e12 + seed % 0.05 ether));
            uint256 owned = MugiCrewToken(crew[tradeCrew]).balanceOf(buyer);
            vm.prank(buyer);
            MugiCrewToken(crew[tradeCrew]).transfer(recipient, owned / 3);
            _swap(buyer, tradeCrew, false, -int256(owned / 7));
            vm.prank(recipient);
            game.claimTokens();
            vm.prank(buyer);
            game.claimEth(payable(buyer));
            if ((seed & 1) != 0) game.collectTeamFees(tradeCrew);
            if ((seed & 2) != 0) game.withdrawTeamFees();
            skip(16 minutes);
            uint256 own = game.ownBurnBudget(tradeCrew);
            game.executeOwnBuyback(tradeCrew, (own + 99) / 100);
            _assertBuckets(freeEth);

            uint8 loser = _crewAt(seed >> 32, game.aliveMask());
            uint256 principal = _ethForLiquidity(loser, game.positionLiquidity(loser), false);
            uint256 survivorCount = 9 - round;
            uint256 treasurePerCrew = game.treasure(loser) / survivorCount;
            uint256 unallocated = game.treasure(loser);
            uint128[10] memory oldLiquidity;
            for (uint8 i; i < 10; ++i) {
                oldLiquidity[i] = game.positionLiquidity(i);
                if (i != loser && (game.aliveMask() & (uint16(1) << i)) != 0 && game.eligibleSupply(i) != 0) {
                    unallocated -= treasurePerCrew;
                }
            }
            _requestAndFulfill(seed >> 32);
            uint256 share = (principal / 2) / survivorCount;
            uint256 roundFree = freeEth + unallocated + principal / 2 - share * survivorCount;
            while (game.phase() != MugiGameHook.Phase.Live) {
                game.settleRound(uint8(1 + seed % 3));
                uint256 consumedRemainders;
                for (uint8 i; i < game.settlementCursor(); ++i) {
                    if ((game.aliveMask() & (uint16(1) << i)) == 0) continue;
                    uint128 added = game.positionLiquidity(i) - oldLiquidity[i];
                    consumedRemainders += share - _ethForLiquidity(i, added, true);
                }
                freeEth = roundFree + consumedRemainders;
                _assertBuckets(freeEth);
            }
            uint8 purchaseCrew = _crewAt(seed >> 64, game.aliveMask());
            MugiBuybacks.Budget memory budget = game.roundBudget(round + 1);
            game.executeBuyback(round + 1, purchaseCrew, (budget.allocation[purchaseCrew] + 99) / 100);
            vm.prank(actors[(seed >> 96) % actors.length]);
            game.claimTokens();
            _assertBuckets(freeEth);
        }
        uint8 survivor = _crewAt(0, game.aliveMask());
        uint128 finalLiquidity = game.positionLiquidity(survivor);
        pendingMigrationEth = address(game).balance + game.unredeemedGameFees()
            + _ethForLiquidity(survivor, finalLiquidity, false) - game.teamEth() - game.reservedPlayerEth();
        pendingMigrationTokens[survivor] = MugiCrewToken(crew[survivor]).balanceOf(address(game))
            + _tokensForLiquidity(survivor, finalLiquidity) - game.teamTokens(survivor) - game.escrowBacking(survivor)
            - game.unreleasedReserve(survivor);
        vm.warp(game.nextCutoff());
        game.finalize();
        _assertBuckets(0);
        for (uint256 a; a < actors.length; ++a) {
            vm.prank(actors[a]);
            game.claimEth(payable(actors[a]));
        }
        game.withdrawTeamFees();
        _assertBuckets(0);
        game.migrateToV2(_migrationTarget());
        assertEq(migratedEth, pendingMigrationEth);
        assertEq(migratedTokens, pendingMigrationTokens[survivor]);
        pendingMigrationEth = 0;
        pendingMigrationTokens[survivor] = 0;
        _assertBuckets(0);
    }

    function _feesIfCollected(uint8 id) private returns (uint256 ethFees, uint256 tokenFees) {
        uint256 snapshot = vm.snapshotState();
        game.collectTeamFees(id);
        ethFees = game.teamEth();
        tokenFees = game.teamTokens(id);
        assertTrue(vm.revertToState(snapshot));
    }

    function _ethForLiquidity(uint8 id, uint128 liquidity, bool roundUp) private view returns (uint256) {
        if (liquidity == 0) return 0;
        (uint160 price,,) = game.poolState(id);
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(game.poolKey(id).tickSpacing));
        return SqrtPriceMath.getAmount0Delta(price, upper, liquidity, roundUp);
    }

    function _tokensForLiquidity(uint8 id, uint128 liquidity) private view returns (uint256) {
        if (liquidity == 0) return 0;
        (uint160 price,,) = game.poolState(id);
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(game.poolKey(id).tickSpacing));
        return SqrtPriceMath.getAmount1Delta(lower, price, liquidity, false);
    }

    function _assertTreasuryHasNoGameRights() private view {
        (uint256[10] memory claimable, uint256 earned, uint256[10] memory virtualUnits) = game.previewAccount(TEAM);
        assertEq(earned, 0);
        for (uint8 i; i < 10; ++i) {
            assertEq(claimable[i], 0);
            assertEq(virtualUnits[i], 0);
        }
    }

    function _assertBuckets(uint256 freeEth) private view {
        bool finalized = game.phase() == MugiGameHook.Phase.Finalized;
        uint256 assigned = game.teamEth() + game.reservedPlayerEth() + pendingMigrationEth;
        if (!finalized) {
            for (uint8 i; i < 10; ++i) assigned += game.treasure(i) + game.ownBurnBudget(i);
            for (uint64 round = 1; round <= game.eliminations(); ++round) {
                MugiBuybacks.Budget memory budget = game.roundBudget(round);
                assigned += budget.total - budget.spent;
            }
            if (game.phase() == MugiGameHook.Phase.Settling) {
                assigned += game.settlementBuybackEth();
                uint256 share = game.settlementLiquidityEth() / (10 - game.eliminations());
                for (uint8 i = game.settlementCursor(); i < 10; ++i) {
                    if ((game.aliveMask() & (uint16(1) << i)) != 0) assigned += share;
                }
            }
        }
        assertEq(address(game).balance + game.unredeemedGameFees(), assigned + freeEth, "all ETH buckets reconcile");
        address[5] memory actors = _actors();
        uint256[10] memory virtualSum;
        uint256[10] memory eligibleSum;
        for (uint256 a; a < actors.length; ++a) {
            (,, uint256[10] memory virtualUnits) = game.previewAccount(actors[a]);
            for (uint8 i; i < 10; ++i) {
                virtualSum[i] += virtualUnits[i];
                if ((game.aliveMask() & (uint16(1) << i)) != 0) {
                    eligibleSum[i] += virtualUnits[i] + MugiCrewToken(crew[i]).balanceOf(actors[a]) * 95_126_814_720;
                }
            }
        }
        for (uint8 i; i < 10; ++i) {
            uint256 reserve = game.unreleasedReserve(i);
            uint256 inventory = reserve + game.escrowBacking(i) + game.teamTokens(i) + pendingMigrationTokens[i];
            if (!finalized && (game.aliveMask() & (uint16(1) << i)) != 0) inventory += initialTokenDust[i];
            if (finalized || (game.aliveMask() & (uint16(1) << i)) == 0) {
                assertEq(reserve, 0, "closed crew cannot retain unused reserve");
            }
            assertEq(MugiCrewToken(crew[i]).balanceOf(address(game)), inventory, "reserve/escrow/team/dust reconcile");
            // Terminal reward denominators are frozen; escrow remains a live
            // liability until claimed or expired, independent of V2 inventory.
            if (!finalized) assertEq(game.eligibleSupply(i), eligibleSum[i], "system inventory cannot gain holder rights");
            assertEq(game.escrowBacking(i), (virtualSum[i] + 95_126_814_720 - 1) / 95_126_814_720);
        }
        _assertTreasuryHasNoGameRights();
    }

    function _crewAt(uint256 index, uint16 aliveMask) private pure returns (uint8) {
        uint256 count;
        for (uint8 i; i < 10; ++i) if ((aliveMask & (uint16(1) << i)) != 0) ++count;
        index %= count;
        for (uint8 i; i < 10; ++i) {
            if ((aliveMask & (uint16(1) << i)) == 0) continue;
            if (index == 0) return i;
            --index;
        }
        revert("no living crew");
    }

    function _actors() private pure returns (address[5] memory) {
        return [ALICE, BOB, CAROL, EARLY, LATE];
    }
}
