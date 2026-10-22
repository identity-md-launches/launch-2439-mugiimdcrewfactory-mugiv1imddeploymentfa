// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiAirdrop} from "src/game/MugiAirdrop.sol";
import {MugiIMDCrewToken} from "src/imd/MugiIMDCrewToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MugiAirdropAuthorizationTest is Test {
    uint256 private constant KEY = 0xAD123;
    uint256 private constant INITIAL = 100_003;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    MugiAirdrop private drop;
    address[10] private tokens;

    function setUp() public {
        vm.warp(1_800_000_000);
        for (uint8 i; i < 10; ++i) {
            tokens[i] = address(new MugiIMDCrewToken(i, address(this), INITIAL));
        }
        drop = new MugiAirdrop(address(this), vm.addr(KEY), INITIAL, tokens);
        for (uint8 i; i < 10; ++i) {
            MugiIMDCrewToken(tokens[i]).transfer(address(drop), INITIAL / 20);
        }
    }

    function testRegistrationSignatureBindsAccountCrewSocialAndContract() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 social = keccak256("alice social");
        bytes memory signature = _sign(drop, false, ALICE, 2, social, deadline);
        vm.prank(BOB);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(2, social, deadline, signature);
        vm.startPrank(ALICE);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(3, social, deadline, signature);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(2, keccak256("changed social"), deadline, signature);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(2, social, deadline + 1, signature);
        vm.stopPrank();
        MugiAirdrop other = new MugiAirdrop(address(this), vm.addr(KEY), INITIAL, tokens);
        vm.prank(ALICE);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        other.register(2, social, deadline, signature);
        vm.prank(ALICE);
        drop.register(2, social, deadline, signature);
        assertEq(drop.crewPlusOne(ALICE), 3);
        assertEq(drop.registrations(2), 1);
        assertEq(drop.crewPlusOne(BOB), 0);
    }

    function testSocialIdentityAndWalletCannotRegisterTwiceEvenWithFreshValidSignatures() public {
        bytes32 social = keccak256("one identity");
        uint64 deadline = uint64(block.timestamp + 1 days);
        _register(drop, ALICE, 0, social, deadline);
        bytes memory signature = _sign(drop, false, BOB, 1, social, deadline);
        vm.prank(BOB);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(1, social, deadline, signature);
        bytes32 different = keccak256("second identity");
        signature = _sign(drop, false, ALICE, 1, different, deadline);
        vm.prank(ALICE);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(1, different, deadline, signature);
        assertEq(drop.registrations(0), 1);
        assertEq(drop.registrations(1), 0);
        assertFalse(drop.usedSocialId(different), "failed registration consumed identity");
    }

    function testRegistrationDeadlineIsInclusiveButExpiredSignatureDoesNotConsumeIdentity() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 social = keccak256("boundary");
        bytes memory aliceSignature = _sign(drop, false, ALICE, 0, social, deadline);
        bytes memory bobSignature = _sign(drop, false, BOB, 1, keccak256("bob"), deadline);
        vm.warp(deadline);
        vm.prank(ALICE);
        drop.register(0, social, deadline, aliceSignature);
        vm.warp(uint256(deadline) + 1);
        vm.prank(BOB);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.register(1, keccak256("bob"), deadline, bobSignature);
        assertFalse(drop.usedSocialId(keccak256("bob")));
        assertEq(drop.crewPlusOne(BOB), 0);
    }

    function testRejectedTokenPaymentRollsBackClaimFlagAndCanBeRetriedAfterFunding() public {
        MugiAirdrop unfunded = new MugiAirdrop(address(this), vm.addr(KEY), INITIAL, tokens);
        bytes32 social = keccak256("funding failure");
        uint64 deadline = uint64(block.timestamp + 1 days);
        _register(unfunded, ALICE, 0, social, deadline);
        unfunded.launch();
        bytes memory signature = _sign(unfunded, true, ALICE, 0, social, deadline);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(unfunded), 0, INITIAL / 1000)
        );
        unfunded.claim(deadline, signature);
        assertFalse(unfunded.claimed(ALICE));
        assertEq(MugiIMDCrewToken(tokens[0]).balanceOf(ALICE), 0);
        MugiIMDCrewToken(tokens[0]).transfer(address(unfunded), INITIAL / 20);
        vm.prank(ALICE);
        unfunded.claim(deadline, signature);
        assertTrue(unfunded.claimed(ALICE));
        assertEq(MugiIMDCrewToken(tokens[0]).balanceOf(ALICE), INITIAL / 1000);
        vm.prank(ALICE);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        unfunded.claim(deadline, signature);
    }

    function testClaimRejectsForeignWalletAndExpiredAttestationThenAcceptsFreshOne() public {
        bytes32 social = keccak256("claim identity");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        _register(drop, ALICE, 4, social, deadline);
        drop.launch();
        bytes memory signature = _sign(drop, true, ALICE, 4, social, deadline);
        vm.prank(BOB);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.claim(deadline, signature);
        vm.warp(uint256(deadline) + 1);
        vm.prank(ALICE);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.claim(deadline, signature);
        assertFalse(drop.claimed(ALICE));
        uint64 freshDeadline = deadline + 1 hours;
        signature = _sign(drop, true, ALICE, 4, social, freshDeadline);
        vm.prank(ALICE);
        drop.claim(freshDeadline, signature);
        assertEq(MugiIMDCrewToken(tokens[4]).balanceOf(ALICE), INITIAL / 1000);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzCohortCannotExceedFivePercentOrPerAccountCap(uint8 countSeed) public {
        uint256 count = bound(countSeed, 1, 120);
        uint64 deadline = uint64(block.timestamp + 1 days);
        for (uint256 a; a < count; ++a) {
            address account = address(uint160(0xA10000 + a));
            _register(drop, account, 0, bytes32(a + 1), deadline);
        }
        assertEq(drop.launchEligible(uint64(block.timestamp)), count >= 100);
        drop.launch();
        uint256 paid;
        for (uint256 a; a < count; ++a) {
            address account = address(uint160(0xA10000 + a));
            bytes memory signature = _sign(drop, true, account, 0, bytes32(a + 1), deadline);
            vm.prank(account);
            drop.claim(deadline, signature);
            uint256 balance = MugiIMDCrewToken(tokens[0]).balanceOf(account);
            assertGt(balance, 0);
            assertLe(balance, INITIAL / 1000);
            paid += balance;
        }
        assertLe(paid, INITIAL / 20);
        assertEq(paid + MugiIMDCrewToken(tokens[0]).balanceOf(address(drop)), INITIAL / 20);
        if (count <= 50) assertEq(paid, count * (INITIAL / 1000));
        else assertLt(INITIAL / 20 - paid, count, "only indivisible remainder may remain for a full cohort");
        for (uint8 i = 1; i < 10; ++i) {
            assertEq(drop.allocation(i), 0);
        }
    }

    function testAutomaticLaunchThresholdAndSevenDayBoundary() public {
        uint64 configured = uint64(block.timestamp);
        assertFalse(drop.launchEligible(0));
        assertFalse(drop.launchEligible(configured));
        vm.warp(uint256(configured) + 7 days - 1);
        assertFalse(drop.launchEligible(configured));
        vm.warp(uint256(configured) + 7 days);
        assertTrue(drop.launchEligible(configured));
        drop.launch();
        assertFalse(drop.launchEligible(configured));
    }

    function _register(MugiAirdrop target, address account, uint8 crew, bytes32 social, uint64 deadline) private {
        bytes memory signature = _sign(target, false, account, crew, social, deadline);
        vm.prank(account);
        target.register(crew, social, deadline, signature);
    }

    function _sign(MugiAirdrop target, bool claim, address account, uint8 crew, bytes32 social, uint64 deadline)
        private
        view
        returns (bytes memory)
    {
        bytes32 kind = claim ? target.CLAIM_TYPEHASH() : target.REGISTRATION_TYPEHASH();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", target.DOMAIN_SEPARATOR(), keccak256(abi.encode(kind, account, crew, social, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
