// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {MugiIMDLedger} from "./modules/MugiIMDLedger.sol";
import {MugiIMDV4Engine as MugiV4Engine} from "./modules/MugiIMDV4Engine.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MugiIMDBuybacks as MugiBuybacks} from "./modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle as MugiPriceOracle} from "./modules/MugiIMDPriceOracle.sol";
import {MugiCrewToken} from "../../src/game/MugiCrewToken.sol";
import {MugiReserveMath} from "../../src/game/MugiReserveMath.sol";
import {MugiAirdrop} from "../../src/game/MugiAirdrop.sol";

interface IMugiRandomness {
    function requestRandomness() external returns (uint256);
    function fulfilledAt(uint256 requestId) external view returns (uint64);
}
interface IMugiV2FinaleReceiver {
    function receiveV1Finale(uint8 survivor, address survivorToken, uint256 survivorTokens) external payable;
}

/// @notice Shared, non-upgradeable season controller and Uniswap v4 hook.
/// @dev Immutable-bound CALL modules replace linked libraries. The engine owns LP positions;
/// withdrawals and swap proceeds return here, with all rewards and treasury liabilities retained here.
contract MugiIMDGameHook {
    using TransientStateLibrary for IPoolManager;

    // beforeInitialize, beforeAdd/RemoveLiquidity, before/afterSwap, beforeDonate,
    // before/afterSwap return deltas. Self-initiated PoolManager calls skip hooks.
    uint160 public constant HOOK_FLAGS = 0x2aec;
    uint256 public constant WINDOW = 22 hours;
    uint256 public constant FINAL_CLAIM_WINDOW = 30 days;
    uint256 public constant RANDOMNESS_TIMEOUT = 7 days;
    enum Phase { Setup, Live, AwaitingRandomness, OutcomeReady, Settling, Finalized, Aborted, EmergencyUnwinding, EmergencyClosed }
    address public owner;
    address public pendingOwner;
    address public immutable teamTreasury;
    address public immutable communityTreasury;
    IPoolManager public immutable poolManager;
    uint256 public immutable initialSupply;
    address public immutable v2MigrationTarget;
    address public randomnessProvider;
    address public imdVerifier;
    MugiAirdrop public airdrop;
    address[10] public tokens;
    Phase public phase;
    uint16 public aliveMask = 1023;
    uint16 public seededMask;
    uint8 public eliminations;
    uint8 public defeatedCrew;
    uint8 public settlementCursor;
    uint64 public launchedAt;
    uint64 public configuredAt;
    uint64 public nextCutoff;
    uint64 public claimsExpireAt;
    uint64 public migrationDeadline;
    uint256 public pendingRequest;
    uint256 public teamEth;
    uint256[10] public teamTokens;
    uint256[10] public treasure;
    uint256[10] public ownBurnBudget;
    uint64[10] public ownLastTrade;
    bool public airdropRetired;
    bool public migrated;
    uint256 public settlementLiquidityEth;
    uint256 public settlementBuybackEth;
    bool private entered;
    MugiIMDLedger public ledger;
    MugiV4Engine public engine;
    uint256 private hookFeeClaims;
    bytes32 private pendingFeeWithdrawal;
    MugiBuybacks public budgets;
    MugiPriceOracle public prices;

    error Unauthorized();
    error InvalidState();
    error InvalidConfiguration();
    error EthTransferFailed();
    event SeasonConfigured(address[10] tokens, address airdrop, address randomnessProvider, address imdVerifier);
    event PoolSeeded(uint8 indexed crew, uint256 ethUsed, uint256 tokenUsed);
    event LiquidityDeferred(uint8 indexed crew, uint256 ethAmount);
    event SeasonLaunched(uint64 timestamp, uint64 cutoff);
    event EliminationRequested(uint8 indexed round, uint256 indexed requestId, uint16 aliveMask);
    event OutcomeRecorded(uint8 indexed round, uint256 indexed requestId, uint8 indexed defeatedCrew);
    event RoundSettled(uint8 indexed round, uint8 indexed defeatedCrew, uint16 survivors, uint256 buybackBudget);
    event MigrationRecorded(uint8 indexed round, uint8 indexed defeatedCrew, uint256 treasureAllocated, uint256 retiredTokens, uint256[10] escrowMinted);
    event LiquidityReinforced(uint8 indexed round, uint8 indexed crew, uint256 ethPrincipal, uint256 tokenPrincipal, uint128 liquidity);
    event TeamFeesAccrued(uint8 indexed crew, uint256 ethAmount, uint256 tokenAmount);
    event TeamTokenFeesPaid(uint8 indexed crew, uint256 amount);
    event TokensClaimed(address indexed account, uint8 indexed crew, uint256 amount);
    event BuybackExecuted(uint64 indexed roundId, uint8 indexed crew, uint256 ethSpent, uint256 tokensBurned, bool ownBudget);
    event GameFee(uint8 indexed crew, uint256 ownBurn, uint256 treasureAmount);
    event EthClaimed(address indexed account, address indexed recipient, uint256 amount);
    event FinalClaimsExpired(uint64 indexed deadline, uint256 expiredEth);
    event ReserveReleased(uint8 indexed crew, uint256 amount);
    event ReserveRetired(uint8 indexed crew, uint256 amount);
    event V2Handoff(address indexed target, uint8 indexed survivor, uint256 ethAmount, uint256 tokens);
    event FinaleFallback(address indexed community, uint8 indexed survivor, uint256 ethAmount, uint256 tokens);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyRecoveryStarted(uint256 indexed requestId, uint64 deadline);
    event EmergencyRecoveryClosed(uint16 aliveMask, uint256 recoveryEth, uint64 claimsDeadline);

    /// @notice Dependencies and the initial owner are fixed at construction. The crew
    /// factory creates exactly ten tokens using CREATE nonces 1..10.
    struct Configuration {
        address owner;
        address manager;
        address team;
        address community;
        address v2MigrationTarget;
        uint256 initialSupply;
        address ledger;
        address engine;
        address budgets;
        address prices;
        address randomnessProvider;
        address imdVerifier;
        address airdrop;
        address crewFactory;
    }
    uint256[10] public unreleasedReserve;

    constructor(Configuration memory c) {
        if (c.owner == address(0) || c.team == address(0) || c.community == address(0)
            || c.v2MigrationTarget == address(0) || c.community == c.owner || c.community == c.team
            || c.v2MigrationTarget == c.owner || c.v2MigrationTarget == c.team
            || c.v2MigrationTarget == c.community || c.manager == address(0) || c.ledger == address(0) || c.engine == address(0)
            || c.budgets == address(0) || c.prices == address(0) || c.randomnessProvider == address(0)
            || c.airdrop == address(0) || c.crewFactory == address(0)
            || c.initialSupply < 1000 || c.initialSupply > 1e36
            || (uint160(address(this)) & 0x3fff) != HOOK_FLAGS) revert InvalidConfiguration();
        owner = c.owner; poolManager = IPoolManager(c.manager);
        teamTreasury = c.team; communityTreasury = c.community;
        initialSupply = c.initialSupply; v2MigrationTarget = c.v2MigrationTarget;
        ledger = MugiIMDLedger(c.ledger); engine = MugiV4Engine(payable(c.engine));
        budgets = MugiBuybacks(c.budgets); prices = MugiPriceOracle(c.prices);
        randomnessProvider = c.randomnessProvider; imdVerifier = c.imdVerifier;
        airdrop = MugiAirdrop(c.airdrop); configuredAt = uint64(block.timestamp);
        uint256 reserve = MugiReserveMath.reserveFor(c.initialSupply);
        for (uint8 i; i < 10; ++i) {
            tokens[i] = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", c.crewFactory, bytes1(i + 1))))));
            unreleasedReserve[i] = reserve;
        }
        emit OwnershipTransferred(address(0), c.owner);
        emit SeasonConfigured(tokens, c.airdrop, c.randomnessProvider, c.imdVerifier);
    }

    modifier onlyOwner() { if (msg.sender != owner) revert Unauthorized(); _; }
    modifier onlyManager() { if (msg.sender != address(poolManager)) revert Unauthorized(); _; }
    modifier guarded() { _enter(); _; entered = false; }
    function _enter() private {
        if (entered || poolManager.isUnlocked()) revert InvalidState();
        entered = true;
    }
    receive() external payable {}

    /// @notice A replacement wallet must accept before any owner privilege moves.
    /// The immutable community treasury and V2 receiver can never become owner.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0) || newOwner == owner || newOwner == communityTreasury
            || newOwner == v2MigrationTarget) revert InvalidConfiguration();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        pendingOwner = address(0);
        emit OwnershipTransferStarted(owner, address(0));
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @dev Validate immutable reciprocal bindings on first economic use, never
    /// from a constructor. No caller can replace an address after deployment.
    function _validateConfiguration() private view {
        if (ledger.configurationHash() != keccak256(abi.encode(
            address(this), tokens, address(airdrop), address(engine),
            teamTreasury, communityTreasury, address(poolManager)
        ))) revert InvalidConfiguration();
        if (ledger.hook() != address(this) || budgets.hook() != address(this)
            || prices.hook() != address(this) || engine.hook() != address(this)
            || address(engine.manager()) != address(poolManager)
            || randomnessProvider.code.length == 0 || (imdVerifier != address(0) && imdVerifier.code.length == 0)
            || airdrop.hook() != address(this) || airdrop.initialSupply() != initialSupply)
            revert InvalidConfiguration();
        for (uint8 i; i < 10; ++i) {
            MugiCrewToken token = MugiCrewToken(tokens[i]);
            if (token.hook() != address(this) || token.characterId() != i
                || token.initialSupply() != initialSupply || airdrop.tokens(i) != tokens[i])
                revert InvalidConfiguration();
        }
    }

    function _releaseReserve(uint8 crew, uint256 amount) private {
        uint256 available = unreleasedReserve[crew];
        if (amount > available) revert InvalidState();
        unreleasedReserve[crew] = available - amount;
        emit ReserveReleased(crew, amount);
    }

    function _retireReserve(uint8 crew) private {
        uint256 amount = unreleasedReserve[crew];
        unreleasedReserve[crew] = 0;
        if (amount != 0) MugiCrewToken(tokens[crew]).burn(amount);
        emit ReserveRetired(crew, amount);
    }

    /// @notice Initial supply is split 95/5. Unusable LP token rounding dust remains excluded inventory.
    function seedPool(uint8 crew) external payable onlyOwner guarded {
        if (phase != Phase.Setup || tokens[0] == address(0) || crew >= 10 || msg.value == 0
            || msg.value > 1e30 || (seededMask & (uint16(1) << crew)) != 0) revert InvalidState();
        _validateConfiguration();
        uint256 drop = initialSupply / 20;
        uint256 lpTokens = initialSupply - drop;
        uint128 liquidity = engine.registerInitialPool(crew, tokens[crew], lpTokens, msg.value);
        _releaseReserve(crew, initialSupply);
        MugiCrewToken(tokens[crew]).transfer(address(airdrop), drop);
        MugiCrewToken(tokens[crew]).transfer(address(engine), lpTokens);
        MugiV4Engine.LiquidityResult memory result = engine.addLiquidity{value: msg.value}(crew, liquidity, msg.value, lpTokens);
        _fees(crew, result.ethFees, result.tokenFees);
        seededMask |= uint16(1) << crew;
        _observe(crew);
        emit PoolSeeded(crew, result.ethPrincipal, result.tokenPrincipal);
    }

    /// @notice Permissionless activation once verified participation reaches the
    /// threshold, or seven days after configuration. No agent owner key is needed.
    function launch() external guarded {
        if (phase != Phase.Setup || seededMask != 1023 || !airdrop.launchEligible(configuredAt)) revert InvalidState();
        phase = Phase.Live; launchedAt = uint64(block.timestamp); nextCutoff = uint64(block.timestamp + 1 days);
        airdrop.launch(); emit SeasonLaunched(launchedAt, nextCutoff);
    }

    /// @notice Cancels an unlaunched season and returns only its seeded LP ETH to
    /// the current owner. An ownership handover transfers this prelaunch refund
    /// right too. It is impossible after `launch()`, so it
    /// cannot seize live player liquidity, treasury rewards or player claims.
    function abortPrelaunch() external onlyOwner guarded {
        if (phase != Phase.Setup) revert InvalidState();
        for (uint8 i; i < 10; ++i) {
            if ((seededMask & (uint16(1) << i)) == 0) continue;
            engine.removeLiquidity(i, 0, 0);
        }
        phase = Phase.Aborted;
        uint256 refund = address(this).balance;
        _pay(payable(owner), refund);
    }

    /// @notice Fixed at the round cutoff, including when no request can be accepted.
    function randomnessDeadline() public view returns (uint64) { return uint64(nextCutoff + RANDOMNESS_TIMEOUT); }

    /// @notice Fixed clock cutoff applies even when nobody submits this transaction promptly.
    function requestElimination() external guarded {
        if (phase != Phase.Live || eliminations >= 9 || block.timestamp < nextCutoff
            || block.timestamp >= randomnessDeadline()) revert InvalidState();
        phase = Phase.AwaitingRandomness;
        pendingRequest = IMugiRandomness(randomnessProvider).requestRandomness();
        emit EliminationRequested(eliminations + 1, pendingRequest, aliveMask);
    }

    /// @notice VRF callback stores one result only; it cannot touch LPs or execute purchases.
    function receiveRandomness(uint256 requestId, uint256 word) external {
        if (msg.sender != randomnessProvider) revert Unauthorized();
        if (phase != Phase.AwaitingRandomness || requestId != pendingRequest) revert InvalidState();
        // A word first stored at/after the precommitted deadline cannot revive
        // the season. An on-time word with deferred delivery remains mandatory.
        uint64 deadline = randomnessDeadline();
        if (block.timestamp >= deadline) {
            uint64 received = IMugiRandomness(randomnessProvider).fulfilledAt(requestId);
            if (received == 0 || received >= deadline) return;
        }
        uint256 index = word % (10 - eliminations);
        for (uint8 i; i < 10; ++i) {
            if ((aliveMask & (uint16(1) << i)) == 0) continue;
            if (index == 0) { defeatedCrew = i; break; }
            --index;
        }
        phase = Phase.OutcomeReady;
        emit OutcomeRecorded(eliminations + 1, requestId, defeatedCrew);
    }

    /// @notice No reroll: an overdue unfulfilled request closes the season through
    /// bounded LP withdrawals. Existing ETH claims/team fees stay reserved. The
    /// remainder is shared equally between live crews and pro rata within each
    /// crew's frozen wallet-plus-virtual economic supply. No arbitrary winner or
    /// owner withdrawal is introduced. Unallocated shares expire to community.
    function recoverStalledRandomness(uint8 maxPools) external guarded {
        if (maxPools == 0 || maxPools > 10) revert InvalidState();
        if (phase == Phase.AwaitingRandomness || (phase == Phase.Live && eliminations < 9)) {
            uint64 deadline = randomnessDeadline();
            if (block.timestamp < deadline) revert InvalidState();
            if (phase == Phase.AwaitingRandomness) {
                uint64 received = IMugiRandomness(randomnessProvider).fulfilledAt(pendingRequest);
                if (received != 0 && received < deadline) revert InvalidState();
            } else pendingRequest = 0;
            phase = Phase.EmergencyUnwinding; settlementCursor = 0;
            emit EmergencyRecoveryStarted(pendingRequest, deadline);
        }
        if (phase != Phase.EmergencyUnwinding) revert InvalidState();
        _materializeFees();
        uint8 done;
        while (settlementCursor < 10 && done < maxPools) {
            uint8 crew = settlementCursor++;
            if ((aliveMask & (uint16(1) << crew)) == 0) continue;
            MugiV4Engine.LiquidityResult memory removed = engine.removeLiquidity(crew, 0, 0);
            _fees(crew, removed.ethFees, removed.tokenFees);
            ++done;
        }
        if (settlementCursor == 10) {
            uint256 recoveryEth = address(this).balance - teamEth - ledger.reservedEth();
            ledger.emergencyFinalize(aliveMask, recoveryEth, nextCutoff);
            for (uint8 i; i < 10; ++i) if ((aliveMask & (uint16(1) << i)) != 0) _retireReserve(i);
            phase = Phase.EmergencyClosed;
            claimsExpireAt = uint64(block.timestamp + FINAL_CLAIM_WINDOW);
            emit EmergencyRecoveryClosed(aliveMask, recoveryEth, claimsExpireAt);
        }
    }

    /// @notice Permissionless bounded settlement. Reverts preserve the recorded outcome and completed batches.
    function settleRound(uint8 maxPools) external guarded {
        if (maxPools == 0 || maxPools > 10 || (phase != Phase.OutcomeReady && phase != Phase.Settling)) revert InvalidState();
        if (phase == Phase.OutcomeReady) _beginSettlement();
        uint8 done;
        while (settlementCursor < 10 && done < maxPools) {
            uint8 crew = settlementCursor++;
            if ((aliveMask & (uint16(1) << crew)) == 0) continue;
            uint256 count = 10 - eliminations;
            uint256 share = settlementLiquidityEth / count;
            if (share != 0) _addMatchedLiquidity(crew, share);
            ++done;
        }
        if (settlementCursor == 10) {
            budgets.create(eliminations, settlementBuybackEth, aliveMask);
            nextCutoff = uint64(block.timestamp + 1 days); phase = Phase.Live;
            emit RoundSettled(eliminations, defeatedCrew, aliveMask, settlementBuybackEth);
        }
    }

    function _beginSettlement() private {
        _materializeFees();
        uint8 loser = defeatedCrew;
        MugiV4Engine.LiquidityResult memory removed = engine.removeLiquidity(loser, 0, 0);
        _fees(loser, removed.ethFees, removed.tokenFees);
        _payTeamTokenFees(loser);
        uint256 allocatedTreasure = treasure[loser];
        (uint256[10] memory minted,) = ledger.recordElimination(loser, aliveMask, allocatedTreasure, nextCutoff);
        treasure[loser] = 0;
        // All hook-held loser units are protocol inventory or old escrow. Retire once.
        uint256 retired = MugiCrewToken(tokens[loser]).balanceOf(address(this));
        unreleasedReserve[loser] = 0;
        MugiCrewToken(tokens[loser]).burn(retired);
        aliveMask &= ~(uint16(1) << loser);
        ++eliminations;
        for (uint8 i; i < 10; ++i) if (minted[i] != 0) _releaseReserve(i, minted[i]);
        emit MigrationRecorded(eliminations, loser, allocatedTreasure, retired, minted);
        settlementLiquidityEth = removed.ethPrincipal / 2;
        settlementBuybackEth = removed.ethPrincipal - settlementLiquidityEth + ownBurnBudget[loser];
        ownBurnBudget[loser] = 0; settlementCursor = 0; phase = Phase.Settling;
    }

    function _addMatchedLiquidity(uint8 crew, uint256 ethAmount) private {
        (uint128 liquidity,, uint256 needed) = engine.quoteLiquidityForEth(crew, ethAmount);
        // A sub-liquidity-unit or out-of-range contribution cannot be represented
        // by the fixed position. Preserve this ETH for finale instead of freezing
        // the entire season; all other engine failures still revert settlement.
        if (liquidity == 0) {
            emit LiquidityDeferred(crew, ethAmount);
            return;
        }
        MugiCrewToken token = MugiCrewToken(tokens[crew]);
        _releaseReserve(crew, needed);
        token.transfer(address(engine), needed);
        MugiV4Engine.LiquidityResult memory result = engine.addLiquidity{value: ethAmount}(crew, liquidity, ethAmount, needed);
        if (needed > result.tokenPrincipal) token.burn(needed - result.tokenPrincipal);
        _fees(crew, result.ethFees, result.tokenFees);
        _observe(crew);
        emit LiquidityReinforced(eliminations, crew, result.ethPrincipal, result.tokenPrincipal, liquidity);
    }

    function approvePlan(MugiBuybacks.BuybackPlan calldata plan, bytes calldata proof) external guarded {
        if (phase != Phase.Live || block.timestamp >= nextCutoff || plan.roundId != eliminations) revert InvalidState();
        budgets.approve(plan, imdVerifier, proof);
    }

    function executeBuyback(uint64 roundId, uint8 crew, uint256 ethAmount) external guarded {
        _requireLive(crew);
        if (roundId != eliminations || roundId == 0) revert InvalidState();
        budgets.authorize(roundId, crew, ethAmount);
        (uint256 spent, uint256 burned) = _buyAndBurn(crew, ethAmount);
        budgets.account(roundId, crew, spent);
        emit BuybackExecuted(roundId, crew, spent, burned, false);
    }

    function executeOwnBuyback(uint8 crew, uint256 ethAmount) external guarded {
        _requireLive(crew);
        uint256 minimum = ownBurnBudget[crew] / 100;
        if (ownBurnBudget[crew] % 100 != 0) ++minimum;
        // Keep the same 22-hour execution window in every round, including the opening round.
        if (block.timestamp >= nextCutoff - 2 hours || ethAmount == 0 || ethAmount < minimum
            || ethAmount > (ownBurnBudget[crew] + 19) / 20
            || ethAmount > ownBurnBudget[crew] || (ownLastTrade[crew] != 0 && block.timestamp < ownLastTrade[crew] + 5 minutes))
            revert InvalidState();
        ownLastTrade[crew] = uint64(block.timestamp);
        (uint256 spent, uint256 burned) = _buyAndBurn(crew, ethAmount);
        if (spent < minimum) revert InvalidState();
        ownBurnBudget[crew] -= spent;
        emit BuybackExecuted(eliminations, crew, spent, burned, true);
    }

    function _buyAndBurn(uint8 crew, uint256 ethAmount) private returns (uint256 spent, uint256 burned) {
        _materializeFees();
        (, int24 tick,) = engine.getPoolState(crew);
        prices.update(crew, tick);
        (uint256 minimum, uint160 limit) = prices.quoteMinimum(crew, ethAmount, tick);
        (spent, burned) = engine.buy{value: ethAmount}(crew, ethAmount, minimum, limit);
        MugiCrewToken(tokens[crew]).burn(burned);
        _observe(crew);
    }

    function retireAirdrop() external guarded {
        if (launchedAt == 0 || block.timestamp < launchedAt + WINDOW || airdropRetired) revert InvalidState();
        airdropRetired = true;
        airdrop.retireRemaining();
    }

    function claimTokens() external guarded returns (uint256[10] memory amounts) {
        _requireClaims(); amounts = ledger.claimTokens(msg.sender);
        for (uint8 i; i < 10; ++i) {
            if (amounts[i] != 0) {
                MugiCrewToken(tokens[i]).transfer(msg.sender, amounts[i]);
                emit TokensClaimed(msg.sender, i, amounts[i]);
            }
        }
    }

    function claimToken(uint8 crew, uint256 amount) external guarded {
        _requireClaims(); ledger.claimToken(msg.sender, crew, amount);
        MugiCrewToken(tokens[crew]).transfer(msg.sender, amount);
        emit TokensClaimed(msg.sender, crew, amount);
    }

    function claimEth(address payable recipient) external guarded returns (uint256 amount) {
        _requireEthClaim();
        if (recipient == address(0)) revert InvalidConfiguration();
        amount = ledger.claimEth(msg.sender); _materializeFees();
        _pay(recipient, amount); emit EthClaimed(msg.sender, recipient, amount);
    }

    function collectTeamFees(uint8 crew) external guarded {
        if (crew >= 10 || phase != Phase.Live || block.timestamp >= nextCutoff || (aliveMask & (uint16(1) << crew)) == 0)
            revert InvalidState();
        (uint256 ethFee, uint256 tokenFee) = engine.collectFees(crew);
        _fees(crew, ethFee, tokenFee);
    }

    function withdrawTeamFees() external guarded {
        _requireTeamWithdrawal(); uint256 ethAmount = teamEth; teamEth = 0;
        for (uint8 i; i < 10; ++i) _payTeamTokenFees(i);
        _pay(payable(teamTreasury), ethAmount);
    }

    function finalize() external guarded {
        if (phase != Phase.Live || eliminations != 9 || block.timestamp < nextCutoff) revert InvalidState();
        uint8 survivor;
        while ((aliveMask & (uint16(1) << survivor)) == 0) ++survivor;
        _materializeFees();
        MugiV4Engine.LiquidityResult memory removed = engine.removeLiquidity(survivor, 0, 0);
        _fees(survivor, removed.ethFees, removed.tokenFees);
        _payTeamTokenFees(survivor);
        ledger.finalizeMigration(survivor, nextCutoff);
        _retireReserve(survivor);
        phase = Phase.Finalized;
        claimsExpireAt = uint64(block.timestamp + FINAL_CLAIM_WINDOW);
        migrationDeadline = claimsExpireAt;
    }

    /// @notice Anyone can execute the fixed V2 handoff before the 30-day deadline.
    /// The precommitted receiver must have code and accept the handoff atomically.
    function migrateToV2(address target) external guarded {
        if (phase != Phase.Finalized || migrated || target.code.length == 0
            || target != v2MigrationTarget || block.timestamp >= migrationDeadline) revert InvalidState();
        migrated = true;
        uint8 survivor;
        while ((aliveMask & (uint16(1) << survivor)) == 0) ++survivor;
        uint256 inventory = MugiCrewToken(tokens[survivor]).balanceOf(address(this)) - ledger.escrowBacking(survivor) - unreleasedReserve[survivor];
        uint256 ethAmount = address(this).balance - teamEth - ledger.reservedEth();
        MugiCrewToken(tokens[survivor]).transfer(target, inventory);
        IMugiV2FinaleReceiver(target).receiveV1Finale{value: ethAmount}(survivor, tokens[survivor], inventory);
        emit V2Handoff(target, survivor, ethAmount, inventory);
    }

    /// @notice If V2 has not accepted the handoff within 30 days, anyone can send
    /// only unreserved finale assets to the fixed community treasury. Claims and
    /// team liabilities remain reserved until their separate claim/expiry paths.
    function fallbackFinaleToCommunity() external guarded {
        if (phase != Phase.Finalized || migrated || migrationDeadline == 0
            || block.timestamp < migrationDeadline) revert InvalidState();
        migrated = true;
        uint8 survivor;
        while ((aliveMask & (uint16(1) << survivor)) == 0) ++survivor;
        uint256 inventory = MugiCrewToken(tokens[survivor]).balanceOf(address(this)) - ledger.escrowBacking(survivor) - unreleasedReserve[survivor];
        uint256 ethAmount = address(this).balance - teamEth - ledger.reservedEth();
        MugiCrewToken(tokens[survivor]).transfer(communityTreasury, inventory);
        _pay(payable(communityTreasury), ethAmount);
        emit FinaleFallback(communityTreasury, survivor, ethAmount, inventory);
    }

    /// @notice Resolves liabilities that remain after the published 30-day final
    /// claim window. Expired ETH goes to the immutable community treasury and
    /// remaining migration backing is burned; callers cannot choose a recipient.
    function sweepExpiredFinalClaims() external guarded {
        uint64 deadline = claimsExpireAt;
        if ((phase != Phase.Finalized && phase != Phase.EmergencyClosed) || deadline == 0 || block.timestamp < deadline) revert InvalidState();
        (uint256 expiredEth, uint256[10] memory expiredTokens) = ledger.expireFinalClaims();
        for (uint8 i; i < 10; ++i) {
            if (expiredTokens[i] != 0) MugiCrewToken(tokens[i]).burn(expiredTokens[i]);
        }
        claimsExpireAt = 0;
        // Terminal recovery has no V2 handoff: all unallocated shares and dust
        // join expired player claims. No treasury call can block LP recovery.
        if (phase == Phase.EmergencyClosed) expiredEth = address(this).balance - teamEth;
        _pay(payable(communityTreasury), expiredEth);
        emit FinalClaimsExpired(deadline, expiredEth);
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view onlyManager returns (bytes4) {
        if (sender != address(engine)) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
    }
    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view onlyManager returns (bytes4) {
            if (sender != address(engine)) revert Unauthorized();
            return IHooks.beforeAddLiquidity.selector;
        }
    function beforeRemoveLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external view onlyManager returns (bytes4) {
            if (sender != address(engine)) revert Unauthorized();
            return IHooks.beforeRemoveLiquidity.selector;
        }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external view onlyManager returns (bytes4) { revert Unauthorized(); }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external onlyManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint8 crew = engine.crewForPool(key);
        if (sender == address(engine)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        _requireLive(crew); _observe(crew);
        (BeforeSwapDelta delta, uint256 fee) = engine.beforeSwapFee(params); _gameFee(crew, fee);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyManager returns (bytes4, int128)
    {
        uint8 crew = engine.crewForPool(key);
        if (sender == address(engine)) return (IHooks.afterSwap.selector, 0);
        (int128 returned, uint256 fee) = engine.afterSwapFee(params, delta); _gameFee(crew, fee); _observe(crew);
        return (IHooks.afterSwap.selector, returned);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (pendingFeeWithdrawal == bytes32(0) || keccak256(data) != pendingFeeWithdrawal) revert InvalidState();
        pendingFeeWithdrawal = bytes32(0);
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        return bytes("");
    }
    function _gameFee(uint8 crew, uint256 fee) private {
        if (fee == 0) return;
        hookFeeClaims += fee;
        poolManager.mint(address(this), 0, fee);
        uint256 own = fee / 2; ownBurnBudget[crew] += own; treasure[crew] += fee - own;
        emit GameFee(crew, own, fee - own);
    }
    function _materializeFees() private {
        uint256 amount = hookFeeClaims;
        if (amount == 0) return;
        hookFeeClaims = 0;
        bytes memory data = abi.encode(amount);
        pendingFeeWithdrawal = keccak256(data);
        poolManager.unlock(data);
        if (pendingFeeWithdrawal != bytes32(0)) revert InvalidState();
    }
    function _fees(uint8 crew, uint256 ethFee, uint256 tokenFee) private {
        teamEth += ethFee; teamTokens[crew] += tokenFee;
        if (ethFee != 0 || tokenFee != 0) emit TeamFeesAccrued(crew, ethFee, tokenFee);
    }
    /// @dev Excluded treasury ownership
    /// survives crew closure without adding reward or migration eligibility.
    function _payTeamTokenFees(uint8 crew) private {
        uint256 amount = teamTokens[crew];
        if (amount == 0) return;
        teamTokens[crew] = 0;
        MugiCrewToken(tokens[crew]).transfer(teamTreasury, amount);
        emit TeamTokenFeesPaid(crew, amount);
    }
    function _observe(uint8 crew) private { (, int24 tick,) = engine.getPoolState(crew); prices.update(crew, tick); }
    function _requireLive(uint8 crew) private view {
        if (crew >= 10 || phase != Phase.Live || block.timestamp >= nextCutoff || (aliveMask & (uint16(1) << crew)) == 0)
            revert InvalidState();
    }
    function _requireClaims() private view {
        if (phase != Phase.Live && phase != Phase.Finalized && phase != Phase.EmergencyClosed) revert InvalidState();
        if (phase == Phase.Live && block.timestamp >= nextCutoff) revert InvalidState();
        if (phase != Phase.Live && block.timestamp >= claimsExpireAt) revert InvalidState();
    }
    function _requireEthClaim() private view {
        if (phase == Phase.Setup || phase == Phase.Aborted) revert InvalidState();
        if ((phase == Phase.Finalized || phase == Phase.EmergencyClosed) && block.timestamp >= claimsExpireAt) revert InvalidState();
    }
    function _requireTeamWithdrawal() private view {
        if (phase != Phase.Live && phase != Phase.Finalized && phase != Phase.EmergencyClosed) revert InvalidState();
        if (phase == Phase.Live && block.timestamp >= nextCutoff) revert InvalidState();
    }
    function _pay(address payable recipient, uint256 amount) private {
        if (amount != 0) { (bool success,) = recipient.call{value: amount}(""); if (!success) revert EthTransferFailed(); }
    }

    /// @dev Identically named read-only module APIs share the hook's public ABI.
    /// Return the module's ABI bytes directly to avoid repeated array decoding /
    /// encoding; STATICCALL cannot mutate state and reverts propagate unchanged.
    function _forwardView(address target) private view {
        if (target.code.length == 0) revert InvalidConfiguration();
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := staticcall(gas(), target, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }

    function previewAccount(address account) external view returns (uint256[10] memory, uint256, uint256[10] memory) { _forwardView(address(ledger)); }
    function eligibleSupply(uint8 crew) external view returns (uint256) { _forwardView(address(ledger)); }
    function reservedPlayerEth() external view returns (uint256) { return ledger.reservedEth(); }
    function escrowBacking(uint8 crew) external view returns (uint256) { _forwardView(address(ledger)); }
    function unredeemedGameFees() external view returns (uint256) { return hookFeeClaims; }
    function poolKey(uint8 crew) external view returns (PoolKey memory) { _forwardView(address(engine)); }
    function poolId(uint8 crew) external view returns (PoolId) { _forwardView(address(engine)); }
    function poolState(uint8 crew) external view returns (uint160, int24, uint128) { _forwardView(address(engine)); }
    function positionLiquidity(uint8 crew) external view returns (uint128) { _forwardView(address(engine)); }
    function buybackTwap(uint8 crew) external view returns (int24 tick, uint32 secondsUsed, uint16 observations) {
        _forwardView(address(prices));
    }
    function planHash(MugiBuybacks.BuybackPlan calldata plan) external view returns (bytes32) { return budgets.hash(plan); }
    function roundBudget(uint64 id) external view returns (MugiBuybacks.Budget memory) { _forwardView(address(budgets)); }
}
