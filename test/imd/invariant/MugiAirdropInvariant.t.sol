// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiAirdrop} from "src/game/MugiAirdrop.sol";
import {MugiIMDCrewToken} from "src/imd/MugiIMDCrewToken.sol";

/// @dev Test-only attestor and hook; all claim payments use the real fixed-reserve tokens.
contract AirdropAccountingHandler is Test {
    uint256 private constant ATTESTOR_KEY = 0xAD123;
    uint256 public constant INITIAL = 100_003;
    uint256 public constant ACTORS = 20;
    MugiAirdrop public immutable drop;
    MugiIMDCrewToken[10] public tokens;
    address[20] public actors;
    uint256[10] public paid;
    uint256[10] public retired;
    bool[20] public paidAccount;
    uint8[20] public registeredCrew;
    uint256 public successfulClaims;
    uint256 public rejectedClaims;

    constructor() {
        address[10] memory assets;
        for (uint8 i; i < 10; ++i) {
            tokens[i] = new MugiIMDCrewToken(i, address(this), INITIAL);
            assets[i] = address(tokens[i]);
        }
        drop = new MugiAirdrop(address(this), vm.addr(ATTESTOR_KEY), INITIAL, assets);
        for (uint8 i; i < 10; ++i) {
            tokens[i].transfer(address(drop), INITIAL / 20);
        }
        for (uint256 a; a < ACTORS; ++a) {
            actors[a] = address(uint160(0xA10000 + a));
        }
        // Both populated and empty crews exist before the random sequence starts.
        for (uint256 a; a < 10; ++a) {
            _register(a, uint8(a % 5));
        }
    }

    function register(uint256 actorSeed, uint256 crewSeed) external {
        uint256 a = actorSeed % ACTORS;
        uint8 crew = uint8(crewSeed % 10);
        bool permitted = drop.launchedAt() == 0 && registeredCrew[a] == 0;
        if (permitted) {
            _register(a, crew);
        } else {
            uint64 deadline = uint64(block.timestamp + 1 days);
            bytes32 social = _social(a);
            bytes memory signature = _signature(drop.REGISTRATION_TYPEHASH(), actors[a], crew, social, deadline);
            vm.prank(actors[a]);
            vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
            drop.register(crew, social, deadline, signature);
        }
    }

    function launch() external {
        if (drop.launchedAt() == 0) {
            drop.launch();
        } else {
            vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
            drop.launch();
        }
    }

    function claim(uint256 actorSeed, bool wrongSignature) external {
        uint256 a = actorSeed % ACTORS;
        uint8 encoded = registeredCrew[a];
        uint8 crew = encoded == 0 ? 0 : encoded - 1;
        uint64 deadline = uint64(block.timestamp + 1 days);
        // A valid registration attestation must never authorize the second social action.
        bytes32 kind = wrongSignature ? drop.REGISTRATION_TYPEHASH() : drop.CLAIM_TYPEHASH();
        bytes memory signature = _signature(kind, actors[a], crew, _social(a), deadline);
        bool permitted = !wrongSignature && drop.launchedAt() != 0 && block.timestamp < drop.launchedAt() + 22 hours
            && encoded != 0 && !paidAccount[a];
        uint256 beforeBalance = tokens[crew].balanceOf(actors[a]);
        vm.prank(actors[a]);
        (bool ok,) = address(drop).call(abi.encodeCall(drop.claim, (deadline, signature)));
        assertEq(ok, permitted);
        if (ok) {
            uint256 amount = tokens[crew].balanceOf(actors[a]) - beforeBalance;
            assertGt(amount, 0);
            assertLe(amount, INITIAL / 1000);
            assertEq(amount, drop.allocation(crew));
            paid[crew] += amount;
            paidAccount[a] = true;
            ++successfulClaims;
        } else {
            assertEq(tokens[crew].balanceOf(actors[a]), beforeBalance);
            ++rejectedClaims;
        }
    }

    function advance(uint256 entropy) external {
        uint64 start = drop.launchedAt();
        if (start == 0) return;
        uint256 destination = uint256(start) + 22 hours - (entropy % 2);
        if (destination > block.timestamp) vm.warp(destination);
    }

    function retire() external {
        if (drop.launchedAt() == 0 || block.timestamp < drop.launchedAt() + 22 hours) {
            vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
            drop.retireRemaining();
            return;
        }
        uint256[10] memory balances;
        for (uint8 i; i < 10; ++i) {
            balances[i] = tokens[i].balanceOf(address(drop));
        }
        drop.retireRemaining();
        for (uint8 i; i < 10; ++i) {
            assertEq(tokens[i].balanceOf(address(drop)), 0);
            retired[i] += balances[i];
        }
    }

    function unauthorizedLifecycle(uint256 actorSeed) external {
        vm.startPrank(actors[actorSeed % ACTORS]);
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.launch();
        vm.expectRevert(MugiAirdrop.InvalidAirdrop.selector);
        drop.retireRemaining();
        vm.stopPrank();
    }

    function assertConservation() external view {
        uint256[10] memory registered;
        uint256[10] memory walletBalances;
        for (uint256 a; a < ACTORS; ++a) {
            assertEq(drop.claimed(actors[a]), paidAccount[a]);
            assertEq(drop.crewPlusOne(actors[a]), registeredCrew[a]);
            if (registeredCrew[a] != 0) {
                ++registered[registeredCrew[a] - 1];
                assertTrue(drop.usedSocialId(_social(a)));
                assertEq(drop.socialIdByAccount(actors[a]), _social(a));
            }
            for (uint8 i; i < 10; ++i) {
                walletBalances[i] += tokens[i].balanceOf(actors[a]);
            }
        }
        for (uint8 i; i < 10; ++i) {
            assertEq(drop.registrations(i), registered[i]);
            assertEq(walletBalances[i], paid[i]);
            assertEq(tokens[i].balanceOf(address(drop)) + paid[i] + retired[i], INITIAL / 20);
            assertEq(tokens[i].totalSupply() + retired[i], tokens[i].reserveCap());
            assertEq(
                tokens[i].balanceOf(address(this)) + tokens[i].balanceOf(address(drop)) + walletBalances[i],
                tokens[i].totalSupply()
            );
        }
    }

    function _register(uint256 a, uint8 crew) private {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory signature = _signature(drop.REGISTRATION_TYPEHASH(), actors[a], crew, _social(a), deadline);
        vm.prank(actors[a]);
        drop.register(crew, _social(a), deadline, signature);
        registeredCrew[a] = crew + 1;
    }

    function _social(uint256 a) private pure returns (bytes32) {
        return keccak256(abi.encode("test social", a));
    }

    function _signature(bytes32 kind, address actor, uint8 crew, bytes32 social, uint64 deadline)
        private
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", drop.DOMAIN_SEPARATOR(), keccak256(abi.encode(kind, actor, crew, social, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MugiAirdropAccountingInvariantTest is Test {
    AirdropAccountingHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new AirdropAccountingHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.register.selector;
        selectors[1] = handler.launch.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.retire.selector;
        selectors[5] = handler.unauthorizedLifecycle.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_registrationAndFiniteAllocationRemainConserved() public view {
        handler.assertConservation();
    }

    function testAirdropHandlerExercisesWrongAttestationReplayAndExactWindow() public {
        handler.register(10, 9);
        handler.launch();
        handler.claim(0, true);
        handler.claim(0, false);
        handler.claim(0, false);
        handler.advance(1); // One second before expiry.
        handler.claim(10, false);
        handler.retire(); // Early retirement must fail.
        handler.advance(0); // Exactly at expiry.
        handler.claim(1, false);
        handler.retire();
        handler.retire(); // Repetition cannot burn a holder's already-paid allocation.
        handler.assertConservation();
        assertEq(handler.successfulClaims(), 2);
        assertEq(handler.rejectedClaims(), 3);
    }
}
