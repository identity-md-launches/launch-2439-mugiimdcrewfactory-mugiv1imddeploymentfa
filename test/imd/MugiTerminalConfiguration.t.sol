// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
import {MugiIMDGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";
contract MugiTerminalConfigurationTest is MugiIMDDeploymentFixture {
    function setUp() public { vm.warp(1 days); manager = new PoolManager(address(this)); _newFactories(); }
    function _reject(MugiIMDGameHook.Configuration memory c) private {
        bytes memory code = _hookCode(c);
        bytes32 salt = _mine(keccak256(code));
        address futureHook = _deployBeforeHook(code, salt);
        assertEq(uint160(futureHook) & 0x3fff, 0x2aec, "valid hook address flags");
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.DeploymentFailed.selector);
        factory.deployHook(code);
        assertEq(futureHook.code.length, 0);
    }
    function testZeroV2ReceiverCannotCreateHook() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = address(0); _reject(c);
    }
    function testOwnerCannotBeCommunityDestination() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.community = OWNER; _reject(c);
    }
    function testTeamCannotBeCommunityDestination() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.community = TEAM; _reject(c);
    }
    // Follow-up finding 71d0d1a9: the V2 receiver pin must be gated like the
    // community treasury, so no owner, team or community address can be the
    // permissionless finale handoff destination.
    function testOwnerCannotBeV2Receiver() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = OWNER; _reject(c);
    }
    function testTeamCannotBeV2Receiver() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = TEAM; _reject(c);
    }
    function testCommunityCannotBeV2Receiver() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = COMMUNITY; _reject(c);
    }
    function testV2ReceiverCannotBecomeOwnerEvenAfterOwnershipTransfer() public {
        MugiIMDGameHook game = _deployGraph();
        address receiver = game.v2MigrationTarget();
        assertEq(receiver, address(this));
        vm.prank(OWNER);
        vm.expectRevert(MugiIMDGameHook.InvalidConfiguration.selector);
        game.transferOwnership(receiver);
        assertEq(game.pendingOwner(), address(0));
        address replacement = address(0xB0B);
        vm.prank(OWNER);
        game.transferOwnership(replacement);
        vm.prank(replacement);
        game.acceptOwnership();
        assertEq(game.owner(), replacement);
        vm.prank(replacement);
        vm.expectRevert(MugiIMDGameHook.InvalidConfiguration.selector);
        game.transferOwnership(receiver);
        vm.prank(replacement);
        vm.expectRevert(MugiIMDGameHook.InvalidConfiguration.selector);
        game.transferOwnership(COMMUNITY);
        assertEq(game.pendingOwner(), address(0));
        assertEq(game.owner(), replacement);
    }
    function testNonzeroFutureV2ContractCanBePinnedBeforeItsDeployment() public {
        MugiIMDGameHook.Configuration memory c = _hookConfiguration(); c.v2MigrationTarget = address(0xABC123);
        assertEq(c.v2MigrationTarget.code.length, 0);
        bytes memory code = _hookCode(c); bytes32 salt = _mine(keccak256(code)); _deployBeforeHook(code, salt);
        vm.prank(OWNER); MugiIMDGameHook game = factory.deployHook(code);
        assertEq(game.v2MigrationTarget(), c.v2MigrationTarget);
    }
}
