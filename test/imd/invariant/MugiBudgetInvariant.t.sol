// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiIMDBuybacks as Budgets} from "src/imd/modules/MugiIMDBuybacks.sol";

/// @dev Isolates budget arithmetic from signature verification (covered by the verifier suite).
contract BudgetPlanVerifierFixture {
    address public immutable consumer;

    constructor(address consumer_) {
        consumer = consumer_;
    }

    function verify(bytes32, bytes calldata, address candidate) external view returns (bool) {
        return candidate == consumer;
    }
}

contract BudgetAccountingHandler is Test {
    uint256 public constant TOTAL = 100_003;
    Budgets public immutable budgets;
    BudgetPlanVerifierFixture public immutable verifier;
    uint64 public immutable deadline;
    uint256[3] public paid;
    uint256 public approvals;
    uint256 public trades;

    constructor() {
        budgets = new Budgets(address(this));
        verifier = new BudgetPlanVerifierFixture(address(this));
        budgets.create(1, TOTAL, 7);
        deadline = budgets.roundBudget(1).deadline;
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 15 minutes));
    }

    function approve(uint256 rotationSeed) external {
        Budgets.Budget memory b = budgets.roundBudget(1);
        if (b.authorizationPending || block.timestamp + 10 minutes >= deadline) return;
        Budgets.BuybackPlan memory plan;
        plan.roundId = 1;
        plan.nonce = b.nonce + 1;
        plan.deadline = uint64(block.timestamp + 10 minutes);
        uint256 rotation = rotationSeed % 3;
        plan.allocations[rotation] = 41_667;
        plan.allocations[(rotation + 1) % 3] = 25_000;
        plan.allocations[(rotation + 2) % 3] = 33_336;
        for (uint8 i; i < 3; ++i) {
            if (plan.allocations[i] < b.crewSpent[i]) return;
        }
        budgets.approve(plan, address(verifier), "");
        ++approvals;
        vm.expectRevert(Budgets.InvalidPlan.selector);
        budgets.approve(plan, address(verifier), "");
    }

    function authorize(uint256 crewSeed, uint256 amountSeed) external {
        Budgets.Budget memory b = budgets.roundBudget(1);
        if (b.authorizationPending || block.timestamp >= deadline) return;
        uint8 crew = uint8(crewSeed % 3);
        if (block.timestamp > b.planValidUntil) {
            // Every fallback allocation is at least 25,000 or already spent.
            // A lightly spent crew can therefore always execute 500, regardless
            // of which overweight crew the fallback has to preserve.
            uint8 checked;
            while (b.crewSpent[crew] > 24_000 && checked < 3) {
                crew = (crew + 1) % 3;
                ++checked;
            }
            if (checked == 3) return;
            if (b.lastTrade[crew] != 0 && block.timestamp < b.lastTrade[crew] + 5 minutes) return;
            budgets.authorize(1, crew, 500);
            return;
        }
        if (b.lastTrade[crew] != 0 && block.timestamp < b.lastTrade[crew] + 5 minutes) return;
        uint256 remaining = b.allocation[crew] - b.crewSpent[crew];
        if (remaining == 0) return;
        uint256 minimum = (b.allocation[crew] + 99) / 100;
        if (remaining < minimum) minimum = remaining;
        uint256 maximum = remaining < (TOTAL + 19) / 20 ? remaining : (TOTAL + 19) / 20;
        uint256 amount = bound(amountSeed, minimum, maximum);
        budgets.authorize(1, crew, amount);
    }

    function account(uint256 amountSeed, bool wrongCrew, bool overspend) external {
        Budgets.Budget memory b = budgets.roundBudget(1);
        if (!b.authorizationPending) {
            vm.expectRevert(Budgets.InvalidExecution.selector);
            budgets.account(1, 0, 1);
            return;
        }
        uint8 crew = b.authorizedCrew;
        uint256 remaining = b.allocation[crew] - b.crewSpent[crew];
        uint256 minimum = (b.allocation[crew] + 99) / 100;
        if (minimum > remaining) minimum = remaining;
        uint256 amount = overspend ? b.authorizedAmount + 1 : bound(amountSeed, minimum, b.authorizedAmount);
        if (wrongCrew || overspend) {
            vm.expectRevert(Budgets.InvalidExecution.selector);
            budgets.account(1, wrongCrew ? (crew + 1) % 3 : crew, amount);
            assertEq(keccak256(abi.encode(budgets.roundBudget(1))), keccak256(abi.encode(b)));
        } else {
            budgets.account(1, crew, amount);
            paid[crew] += amount;
            ++trades;
            vm.expectRevert(Budgets.InvalidExecution.selector);
            budgets.account(1, crew, amount);
        }
    }

    function unauthorized(uint256 seed) external {
        address outsider = address(uint160(bound(seed, 1, type(uint128).max)));
        Budgets.Budget memory before_ = budgets.roundBudget(1);
        Budgets.BuybackPlan memory plan;
        vm.startPrank(outsider);
        vm.expectRevert(Budgets.NotHook.selector);
        budgets.create(2, 1, 1);
        vm.expectRevert(Budgets.NotHook.selector);
        budgets.authorize(1, 0, 1);
        vm.expectRevert(Budgets.NotHook.selector);
        budgets.account(1, 0, 1);
        vm.expectRevert(Budgets.NotHook.selector);
        budgets.approve(plan, address(verifier), "");
        vm.stopPrank();
        assertEq(keccak256(abi.encode(budgets.roundBudget(1))), keccak256(abi.encode(before_)));
    }

    function assertAccounting() external view {
        Budgets.Budget memory b = budgets.roundBudget(1);
        uint256 allocations;
        uint256 spent;
        for (uint8 i; i < 10; ++i) {
            allocations += b.allocation[i];
            spent += b.crewSpent[i];
            assertLe(b.crewSpent[i], b.allocation[i]);
            if (i < 3) assertEq(b.crewSpent[i], paid[i]);
            else assertEq(b.allocation[i] + b.crewSpent[i], 0);
        }
        assertEq(allocations, TOTAL);
        assertEq(b.total, TOTAL);
        assertEq(spent, b.spent);
        assertLe(spent, TOTAL);
        assertEq(b.deadline, deadline);
        assertEq(b.aliveMask, 7);
        if (b.authorizationPending) {
            assertGt(b.authorizedAmount, 0);
            assertLe(b.authorizedAmount, (TOTAL + 19) / 20);
            assertLe(b.authorizedAmount + b.crewSpent[b.authorizedCrew], b.allocation[b.authorizedCrew]);
        } else {
            assertEq(b.authorizedAmount, 0);
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract MugiBudgetAccountingInvariantTest is Test {
    BudgetAccountingHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new BudgetAccountingHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.authorize.selector;
        selectors[3] = handler.account.selector;
        selectors[4] = handler.unauthorized.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allocationsAndActualSpendingAlwaysConserveTheBudget() public view {
        handler.assertAccounting();
    }

    function testExpiredPlanFallbackPreservesAlreadySpentOverweightAllocation() public {
        handler.approve(0);
        // Spend above the equal allocation before the signed plan expires.
        for (uint256 i; i < 8; ++i) {
            handler.authorize(0, 5_001);
            handler.account(5_001, false, false);
            // Keep the short plan alive while exercising the cadence boundary.
            handler.advance(5 minutes);
            handler.approve(0);
        }
        assertGt(handler.paid(0), handler.TOTAL() / 3);
        handler.advance(11 minutes);
        handler.authorize(1, 500);
        handler.account(500, false, false);
        handler.assertAccounting();
        assertEq(handler.budgets().roundBudget(1).planValidUntil, handler.deadline());
        assertGt(handler.trades(), 8);
    }
}
