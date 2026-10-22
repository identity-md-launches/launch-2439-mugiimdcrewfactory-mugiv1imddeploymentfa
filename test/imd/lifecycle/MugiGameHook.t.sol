// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// IMD modular regression adapted from v1/test/game/MugiGameHook.t.sol.
// Exercises CALL-module custody with the same season/accounting assertions.

import {MugiIMDLedger} from "../../../src/imd/modules/MugiIMDLedger.sol";
import {MugiIMDV4Engine} from "../../../src/imd/modules/MugiIMDV4Engine.sol";
import {MugiIMDAccountingFactory} from "../../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../../src/imd/MugiIMDEngineFactory.sol";
import {Test} from "forge-std/Test.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDCrewFactory as MugiCrewFactory} from "../../../src/imd/MugiIMDCrewFactory.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {MugiAirdrop} from "../../../src/game/MugiAirdrop.sol";
import {MugiIMDBuybacks as MugiBuybacks} from "../../../src/imd/modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle as MugiPriceOracle} from "../../../src/imd/modules/MugiIMDPriceOracle.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract GameRandomnessMock {
    uint256 public requests;
    mapping(uint256 => address) public receivers;
    mapping(uint256 => uint64) public fulfilledAt;
    function requestRandomness() external returns (uint256 request) {
        request = ++requests;
        receivers[request] = msg.sender;
    }
    function fulfill(uint256 request, uint256 word) external {
        if (fulfilledAt[request] == 0) fulfilledAt[request] = uint64(block.timestamp);
        MugiGameHook(payable(receivers[request])).receiveRandomness(request, word);
    }
}

/// @dev Test-only V2 receiver with its own address. It forwards the survivor tokens
/// and finale ETH to the test contract's recorder so existing assertions on
/// `address(this)` balances and the migrated* counters remain valid.
contract ForwardingV2Receiver {
    address payable private immutable sink;
    constructor(address sink_) { sink = payable(sink_); }
    function receiveV1Finale(uint8 survivor, address survivorToken, uint256 survivorTokens) external payable {
        require(MugiCrewToken(survivorToken).transfer(sink, survivorTokens), "forward failed");
        MugiGameTestBase(sink).receiveV1Finale{value: msg.value}(survivor, survivorToken, survivorTokens);
    }
}

abstract contract MugiGameTestBase is Test {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant POOL_ETH = 100 ether;
    uint256 internal constant ATTESTOR_KEY = 0xA11CE123;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant EARLY = address(0xEA21);
    address internal constant LATE = address(0x1A7E);
    address internal constant TEAM = address(0x7EA0);
    address internal constant COMMUNITY = address(0xC000);
    MugiGameHook internal game;
    MugiAirdrop internal airdrop;
    MugiCrewFactory internal factory;
    GameRandomnessMock internal randomness;
    IPoolManager internal manager;
    PoolSwapTest internal router;
    address[10] internal crew;
    uint8 internal migratedSurvivor;
    address internal migratedToken;
    uint256 internal migratedEth;
    uint256 internal migratedTokens;
    ForwardingV2Receiver internal v2Receiver;

    receive() external payable {}

    /// @dev Test V2 receiver. Production V2 implements this narrow callback.
    function receiveV1Finale(uint8 survivor, address survivorToken, uint256 survivorTokens) external payable {
        migratedSurvivor = survivor;
        migratedToken = survivorToken;
        migratedEth += msg.value;
        migratedTokens += survivorTokens;
    }

    function _setup(IPoolManager manager_) internal {
        manager = manager_;
        vm.deal(address(this), 100_000 ether);
        game = _deployGame(manager);
        for (uint8 i; i < 10; ++i) crew[i] = game.tokens(i);
        airdrop = game.airdrop();
        // `block.timestamp` can be common-subexpression optimized within this
        // setup transaction. Move past the permissionless seven-day launch
        // condition before constructing signed registration/claim deadlines.
        vm.warp(block.timestamp + 7 days);
        _register(ALICE, 0);
        _register(BOB, 1);
        _register(CAROL, 2);
        _register(EARLY, 0);
        _register(LATE, 0);
        for (uint8 i; i < 10; ++i) game.seedPool{value: POOL_ETH}(i);
        game.launch();
        _claimAirdrop(ALICE);
        _claimAirdrop(BOB);
        _claimAirdrop(CAROL);
        _claimAirdrop(EARLY);
        _claimAirdrop(LATE);
        router = new PoolSwapTest(manager);
    }

    function _deployGame(IPoolManager manager_) internal virtual returns (MugiGameHook deployed) {
        (deployed,,) = _deployGameAt(address(uint160(0x1234000000) | uint160(0x2aec)), SUPPLY, manager_);
    }

    function _deployGameAt(address hookAddress, uint256 supply, IPoolManager manager_)
        internal returns (MugiGameHook deployed, address[10] memory assets, MugiAirdrop drop)
    {
        MugiCrewFactory crews = new MugiCrewFactory(address(this));
        assets = crews.deployCrewSet(hookAddress, supply);
        drop = new MugiAirdrop(hookAddress, vm.addr(ATTESTOR_KEY), supply, assets);
        MugiIMDV4Engine engine = new MugiIMDV4Engine(hookAddress, manager_);
        MugiIMDLedger.Configuration memory lc = abi.decode(
            abi.encode(hookAddress, assets, address(drop), address(engine), TEAM, COMMUNITY, address(manager_)),
            (MugiIMDLedger.Configuration)
        );
        MugiIMDLedger ledger = new MugiIMDLedger(lc);
        MugiBuybacks budgets = new MugiBuybacks(hookAddress);
        MugiPriceOracle prices = new MugiPriceOracle(hookAddress);
        MugiGameHook.Configuration memory c = MugiGameHook.Configuration({
            owner: address(this), manager: address(manager_), team: TEAM, community: COMMUNITY,
            v2MigrationTarget: _migrationTarget(), initialSupply: supply, ledger: address(ledger),
            engine: address(engine), budgets: address(budgets), prices: address(prices),
            randomnessProvider: _makeRandomness(hookAddress), imdVerifier: _makeVerifier(hookAddress),
            airdrop: address(drop), crewFactory: address(crews)
        });
        deployCodeTo("MugiIMDGameHook.sol:MugiIMDGameHook", abi.encode(c), hookAddress);
        deployed = MugiGameHook(payable(hookAddress));
    }

    /// @dev The hook constructor rejects a V2 receiver aliased to the owner (this
    /// test contract), team or community. The default receiver is therefore a
    /// distinct contract that forwards the handoff to this contract's recorder.
    function _migrationTarget() internal virtual returns (address) {
        if (address(v2Receiver) == address(0)) v2Receiver = new ForwardingV2Receiver(address(this));
        return address(v2Receiver);
    }

    function _makeRandomness(address) internal virtual returns (address) {
        randomness = new GameRandomnessMock();
        return address(randomness);
    }

    function _makeVerifier(address) internal virtual returns (address) {
        return address(0);
    }

    function _register(address account, uint8 id) private {
        bytes32 social = keccak256(abi.encode(account));
        uint64 deadline = uint64(block.timestamp + 2 days);
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", airdrop.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(airdrop.REGISTRATION_TYPEHASH(), account, id, social, deadline))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_KEY, digest);
        vm.prank(account);
        airdrop.register(id, social, deadline, abi.encodePacked(r, s, v));
    }

    function _claimAirdrop(address account) private {
        uint8 id = airdrop.crewPlusOne(account) - 1;
        uint64 deadline = uint64(block.timestamp + 2 days);
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", airdrop.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(airdrop.CLAIM_TYPEHASH(), account, id, airdrop.socialIdByAccount(account), deadline))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_KEY, digest);
        vm.prank(account);
        airdrop.claim(deadline, abi.encodePacked(r, s, v));
    }

    function _swap(address account, uint8 id, bool buy, int256 specified) internal returns (BalanceDelta delta) {
        vm.deal(account, 1_000 ether);
        vm.startPrank(account);
        MugiCrewToken(crew[id]).approve(address(router), type(uint256).max);
        delta = router.swap{value: buy ? 10 ether : 0}(
            game.poolKey(id),
            IPoolManager.SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), bytes("")
        );
        vm.stopPrank();
    }

    function _requestAndFulfill(uint256 word) internal {
        vm.warp(game.nextCutoff());
        vm.prank(address(0xFEED));
        game.requestElimination();
        randomness.fulfill(game.pendingRequest(), word);
    }

    function _round(uint256 word) internal {
        _requestAndFulfill(word);
        game.settleRound(10);
        _assertSolvent();
    }

    function _assertSolvent() internal view {
        assertGe(address(game).balance + game.unredeemedGameFees(), game.reservedPlayerEth() + game.teamEth());
        for (uint8 i; i < 10; ++i) {
            assertGe(MugiCrewToken(crew[i]).balanceOf(address(game)),
                game.escrowBacking(i) + game.unreleasedReserve(i) + game.teamTokens(i));
        }
    }

    function _fundTreasure(uint8 id) internal {
        _swap(address(this), id, true, -int256(1 ether));
    }
}

contract MugiGameHookTest is MugiGameTestBase {
    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
    }

    function testInitialAllocationAndAirdropClaimsAreTracked() public view {
        assertEq(game.seededMask(), 1023);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        for (uint8 i; i < 10; ++i) {
            assertEq(MugiCrewToken(crew[i]).totalSupply(), MugiCrewToken(crew[i]).reserveCap());
            assertGt(game.positionLiquidity(i), 0);
        }
        assertEq(MugiCrewToken(crew[0]).balanceOf(ALICE), SUPPLY / 1000);
        assertEq(MugiCrewToken(crew[0]).balanceOf(EARLY), SUPPLY / 1000);
        assertEq(MugiCrewToken(crew[0]).balanceOf(LATE), SUPPLY / 1000);
        assertEq(game.eligibleSupply(0), 3 * (SUPPLY / 1000) * 95_126_814_720);
        assertEq(game.eligibleSupply(1), (SUPPLY / 1000) * 95_126_814_720);
    }

    function testAllFourSwapModesFundSeparateEthBudgets() public {
        BalanceDelta buyIn = _swap(ALICE, 0, true, -int256(1 ether));
        assertEq(buyIn.amount0(), -int128(1 ether));
        assertEq(game.ownBurnBudget(0), 0.01 ether);
        assertEq(game.treasure(0), 0.01 ether);
        BalanceDelta sellIn = _swap(ALICE, 0, false, -int256(100 ether));
        assertEq(sellIn.amount1(), -int128(100 ether));
        uint256 feesAfterSell = game.unredeemedGameFees();
        assertGt(feesAfterSell, 0.02 ether);
        BalanceDelta buyOut = _swap(ALICE, 0, true, int256(100 ether));
        assertEq(buyOut.amount1(), int128(100 ether));
        BalanceDelta sellOut = _swap(ALICE, 0, false, int256(0.01 ether));
        assertEq(sellOut.amount0(), int128(0.01 ether));
        assertGt(game.unredeemedGameFees(), feesAfterSell);
        assertEq(game.unredeemedGameFees(), game.ownBurnBudget(0) + game.treasure(0));
        _assertSolvent();
    }

    function testWalletTransferHasNoTaxAndPreservesSupplyAccounting() public {
        uint256 supply = game.eligibleSupply(0);
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(BOB, 100 ether);
        assertEq(MugiCrewToken(crew[0]).balanceOf(BOB), 100 ether);
        assertEq(game.eligibleSupply(0), supply);
        assertEq(game.treasure(0), 0);
    }

    function testFixedCutoffAllowsTransfersButClosesOfficialRoundAndMaterialization() public {
        vm.warp(game.nextCutoff());
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(BOB, 1);
        PoolKey memory key = game.poolKey(0);
        vm.expectRevert();
        router.swap{value: 0.01 ether}(key,
            IPoolManager.SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), bytes(""));
        vm.prank(ALICE);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimTokens();
        vm.prank(address(0x123));
        game.requestElimination();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.AwaitingRandomness));
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.requestElimination();
    }

    function testRandomnessOnlyRecordsOutcomeAndRejectsDuplicates() public {
        vm.warp(game.nextCutoff());
        game.requestElimination();
        uint256 request = game.pendingRequest();
        uint128 initialLiquidity = game.positionLiquidity(0);
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.receiveRandomness(request, 0);
        vm.prank(address(randomness));
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.receiveRandomness(request + 1, 0);
        uint256 beforeGas = gasleft();
        randomness.fulfill(request, 0);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Randomness callback gas", used);
        assertLt(used, 120_000);
        assertEq(game.positionLiquidity(0), initialLiquidity);
        assertEq(game.eliminations(), 0);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.OutcomeReady));
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        randomness.fulfill(request, 1);
        assertEq(game.defeatedCrew(), 0);
    }

    function testStagedSettlementRewardsPreexistingSurvivors() public {
        _fundTreasure(0);
        uint256 pot = game.treasure(0);
        uint256 bobBefore = BOB.balance;
        uint128[10] memory priorLiquidity;
        for (uint8 i; i < 10; ++i) priorLiquidity[i] = game.positionLiquidity(i);
        _requestAndFulfill(0);
        game.settleRound(1);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Settling));
        assertEq(game.eliminations(), 1);
        assertEq(game.positionLiquidity(0), 0);
        (uint256[10] memory aliceTokens, uint256 aliceEth,) = game.previewAccount(ALICE);
        (, uint256 bobEth,) = game.previewAccount(BOB);
        assertEq(aliceEth, 0);
        assertEq(bobEth, pot / 9);
        assertEq(aliceTokens[1], uint256(1_000 ether) * 75 / 100 / 9);
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), bobEth);
        assertEq(BOB.balance, bobBefore + bobEth);
        _assertSolvent();
        game.settleRound(10);
        for (uint8 i = 1; i < 10; ++i) assertGt(game.positionLiquidity(i), priorLiquidity[i]);
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), 0);
        assertEq(BOB.balance, bobBefore + bobEth);
        vm.prank(ALICE);
        game.claimTokens();
        assertEq(MugiCrewToken(crew[1]).balanceOf(ALICE), aliceTokens[1]);
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).transfer(BOB, 1);
        _assertSolvent();
    }

    function testPreviouslyEarnedEthDoesNotFollowTransferredSurvivorTokens() public {
        _fundTreasure(0);
        _round(0);
        (, uint256 owed,) = game.previewAccount(BOB);
        vm.prank(BOB);
        MugiCrewToken(crew[1]).transfer(CAROL, 1_000 ether);
        (, uint256 afterTransfer,) = game.previewAccount(BOB);
        assertEq(afterTransfer, owed);
        uint256 before = BOB.balance;
        vm.prank(BOB);
        game.claimEth(payable(BOB));
        assertEq(BOB.balance, before + owed);
    }

    function testEarnedEthRemainsClaimableDuringNextRandomnessWait() public {
        _fundTreasure(0);
        _round(0);
        (, uint256 owed,) = game.previewAccount(BOB);
        assertGt(owed, 0);
        vm.warp(game.nextCutoff());
        game.requestElimination();
        uint256 beforeBalance = BOB.balance;
        vm.prank(BOB);
        assertEq(game.claimEth(payable(BOB)), owed);
        assertEq(BOB.balance, beforeBalance + owed);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.AwaitingRandomness));
        vm.prank(BOB);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimTokens();
        randomness.fulfill(game.pendingRequest(), 0);
        game.settleRound(10);
        _assertSolvent();
    }

    function testFullNineRoundsAndFinaleEarlyAndLateClaimsAgree() public {
        for (uint8 round; round < 9; ++round) {
            _fundTreasure(round);
            uint256 beforeGas = gasleft();
            _round(0); // Each outcome selects the first remaining crew.
            emit log_named_uint("Settlement and request gas", beforeGas - gasleft());
            vm.startPrank(EARLY);
            game.claimTokens();
            game.claimEth(payable(EARLY));
            vm.stopPrank();
            assertEq(game.eliminations(), round + 1);
            for (uint8 dead; dead <= round; ++dead) assertEq(game.positionLiquidity(dead), 0);
            _assertSolvent();
        }
        assertEq(game.aliveMask(), uint16(1 << 9));
        vm.warp(game.nextCutoff());
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.requestElimination();
        uint256 earlyBefore = EARLY.balance;
        uint256 lateBefore = LATE.balance;
        (, uint256 latePrior,) = game.previewAccount(LATE);
        uint256 reservedPrior = game.reservedPlayerEth();
        game.finalize();
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Finalized));
        assertEq(game.positionLiquidity(9), 0);
        assertGe(game.reservedPlayerEth(), reservedPrior);
        (, uint256 earlyFinal,) = game.previewAccount(EARLY);
        (, uint256 lateTotal,) = game.previewAccount(LATE);
        assertEq(earlyFinal, 0, "final V1 holder reward is migrated to V2");
        assertEq(lateTotal, latePrior, "final V1 holder reward is migrated to V2");
        assertEq(migratedEth, 0, "final assets wait for the manual V2 binding step");
        game.migrateToV2(_migrationTarget());
        assertEq(migratedSurvivor, 9);
        assertEq(migratedToken, crew[9]);
        assertGt(migratedEth, 0);
        assertGt(migratedTokens, 0);
        vm.prank(EARLY);
        game.claimEth(payable(EARLY));
        vm.prank(LATE);
        game.claimEth(payable(LATE));
        assertEq(EARLY.balance, earlyBefore + earlyFinal);
        assertEq(LATE.balance, lateBefore + lateTotal);
        (uint256[10] memory lateTokens,,) = game.previewAccount(LATE);
        vm.prank(LATE);
        game.claimTokens();
        assertEq(MugiCrewToken(crew[9]).balanceOf(LATE), lateTokens[9]);
        vm.prank(EARLY);
        assertEq(game.claimEth(payable(EARLY)), 0);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.finalize();
        _assertSolvent();
    }

    function testOwnBuybackUsesTwapAndBurnsActualPurchasedTokens() public {
        _fundTreasure(0);
        uint256 budgetBefore = game.ownBurnBudget(0);
        uint256 amount = budgetBefore / 20;
        vm.expectRevert(MugiPriceOracle.InsufficientHistory.selector);
        game.executeOwnBuyback(0, amount);
        vm.warp(block.timestamp + 16 minutes);
        uint256 beforeSupply = MugiCrewToken(crew[0]).totalSupply();
        uint256 beforeReserve = game.treasure(0);
        game.executeOwnBuyback(0, amount);
        assertLt(MugiCrewToken(crew[0]).totalSupply(), beforeSupply);
        assertEq(game.ownBurnBudget(0), budgetBefore - amount);
        assertEq(game.treasure(0), beforeReserve);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.executeOwnBuyback(0, amount);
        _assertSolvent();
    }

    function testRoundBuybackFallbackSpendsOnlyAuthorizedBudgetAndBurns() public {
        _round(0);
        MugiBuybacks.Budget memory beforeBudget = game.roundBudget(1);
        uint256 amount = (beforeBudget.allocation[1] + 99) / 100;
        uint256 beforeSupply = MugiCrewToken(crew[1]).totalSupply();
        game.executeBuyback(1, 1, amount);
        MugiBuybacks.Budget memory afterBudget = game.roundBudget(1);
        assertEq(afterBudget.spent, amount);
        assertEq(afterBudget.crewSpent[1], amount);
        assertLt(MugiCrewToken(crew[1]).totalSupply(), beforeSupply);
        vm.expectRevert(MugiBuybacks.InvalidExecution.selector);
        game.executeBuyback(1, 1, amount);
        vm.warp(afterBudget.deadline);
        vm.expectRevert(MugiBuybacks.InvalidExecution.selector);
        game.executeBuyback(1, 2, amount);
        _assertSolvent();
    }

    function testDustBuybacksCannotConsumeRoundOrOwnCadence() public {
        _fundTreasure(0);
        vm.warp(block.timestamp + 16 minutes);
        uint256 ownBudget = game.ownBurnBudget(0);
        uint256 ownMinimum = (ownBudget + 99) / 100;
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.executeOwnBuyback(0, ownMinimum - 1);
        assertEq(game.ownLastTrade(0), 0);
        assertEq(game.ownBurnBudget(0), ownBudget);
        game.executeOwnBuyback(0, ownMinimum);
        assertEq(game.ownLastTrade(0), block.timestamp);

        _round(0);
        MugiBuybacks.Budget memory before = game.roundBudget(1);
        uint256 roundMinimum = (before.allocation[1] + 99) / 100;
        vm.expectRevert(MugiBuybacks.InvalidExecution.selector);
        game.executeBuyback(1, 1, roundMinimum - 1);
        MugiBuybacks.Budget memory afterDust = game.roundBudget(1);
        assertEq(afterDust.lastTrade[1], 0);
        assertEq(afterDust.spent, 0);
        game.executeBuyback(1, 1, roundMinimum);
        assertEq(game.roundBudget(1).lastTrade[1], block.timestamp);
        _assertSolvent();
    }

    function testTeamFeeCollectionCannotWithdrawPrincipalOrPlayerRewards() public {
        _fundTreasure(0);
        _swap(ALICE, 0, false, -int256(100 ether));
        uint128 beforeLiquidity = game.positionLiquidity(0);
        uint256 pot = game.treasure(0);
        game.collectTeamFees(0);
        assertEq(game.positionLiquidity(0), beforeLiquidity);
        assertGt(game.teamEth(), 0);
        assertGt(game.teamTokens(0), 0);
        uint256 owed = game.teamEth();
        uint256 tokenFees = game.teamTokens(0);
        game.withdrawTeamFees();
        assertEq(TEAM.balance, owed);
        assertEq(MugiCrewToken(crew[0]).balanceOf(TEAM), tokenFees);
        assertEq(game.treasure(0), pot);
        _assertSolvent();
    }

    function testExternalPositionsAndAlternativeKeysUsingHookAreRejected() public {
        PoolModifyLiquidityTest outsider = new PoolModifyLiquidityTest(manager);
        vm.prank(ALICE);
        MugiCrewToken(crew[0]).approve(address(outsider), type(uint256).max);
        PoolKey memory official = game.poolKey(0);
        vm.expectRevert();
        outsider.modifyLiquidity{value: 1 ether}(
            official, IPoolManager.ModifyLiquidityParams(-887220, 887220, 1 ether, bytes32(0)), bytes("")
        );
        PoolKey memory alternate = game.poolKey(0);
        alternate.fee = 500;
        vm.expectRevert();
        manager.initialize(alternate, uint160(1 << 96));
        vm.expectRevert(MugiGameHook.Unauthorized.selector);
        game.unlockCallback(bytes("malicious action"));
    }

    function testAirdropRemainderRetiresAfterDeadline() public {
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.retireAirdrop();
        uint256 initial = MugiCrewToken(crew[0]).totalSupply();
        uint256 remainder = MugiCrewToken(crew[0]).balanceOf(address(airdrop));
        vm.warp(game.launchedAt() + 22 hours);
        game.retireAirdrop();
        assertEq(MugiCrewToken(crew[0]).balanceOf(address(airdrop)), 0);
        assertEq(MugiCrewToken(crew[0]).totalSupply(), initial - remainder);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.retireAirdrop();
    }

    function testOwnerCanAbortOnlyBeforeLaunchAndRecoverSeededEth() public {
        address hookAddress = address(uint160(0x1235000000) | uint160(0x2aec));
        (MugiGameHook prelaunch, address[10] memory prelaunchCrew,) = _deployGameAt(hookAddress, SUPPLY, manager);

        uint256 ownerBefore = address(this).balance;
        prelaunch.seedPool{value: 7 ether}(0);
        assertEq(MugiCrewToken(prelaunchCrew[0]).totalSupply(), MugiCrewToken(prelaunchCrew[0]).reserveCap());

        prelaunch.abortPrelaunch();

        assertEq(uint8(prelaunch.phase()), uint8(MugiGameHook.Phase.Aborted));
        assertGe(address(this).balance, ownerBefore - 1);
        assertEq(prelaunch.positionLiquidity(0), 0);
        assertGe(MugiCrewToken(prelaunchCrew[0]).balanceOf(address(prelaunch)), SUPPLY * 95 / 100 - 1);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        prelaunch.abortPrelaunch();
    }

    function testFinalClaimsExpireToCommunityAfterThirtyDays() public {
        _fundTreasure(0);
        for (uint8 round; round < 9; ++round) _round(0);
        vm.warp(game.nextCutoff());
        game.finalize();

        uint256 reserved = game.reservedPlayerEth();
        uint256 communityBefore = COMMUNITY.balance;
        assertGt(reserved, 0);
        assertGt(game.escrowBacking(9), 0);

        vm.warp(game.claimsExpireAt());
        game.sweepExpiredFinalClaims();

        assertEq(game.claimsExpireAt(), 0);
        assertEq(game.reservedPlayerEth(), 0);
        assertEq(COMMUNITY.balance, communityBefore + reserved);
        assertEq(game.escrowBacking(9), 0);
        vm.prank(BOB);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimEth(payable(BOB));
        vm.prank(ALICE);
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.claimTokens();
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.sweepExpiredFinalClaims();
    }

    function testModularHookFitsMainnetRuntimeLimit() public view {
        assertLe(address(game).code.length, 24_576);
    }
}
