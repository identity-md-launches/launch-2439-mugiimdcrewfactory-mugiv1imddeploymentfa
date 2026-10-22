// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MugiIMDDeploymentFixture} from "./helpers/MugiIMDDeploymentFixture.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDCrewFactory} from "../../src/imd/MugiIMDCrewFactory.sol";
import {MugiIMDAccountingFactory} from "../../src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "../../src/imd/MugiIMDEngineFactory.sol";
import {MugiV1IMDDeploymentFactory} from "../../src/imd/MugiV1IMDDeploymentFactory.sol";
import {MugiVRFAdapter} from "../../src/game/MugiVRFAdapter.sol";
import {MugiIMDLedger} from "../../src/imd/modules/MugiIMDLedger.sol";

interface IOwnedFactory {
    function owner() external view returns (address);
}

/// @dev Test-only meter. Deploys raw initcode through CREATE2 in one call and
/// measures the gas inside the EVM, including initcode execution and the
/// 200 gas/byte runtime code deposit. It is never part of the launch.
contract RawCreationMeter {
    function create(bytes[] calldata codes) external returns (address[] memory created, uint256 gasUsed) {
        created = new address[](codes.length);
        uint256 start = gasleft();
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(code, 0x20), mload(code), i) }
            require(deployed != address(0) && deployed.code.length != 0, "creation failed");
            created[i] = deployed;
        }
        gasUsed = start - gasleft();
    }
}

contract MugiV1IMDDeploymentFactoryTest is MugiIMDDeploymentFixture {
    function setUp() public {
        vm.warp(1 days);
        manager = new PoolManager(address(this));
        _newFactories();
    }

    function testCompleteConstructorGraphSeedsAllPoolsAndLaunchesWithoutInitializers() public {
        MugiGameHook game = _deployGraph();
        _seedAndLaunch(game);
    }

    function testFactoriesPinSourceHaveNoChildrenAtConstructionAndFitEvmLimits() public view {
        assertEq(factory.hookCreationCodeHash(), keccak256(type(MugiGameHook).creationCode));
        assertEq(factory.hookCreationCodeLength(), type(MugiGameHook).creationCode.length);
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(vm.getNonce(address(crewFactory)), 1);
        assertEq(vm.getNonce(address(accountingFactory)), 1);
        assertEq(vm.getNonce(address(engineFactory)), 1);
        assertLe(address(factory).code.length, 24_576);
        assertLe(address(crewFactory).code.length, 24_576);
        assertLe(address(accountingFactory).code.length, 24_576);
        assertLe(address(engineFactory).code.length, 24_576);
        assertLe(type(MugiV1IMDDeploymentFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDCrewFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDAccountingFactory).creationCode.length + 32, 49_152);
        assertLe(type(MugiIMDEngineFactory).creationCode.length + 32, 49_152);
    }

    function testFactoryCreationBatchHasConservativeGasHeadroom() public {
        // Raw CREATE2 of the exact initcode in manifest order, as the IMD project
        // factory deploys it. Forge 1.8 does not meter `new` of a project artifact
        // from a test-directory contract, so gasleft() around _newFactories()
        // under-reports creation gas there; raw CREATE2 is metered normally.
        RawCreationMeter meter = new RawCreationMeter();
        bytes memory ownerArgument = abi.encode(OWNER);
        bytes[] memory codes = new bytes[](4);
        codes[0] = abi.encodePacked(type(MugiIMDCrewFactory).creationCode, ownerArgument);
        codes[1] = abi.encodePacked(type(MugiV1IMDDeploymentFactory).creationCode, ownerArgument);
        codes[2] = abi.encodePacked(type(MugiIMDAccountingFactory).creationCode, ownerArgument);
        codes[3] = abi.encodePacked(type(MugiIMDEngineFactory).creationCode, ownerArgument);
        (address[] memory created, uint256 execution) = meter.create(codes);
        uint256 calldataBytes = 4 * 32 + 4096;
        uint256 runtimeBytes;
        for (uint256 i; i < 4; ++i) {
            calldataBytes += codes[i].length;
            runtimeBytes += created[i].code.length;
            assertEq(IOwnedFactory(created[i]).owner(), OWNER);
        }
        assertEq(created[0].code, address(crewFactory).code);
        assertEq(created[1].code, address(factory).code);
        assertEq(created[2].code, address(accountingFactory).code);
        assertEq(created[3].code, address(engineFactory).code);
        // This is a local creation bound with explicit ABI/registry allowance;
        // the exact IMD launchContracts transaction also needs RPC simulation.
        _assertTransactionGas("Four factory creation bound", execution, calldataBytes, runtimeBytes, 4, 1_000_000);
    }

    function testEveryDescendantCreationCallFitsSeparateTransactionGasCap() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        vm.startPrank(OWNER);
        uint256 start = gasleft();
        factory.deployModules(salt, keccak256(code), moduleConfig);
        uint256 execution = start - gasleft();
        uint256 runtimeBytes = address(factory.router()).code.length + address(factory.vrf()).code.length
            + address(factory.imdVerifier()).code.length + address(factory.airdrop()).code.length;
        _assertTransactionGas("Four service module creations", execution, 4 + 16 * 32, runtimeBytes, 4, 100_000);
        start = gasleft();
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        execution = start - gasleft();
        runtimeBytes = 0;
        for (uint256 i; i < 10; ++i) runtimeBytes += crewFactory.tokens(i).code.length;
        _assertTransactionGas("Ten crew token creations", execution, 4 + 2 * 32, runtimeBytes, 10, 100_000);
        start = gasleft();
        engineFactory.deployForHook(futureHook, manager);
        execution = start - gasleft();
        _assertTransactionGas("Engine creation", execution, 4 + 2 * 32, address(engineFactory.engine()).code.length, 1, 100_000);
        start = gasleft();
        accountingFactory.deployForHook(ledgerConfig);
        execution = start - gasleft();
        MugiIMDAccountingFactory.Modules memory accounting = accountingFactory.predictModules();
        runtimeBytes = address(accounting.ledger).code.length + address(accounting.budgets).code.length
            + address(accounting.prices).code.length;
        _assertTransactionGas("Three accounting module creations", execution, 4 + 16 * 32, runtimeBytes, 3, 100_000);
        start = gasleft();
        factory.deployHook(code);
        execution = start - gasleft();
        _assertTransactionGas("Hook creation", execution, 4 + 2 * 32 + code.length + 32, futureHook.code.length, 1, 100_000);
        vm.stopPrank();
    }

    function _assertTransactionGas(string memory label, uint256 execution, uint256 calldataBytes,
        uint256 runtimeBytes, uint256 createdContracts, uint256 overheadAllowance) private
    {
        uint256 codeDeposit = 200 * runtimeBytes;
        // gasleft around real CREATE includes code deposit. Fail explicitly if
        // a test runner's instrumentation omits it; never accept a tiny trace
        // instruction count as total creation gas or add the deposit twice.
        assertGe(execution, codeDeposit, "creation meter omitted runtime code-deposit gas");
        uint256 otherCreationGas = execution - codeDeposit;
        // Add the maximum EIP-3860 (2 gas/word) plus CREATE2 hash (6 gas/word)
        // cost for each EIP-3860-sized initcode even though CREATE gasleft also
        // normally includes it. This deliberately overcounts for headroom.
        uint256 initcodeUpperBound = createdContracts * 8 * ((uint256(49_152) + 31) / 32);
        uint256 totalBound = codeDeposit + otherCreationGas + initcodeUpperBound
            + 21_000 + 16 * calldataBytes + overheadAllowance;
        emit log_named_uint(label, execution);
        emit log_named_uint("Runtime code-deposit component", codeDeposit);
        emit log_named_uint("Conservative independent-transaction bound", totalBound);
        assertLt(totalBound, 16_777_216);
    }

    function testUnauthorizedCallersCannotConsumeAnyPredictedAddress() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        vm.startPrank(address(0xBAD));
        vm.expectRevert(MugiIMDCrewFactory.Unauthorized.selector);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.expectRevert(MugiIMDAccountingFactory.Unauthorized.selector);
        accountingFactory.deployForHook(ledgerConfig);
        vm.expectRevert(MugiIMDEngineFactory.Unauthorized.selector);
        engineFactory.deployForHook(futureHook, manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployModules(salt, keccak256(code), moduleConfig);
        vm.expectRevert(MugiV1IMDDeploymentFactory.Unauthorized.selector);
        factory.deployHook(code);
        vm.stopPrank();
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(vm.getNonce(address(crewFactory)), 1);
        assertEq(vm.getNonce(address(accountingFactory)), 1);
        assertEq(vm.getNonce(address(engineFactory)), 1);
    }

    function testConstructorFailureRollsBackModuleCommitmentAndCreateNonces() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory c = _moduleConfiguration();
        c.vrfCallbackGasLimit = 1;
        vm.prank(OWNER);
        vm.expectRevert(MugiVRFAdapter.InvalidConfiguration.selector);
        factory.deployModules(salt, keccak256(code), c);
        assertFalse(factory.modulesDeployed());
        assertEq(factory.plannedHook(), address(0));
        assertEq(factory.hookInitCodeHash(), bytes32(0));
        assertEq(vm.getNonce(address(factory)), 1);
        assertEq(factory.predictModules().router.code.length, 0);
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        assertEq(vm.getNonce(address(factory)), 5);
    }

    function testHookRequiresAllFourOwnModulesAndCrewCreationAndExactCommittedCode() public {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        factory.deployHook(code);
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
        address futureHook = factory.plannedHook();
        vm.prank(OWNER);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        bytes memory wrong = bytes.concat(code, hex"00");
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        factory.deployHook(wrong);
        assertEq(address(factory.hook()), address(0));
    }

    function testEvenCommittedArbitraryCreationCodeCannotReplacePinnedImplementation() public {
        bytes memory wrong = new bytes(type(MugiGameHook).creationCode.length + 14 * 32);
        bytes32 salt = _mine(keccak256(wrong));
        vm.prank(OWNER);
        factory.deployModules(salt, keccak256(wrong), _moduleConfiguration());
        address futureHook = factory.plannedHook();
        vm.prank(OWNER);
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidHookInitCode.selector);
        factory.deployHook(wrong);
        assertEq(factory.plannedHook().code.length, 0);
    }

    function testHookConfigurationCannotSubstituteFactoryModuleOrOwner() public {
        MugiGameHook.Configuration memory c = _hookConfiguration();
        c.randomnessProvider = address(0xBAD);
        bytes memory code = _hookCode(c);
        bytes32 salt = _mine(keccak256(code));
        _deployBeforeHook(code, salt);
        vm.prank(OWNER);
        vm.expectRevert(MugiV1IMDDeploymentFactory.InvalidConfiguration.selector);
        factory.deployHook(code);
    }

    function testMismatchedLedgerTokenBindingRejectsFirstPoolSeed() public {
        _assertMismatchedLedgerRejected(true);
    }

    function testMismatchedLedgerExclusionBindingRejectsFirstPoolSeed() public {
        _assertMismatchedLedgerRejected(false);
    }

    function _assertMismatchedLedgerRejected(bool changeToken) private {
        bytes memory code = _hookCode(_hookConfiguration());
        bytes32 salt = _mine(keccak256(code));
        address futureHook = factory.predictHook(salt, keccak256(code));
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(futureHook);
        if (changeToken) ledgerConfig.token0 = address(0xBAD);
        else ledgerConfig.manager = address(0xBAD);
        vm.deal(OWNER, 2 ether);
        vm.startPrank(OWNER);
        factory.deployModules(salt, keccak256(code), _moduleConfiguration());
        crewFactory.deployCrewSet(futureHook, SUPPLY);
        engineFactory.deployForHook(futureHook, manager);
        accountingFactory.deployForHook(ledgerConfig);
        MugiGameHook game = factory.deployHook(code);
        vm.expectRevert(MugiGameHook.InvalidConfiguration.selector);
        game.seedPool{value: 1 ether}(0);
        vm.stopPrank();
        assertEq(game.seededMask(), 0);
        assertEq(address(game).balance, 0);
    }

    function testSingleSeasonCommitmentsCannotBeReplacedAfterSuccess() public {
        MugiGameHook game = _deployGraph();
        bytes memory code = _hookCode(_hookConfiguration());
        MugiIMDLedger.Configuration memory ledgerConfig = _ledgerConfiguration(address(game));
        MugiV1IMDDeploymentFactory.ModuleConfiguration memory moduleConfig = _moduleConfiguration();
        bytes32 salt = factory.hookSalt();
        vm.startPrank(OWNER);
        vm.expectRevert(MugiIMDCrewFactory.AlreadyDeployed.selector);
        crewFactory.deployCrewSet(address(game), SUPPLY);
        vm.expectRevert(MugiIMDAccountingFactory.AlreadyDeployed.selector);
        accountingFactory.deployForHook(ledgerConfig);
        vm.expectRevert(MugiIMDEngineFactory.AlreadyDeployed.selector);
        engineFactory.deployForHook(address(game), manager);
        vm.expectRevert(MugiV1IMDDeploymentFactory.ModulesUnavailable.selector);
        factory.deployModules(salt, keccak256(code), moduleConfig);
        vm.expectRevert(MugiV1IMDDeploymentFactory.HookAlreadyDeployed.selector);
        factory.deployHook(code);
        vm.stopPrank();
    }
}
