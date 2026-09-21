// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SafeTxUtil, SerializedTx} from "scripts/SafeBatchSerialize.sol";
import {SafeDelegateBatch} from "../SafeDelegateBatch.sol";
import {MeshCleanupPlasma} from "./MeshCleanupPlasma.sol";
import {MeshCleanupBlast} from "./MeshCleanupBlast.sol";
import {MeshCleanupFraxtal} from "./MeshCleanupFraxtal.sol";
import {MeshCleanupEthereum} from "./MeshCleanupEthereum.sol";
import {MeshCleanupEthereumHop} from "./MeshCleanupEthereumHop.sol";
import {MeshCleanupArbitrum} from "./MeshCleanupArbitrum.sol";
import {MeshCleanupBase} from "./MeshCleanupBase.sol";
import {MeshCleanupSei} from "./MeshCleanupSei.sol";
import {MeshCleanupXLayer} from "./MeshCleanupXLayer.sol";

/// @dev `isContext` is newer than the pinned forge-std; call the cheatcode directly.
interface IForgeContext {
    function isContext(uint8 context) external view returns (bool);
}

/// @notice Deploys every MeshCleanup* SafeDelegateBatch that belongs to the broadcast chain (Ethereum
///         has two: the OFT-admin Safe and the Hop Safe are different Safes) and writes each Safe's
///         one-call payload — `execute()` with operation 1 / DELEGATECALL — to
///         txs/mesh-cleanup/Execute-<Contract>.json, the same way DeployFraxOFTProtocol writes its
///         batches. Deployment is CREATE2 through the canonical deployer proxy, so the address in
///         the payload is the address that is broadcast; the payload is only written under
///         --broadcast so a dry run can never leave a queueable file behind.
///
///         forge script scripts/ops/DeprecateChain/DeployMeshCleanup.s.sol \
///             --rpc-url <rpc> --sender <deployer> --gcp --broadcast --ffi
///         (--ffi: SafeTxUtil post-processes the JSON with sed, like every generator here.)
///
///         Verify (constructor-less, default profile), e.g.
///           forge verify-contract <addr> scripts/ops/DeprecateChain/MeshCleanupBlast.sol:MeshCleanupBlast \
///               --chain 81457 --etherscan-api-key $ETHERSCAN_API_KEY --watch
///           Plasma has no Etherscan: --verifier etherscan \
///               --verifier-url https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan \
///               --etherscan-api-key verifyContract
contract DeployMeshCleanup is Script {
    uint8 internal constant SCRIPT_BROADCAST = 6; // VmSafe.ForgeContext.ScriptBroadcast
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = keccak256("frax-lz-mesh-cleanup-2026-09");

    SafeDelegateBatch[] internal deployed;
    string[] internal names;

    /// @notice Use --sender / --gcp instead of a raw private key.
    function run() external {
        require(CREATE2_DEPLOYER.code.length != 0, "no CREATE2 deployer on this chain");
        vm.startBroadcast();
        if (block.chainid == 9745) _record(new MeshCleanupPlasma{salt: SALT}(), "MeshCleanupPlasma");
        else if (block.chainid == 81457) _record(new MeshCleanupBlast{salt: SALT}(), "MeshCleanupBlast");
        else if (block.chainid == 252) _record(new MeshCleanupFraxtal{salt: SALT}(), "MeshCleanupFraxtal");
        else if (block.chainid == 42161) _record(new MeshCleanupArbitrum{salt: SALT}(), "MeshCleanupArbitrum");
        else if (block.chainid == 8453) _record(new MeshCleanupBase{salt: SALT}(), "MeshCleanupBase");
        else if (block.chainid == 1329) _record(new MeshCleanupSei{salt: SALT}(), "MeshCleanupSei");
        else if (block.chainid == 196) _record(new MeshCleanupXLayer{salt: SALT}(), "MeshCleanupXLayer");
        else if (block.chainid == 1) {
            _record(new MeshCleanupEthereum{salt: SALT}(), "MeshCleanupEthereum");
            _record(new MeshCleanupEthereumHop{salt: SALT}(), "MeshCleanupEthereumHop");
        } else revert("no MeshCleanup batch for this chain");
        vm.stopBroadcast();

        // Payloads are written outside the broadcast (SafeTxUtil is a script helper, not a
        // contract to deploy) and only under --broadcast, so a dry run leaves no queueable file.
        bool broadcasting = IForgeContext(address(vm)).isContext(SCRIPT_BROADCAST);
        for (uint256 i = 0; i < deployed.length; i++) {
            if (broadcasting) _writePayload(deployed[i], names[i]);
            else console.log("dry run: payload not written for", names[i]);
        }
    }

    function _record(SafeDelegateBatch helper, string memory name) internal {
        require(address(helper).code.length != 0, "helper has no code");
        console.log("Deployed", name, "at", address(helper));
        console.log("  pinned Safe:", helper.safe());
        deployed.push(helper);
        names.push(name);
    }

    function _writePayload(SafeDelegateBatch helper, string memory name) internal {
        SerializedTx[] memory txs = new SerializedTx[](1);
        txs[0] = SerializedTx({
            name: string.concat(name, ".execute() [DELEGATECALL]"),
            to: address(helper),
            value: 0,
            data: abi.encodeCall(SafeDelegateBatch.execute, ())
        });
        string memory dir = string.concat(vm.projectRoot(), "/scripts/ops/DeprecateChain/txs/mesh-cleanup");
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/Execute-", name, ".json");
        new SafeTxUtil().writeTxs(txs, path, "1");
        console.log("  wrote", path);
    }
}
