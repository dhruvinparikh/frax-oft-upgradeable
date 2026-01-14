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
    address internal constant OFT_ADAPTER = 0x6A678cEfcA10d5bBe4638D27C671CE7d56865037;

    // Ethereum Sepolia EID
    uint32 internal constant DST_EID = 40161;

    // Amount to send (1 frxUSD with 6 decimals)
    uint256 internal constant AMOUNT = 1e6;

    // ISSUER_ROLE for TIP20 tokens
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    function run() external {
        vm.startBroadcast(configDeployerPK);

        address sender = msg.sender;

        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(TOKEN);

        // Add DEX liquidity for frxUSD <-> PATH_USD swaps (required for gas token swaps)
        addDexLiquidity();

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

        // 2. Quote the fee
        MessagingFee memory fee = IOFT(OFT_ADAPTER).quoteSend(sendParam, false);

        // 3. Approve the OFT adapter to spend tokens
        ITIP20(TOKEN).approve(OFT_ADAPTER, AMOUNT + fee.nativeFee);

        // 4. Send tokens cross-chain
        IOFT(OFT_ADAPTER).send{ value: fee.nativeFee }(sendParam, fee, sender);

        vm.stopBroadcast();
    }

    /// @notice Add liquidity to DEX for frxUSD <-> PATH_USD swaps
    /// @dev This allows users to pay gas fees with frxUSD token
    /// @dev Only creates pair if it doesn't exist, only adds liquidity if < 10 tokens
    function addDexLiquidity() internal {
        IStablecoinDEX dex = StdPrecompiles.STABLECOIN_DEX;

        // Check if pair exists by querying books
        bytes32 key = dex.pairKey(TOKEN, StdTokens.PATH_USD_ADDRESS);
        (address base, , , ) = dex.books(key);

        // Create DEX pair only if it doesn't exist
        if (base == address(0)) {
            dex.createPair(TOKEN);
        }

        // Check current liquidity at tick 0 (bid side)
        (, , uint128 totalLiquidity) = dex.getTickLevel(TOKEN, 0, true);

        // Only add liquidity if less than 10 TIP20 tokens (10e6 with 6 decimals)
        uint256 minLiquidity = 10e6;
        if (totalLiquidity < minLiquidity) {
            // Add liquidity: place bid order
            uint256 liquidityAmount = 100e6; // 100 PATH_USD (6 decimals)
            ITIP20(StdTokens.PATH_USD_ADDRESS).approve(address(dex), liquidityAmount);
            dex.place(TOKEN, uint128(liquidityAmount), true, 0);
        }
    }
}
