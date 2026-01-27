// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { FraxOFTUpgradeable } from "contracts/FraxOFTUpgradeable.sol";
import { OAppSenderUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/OAppSenderUpgradeable.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

/// @notice Tempo variant of FraxOFT that pays gas in ERC20 native token (via EndpointV2Alt)
contract FraxOFTUpgradeableTempo is FraxOFTUpgradeable {
    constructor(address _lzEndpoint) FraxOFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    /// @dev Returns the native ERC20 token used by the endpoint for gas payment
    function _endpointNativeToken() internal view returns (address) {
        return IEndpointV2Alt(address(endpoint)).nativeToken();
    }

    /// @inheritdoc OAppSenderUpgradeable
    /// @dev Overrides _quote to return the fee in the user's TIP20 token instead of the endpoint's native token.
    ///      This allows users to get an accurate quote for their gas token.
    function _quote(
        uint32 _dstEid,
        bytes memory _message,
        bytes memory _options,
        bool _payInLzToken
    ) internal view virtual override returns (MessagingFee memory fee) {
        // Get the base quote in endpoint native token terms
        fee = super._quote(_dstEid, _message, _options, _payInLzToken);

        // Convert nativeFee from endpoint native token to user's token if different
        address endpointNative = _endpointNativeToken();
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);
        if (userToken != endpointNative && fee.nativeFee > 0) {
            fee.nativeFee = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                tokenIn: userToken,
                tokenOut: endpointNative,
                amountOut: uint128(fee.nativeFee)
            });
        }
    }

    /// @dev Handles gas payment for EndpointV2Alt which uses an ERC20 token as native.
    ///      Swaps user's TIP20 gas token to the endpoint's native token if needed, then transfers to endpoint.
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        address endpointNative = _endpointNativeToken();
        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);

        if (userToken != endpointNative) {
            // Quote swap amount needed to receive exactly _nativeFee of endpoint native token
            uint128 _userTokenAmount = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
                tokenIn: userToken,
                tokenOut: endpointNative,
                amountOut: uint128(_nativeFee)
            });
            // Pull user's gas token and swap to endpoint native token
            ITIP20(userToken).transferFrom(msg.sender, address(this), _userTokenAmount);
            ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), _userTokenAmount);
            StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
                tokenIn: userToken,
                tokenOut: endpointNative,
                amountOut: uint128(_nativeFee),
                maxAmountIn: _userTokenAmount
            });
            // Transfer endpoint native token to endpoint (EndpointV2Alt._suppliedNative() checks its balance)
            ITIP20(endpointNative).transfer(address(endpoint), _nativeFee);
        } else {
            // Pull endpoint native token directly from user to endpoint
            ITIP20(endpointNative).transferFrom(msg.sender, address(endpoint), _nativeFee);
        }

        return 0;
    }
}
