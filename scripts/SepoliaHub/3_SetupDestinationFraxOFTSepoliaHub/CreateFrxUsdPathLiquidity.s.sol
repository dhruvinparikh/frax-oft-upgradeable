// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

/// @notice Creates the frxUSD/PATH pair (if missing) and seeds bid-side liquidity at tick 0.
/// @dev Run with PK_CONFIG_DEPLOYER set. Example:
/// forge script scripts/SepoliaHub/CreateFrxUsdPathLiquidity.s.sol \
///   --rpc-url https://rpc.testnet.tempo.xyz \
///   --broadcast
contract CreateFrxUsdPathLiquidity is Script {
    // frxUSD TIP20
    address internal constant TOKEN = 0x20C00000000000000000000000000000001116e8;

    // Liquidity to seed on bid side (escrows PATH and buys frxUSD at 1:1 tick 0)
    uint256 public constant LIQ_AMOUNT = 10e6; // 10 PATH_USD (6 decimals)

    function run() external {
        uint256 pk = vm.envUint("PK_CONFIG_DEPLOYER");
        vm.startBroadcast(pk);

        IStablecoinDEX dex = StdPrecompiles.STABLECOIN_DEX;

        // Ensure pair exists
        bytes32 key = dex.pairKey(TOKEN, StdTokens.PATH_USD_ADDRESS);
        (address base,,,) = dex.books(key);
        if (base == address(0)) {
            dex.createPair(TOKEN);
        }

        // Approve PATH to place bid liquidity
        ITIP20(StdTokens.PATH_USD_ADDRESS).approve(address(dex), LIQ_AMOUNT);

        // Place bid at tick 0 for LIQ_AMOUNT base (frxUSD) priced in PATH
        dex.place(TOKEN, uint128(LIQ_AMOUNT), true, 0);

        vm.stopBroadcast();
    }
}
