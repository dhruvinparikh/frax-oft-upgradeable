// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SafeTxUtil, SerializedTx} from "scripts/SafeBatchSerialize.sol";
import {SafeDelegateBatch} from "./SafeDelegateBatch.sol";

/// @dev `isContext` is newer than the pinned forge-std; call the cheatcode directly.
interface IForgeContext {
    function isContext(uint8 context) external view returns (bool);
}

/// @notice Deploys any SafeDelegateBatch by artifact name and writes the Safe's one-call payload —
///         `execute()`, operation 1 / DELEGATECALL — to scripts/ops/SafeBatch/txs/Execute-<name>.json,
///         the same way DeployFraxOFTProtocol writes its batches. Campaign-agnostic: nothing here
///         changes when a new batch is added.
///
///           BATCH=Batch202609Fraxtal forge script scripts/ops/SafeBatch/DeploySafeBatch.s.sol \
///               --rpc-url <rpc> --gcp --sender 0x54F9b12743A7DeeC0ea48721683cbebedC6E17bC --broadcast --ffi
///
///         Deployment goes through the canonical CREATE2 deployer proxy with a salt derived from the
///         batch name, so the simulated address is the broadcast address and a re-run is refused
///         (address already has code). The batch's `chainId()` must match the RPC and `safe()` must
///         be set, and the payload is only written under --broadcast so a dry run never leaves a
///         queueable file behind. --ffi: SafeTxUtil post-processes the JSON with sed.
///
///         Verify (no constructor args; <name> = contract, <addr> from the console):
///           Etherscan v2 (1, 252, 1329, 8453, 42161, 81457, 747474):
///             forge verify-contract <addr> scripts/ops/SafeBatch/Batch202609/<name>.sol:<name> \
///               --verifier-url "https://api.etherscan.io/v2/api?chainid=<id>" --etherscan-api-key $ETHERSCAN_API_KEY --watch
///           Plasma 9745 (Routescan):  --verifier etherscan \
///               --verifier-url https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan --etherscan-api-key verifyContract
///           X-Layer 196 (OKLink):     --verifier oklink \
///               --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER --etherscan-api-key $OKLINK_API_KEY
contract DeploySafeBatch is Script {
    uint8 internal constant SCRIPT_BROADCAST = 6; // VmSafe.ForgeContext.ScriptBroadcast
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Use --sender / --gcp instead of a raw private key.
    function run() external {
        string memory name = vm.envString("BATCH");
        bytes memory initCode = vm.getCode(string.concat(name, ".sol:", name));
        bytes32 salt = keccak256(bytes(name));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);
        require(CREATE2_DEPLOYER.code.length != 0, "no CREATE2 deployer on this chain");
        require(predicted.code.length == 0, "batch already deployed at the predicted address");

        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        require(ok && ret.length == 20, "CREATE2 deploy failed");
        address deployed = address(bytes20(ret));
        require(deployed == predicted && deployed.code.length != 0, "deployed address mismatch");

        SafeDelegateBatch batch = SafeDelegateBatch(deployed);
        require(batch.chainId() == block.chainid, "batch is for another chain");
        require(batch.safe() != address(0), "batch has no pinned Safe");
        console.log("Deployed", name, "at", deployed);
        console.log("  pinned Safe:", batch.safe());

        if (!IForgeContext(address(vm)).isContext(SCRIPT_BROADCAST)) {
            console.log("  dry run: payload not written");
            return;
        }
        SerializedTx[] memory txs = new SerializedTx[](1);
        txs[0] = SerializedTx({
            name: string.concat(name, ".execute() [DELEGATECALL]"),
            to: deployed,
            value: 0,
            data: abi.encodeCall(SafeDelegateBatch.execute, ())
        });
        string memory dir = string.concat(vm.projectRoot(), "/scripts/ops/SafeBatch/txs");
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/Execute-", name, ".json");
        new SafeTxUtil().writeTxs(txs, path, "1");
        console.log("  wrote", path);
    }
}
