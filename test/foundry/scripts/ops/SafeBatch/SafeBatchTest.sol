// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeDelegateBatch} from "scripts/ops/SafeBatch/SafeDelegateBatch.sol";
import {OftConfigBatch} from "scripts/ops/SafeBatch/OftConfigBatch.sol";

interface ISafe {
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

interface IEndpointView {
    function getSendLibrary(address _sender, uint32 _eid) external view returns (address);
    function getReceiveLibrary(address _receiver, uint32 _eid) external view returns (address, bool);
}

interface IOAppView {
    function peers(uint32 _eid) external view returns (bytes32);
    function enforcedOptions(uint32 _eid, uint16 _msgType) external view returns (bytes memory);
}

interface IUlnView {
    function getAppUlnConfig(address _oapp, uint32 _remoteEid)
        external
        view
        returns (OftConfigBatch.UlnConfig memory);
}

/// @notice Pre-flight harness for a SafeDelegateBatch: runs it through the REAL Safe on a fork as one
///         delegatecall and pins the safety envelope — it executes without reverting (so no route has
///         drifted into LZ_SameValue), it writes storage only to the accounts it declares, it changes
///         only the LayerZero routes it declares (everything else on the chain, the canonical mesh
///         included, stays byte-identical), a replay reverts instead of burning a Safe nonce, and its
///         runtime code holds no opcode that could corrupt the Safe through delegatecall.
///
///         This is campaign tooling: delete the per-campaign suites once their batches have executed,
///         since their pre-state assumptions are true only until then.
abstract contract SafeBatchTest is Test {
    uint8 internal constant OPERATION_DELEGATECALL = 1;

    SafeDelegateBatch internal helper;
    address internal endpoint;
    address internal sendUln;
    address internal receiveUln;

    /// @dev Reads the chain constants off the batch under test.
    function _bind(OftConfigBatch batch) internal {
        helper = batch;
        endpoint = batch.endpoint();
        sendUln = batch.sendUln302();
        receiveUln = batch.receiveUln302();
    }

    /// @dev Accounts this batch may write storage to; its Safe is allowed implicitly.
    function _expectedWriteAccounts() internal virtual returns (address[] memory);

    /// @dev OFTs whose every route is fingerprinted before/after. Empty = skip the route audit
    ///      (batches that touch no LayerZero config).
    function _auditedOfts() internal virtual returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Routes this batch may change, as (oft, eid).
    function _isExpectedRoute(address, uint32) internal virtual returns (bool) {
        return false;
    }

    /// @notice Executes, then proves nothing outside the declared accounts had storage written.
    function test_WritesOnlyToExpectedAccounts() public {
        address[] memory expected = _expectedWriteAccounts();

        vm.startStateDiffRecording();
        assertTrue(_execViaSafe(), "Safe execution failed");
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].reverted) continue;
            for (uint256 j = 0; j < accesses[i].storageAccesses.length; j++) {
                Vm.StorageAccess memory sa = accesses[i].storageAccesses[j];
                if (!sa.isWrite || sa.reverted || sa.previousValue == sa.newValue) continue;
                bool ok = sa.account == helper.safe();
                for (uint256 k = 0; k < expected.length && !ok; k++) {
                    ok = sa.account == expected[k];
                }
                if (!ok) {
                    emit log_named_address("unexpected storage write to", sa.account);
                    fail();
                }
            }
        }
    }

    /// @notice Executes, then proves every route it did not declare — the canonical mesh included —
    ///         is byte-identical: peer, send library, receive library, enforced options, ULN config.
    function test_ChangesOnlyExpectedRoutes() public {
        address[] memory ofts = _auditedOfts();
        if (ofts.length == 0) return;
        uint32[] memory eids = _meshEids();

        bytes32[][] memory before = new bytes32[][](ofts.length);
        for (uint256 i = 0; i < ofts.length; i++) {
            before[i] = new bytes32[](eids.length);
            for (uint256 j = 0; j < eids.length; j++) {
                before[i][j] = _routeFingerprint(ofts[i], eids[j]);
            }
        }

        assertTrue(_execViaSafe(), "Safe execution failed");

        uint256 changed;
        for (uint256 i = 0; i < ofts.length; i++) {
            for (uint256 j = 0; j < eids.length; j++) {
                if (_routeFingerprint(ofts[i], eids[j]) == before[i][j]) continue;
                changed++;
                if (!_isExpectedRoute(ofts[i], eids[j])) {
                    emit log_named_address("unexpected route change on OFT", ofts[i]);
                    emit log_named_uint("  eid", eids[j]);
                    fail();
                }
            }
        }
        assertTrue(changed > 0, "batch changed no route at all");
        emit log_named_uint("routes changed (all declared)", changed);
    }

    /// @notice A re-queued batch reverts (GS013, safeTxGas == 0) instead of consuming a Safe nonce.
    function test_SecondExecutionRevertsInsteadOfConsumingNonce() public {
        assertTrue(_execViaSafe(), "first execution failed");
        ISafe safe = ISafe(helper.safe());
        uint256 nonceAfterFirst = safe.nonce();
        (bytes memory data, bytes memory signatures, address executor) = _prepareSafeTx();
        vm.expectRevert(bytes("GS013"));
        vm.prank(executor);
        safe.execTransaction(
            address(helper), 0, data, OPERATION_DELEGATECALL, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        assertEq(safe.nonce(), nonceAfterFirst, "nonce consumed by a failed replay");
    }

    /// @notice The delegatecall-safety invariant: the batch cannot touch the Safe's own storage.
    function test_NoStorageOrDangerousOpcodesInExecutableCode() public {
        bytes memory code = address(helper).code;
        uint256 cborLength = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        uint256 executableEnd = code.length - 2 - cborLength;
        for (uint256 i; i < executableEnd; i++) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0x54 && op != 0x55, "SLOAD/SSTORE in delegatecall target");
            assertTrue(op != 0x5c && op != 0x5d, "TLOAD/TSTORE in delegatecall target");
            assertTrue(op != 0xf0 && op != 0xf5, "CREATE in delegatecall target");
            assertTrue(op != 0xf2 && op != 0xf4, "CALLCODE/DELEGATECALL in delegatecall target");
            assertTrue(op != 0xff, "SELFDESTRUCT in delegatecall target");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f; // skip PUSH data
        }
    }

    function _execViaSafe() internal returns (bool) {
        (bytes memory data, bytes memory signatures, address executor) = _prepareSafeTx();
        vm.prank(executor);
        return ISafe(helper.safe()).execTransaction(
            address(helper), 0, data, OPERATION_DELEGATECALL, 0, 0, 0, address(0), payable(address(0)), signatures
        );
    }

    /// @dev Threshold owners pre-approve the hash and sign with the v == 1 "approved hash" type,
    ///      which is what the Safe UI submits once each hardware wallet has confirmed.
    function _prepareSafeTx() internal returns (bytes memory data, bytes memory signatures, address executor) {
        ISafe safe = ISafe(helper.safe());
        data = abi.encodeCall(SafeDelegateBatch.execute, ());
        bytes32 txHash = safe.getTransactionHash(
            address(helper), 0, data, OPERATION_DELEGATECALL, 0, 0, 0, address(0), address(0), safe.nonce()
        );
        address[] memory owners = safe.getOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            for (uint256 j = i + 1; j < owners.length; j++) {
                if (owners[j] < owners[i]) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        for (uint256 i = 0; i < safe.getThreshold(); i++) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
            signatures = abi.encodePacked(signatures, bytes32(uint256(uint160(owners[i]))), bytes32(0), uint8(1));
        }
        executor = owners[0];
    }

    /// @dev Every eid in the Frax mesh: the proxy chains, the legacy four and the non-EVM three.
    function _meshEids() internal pure returns (uint32[] memory eids) {
        uint32[33] memory list = [
            uint32(30101), 30102, 30106, 30108, 30109, 30110, 30111, 30151, 30158, 30165, 30168,
            30183, 30184, 30211, 30214, 30243, 30255, 30260, 30274, 30280, 30319, 30320, 30324,
            30325, 30332, 30339, 30362, 30367, 30370, 30375, 30380, 30383, 30390
        ];
        eids = new uint32[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            eids[i] = list[i];
        }
    }

    function _routeFingerprint(address oft, uint32 eid) internal view returns (bytes32) {
        bytes32 peer;
        try IOAppView(oft).peers(eid) returns (bytes32 p) {
            peer = p;
        } catch {}
        address sendLib;
        try IEndpointView(endpoint).getSendLibrary(oft, eid) returns (address l) {
            sendLib = l;
        } catch {}
        address recvLib;
        bool recvDefault;
        try IEndpointView(endpoint).getReceiveLibrary(oft, eid) returns (address l, bool d) {
            (recvLib, recvDefault) = (l, d);
        } catch {}
        bytes memory eo1;
        bytes memory eo2;
        try IOAppView(oft).enforcedOptions(eid, 1) returns (bytes memory e) {
            eo1 = e;
        } catch {}
        try IOAppView(oft).enforcedOptions(eid, 2) returns (bytes memory e) {
            eo2 = e;
        } catch {}
        bytes memory ulnSend;
        bytes memory ulnRecv;
        try IUlnView(sendUln).getAppUlnConfig(oft, eid) returns (OftConfigBatch.UlnConfig memory c) {
            ulnSend = abi.encode(c);
        } catch {}
        try IUlnView(receiveUln).getAppUlnConfig(oft, eid) returns (OftConfigBatch.UlnConfig memory c) {
            ulnRecv = abi.encode(c);
        } catch {}
        return keccak256(abi.encode(peer, sendLib, recvLib, recvDefault, eo1, eo2, ulnSend, ulnRecv));
    }
}
