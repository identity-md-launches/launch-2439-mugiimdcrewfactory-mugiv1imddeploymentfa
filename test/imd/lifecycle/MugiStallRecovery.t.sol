// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiVRFAdapter, IMugiVRFCoordinator} from "../../../src/game/MugiVRFAdapter.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

contract RecoveryCoordinator is IMugiVRFCoordinator {
    uint256 public requests;
    bool public rejectRequests;
    function setRejectRequests(bool value) external { rejectRequests = value; }
    function requestRandomWords(RandomWordsRequest calldata) external returns (uint256) {
        require(!rejectRequests, "coordinator unavailable");
        return ++requests;
    }
    function fulfill(MugiVRFAdapter adapter, uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        adapter.rawFulfillRandomWords(requestId, words);
    }
    function fulfillWithBudget(MugiVRFAdapter adapter, uint256 requestId, uint256 word) external returns (bool) {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        (bool ok,) = address(adapter).call{gas: 300_000}(abi.encodeCall(MugiVRFAdapter.rawFulfillRandomWords, (requestId, words)));
        return ok;
    }
}

contract MugiStallRecoveryTest is MugiGameTestBase {
    RecoveryCoordinator internal coordinator;
    MugiVRFAdapter internal adapter;

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
    }

    function _makeRandomness(address hook) internal override returns (address) {
        coordinator = new RecoveryCoordinator();
        adapter = new MugiVRFAdapter(hook, address(coordinator), bytes32(uint256(1)), 1, 300_000, true);
        return address(adapter);
    }

    function _request() private returns (uint256 requestId) {
        vm.warp(game.nextCutoff());
        game.requestElimination();
        requestId = game.pendingRequest();
    }

    function testSilentRequestRecoversTenPoolsWithoutRerollOrOwnerCashout() public {
        uint256 ownerBefore = address(this).balance;
        _request();
        vm.warp(game.randomnessDeadline() - 1);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.recoverStalledRandomness(1);
        vm.warp(game.randomnessDeadline());
        vm.prank(BOB);
        game.recoverStalledRandomness(1);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyUnwinding));
        assertEq(game.settlementCursor(), 1);
        assertEq(game.positionLiquidity(0), 0);
        assertGt(game.positionLiquidity(1), 0);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.recoverStalledRandomness(0);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.recoverStalledRandomness(11);
        for (uint8 i; i < 9; ++i) game.recoverStalledRandomness(1);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyClosed));
        for (uint8 i; i < 10; ++i) assertEq(game.positionLiquidity(i), 0);
        assertEq(coordinator.requests(), 1);
        assertEq(game.eliminations(), 0);
        assertEq(address(this).balance, ownerBefore);
        assertGt(game.reservedPlayerEth(), 0);
        (, uint256 bobEarned,) = game.previewAccount(BOB);
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        game.claimEth(payable(BOB));
        assertEq(BOB.balance, bobBefore + bobEarned);
        assertGt(bobEarned, 99 ether);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.requestElimination();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.finalize();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.migrateToV2(_migrationTarget());
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.recoverStalledRandomness(10);
        _assertSolvent();
    }

    function testRejectedRequestInitiationCannotFreezeSeasonOrExtendCutoffDeadline() public {
        coordinator.setRejectRequests(true);
        uint64 deadline = game.randomnessDeadline();
        vm.warp(game.nextCutoff());
        vm.expectRevert(bytes("coordinator unavailable"));
        game.requestElimination();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        assertEq(game.randomnessDeadline(), deadline);
        vm.warp(deadline - 1);
        vm.expectRevert(bytes("coordinator unavailable"));
        game.requestElimination();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.recoverStalledRandomness(10);
        vm.warp(deadline);
        game.recoverStalledRandomness(10);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyClosed));
        assertEq(coordinator.requests(), 0);
        assertEq(game.pendingRequest(), 0);
        for (uint8 i; i < 10; ++i) assertEq(game.positionLiquidity(i), 0);
    }

    function testNobodyRequestsBeforeDeadlineCannotStartFreshRandomnessAfterwards() public {
        vm.warp(game.randomnessDeadline());
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.requestElimination();
        game.recoverStalledRandomness(10);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyClosed));
        assertEq(coordinator.requests(), 0);
    }

    function testLastSecondRequestDoesNotExtendDeadline() public {
        uint64 deadline = game.randomnessDeadline();
        vm.warp(deadline - 1);
        game.requestElimination();
        assertEq(game.randomnessDeadline(), deadline);
        vm.warp(deadline);
        coordinator.fulfill(adapter, game.pendingRequest(), 0);
        game.recoverStalledRandomness(10);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyClosed));
        assertEq(game.eliminations(), 0);
        assertEq(coordinator.requests(), 1);
    }

    function testOnTimeStoredWordCannotBeDiscardedAfterDeferredDelivery() public {
        uint256 requestId = _request();
        vm.warp(game.randomnessDeadline() - 1);
        vm.mockCallRevert(address(game), abi.encodeCall(MugiGameHook.receiveRandomness, (requestId, 3)), hex"01");
        coordinator.fulfill(adapter, requestId, 3);
        assertEq(adapter.fulfilledAt(requestId), game.randomnessDeadline() - 1);
        (uint256 word,, bool ready, bool delivered) = adapter.requests(requestId);
        assertEq(word, 3); assertTrue(ready); assertFalse(delivered);
        vm.clearMockedCalls();
        vm.warp(game.randomnessDeadline() + 30 days);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.recoverStalledRandomness(10);
        adapter.retryDelivery(requestId);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.OutcomeReady));
        assertEq(game.defeatedCrew(), 3);
        game.settleRound(10);
        assertEq(game.eliminations(), 1);
        assertEq(coordinator.requests(), 1);
    }

    function testConfiguredCallbackBudgetStoresTimeAndDeliversValidZeroWord() public {
        uint256 requestId = _request();
        assertTrue(coordinator.fulfillWithBudget(adapter, requestId, 0));
        (uint256 word,, bool ready, bool delivered) = adapter.requests(requestId);
        assertEq(word, 0); assertTrue(ready); assertTrue(delivered);
        assertEq(adapter.fulfilledAt(requestId), block.timestamp);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.OutcomeReady));
        assertEq(game.defeatedCrew(), 0);
    }

    function testWordFirstStoredAtDeadlineCannotReviveSeason() public {
        uint256 requestId = _request();
        vm.warp(game.randomnessDeadline());
        coordinator.fulfill(adapter, requestId, 9);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.AwaitingRandomness));
        game.recoverStalledRandomness(10);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyClosed));
        assertEq(game.eliminations(), 0);
        assertEq(coordinator.requests(), 1);
    }

    function testLateWordDuringPartialRecoveryCannotChooseLoserOrReopenPools() public {
        uint256 requestId = _request();
        vm.warp(game.randomnessDeadline() + 30 days);
        game.recoverStalledRandomness(2);
        coordinator.fulfill(adapter, requestId, 5);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyUnwinding));
        assertEq(game.eliminations(), 0);
        game.recoverStalledRandomness(10);
        adapter.retryDelivery(requestId);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.EmergencyClosed));
        assertEq(game.eliminations(), 0);
    }

    function testRecoveryPreservesPriorRewardsAndVirtualHolderRights() public {
        _fundTreasure(0);
        uint256 requestId = _request();
        coordinator.fulfill(adapter, requestId, 0);
        game.settleRound(10);
        (, uint256 bobPrior,) = game.previewAccount(BOB);
        (uint256[10] memory aliceTokens,,) = game.previewAccount(ALICE);
        assertGt(bobPrior, 0);
        assertGt(aliceTokens[1], 0);
        _request();
        vm.warp(game.randomnessDeadline());
        game.recoverStalledRandomness(1);
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), bobPrior);
        game.recoverStalledRandomness(10);
        (, uint256 aliceRecovery,) = game.previewAccount(ALICE);
        assertGt(aliceRecovery, 0);
        vm.prank(ALICE);
        game.claimTokens();
        (, uint256 aliceAfterTokens,) = game.previewAccount(ALICE);
        assertEq(aliceAfterTokens, aliceRecovery, "materialization must not earn recovery twice");
        vm.prank(ALICE);
        assertEq(game.claimEth(payable(ALICE)), aliceRecovery);
        vm.prank(ALICE);
        assertEq(game.claimEth(payable(ALICE)), 0);
        uint256 team = game.teamEth();
        uint256 communityBefore = COMMUNITY.balance;
        uint256 toExpire = address(game).balance - team;
        vm.warp(game.claimsExpireAt());
        game.sweepExpiredFinalClaims();
        assertEq(COMMUNITY.balance, communityBefore + toExpire);
        assertEq(address(game).balance, team);
        game.withdrawTeamFees();
        assertEq(address(game).balance, 0);
        _assertSolvent();
    }
}

contract MugiFinaleRightsTest is MugiGameTestBase {
    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
    }

    // IMD disallows owner pausing. The capability is absent, not disabled by a flag.
    function testOwnerCannotInstallPauseAndTradingStillWorks() public {
        (bool ok,) = address(game).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertFalse(ok);
        _fundTreasure(0);
        assertGt(game.treasure(0), 0);
    }

    function testNoPauseCanDelayTheFixedRandomnessCutoff() public {
        vm.warp(game.nextCutoff());
        game.requestElimination();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.AwaitingRandomness));
    }

    function testCommittedV2TargetAndOneShotMigrationReserveUnclaimedTokens() public {
        for (uint8 i; i < 9; ++i) _round(0);
        (uint256[10] memory beforeFinal,,) = game.previewAccount(ALICE);
        vm.warp(game.nextCutoff());
        game.finalize();
        assertEq(game.v2MigrationTarget(), _migrationTarget());
        assertTrue(_migrationTarget() != address(this), "V2 receiver is distinct from the owner");
        uint256 reservedTokens = game.escrowBacking(9);
        assertGt(reservedTokens, 0);
        (uint256[10] memory afterFinal,,) = game.previewAccount(ALICE);
        assertEq(afterFinal[9], beforeFinal[9]);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.migrateToV2(address(router));
        game.migrateToV2(_migrationTarget());
        assertTrue(game.migrated());
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), reservedTokens);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.migrateToV2(_migrationTarget());
        uint256 aliceBefore = MugiCrewToken(crew[9]).balanceOf(ALICE);
        vm.prank(ALICE);
        game.claimTokens();
        assertEq(MugiCrewToken(crew[9]).balanceOf(ALICE), aliceBefore + beforeFinal[9]);
        assertEq(game.escrowBacking(9), reservedTokens - beforeFinal[9]);
        vm.warp(game.claimsExpireAt());
        vm.prank(BOB);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimTokens();
        game.sweepExpiredFinalClaims();
        assertEq(game.escrowBacking(9), 0);
        assertEq(MugiCrewToken(crew[9]).balanceOf(address(game)), 0);
        _assertSolvent();
    }
}
