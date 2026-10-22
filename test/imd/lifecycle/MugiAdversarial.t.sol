// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// IMD modular regression adapted from v1/test/game/MugiAdversarial.t.sol.
// Exercises CALL-module custody with the same season/accounting assertions.

import {MugiGameTestBase, GameRandomnessMock} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {MugiIMDCrewFactory as MugiCrewFactory} from "../../../src/imd/MugiIMDCrewFactory.sol";
import {MugiAirdrop} from "../../../src/game/MugiAirdrop.sol";
import {MugiIMDPriceOracle as MugiPriceOracle} from "../../../src/imd/modules/MugiIMDPriceOracle.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract MugiUnlockedProbe {
    IPoolManager private immutable manager;
    MugiGameHook private immutable game;
    bool public requestSucceeded;
    bool public claimSucceeded;
    bool public tokenClaimSucceeded;

    constructor(IPoolManager manager_, MugiGameHook game_) {
        manager = manager_;
        game = game_;
    }

    function probe() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (requestSucceeded,) = address(game).call(abi.encodeCall(game.requestElimination, ()));
        (claimSucceeded,) = address(game).call(abi.encodeCall(game.claimEth, (payable(address(this)))));
        (tokenClaimSucceeded,) = address(game).call(abi.encodeCall(game.claimTokens, ()));
        return "";
    }

    receive() external payable {}
}

contract MugiReentrantRecipient {
    MugiGameHook private immutable game;
    bool public reentrySucceeded;
    uint256 public receipts;

    constructor(MugiGameHook game_) {
        game = game_;
    }

    function claim() external returns (uint256) {
        return game.claimEth(payable(address(this)));
    }

    receive() external payable {
        ++receipts;
        (reentrySucceeded,) = address(game).call(abi.encodeCall(game.claimEth, (payable(address(this)))));
    }
}

contract MugiClaimCustodian {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deposit(address token, uint256 amount) external {
        manager.unlock(abi.encode(token, msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address token, address account, uint256 amount) = abi.decode(data, (address, address, uint256));
        manager.sync(Currency.wrap(token));
        MugiCrewToken(token).transferFrom(account, address(manager), amount);
        manager.settle();
        manager.mint(account, uint256(uint160(token)), amount);
        return "";
    }
}

contract MugiAdversarialTest is MugiGameTestBase {
    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
    }

    function testThirdPartyPoolManagerUnlockCannotRecordCutoffOrWithdrawClaims() public {
        MugiUnlockedProbe probe = new MugiUnlockedProbe(manager, game);
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(address(probe), 100 ether);
        _round(0);
        (uint256[10] memory claimable,,) = game.previewAccount(address(probe));
        assertGt(claimable[1], 0);
        probe.probe();
        assertFalse(probe.claimSucceeded());
        assertFalse(probe.tokenClaimSucceeded());
        vm.warp(game.nextCutoff());
        probe.probe();
        assertFalse(probe.requestSucceeded());
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        game.requestElimination();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.AwaitingRandomness));
        _assertSolvent();
    }

    function testUnregisteredCallerCannotForgeTokenBalanceAccounting() public {
        uint256 beforeSupply = game.eligibleSupply(1);
        (bool beforeOK,) = address(game).call(abi.encodeWithSignature(
            "beforeTokenTransfer(uint8,address,address,uint256)", 1, address(0), BOB, 1_000_000 ether));
        (bool afterOK,) = address(game).call(abi.encodeWithSignature(
            "afterTokenTransfer(uint8,address,address,uint256)", 1, address(0), BOB, 1_000_000 ether));
        assertFalse(beforeOK, "removed callback cannot forge accounting");
        assertFalse(afterOK, "removed callback cannot forge accounting");
        assertEq(game.eligibleSupply(1), beforeSupply);
    }

    function testEthRecipientCannotReenterAndWithdrawItsRewardTwice() public {
        MugiReentrantRecipient recipient = new MugiReentrantRecipient(game);
        vm.prank(BOB);
        MugiCrewToken(crew[1]).transfer(address(recipient), 100 ether);
        _fundTreasure(0);
        _round(0);
        (, uint256 owed,) = game.previewAccount(address(recipient));
        assertGt(owed, 0);
        assertEq(recipient.claim(), owed);
        assertEq(address(recipient).balance, owed);
        assertFalse(recipient.reentrySucceeded());
        assertEq(recipient.receipts(), 1);
        assertEq(recipient.claim(), 0);
        _assertSolvent();
    }

    function testPoolManagerClaimCustodyIsExplicitlyExcludedFromHolderRights() public {
        MugiClaimCustodian custodian = new MugiClaimCustodian(manager);
        uint256 amount = MugiCrewToken(crew[1]).balanceOf(BOB);
        vm.startPrank(BOB);
        MugiCrewToken(crew[1]).approve(address(custodian), amount);
        custodian.deposit(crew[1], amount);
        vm.stopPrank();
        assertEq(MugiCrewToken(crew[1]).balanceOf(BOB), 0);
        assertEq(manager.balanceOf(BOB, uint256(uint160(crew[1]))), amount);
        assertEq(game.eligibleSupply(1), 0);
        _fundTreasure(0);
        _round(0);
        (, uint256 earned,) = game.previewAccount(BOB);
        assertEq(earned, 0);
        _assertSolvent();
    }

    function testFinalizationMigrationPreservesEarlierRewardsWithoutPauseCapability() public {
        _fundTreasure(0);
        for (uint8 i; i < 9; ++i) _round(0);
        (, uint256 earlierReward,) = game.previewAccount(BOB);
        assertGt(earlierReward, 0);
        vm.warp(game.nextCutoff());
        game.finalize();
        (, uint256 owed,) = game.previewAccount(BOB);
        assertEq(owed, earlierReward);
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), earlierReward);
        (, uint256 aliceReward,) = game.previewAccount(ALICE);
        assertEq(aliceReward, 0, "final LP principal does not create a holder reward");
        uint256 pendingMigration = address(game).balance - game.teamEth() - game.reservedPlayerEth();
        game.migrateToV2(_migrationTarget());
        assertEq(migratedEth, pendingMigration);
        _assertSolvent();
    }

    function testPartialMaterializationAndFrequentEthClaimsMatchDeferredRewardsExactly() public {
        uint256 earlyPaid;
        for (uint8 i; i < 9; ++i) {
            _fundTreasure(i);
            _round(0);
            vm.prank(EARLY);
            earlyPaid += game.claimEth(payable(EARLY));
            (uint256[10] memory amounts,,) = game.previewAccount(EARLY);
            vm.prank(EARLY);
            game.claimToken(i + 1, amounts[i + 1] / 2);
            (, uint256 lateOwed,) = game.previewAccount(LATE);
            assertEq(earlyPaid, lateOwed, "claim timing must not change per-round ETH rounding");
        }
        vm.warp(game.nextCutoff());
        game.finalize();
        vm.prank(EARLY);
        earlyPaid += game.claimEth(payable(EARLY));
        (, uint256 lateFinal,) = game.previewAccount(LATE);
        assertEq(earlyPaid, lateFinal);
        _assertSolvent();
    }

    function testSpotManipulationCannotForceTreasuryBuyAtManipulatedPrice() public {
        _fundTreasure(0);
        skip(16 minutes);
        _swap(address(0xBAD), 0, true, -int256(10 ether));
        uint256 beforeBudget = game.ownBurnBudget(0);
        // The intervening swap adds fees. Use a currently valid trade amount so
        // this regression exercises the price guard rather than the budget floor.
        uint256 amount = beforeBudget / 20;
        uint256 beforeSupply = MugiCrewToken(crew[0]).totalSupply();
        vm.expectRevert(MugiPriceOracle.SpotDeviation.selector);
        game.executeOwnBuyback(0, amount);
        assertEq(game.ownBurnBudget(0), beforeBudget);
        assertEq(MugiCrewToken(crew[0]).totalSupply(), beforeSupply);
        _assertSolvent();
    }

    function testSubLiquidityUnitRemainderDoesNotPermanentlyFreezeSettlement() public {
        address microAddress = address(uint160(0x5678000000) | uint160(0x2aec));
        (MugiGameHook micro,,) = _deployGameAt(microAddress, 1000, manager);
        GameRandomnessMock microRandomness = randomness;
        for (uint8 i; i < 10; ++i) micro.seedPool{value: i == 0 ? 20 : 1000}(i);
        vm.warp(block.timestamp + 7 days);
        micro.launch();
        vm.warp(micro.nextCutoff());
        micro.requestElimination();
        microRandomness.fulfill(micro.pendingRequest(), 0);
        vm.expectEmit(true, false, false, true, address(micro));
        emit MugiGameHook.LiquidityDeferred(1, 1);
        micro.settleRound(10);
        assertEq(uint8(micro.phase()), uint8(MugiGameHook.Phase.Live));
        assertEq(micro.eliminations(), 1);
        assertGe(address(micro).balance, micro.reservedPlayerEth() + micro.teamEth());
    }
}
