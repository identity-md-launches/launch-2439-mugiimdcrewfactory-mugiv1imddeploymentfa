// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiGameTestBase, GameRandomnessMock} from "../lifecycle/MugiGameHook.t.sol";
import {MugiIMDGameHook as Hook} from "src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "src/game/MugiCrewToken.sol";
import {MugiIMDSwapRouter} from "src/imd/MugiIMDSwapRouter.sol";
import {MugiIMDBuybacks} from "src/imd/modules/MugiIMDBuybacks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract SeasonAccountingHandler is Test {
    using TransientStateLibrary for IPoolManager;
    uint256 private constant SCALE = 95_126_814_720;
    Hook public immutable game;
    MugiIMDSwapRouter public immutable router;
    GameRandomnessMock public immutable randomness;
    address[5] public actors;
    uint256 public immutable openingEth;
    uint256[10] public lastSupply;
    uint256[10] public lastReserve;
    uint256 public buys;
    uint256 public sells;
    uint256 public claims;
    uint256 public steps;
    uint256 public failedSlippage;

    constructor(Hook game_, GameRandomnessMock randomness_, address[5] memory actors_) {
        game = game_;
        randomness = randomness_;
        actors = actors_;
        router = new MugiIMDSwapRouter(game_, game_.poolManager());
        openingEth = _ethInSystem();
        for (uint8 i; i < 10; ++i) {
            lastSupply[i] = MugiCrewToken(game_.tokens(i)).totalSupply();
            lastReserve[i] = game_.unreleasedReserve(i);
        }
    }

    modifier observe() {
        _;
        for (uint8 i; i < 10; ++i) {
            uint256 supply = MugiCrewToken(game.tokens(i)).totalSupply();
            uint256 reserve = game.unreleasedReserve(i);
            assertLe(supply, lastSupply[i], "tokens minted after constructor");
            assertLe(reserve, lastReserve[i], "retired or released reserve restored");
            lastSupply[i] = supply;
            lastReserve[i] = reserve;
        }
    }

    function trade(uint256 actorSeed, uint256 crewSeed, uint256 amountSeed, bool buy, bool impossibleMinimum)
        external
        observe
    {
        if (!_live()) return;
        address actor = actors[actorSeed % 5];
        uint8 crew = _livingCrew(crewSeed);
        MugiCrewToken token = MugiCrewToken(game.tokens(crew));
        uint256 amount;
        if (buy) {
            amount = bound(amountSeed, 1e12, 0.1 ether);
        } else {
            uint256 maximum = token.balanceOf(actor);
            if (maximum > 100 ether) maximum = 100 ether;
            if (maximum < 1e12) return;
            amount = bound(amountSeed, 1e12, maximum);
        }
        uint256 ethBefore = actor.balance;
        uint256 tokensBefore = token.balanceOf(actor);
        uint256 feesBefore = game.unredeemedGameFees();
        (uint160 priceBefore,,) = game.poolState(crew);
        vm.startPrank(actor);
        if (!buy) token.approve(address(router), amount);
        if (impossibleMinimum) vm.expectRevert(MugiIMDSwapRouter.InsufficientOutput.selector);
        uint256 output;
        if (buy) output = router.buy{value: amount}(crew, impossibleMinimum ? type(uint256).max : 1, type(uint64).max);
        else output = router.sell(crew, amount, impossibleMinimum ? type(uint256).max : 1, type(uint64).max);
        vm.stopPrank();
        if (impossibleMinimum) {
            assertEq(actor.balance, ethBefore);
            assertEq(token.balanceOf(actor), tokensBefore);
            assertEq(game.unredeemedGameFees(), feesBefore);
            (uint160 priceAfter,,) = game.poolState(crew);
            assertEq(priceAfter, priceBefore);
            ++failedSlippage;
        } else if (buy) {
            assertEq(actor.balance + amount, ethBefore);
            assertEq(token.balanceOf(actor), tokensBefore + output);
            assertEq(game.unredeemedGameFees() - feesBefore, amount / 50);
            ++buys;
        } else {
            assertEq(actor.balance, ethBefore + output);
            assertEq(token.balanceOf(actor), tokensBefore - amount);
            assertEq(token.allowance(actor, address(router)), 0);
            ++sells;
        }
    }

    function wallet(uint256 fromSeed, uint256 toSeed, uint256 crewSeed, uint256 amountSeed, bool burn_)
        external
        observe
    {
        address from = actors[fromSeed % 5];
        MugiCrewToken token = MugiCrewToken(game.tokens(crewSeed % 10));
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        if (burn_) token.burn(amount);
        else token.transfer(actors[toSeed % 5], amount);
    }

    function claim(uint256 actorSeed, uint256 amountSeed, uint256 crewSeed, bool all) external observe {
        address actor = actors[actorSeed % 5];
        (, uint256 ethOwed,) = game.previewAccount(actor);
        uint256 beforeEth = actor.balance;
        vm.prank(actor);
        assertEq(game.claimEth(payable(actor)), ethOwed);
        assertEq(actor.balance, beforeEth + ethOwed);
        if (_live() || game.phase() == Hook.Phase.Finalized) {
            (uint256[10] memory owed,,) = game.previewAccount(actor);
            if (all) {
                uint256[10] memory balances;
                for (uint8 i; i < 10; ++i) {
                    balances[i] = MugiCrewToken(game.tokens(i)).balanceOf(actor);
                }
                vm.prank(actor);
                game.claimTokens();
                for (uint8 i; i < 10; ++i) {
                    assertEq(MugiCrewToken(game.tokens(i)).balanceOf(actor), balances[i] + owed[i]);
                }
            } else {
                uint8 crew = uint8(crewSeed % 10);
                uint256 amount = bound(amountSeed, 0, owed[crew]);
                uint256 beforeBalance = MugiCrewToken(game.tokens(crew)).balanceOf(actor);
                vm.prank(actor);
                game.claimToken(crew, amount);
                assertEq(MugiCrewToken(game.tokens(crew)).balanceOf(actor), beforeBalance + amount);
            }
            ++claims;
        } else {
            vm.prank(actor);
            vm.expectRevert(Hook.InvalidState.selector);
            game.claimTokens();
        }
    }

    /// @dev Separate calls expose all intermediate phases to the invariant runner.
    function progress(uint256 word, uint256 batchSeed) external observe {
        Hook.Phase phase = game.phase();
        if (phase == Hook.Phase.Live) {
            vm.warp(game.nextCutoff());
            if (game.eliminations() == 9) game.finalize();
            else game.requestElimination();
        } else if (phase == Hook.Phase.AwaitingRandomness) {
            randomness.fulfill(game.pendingRequest(), word);
        } else if (phase == Hook.Phase.OutcomeReady || phase == Hook.Phase.Settling) {
            game.settleRound(uint8(bound(batchSeed, 1, 10)));
        } else {
            return;
        }
        ++steps;
    }

    function fees(uint256 crewSeed, bool withdraw) external observe {
        if (_live()) game.collectTeamFees(_livingCrew(crewSeed));
        if (withdraw && (_live() || game.phase() == Hook.Phase.Finalized)) game.withdrawTeamFees();
    }

    function retireDrop() external observe {
        if (!game.airdropRetired() && block.timestamp >= game.launchedAt() + 22 hours) game.retireAirdrop();
    }

    function assertAccounting() external view {
        assertEq(_ethInSystem(), openingEth, "ETH escaped tracked custody");
        assertGe(address(game).balance + game.unredeemedGameFees(), game.reservedPlayerEth() + game.teamEth());
        assertEq(address(router).balance, 0);
        assertEq(address(game.engine()).balance, 0);
        assertFalse(game.poolManager().isUnlocked());
        assertEq(game.poolManager().balanceOf(address(game), 0), game.unredeemedGameFees());
        uint256 rewardSum;
        uint256[10] memory units;
        uint256[10] memory wallets;
        for (uint256 a; a < 5; ++a) {
            (, uint256 ethOwed, uint256[10] memory virtual_) = game.previewAccount(actors[a]);
            rewardSum += ethOwed;
            for (uint8 i; i < 10; ++i) {
                units[i] += virtual_[i];
                wallets[i] += MugiCrewToken(game.tokens(i)).balanceOf(actors[a]);
            }
        }
        assertLe(rewardSum, game.reservedPlayerEth());
        uint256 living;
        for (uint8 i; i < 10; ++i) {
            MugiCrewToken token = MugiCrewToken(game.tokens(i));
            uint256 hookBalance = token.balanceOf(address(game));
            assertGe(hookBalance, game.unreleasedReserve(i) + game.escrowBacking(i) + game.teamTokens(i));
            assertEq(game.escrowBacking(i), (units[i] + SCALE - 1) / SCALE);
            assertEq(token.balanceOf(address(router)), 0);
            assertEq(token.balanceOf(address(game.engine())), 0);
            uint256 protocol = hookBalance + token.balanceOf(address(game.poolManager()))
                + token.balanceOf(address(game.airdrop())) + token.balanceOf(game.teamTreasury())
                + token.balanceOf(game.communityTreasury());
            assertEq(token.totalSupply(), protocol + wallets[i]);
            if ((game.aliveMask() & (uint16(1) << i)) == 0) {
                assertEq(game.unreleasedReserve(i), 0);
                assertEq(game.positionLiquidity(i), 0);
                assertEq(game.eligibleSupply(i), 0);
            } else {
                ++living;
                if (game.phase() != Hook.Phase.Finalized) {
                    assertEq(game.eligibleSupply(i), wallets[i] * SCALE + units[i]);
                }
            }
        }
        assertEq(living + game.eliminations(), 10);
        for (uint64 r = 1; r <= game.eliminations(); ++r) {
            MugiIMDBuybacks.Budget memory b = game.roundBudget(r);
            uint256 allocation;
            uint256 spent;
            for (uint8 i; i < 10; ++i) {
                allocation += b.allocation[i];
                spent += b.crewSpent[i];
                assertLe(b.crewSpent[i], b.allocation[i]);
            }
            assertEq(allocation, b.total);
            assertEq(spent, b.spent);
            assertLe(spent, b.total);
            assertFalse(b.authorizationPending, "an atomic hook trade left an open budget authorization");
        }
    }

    function _ethInSystem() private view returns (uint256 total) {
        total = address(game).balance + address(game.poolManager()).balance + address(game.engine()).balance
            + address(router).balance + game.teamTreasury().balance + game.communityTreasury().balance;
        for (uint256 a; a < 5; ++a) {
            total += actors[a].balance;
        }
    }

    function _live() private view returns (bool) {
        return game.phase() == Hook.Phase.Live && block.timestamp < game.nextCutoff();
    }

    function _livingCrew(uint256 entropy) private view returns (uint8 crew) {
        crew = uint8(entropy % 10);
        while ((game.aliveMask() & (uint16(1) << crew)) == 0) crew = (crew + 1) % 10;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract MugiSeasonAccountingInvariantTest is MugiGameTestBase {
    SeasonAccountingHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
        address[5] memory actors = [ALICE, BOB, CAROL, EARLY, LATE];
        for (uint256 a; a < 5; ++a) {
            vm.deal(actors[a], 100 ether);
        }
        handler = new SeasonAccountingHandler(game, randomness, actors);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.wallet.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.progress.selector;
        selectors[4] = handler.fees.selector;
        selectors[5] = handler.retireDrop.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        handler.assertAccounting();
    }

    function invariant_realPoolCustodyAndLedgerClaimsReconcile() public view {
        handler.assertAccounting();
    }

    function testHandlerReachesNineRoundsWithRealTradesAndClaims() public {
        for (uint8 round; round < 9; ++round) {
            handler.trade(0, round, 0.01 ether, true, false);
            handler.trade(0, round, 1 ether, false, false);
            handler.trade(0, round, 0.01 ether, true, true);
            handler.fees(round, true);
            handler.progress(0, 10);
            handler.wallet(0, 1, round, 1, false);
            handler.progress(0, 10);
            handler.progress(0, 10);
            handler.claim(round % 5, 1, round + 1, round % 2 == 0);
            handler.retireDrop();
            handler.assertAccounting();
        }
        handler.progress(0, 10);
        handler.assertAccounting();
        assertEq(game.eliminations(), 9);
        assertEq(uint8(game.phase()), uint8(Hook.Phase.Finalized));
        assertEq(handler.buys(), 9);
        assertEq(handler.sells(), 9);
        assertEq(handler.failedSlippage(), 9);
        assertEq(handler.claims(), 9);
    }
}
