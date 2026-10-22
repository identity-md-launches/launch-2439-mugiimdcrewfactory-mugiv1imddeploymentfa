// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {MugiIMDCrewFactory} from "src/imd/MugiIMDCrewFactory.sol";
import {MugiV1IMDDeploymentFactory} from "src/imd/MugiV1IMDDeploymentFactory.sol";
import {MugiIMDAccountingFactory} from "src/imd/MugiIMDAccountingFactory.sol";
import {MugiIMDEngineFactory} from "src/imd/MugiIMDEngineFactory.sol";
import {MugiIMDGameHook} from "src/imd/MugiIMDGameHook.sol";

interface ManifestOwnedFactory {
    function owner() external view returns (address);
}

/// @dev All four creations occur inside one external call, matching the transaction
/// boundary of the launch. This is an offline probe, not the deployed IMD factory.
contract ManifestCreationProbe {
    function batch(bytes[] calldata codes) external returns (address[4] memory created) {
        require(codes.length == 4);
        for (uint256 i; i < 4; ++i) {
            bytes memory code = codes[i];
            address deployment;
            assembly ("memory-safe") { deployment := create2(0, add(code, 32), mload(code), i) }
            require(deployment != address(0), "factory constructor failed");
            created[i] = deployment;
        }
    }

    function tryCreate(bytes calldata initcode, uint256 value) external returns (address created) {
        bytes memory code = initcode;
        assembly ("memory-safe") { created := create(value, add(code, 32), mload(code)) }
    }
}

contract MugiManifestConstructorsTest is Test {
    address private constant MANIFEST_OWNER = address(bytes20(hex"20714d50f4675c366de30b603728a90ddddb240f"));

    function testExactManifestBatchHasFourOwnerBoundFactoriesAndNoConstructorDependencies() public {
        vm.chainId(1);
        ManifestCreationProbe probe = new ManifestCreationProbe();
        bytes[] memory codes = _codes(MANIFEST_OWNER);
        vm.startStateDiffRecording();
        address[4] memory created = probe.batch(codes);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creations;
        for (uint256 a; a < accesses.length; ++a) {
            VmSafe.AccountAccess memory access_ = accesses[a];
            if (access_.kind == VmSafe.AccountAccessKind.Create) {
                assertLt(creations, 4, "constructor created a hidden descendant");
                assertEq(access_.accessor, address(probe));
                assertEq(access_.account, created[creations]);
                assertEq(access_.value, 0);
                assertFalse(access_.reverted);
                ++creations;
            }
            for (uint256 i; i < 4; ++i) {
                if (access_.accessor != created[i]) continue;
                assertTrue(
                    access_.kind != VmSafe.AccountAccessKind.Call && access_.kind != VmSafe.AccountAccessKind.StaticCall
                        && access_.kind != VmSafe.AccountAccessKind.DelegateCall
                        && access_.kind != VmSafe.AccountAccessKind.CallCode
                        && access_.kind != VmSafe.AccountAccessKind.Extcodesize
                        && access_.kind != VmSafe.AccountAccessKind.Extcodehash
                        && access_.kind != VmSafe.AccountAccessKind.Extcodecopy
                        && access_.kind != VmSafe.AccountAccessKind.SelfDestruct,
                    "constructor accessed an external dependency or escape route"
                );
            }
        }
        assertEq(creations, 4);
        for (uint256 i; i < 4; ++i) {
            address predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(probe), bytes32(i), keccak256(codes[i]))))
                )
            );
            assertEq(created[i], predicted);
            assertEq(ManifestOwnedFactory(created[i]).owner(), MANIFEST_OWNER);
            assertEq(vm.getNonce(created[i]), 1, "factory created descendants during construction");
            assertGt(created[i].code.length, 45, "full code factory required");
            assertLe(created[i].code.length, 24_576);
            assertLe(codes[i].length, 49_152);
        }
        MugiV1IMDDeploymentFactory main = MugiV1IMDDeploymentFactory(created[1]);
        assertEq(main.hookCreationCodeHash(), keccak256(type(MugiIMDGameHook).creationCode));
        assertEq(main.hookCreationCodeLength(), type(MugiIMDGameHook).creationCode.length);
        assertFalse(main.modulesDeployed());
        assertEq(address(main.hook()), address(0));
        assertEq(main.plannedHook(), address(0));
        address[10] memory crews = MugiIMDCrewFactory(created[0]).predictCrewSet();
        for (uint256 i; i < 10; ++i) {
            assertEq(crews[i].code.length, 0);
        }
        MugiV1IMDDeploymentFactory.Modules memory services = main.predictModules();
        assertEq(
            services.router.code.length + services.vrf.code.length + services.imdVerifier.code.length
                + services.airdrop.code.length,
            0
        );
        MugiIMDAccountingFactory.Modules memory accounting = MugiIMDAccountingFactory(created[2]).predictModules();
        assertEq(
            address(accounting.ledger).code.length + address(accounting.budgets).code.length
                + address(accounting.prices).code.length,
            0
        );
        assertEq(MugiIMDEngineFactory(created[3]).predictEngine().code.length, 0);
    }

    function testEveryManifestConstructorRejectsValueAndZeroOwner() public {
        ManifestCreationProbe probe = new ManifestCreationProbe();
        vm.deal(address(probe), 1);
        bytes[] memory valid = _codes(MANIFEST_OWNER);
        bytes[] memory zeroOwner = _codes(address(0));
        for (uint256 i; i < 4; ++i) {
            assertEq(probe.tryCreate(valid[i], 1), address(0), "manifest constructor accepted ETH");
            assertEq(address(probe).balance, 1, "rejected creation consumed value");
            assertEq(probe.tryCreate(zeroOwner[i], 0), address(0), "ownerless factory deployed");
        }
        // Failed creations do not poison a later valid batch.
        address[4] memory created = probe.batch(valid);
        for (uint256 i; i < 4; ++i) {
            assertEq(ManifestOwnedFactory(created[i]).owner(), MANIFEST_OWNER);
        }
    }

    function _codes(address owner) private pure returns (bytes[] memory codes) {
        codes = new bytes[](4);
        codes[0] = abi.encodePacked(type(MugiIMDCrewFactory).creationCode, abi.encode(owner));
        codes[1] = abi.encodePacked(type(MugiV1IMDDeploymentFactory).creationCode, abi.encode(owner));
        codes[2] = abi.encodePacked(type(MugiIMDAccountingFactory).creationCode, abi.encode(owner));
        codes[3] = abi.encodePacked(type(MugiIMDEngineFactory).creationCode, abi.encode(owner));
    }
}
