// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { FraxOFTUpgradeable } from "contracts/FraxOFTUpgradeable.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

/// @notice Tempo variant of FraxOFT that pays gas in PATH_USD (ERC20-native)
contract FraxOFTUpgradeableTempo is FraxOFTUpgradeable {
    constructor(address _lzEndpoint) FraxOFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    /// @dev Handles gas payment for EndpointV2Alt which uses PATH_USD ERC20 as native token.
    ///      Swaps user's TIP20 gas token to PATH_USD if needed, then transfers to endpoint.
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);

        if (userToken != StdTokens.PATH_USD_ADDRESS) {
            // Quote swap amount needed to receive exactly _nativeFee PATH_USD
            uint128 _userTokenAmount = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                tokenIn: userToken,
                tokenOut: StdTokens.PATH_USD_ADDRESS,
                amountOut: uint128(_nativeFee)
            });
            // Pull user's gas token and swap to PATH_USD
            ITIP20(userToken).transferFrom(msg.sender, address(this), _userTokenAmount);
            ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), _userTokenAmount);
            StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
                tokenIn: userToken,
                tokenOut: StdTokens.PATH_USD_ADDRESS,
                amountOut: uint128(_nativeFee),
                maxAmountIn: _userTokenAmount
            });
            // Transfer PATH_USD to endpoint (EndpointV2Alt._suppliedNative() checks its balance)
            StdTokens.PATH_USD.transfer(address(endpoint), _nativeFee);
        } else {
            // Pull PATH_USD directly from user to endpoint
            StdTokens.PATH_USD.transferFrom(msg.sender, address(endpoint), _nativeFee);
        }

        return 0;
    }
}
