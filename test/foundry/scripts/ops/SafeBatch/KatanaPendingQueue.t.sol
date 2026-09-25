// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Batch202609Katana} from "scripts/ops/SafeBatch/Batch202609/Batch202609Katana.sol";
import {SafeDelegateBatch} from "scripts/ops/SafeBatch/SafeDelegateBatch.sol";
import {OftConfigBatch} from "scripts/ops/SafeBatch/OftConfigBatch.sol";

interface ISafeQueue {
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

interface IEndpointRead {
    function getSendLibrary(address _sender, uint32 _eid) external view returns (address);
    function getReceiveLibrary(address _receiver, uint32 _eid) external view returns (address, bool);
}

interface IUlnRead {
    function getAppUlnConfig(address _oapp, uint32 _remoteEid) external view returns (OftConfigBatch.UlnConfig memory);
}

interface IHopRead {
    function numDVNs() external view returns (uint32);
}

interface IPeerRead {
    function peers(uint32 _eid) external view returns (bytes32);
}

/// @notice The Katana ops Safe is shared, and it is not idle: when this was written its on-chain
///         nonce was 21 with two executable proposals from an earlier campaign already sitting at 21
///         and 22, each with 2 of 3 confirmations. A Safe transaction is pinned to an exact nonce, so
///         ours runs only after both, and nonce 22 severs FPI -> Fraxtal — the same route this batch
///         severs.
///
///         That is why `Batch202609Katana._severFpiTowardFraxtal` guards the two calls that revert
///         `LZ_SameValue` on a second application. These tests pin the outcome in both futures, so
///         the batch does not depend on what the other campaign does:
///
///           - the other proposals execute first  -> our batch still executes, FRA-100 lands
///           - the other proposals are deleted    -> our batch executes, FRA-100 lands, FPI severed
///
///         The pending payloads are passed in rather than hardcoded, since they are live queue state
///         that can be executed or deleted at any time. Refresh from
///         `<tx-service>/v1/safes/<safe>/multisig-transactions/?executed=false`:
///
///           KATANA_PENDING_21_TO=… KATANA_PENDING_21_DATA=… KATANA_PENDING_21_OPERATION=0 \
///           KATANA_PENDING_22_TO=… KATANA_PENDING_22_DATA=… KATANA_PENDING_22_OPERATION=1 \
///             forge test --match-contract KatanaPendingQueueTest -vv
contract KatanaPendingQueueTest is Test {
    uint8 internal constant DELEGATECALL = 1;

    Batch202609Katana internal batch;
    ISafeQueue internal safe;

    function setUp() public {
        vm.createSelectFork("https://rpc.katana.network");
        // KATANA_BATCH exercises the DEPLOYED bytecode rather than a fresh compile of this source,
        // which is what the Safe will actually delegatecall.
        address deployed = vm.envOr("KATANA_BATCH", address(0));
        batch = deployed == address(0) ? new Batch202609Katana() : Batch202609Katana(deployed);
        require(address(batch).code.length > 0, "KATANA_BATCH has no code");
        safe = ISafeQueue(batch.safe());
    }

    /// @notice The case that used to break it: the other campaign lands first, so FPI -> Fraxtal is
    ///         already severed by the time our batch runs.
    function test_BatchStillExecutesAfterThePendingQueueDrains() public {
        if (vm.envOr("KATANA_PENDING_21_DATA", bytes("")).length == 0) {
            emit log("skipped: pass the pending payloads in as env vars (see the NatSpec)");
            return;
        }

        uint256 startNonce = safe.nonce();
        emit log_named_uint("Safe nonce at fork", startNonce);
        _execPending(21);
        _execPending(22);
        assertEq(safe.nonce(), startNonce + 2, "the pending queue did not drain to our nonce");

        // Precondition for this test to mean anything: the other campaign really did sever the route.
        assertEq(
            IEndpointRead(batch.endpoint()).getSendLibrary(batch.FPI_OFT(), batch.FRAXTAL_EID()),
            batch.blockedLibrary(),
            "expected the pending queue to have blocked FPI->Fraxtal"
        );

        assertTrue(_execBatch(), "the batch cannot execute once FPI->Fraxtal is already severed");
        _assertCampaignLanded();
    }

    /// @notice The other case: the pending proposals are dropped, so our batch does the sever itself.
    function test_BatchExecutesAndSeversIfThePendingQueueIsDropped() public {
        assertTrue(_execBatch(), "the batch failed from the current chain state");
        _assertCampaignLanded();
        assertEq(
            IEndpointRead(batch.endpoint()).getSendLibrary(batch.FPI_OFT(), batch.FRAXTAL_EID()),
            batch.blockedLibrary(),
            "FPI->Fraxtal send library was not blocked"
        );
        (, bool isDefault) = IEndpointRead(batch.endpoint()).getReceiveLibrary(batch.FPI_OFT(), batch.FRAXTAL_EID());
        assertTrue(isDefault, "FPI->Fraxtal receive library was not reset to default");
        assertEq(IPeerRead(batch.FPI_OFT()).peers(batch.FRAXTAL_EID()), bytes32(0), "FPI->Fraxtal peer was not cleared");
    }

    /// @dev What FRA-100 is for: five OFTs at five required DVNs each way, both live hops quoting the
    ///      return leg with five. Identical in both futures.
    function _assertCampaignLanded() internal {
        address[] memory ofts = batch.ofts();
        for (uint256 i = 0; i < ofts.length; i++) {
            assertEq(
                IUlnRead(batch.sendUln302()).getAppUlnConfig(ofts[i], batch.FRAXTAL_EID()).requiredDVNCount,
                5,
                "send-side required DVNs did not reach 5"
            );
            assertEq(
                IUlnRead(batch.receiveUln302()).getAppUlnConfig(ofts[i], batch.FRAXTAL_EID()).requiredDVNCount,
                5,
                "receive-side required DVNs did not reach 5"
            );
        }
        assertEq(IHopRead(batch.REMOTE_MINT_REDEEM_HOP()).numDVNs(), 5, "mint-redeem hop numDVNs did not reach 5");
        assertEq(IHopRead(batch.REMOTE_HOP_V2()).numDVNs(), 5, "HopV2 numDVNs did not reach 5");
    }

    function _execPending(uint256 which) internal {
        string memory prefix = string.concat("KATANA_PENDING_", vm.toString(which), "_");
        address to = vm.envAddress(string.concat(prefix, "TO"));
        bytes memory data = vm.envBytes(string.concat(prefix, "DATA"));
        uint8 operation = uint8(vm.envUint(string.concat(prefix, "OPERATION")));

        (bytes memory signatures, address executor) = _approve(to, data, operation);
        vm.prank(executor);
        bool ok =
            safe.execTransaction(to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures);
        assertTrue(ok, string.concat("pending nonce ", vm.toString(which), " failed to execute"));
        emit log_named_uint("executed pending nonce", which);
    }

    function _execBatch() internal returns (bool) {
        bytes memory data = abi.encodeCall(SafeDelegateBatch.execute, ());
        (bytes memory signatures, address executor) = _approve(address(batch), data, DELEGATECALL);
        vm.prank(executor);
        return safe.execTransaction(
            address(batch), 0, data, DELEGATECALL, 0, 0, 0, address(0), payable(address(0)), signatures
        );
    }

    function _approve(address to, bytes memory data, uint8 operation)
        internal
        returns (bytes memory signatures, address executor)
    {
        bytes32 txHash =
            safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), safe.nonce());
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
}
