// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
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

interface IFraxtalHubView {
    function remoteHop(uint32 _eid) external view returns (bytes32);
}

interface IOldHopV2View {
    function paused() external view returns (bool);
    function remoteHop(uint32 eid) external view returns (bytes32);
    function approvedOft(address oft) external view returns (bool);
    function numDVNs() external view returns (uint32);
    function executorOptions(uint32 eid) external view returns (bytes memory);
}

struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

interface IOFTQuote {
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view returns (MessagingFee memory);
}

interface ILegacyHopView {
    function paused() external view returns (bool);
    function fraxtalHop() external view returns (bytes32);
    function numDVNs() external view returns (uint256);
    function hopFee() external view returns (uint256);
    function approvedOft(address _oft) external view returns (bool);
    function executorOptions(uint32 _eid) external view returns (bytes memory);
}

/// @notice Generic harness for any SafeDelegateBatch: runs it through the REAL Safe on a fork as
///         one delegatecall transaction and pins the delegatecall-safety invariants. Subclasses
///         supply the fork, the helper and the before/after state checks.
abstract contract SafeDelegateBatchTest is Test {
    uint8 internal constant OPERATION_DELEGATECALL = 1;

    SafeDelegateBatch internal helper;

    function _assertBefore() internal virtual;
    function _assertAfter() internal virtual;

    function test_ExecutesAsOneSafeTx() public {
        _assertBefore();
        assertTrue(_execViaSafe(), "Safe execution failed");
        _assertAfter();
    }

    function test_SecondExecutionRevertsInsteadOfConsumingNonce() public {
        assertTrue(_execViaSafe(), "first execution failed");
        ISafe safe = ISafe(helper.safe());
        uint256 nonceAfterFirst = safe.nonce();
        (bytes memory data, bytes memory signatures, address executor) = _prepareSafeTx();
        // An inner revert (here LZ_SameValue on the already-blocked send library) surfaces as
        // GS013 because safeTxGas == 0, and the Safe nonce is left untouched.
        vm.expectRevert(bytes("GS013"));
        vm.prank(executor);
        safe.execTransaction(
            address(helper), 0, data, OPERATION_DELEGATECALL, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        assertEq(safe.nonce(), nonceAfterFirst, "nonce consumed by a failed replay");
    }

    function test_DirectCallReverts() public {
        vm.expectRevert(bytes("SafeDelegateBatch: must be delegatecalled by the pinned Safe"));
        helper.execute();
    }

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

    /// @dev First-generation HopV2 pre-state: live, registered, approved, holding whatever it holds.
    function _assertOldHopV2Live(address hop, uint32[] memory eids, address[] memory ofts) internal {
        assertFalse(IOldHopV2View(hop).paused(), "fork state drifted: old HopV2 already paused");
        for (uint256 i = 0; i < eids.length; i++) {
            assertTrue(IOldHopV2View(hop).remoteHop(eids[i]) != bytes32(0), "fork state drifted: registration gone");
        }
        for (uint256 i = 0; i < ofts.length; i++) {
            assertTrue(IOldHopV2View(hop).approvedOft(ofts[i]), "fork state drifted: OFT no longer approved");
        }
    }

    function _assertOldHopV2Shutdown(address hop, uint32[] memory eids, address[] memory ofts) internal {
        assertTrue(IOldHopV2View(hop).paused(), "old HopV2 not paused");
        for (uint256 i = 0; i < eids.length; i++) {
            assertEq(IOldHopV2View(hop).remoteHop(eids[i]), bytes32(0), "old HopV2 registration remains");
        }
        for (uint256 i = 0; i < ofts.length; i++) {
            assertFalse(IOldHopV2View(hop).approvedOft(ofts[i]), "old HopV2 OFT still approved");
        }
        assertEq(IOldHopV2View(hop).numDVNs(), 0, "old HopV2 numDVNs not zeroed");
        assertEq(IOldHopV2View(hop).executorOptions(30168).length, 0, "old HopV2 executor options remain");
        assertEq(hop.balance, 0, "old HopV2 balance not swept");
    }
}

/// @dev Shared LayerZero-config and hop assertions for OftConfigBatch campaigns.
abstract contract OftConfigBatchTest is SafeDelegateBatchTest {
    address internal endpoint;
    address internal blockedLibrary;
    address internal sendUln;
    address internal receiveUln;

    /// @dev Reads the chain constants off the batch under test.
    function _bind(OftConfigBatch batch) internal {
        helper = batch;
        endpoint = batch.endpoint();
        blockedLibrary = batch.blockedLibrary();
        sendUln = batch.sendUln302();
        receiveUln = batch.receiveUln302();
    }

    /// @dev The dirty state every severed route starts from: explicit libraries still in place.
    function _assertRouteDirty(address oft, uint32 eid, bool peerExpected) internal {
        assertEq(IOAppView(oft).peers(eid) != bytes32(0), peerExpected, "fork state drifted: peer");
        assertTrue(IEndpointView(endpoint).getSendLibrary(oft, eid) != blockedLibrary, "fork state drifted: already blocked");
        (, bool isDefaultReceive) = IEndpointView(endpoint).getReceiveLibrary(oft, eid);
        assertFalse(isDefaultReceive, "fork state drifted: receive lib already default");
    }

    function _assertRouteSevered(address oft, uint32 eid) internal {
        _assertRouteSevered(oft, eid, true);
    }

    function _assertRouteSevered(address oft, uint32 eid, bool enforcedOptionsCleared) internal {
        assertEq(IOAppView(oft).peers(eid), bytes32(0), "peer not cleared");
        assertEq(IEndpointView(endpoint).getSendLibrary(oft, eid), blockedLibrary, "send lib not blocked");
        (, bool isDefaultReceive) = IEndpointView(endpoint).getReceiveLibrary(oft, eid);
        assertTrue(isDefaultReceive, "receive lib not reset to default");
        if (enforcedOptionsCleared) {
            assertEq(IOAppView(oft).enforcedOptions(eid, 1), hex"0003", "msgType 1 enforced options not cleared");
            assertEq(IOAppView(oft).enforcedOptions(eid, 2), hex"0003", "msgType 2 enforced options not cleared");
        }
        _assertZeroUlnConfig(oft, eid);
    }

    function _assertZeroUlnConfig(address oft, uint32 eid) internal {
        _assertZeroUln(IUlnView(sendUln).getAppUlnConfig(oft, eid), "send ULN app config not zeroed");
        _assertZeroUln(IUlnView(receiveUln).getAppUlnConfig(oft, eid), "receive ULN app config not zeroed");
    }

    function _assertZeroUln(OftConfigBatch.UlnConfig memory cfg, string memory err) internal {
        assertTrue(
            cfg.confirmations == 0 && cfg.requiredDVNCount == 0 && cfg.optionalDVNCount == 0
                && cfg.optionalDVNThreshold == 0 && cfg.requiredDVNs.length == 0 && cfg.optionalDVNs.length == 0,
            err
        );
    }

    function _assertHopRetired(address hop) internal {
        assertTrue(ILegacyHopView(hop).paused(), "hop not paused");
        assertEq(ILegacyHopView(hop).fraxtalHop(), bytes32(0), "fraxtalHop not cleared");
        assertEq(ILegacyHopView(hop).numDVNs(), 0, "numDVNs not zeroed");
        assertEq(ILegacyHopView(hop).hopFee(), 0, "hopFee not zeroed");
    }

    uint32 internal constant ETHEREUM_LEGACY_EID = 30101;
    /// @dev Receive library per legacy (oft, eid) before execution; must be byte-identical after.
    mapping(address => mapping(uint32 => address)) internal legacyReceiveLibBefore;

    /// @dev Legacy spoke lanes before: peered and open toward both other spokes and Ethereum.
    function _assertLegacyLanesOpen(OftConfigBatch batch, uint32 spokeA, uint32 spokeB) internal {
        address[] memory ofts = batch.legacyOfts();
        for (uint256 i = 0; i < ofts.length; i++) {
            uint32[3] memory eids = [spokeA, spokeB, ETHEREUM_LEGACY_EID];
            for (uint256 j = 0; j < 3; j++) {
                assertTrue(IOAppView(ofts[i]).peers(eids[j]) != bytes32(0), "fork state drifted: legacy peer gone");
                assertTrue(IEndpointView(endpoint).getSendLibrary(ofts[i], eids[j]) != blockedLibrary, "fork state drifted: already blocked");
                (legacyReceiveLibBefore[ofts[i]][eids[j]],) = IEndpointView(endpoint).getReceiveLibrary(ofts[i], eids[j]);
            }
        }
    }

    /// @dev Legacy spoke lanes after: send blocked toward the two spokes ONLY; the Ethereum exit,
    ///      every peer and the receive libraries are exactly as before.
    function _assertLegacySpokeLanesBlocked(OftConfigBatch batch, uint32 spokeA, uint32 spokeB) internal {
        address[] memory ofts = batch.legacyOfts();
        for (uint256 i = 0; i < ofts.length; i++) {
            assertEq(IEndpointView(endpoint).getSendLibrary(ofts[i], spokeA), blockedLibrary, "spoke lane A not blocked");
            assertEq(IEndpointView(endpoint).getSendLibrary(ofts[i], spokeB), blockedLibrary, "spoke lane B not blocked");
            assertTrue(IEndpointView(endpoint).getSendLibrary(ofts[i], ETHEREUM_LEGACY_EID) != blockedLibrary, "Ethereum exit lane blocked");
            uint32[3] memory eids = [spokeA, spokeB, ETHEREUM_LEGACY_EID];
            for (uint256 j = 0; j < 3; j++) {
                assertTrue(IOAppView(ofts[i]).peers(eids[j]) != bytes32(0), "legacy peer must stay set");
                (address receiveLib,) = IEndpointView(endpoint).getReceiveLibrary(ofts[i], eids[j]);
                assertEq(receiveLib, legacyReceiveLibBefore[ofts[i]][eids[j]], "legacy receive lib changed");
            }
        }
    }

    /// @dev Retirement pre-state: peered, nothing blocked yet.
    function _assertRoutesLive(address oft, uint32[] memory eids) internal {
        for (uint256 i = 0; i < eids.length; i++) {
            assertTrue(IOAppView(oft).peers(eids[i]) != bytes32(0), "fork state drifted: peer gone");
            assertTrue(IEndpointView(endpoint).getSendLibrary(oft, eids[i]) != blockedLibrary, "fork state drifted: send already blocked");
            (address receiveLib,) = IEndpointView(endpoint).getReceiveLibrary(oft, eids[i]);
            assertTrue(receiveLib != blockedLibrary, "fork state drifted: receive already blocked");
        }
    }

    /// @dev Retirement post-state (the 2026-08-26 shape): no peer, send and receive both blocked.
    function _assertRoutesRetired(address oft, uint32[] memory eids) internal {
        for (uint256 i = 0; i < eids.length; i++) {
            assertEq(IOAppView(oft).peers(eids[i]), bytes32(0), "peer not cleared");
            assertEq(IEndpointView(endpoint).getSendLibrary(oft, eids[i]), blockedLibrary, "send not blocked");
            (address receiveLib,) = IEndpointView(endpoint).getReceiveLibrary(oft, eids[i]);
            assertEq(receiveLib, blockedLibrary, "receive not blocked");
        }
    }

    function _three(uint32 a, uint32 b, uint32 c) internal pure returns (uint32[] memory eids) {
        eids = new uint32[](3);
        (eids[0], eids[1], eids[2]) = (a, b, c);
    }

    /// @dev Required-DVN set of (oft, eid) on both ULN302 libraries, with confirmations untouched.
    function _assertRequiredDvns(address oft, uint32 eid, address[] memory dvns, uint64 sendConf, uint64 recvConf) internal {
        OftConfigBatch.UlnConfig memory cs = IUlnView(sendUln).getAppUlnConfig(oft, eid);
        OftConfigBatch.UlnConfig memory cr = IUlnView(receiveUln).getAppUlnConfig(oft, eid);
        assertEq(cs.confirmations, sendConf, "send confirmations changed");
        assertEq(cr.confirmations, recvConf, "receive confirmations changed");
        assertEq(cs.requiredDVNs.length, dvns.length, "send DVN count");
        assertEq(cr.requiredDVNs.length, dvns.length, "receive DVN count");
        for (uint256 i = 0; i < dvns.length; i++) {
            assertEq(cs.requiredDVNs[i], dvns[i], "send DVN set");
            assertEq(cr.requiredDVNs[i], dvns[i], "receive DVN set");
        }
        assertEq(cs.optionalDVNCount, type(uint8).max, "send optional DVNs must stay NIL");
        assertEq(cr.optionalDVNCount, type(uint8).max, "receive optional DVNs must stay NIL");
    }

    /// @dev Every configured DVN must price the path, or the lane is dead after the change.
    function _assertQuotes(address oft, uint32 eid) internal {
        SendParam memory p = SendParam({
            dstEid: eid,
            to: bytes32(uint256(uint160(address(0xBEEF)))),
            amountLD: 1e18,
            minAmountLD: 0,
            extraOptions: hex"0003",
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory fee = IOFTQuote(oft).quoteSend(p, false);
        assertTrue(fee.nativeFee > 0, "quoteSend returned no fee");
    }
}
