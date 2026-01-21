// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";
import { IOFT, SendParam, MessagingFee } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

/// @title SendCrossChainScript
/// @notice Sends frxUSD cross-chain via LayerZero OFT
/// @dev Usage:
///   forge script scripts/SepoliaHub/4_SendFraxOFTSepoliaHub/SendFrxUSDTempoTestnetToSepolia \
///     --rpc-url https://rpc.testnet.tempo.xyz \
///     --broadcast \
///     --skip-simulation
contract SendFrxUSDTempoTestnetToSepolia is Script {
    uint256 public configDeployerPK = vm.envUint("PK_CONFIG_DEPLOYER");

    // Hardcoded TIP20 token address (frxUSD)
    address internal constant TOKEN = 0x20C00000000000000000000000000000001116e8;

    // frxUSD OFT adapter on Tempo testnet
    address internal constant OFT_ADAPTER = 0x8Ee7E00790c18f28B65BC4771F2a8273D88f2A54;

    // Ethereum Sepolia EID
    uint32 internal constant DST_EID = 40161;

    // Amount to send (1 frxUSD with 6 decimals)
    uint256 internal constant AMOUNT = 1e6;

    // ISSUER_ROLE for TIP20 tokens
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    function run() external {
        vm.startBroadcast(configDeployerPK);

        address sender = vm.addr(configDeployerPK);

        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(TOKEN);

        // 1. Build SendParam for cross-chain transfer
        SendParam memory sendParam = SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(sender))), // Send to self on destination
            amountLD: AMOUNT,
            minAmountLD: AMOUNT, // No slippage tolerance
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // 2. Quote the fee in the configured gas token (PATH_USD via TIP_FEE_MANAGER)
        MessagingFee memory fee = IOFT(OFT_ADAPTER).quoteSend(sendParam, false);

        // 3. Approve the OFT adapter to spend tokens
        ITIP20(TOKEN).approve(OFT_ADAPTER, AMOUNT + fee.nativeFee);

        // 4. Send tokens cross-chain, paying fees either in TIP20 or native
        IOFT(OFT_ADAPTER).send(sendParam, fee, sender);

        vm.stopBroadcast();
    }
}
