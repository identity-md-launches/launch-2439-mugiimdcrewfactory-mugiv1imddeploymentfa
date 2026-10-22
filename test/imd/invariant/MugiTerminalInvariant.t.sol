// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiGameTestBase} from "../lifecycle/MugiGameHook.t.sol";
import {MugiIMDGameHook as Hook} from "src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

/// @dev Local adversarial receiver, never a proposed live deployment setting.
contract InvariantFinaleReceiver {
    bool public reject;
    uint256 public calls;
    uint256 public receivedEth;
    uint256 public receivedTokens;

    function setReject(bool value) external {
        reject = value;
    }

    function receiveV1Finale(uint8, address token, uint256 amount) external payable {
        require(!reject, "receiver unavailable");
        Hook hook = Hook(payable(msg.sender));
        require(hook.migrated(), "handoff flag not set before interaction");
        require(MugiCrewToken(token).balanceOf(address(this)) == amount, "token delivery not atomic");
        // The receiver must not be able to drain a second handoff or sweep claims.
        (bool again,) = msg.sender.call(abi.encodeCall(hook.migrateToV2, (address(this))));
        (bool sweep,) = msg.sender.call(abi.encodeCall(hook.sweepExpiredFinalClaims, ()));
        require(!again && !sweep, "receiver reentered terminal custody");
        ++calls;
        receivedEth += msg.value;
        receivedTokens += amount;
    }
}

/// @dev All asset movements are real calls. Ghost counters record observed payouts,
/// not values read back from the ledger's aggregate accounting.
contract TerminalCustodyHandler is Test {
    uint256 private constant SCALE = 95_126_814_720;
    Hook public immutable game;
    InvariantFinaleReceiver public immutable receiver;
    address[5] public actors;
    uint64 public immutable deadline;
    bool public immutable emergency;
    uint16 public immutable terminalMask;
    uint256 public immutable openingEth;
    uint256 public immutable openingTeamEth;
    uint256 public immutable openingCommunityEth;
    uint256 public paidPlayers;
    uint256 public paidTeam;
    uint256 public paidProtocol;
    uint256 public paidExpired;
    uint256 public handoffs;
    bool public expired;
    uint256[5] public openingRewards;
    uint256[5] public claimedRewards;
    uint256[10][5] public openingVirtual;
    uint256[10][5] public claimedTokens;
    uint256[10] public openingSupply;
    uint256[10] public burned;
    uint256[10] public terminalEligible;
    uint256 public successfulTokenClaims;
    uint256 public successfulEthClaims;
    uint256 public walletOperations;

    constructor(Hook game_, InvariantFinaleReceiver receiver_, address[5] memory actors_) {
        game = game_;
        receiver = receiver_;
        actors = actors_;
        deadline = game_.claimsExpireAt();
        emergency = game_.phase() == Hook.Phase.EmergencyClosed;
        terminalMask = game_.aliveMask();
        openingEth = address(game_).balance;
        openingTeamEth = game_.teamTreasury().balance;
        openingCommunityEth = game_.communityTreasury().balance;
        for (uint256 a; a < 5; ++a) {
            (, openingRewards[a], openingVirtual[a]) = game_.previewAccount(actors_[a]);
        }
        for (uint8 i; i < 10; ++i) {
            openingSupply[i] = MugiCrewToken(game_.tokens(i)).totalSupply();
            terminalEligible[i] = game_.eligibleSupply(i);
        }
    }

    function advance(uint256 entropy) external {
        uint256 now_ = block.timestamp;
        uint256 destination;
        if (entropy % 4 == 0) destination = deadline - 1;
        else if (entropy % 4 == 1) destination = deadline;
        else destination = now_ + bound(entropy >> 8, 0, 3 days);
        if (destination > now_) vm.warp(destination);
    }

    function claimEth(uint256 actorSeed) external {
        uint256 a = actorSeed % 5;
        address actor = actors[a];
        if (block.timestamp >= deadline || expired) {
            vm.prank(actor);
            vm.expectRevert(Hook.InvalidState.selector);
            game.claimEth(payable(actor));
            return;
        }
        uint256 beforeBalance = actor.balance;
        vm.prank(actor);
        uint256 amount = game.claimEth(payable(actor));
        assertEq(amount, openingRewards[a] - claimedRewards[a], "valid claim must pay all earned ETH");
        assertEq(actor.balance - beforeBalance, amount);
        claimedRewards[a] += amount;
        paidPlayers += amount;
        ++successfulEthClaims;
    }

    function claimTokens(uint256 actorSeed, uint256 crewSeed, uint256 amountSeed, bool all) external {
        uint256 a = actorSeed % 5;
        address actor = actors[a];
        if (block.timestamp >= deadline || expired) {
            vm.prank(actor);
            vm.expectRevert(Hook.InvalidState.selector);
            game.claimTokens();
            return;
        }
        uint256[10] memory beforeBalances;
        (uint256[10] memory expected,,) = game.previewAccount(actor);
        for (uint8 i; i < 10; ++i) {
            beforeBalances[i] = MugiCrewToken(game.tokens(i)).balanceOf(actor);
        }
        if (all) {
            vm.prank(actor);
            game.claimTokens();
        } else {
            uint8 crew = uint8(crewSeed % 10);
            uint256 amount = bound(amountSeed, 0, expected[crew]);
            for (uint8 i; i < 10; ++i) {
                expected[i] = i == crew ? amount : 0;
            }
            vm.prank(actor);
            game.claimToken(crew, amount);
        }
        for (uint8 i; i < 10; ++i) {
            uint256 received = MugiCrewToken(game.tokens(i)).balanceOf(actor) - beforeBalances[i];
            assertEq(received, expected[i], "valid claim must materialize the requested backing");
            claimedTokens[a][i] += received;
        }
        ++successfulTokenClaims;
    }

    function excessiveClaim(uint256 actorSeed, uint256 crewSeed) external {
        if (block.timestamp >= deadline || expired) return;
        address actor = actors[actorSeed % 5];
        uint8 crew = uint8(crewSeed % 10);
        (uint256[10] memory owed,,) = game.previewAccount(actor);
        uint256 beforeBalance = MugiCrewToken(game.tokens(crew)).balanceOf(actor);
        vm.prank(actor);
        (bool ok,) = address(game).call(abi.encodeCall(game.claimToken, (crew, owed[crew] + 1)));
        assertFalse(ok, "claim exceeded earned backing");
        assertEq(MugiCrewToken(game.tokens(crew)).balanceOf(actor), beforeBalance);
    }

    function transferOrBurn(uint256 fromSeed, uint256 toSeed, uint256 crewSeed, uint256 amountSeed, bool burn_)
        external
    {
        address from = actors[fromSeed % 5];
        MugiCrewToken token = MugiCrewToken(game.tokens(crewSeed % 10));
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        if (burn_) {
            token.burn(amount);
            burned[crewSeed % 10] += amount;
        } else {
            token.transfer(actors[toSeed % 5], amount);
        }
        ++walletOperations;
    }

    function withdrawTeam() external {
        uint256 beforeBalance = game.teamTreasury().balance;
        game.withdrawTeamFees();
        paidTeam += game.teamTreasury().balance - beforeBalance;
    }

    function migrate(bool reject, bool wrongTarget) external {
        receiver.setReject(reject);
        uint256 beforeEth = address(game).balance;
        uint256[10] memory beforeTokens;
        for (uint8 i; i < 10; ++i) {
            beforeTokens[i] = MugiCrewToken(game.tokens(i)).balanceOf(address(game));
        }
        bool wasMigrated = game.migrated();
        address target = wrongTarget ? address(this) : address(receiver);
        bool permitted = !emergency && !wasMigrated && block.timestamp < deadline && !reject && !wrongTarget;
        (bool ok,) = address(game).call(abi.encodeCall(game.migrateToV2, (target)));
        assertEq(ok, permitted, "fixed target, deadline, phase and receiver determine handoff");
        if (ok) {
            paidProtocol += beforeEth - address(game).balance;
            ++handoffs;
        } else {
            assertEq(game.migrated(), wasMigrated, "failed handoff consumed migration");
            assertEq(address(game).balance, beforeEth);
            for (uint8 i; i < 10; ++i) {
                assertEq(MugiCrewToken(game.tokens(i)).balanceOf(address(game)), beforeTokens[i]);
            }
        }
    }

    function fallbackToCommunity() external {
        bool permitted = !emergency && !game.migrated() && block.timestamp >= deadline;
        uint256 beforeBalance = game.communityTreasury().balance;
        uint256 ethLiability = game.reservedPlayerEth();
        uint256[10] memory backing;
        for (uint8 i; i < 10; ++i) {
            backing[i] = game.escrowBacking(i);
        }
        (bool ok,) = address(game).call(abi.encodeCall(game.fallbackFinaleToCommunity, ()));
        assertEq(ok, permitted);
        if (ok) {
            paidProtocol += game.communityTreasury().balance - beforeBalance;
            ++handoffs;
        }
        assertEq(game.reservedPlayerEth(), ethLiability, "fallback must not expire claims implicitly");
        for (uint8 i; i < 10; ++i) {
            assertEq(game.escrowBacking(i), backing[i]);
        }
    }

    function sweep() external {
        bool permitted = !expired && block.timestamp >= deadline;
        uint256 beforeBalance = game.communityTreasury().balance;
        uint256[10] memory supply;
        for (uint8 i; i < 10; ++i) {
            supply[i] = MugiCrewToken(game.tokens(i)).totalSupply();
        }
        (bool ok,) = address(game).call(abi.encodeCall(game.sweepExpiredFinalClaims, ()));
        assertEq(ok, permitted);
        if (ok) {
            expired = true;
            paidExpired += game.communityTreasury().balance - beforeBalance;
            for (uint8 i; i < 10; ++i) {
                burned[i] += supply[i] - MugiCrewToken(game.tokens(i)).totalSupply();
            }
        }
    }

    function assertCustody() external view {
        assertEq(address(game).balance + paidPlayers + paidTeam + paidProtocol + paidExpired, openingEth);
        assertGe(address(game).balance, game.reservedPlayerEth() + game.teamEth());
        assertEq(game.teamTreasury().balance, openingTeamEth + paidTeam);
        assertEq(
            game.communityTreasury().balance + address(receiver).balance,
            openingCommunityEth + paidProtocol + paidExpired
        );
        uint256 rewardSum;
        uint256[10] memory virtualSum;
        for (uint256 a; a < 5; ++a) {
            (, uint256 reward, uint256[10] memory units) = game.previewAccount(actors[a]);
            rewardSum += reward;
            if (!expired) {
                assertEq(reward + claimedRewards[a], openingRewards[a], "earned ETH moved with wallet tokens");
            } else {
                assertEq(reward, 0);
            }
            for (uint8 i; i < 10; ++i) {
                virtualSum[i] += units[i];
                if (!expired) assertEq(units[i] + claimedTokens[a][i] * SCALE, openingVirtual[a][i]);
                else assertEq(units[i], 0);
            }
        }
        assertLe(rewardSum, game.reservedPlayerEth());
        for (uint8 i; i < 10; ++i) {
            MugiCrewToken token = MugiCrewToken(game.tokens(i));
            assertEq(game.escrowBacking(i), (virtualSum[i] + SCALE - 1) / SCALE);
            assertGe(token.balanceOf(address(game)), game.escrowBacking(i) + game.teamTokens(i));
            assertEq(token.totalSupply() + burned[i], openingSupply[i], "terminal mint or untracked burn");
            uint256 balances = token.balanceOf(address(game)) + token.balanceOf(address(game.poolManager()))
                + token.balanceOf(address(game.airdrop())) + token.balanceOf(address(game.engine()))
                + token.balanceOf(game.teamTreasury()) + token.balanceOf(game.communityTreasury())
                + token.balanceOf(address(receiver));
            for (uint256 a; a < 5; ++a) {
                balances += token.balanceOf(actors[a]);
            }
            assertEq(balances, token.totalSupply(), "finite supply must equal all custody balances");
            assertEq(game.unreleasedReserve(i), 0);
            assertEq(game.positionLiquidity(i), 0);
            assertEq(game.eligibleSupply(i), expired ? 0 : terminalEligible[i]);
        }
        assertEq(game.aliveMask(), terminalMask);
        assertEq(uint8(game.phase()), uint8(emergency ? Hook.Phase.EmergencyClosed : Hook.Phase.Finalized));
        assertLe(handoffs, 1);
        assertLe(receiver.calls(), 1);
        assertEq(game.migrated(), handoffs == 1);
        assertEq(game.migrationDeadline(), emergency ? 0 : deadline);
        assertEq(game.claimsExpireAt(), expired ? 0 : deadline);
        if (emergency) assertEq(receiver.calls(), 0);
    }
}

abstract contract TerminalInvariantFixture is MugiGameTestBase {
    InvariantFinaleReceiver internal terminalReceiver;
    TerminalCustodyHandler internal handler;

    function _migrationTarget() internal view override returns (address) {
        return address(terminalReceiver);
    }

    function _terminalSetup(bool emergency) internal {
        vm.warp(1_800_000_000);
        terminalReceiver = new InvariantFinaleReceiver();
        _setup(new PoolManager(address(this)));
        uint8 rounds = emergency ? 3 : 9;
        for (uint8 i; i < rounds; ++i) {
            _swap(ALICE, i, true, -int256(0.1 ether));
            _round(0);
        }
        if (emergency) {
            vm.warp(game.randomnessDeadline());
            game.recoverStalledRandomness(10);
        } else {
            vm.warp(game.nextCutoff());
            game.finalize();
        }
        handler = new TerminalCustodyHandler(game, terminalReceiver, [ALICE, BOB, CAROL, EARLY, LATE]);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.claimEth.selector;
        selectors[2] = handler.claimTokens.selector;
        selectors[3] = handler.excessiveClaim.selector;
        selectors[4] = handler.transferOrBurn.selector;
        selectors[5] = handler.withdrawTeam.selector;
        selectors[6] = handler.migrate.selector;
        selectors[7] = handler.fallbackToCommunity.selector;
        selectors[8] = handler.sweep.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        assertGt(game.reservedPlayerEth(), 0, "fixture must contain earned ETH");
        assertGt(game.escrowBacking(9), 0, "fixture must contain earned tokens");
        handler.assertCustody();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MugiFinaleCustodyInvariantTest is TerminalInvariantFixture {
    function setUp() public {
        _terminalSetup(false);
    }

    function invariant_finaleCustodyAndEarnedRightsSurviveEveryOrdering() public view {
        handler.assertCustody();
    }

    function testTerminalHandlerExercisesPartialClaimsFailureRetryAndExpiry() public {
        handler.claimTokens(0, 9, 1, false);
        handler.claimEth(1);
        handler.transferOrBurn(0, 1, 9, 1, false);
        handler.migrate(true, false);
        handler.assertCustody();
        handler.migrate(false, false);
        handler.claimTokens(4, 9, 0, true);
        handler.advance(1);
        handler.sweep();
        handler.withdrawTeam();
        handler.assertCustody();
        assertGt(handler.successfulTokenClaims(), 0);
        assertGt(handler.successfulEthClaims(), 0);
        assertGt(handler.paidPlayers(), 0);
        assertGt(handler.claimedTokens(0, 9), 0);
        assertEq(handler.handoffs(), 1);
        assertEq(address(game).balance, 0);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MugiEmergencyCustodyInvariantTest is TerminalInvariantFixture {
    function setUp() public {
        _terminalSetup(true);
    }

    function invariant_emergencyPreservesLiabilitiesAndNeverMigrates() public view {
        handler.assertCustody();
    }

    function testEmergencyHandlerExercisesClaimsAndFullExpiry() public {
        handler.claimTokens(0, 9, 1, false);
        handler.claimEth(1);
        handler.migrate(false, false);
        handler.advance(1);
        handler.fallbackToCommunity();
        handler.sweep();
        handler.withdrawTeam();
        handler.assertCustody();
        assertEq(address(game).balance, 0);
        assertEq(handler.handoffs(), 0);
        assertGt(handler.paidPlayers(), 0);
        assertGt(handler.claimedTokens(0, 9), 0);
    }
}
