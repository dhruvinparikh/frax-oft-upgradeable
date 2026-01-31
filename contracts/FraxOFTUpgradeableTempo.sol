// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { FraxOFTUpgradeable } from "contracts/FraxOFTUpgradeable.sol";
import { OAppSenderUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/OAppSenderUpgradeable.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ILZEndpointDollar } from "contracts/interfaces/vendor/layerzero/ILZEndpointDollar.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IOFT, SendParam, OFTReceipt } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

/// @notice Tempo variant of FraxOFT that pays gas in ERC20 native token (via EndpointV2Alt)
contract FraxOFTUpgradeableTempo is FraxOFTUpgradeable {
    error NativeTokenUnavailable();
    error OFTAltCore__msg_value_not_zero(uint256 _msg_value);
    error UnsupportedGasToken(address token);

    ILZEndpointDollar public immutable nativeToken;

    constructor(address _lzEndpoint) FraxOFTUpgradeable(_lzEndpoint) {
        nativeToken = ILZEndpointDollar(IEndpointV2Alt(_lzEndpoint).nativeToken());
        _disableInitializers();
    }

    /// @inheritdoc IOFT
    /// @dev Overrides send to prevent msg.value being sent (EndpointV2Alt uses ERC20 for gas)
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable virtual override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        if (msg.value > 0) revert OFTAltCore__msg_value_not_zero(msg.value);

        // Debit tokens from sender
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        // Build message and options
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

        // Send via LayerZero
        msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

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

        if (fee.nativeFee == 0) return fee;

        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);

        // If userToken is whitelisted in LZEndpointDollar, no swap needed
        if (nativeToken.isWhitelistedToken(userToken)) {
            return fee;
        }

        // userToken is not whitelisted, check if PATH_USD is whitelisted
        if (!nativeToken.isWhitelistedToken(StdTokens.PATH_USD_ADDRESS)) {
            revert UnsupportedGasToken(userToken);
        }

        // Quote swap from userToken to PATH_USD
        fee.nativeFee = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
            tokenIn: userToken,
            tokenOut: StdTokens.PATH_USD_ADDRESS,
            amountOut: uint128(fee.nativeFee)
        });
    }

    /// @dev Handles gas payment for EndpointV2Alt which uses an ERC20 token as native.
    ///      If userToken is whitelisted in LZEndpointDollar, wraps directly.
    ///      Otherwise swaps to PATH_USD (if whitelisted) and wraps.
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        if (address(nativeToken) == address(0)) revert NativeTokenUnavailable();

        address userToken = StdPrecompiles.TIP_FEE_MANAGER.userTokens(msg.sender);

        // If userToken is whitelisted in LZEndpointDollar, wrap directly
        if (nativeToken.isWhitelistedToken(userToken)) {
            ITIP20(userToken).transferFrom(msg.sender, address(this), _nativeFee);
            ITIP20(userToken).approve(address(nativeToken), _nativeFee);
            nativeToken.wrap(userToken, address(endpoint), _nativeFee);
            return 0;
        }

        // userToken is not whitelisted, check if PATH_USD is whitelisted
        if (!nativeToken.isWhitelistedToken(StdTokens.PATH_USD_ADDRESS)) {
            revert UnsupportedGasToken(userToken);
        }

        // Swap userToken to PATH_USD, then wrap
        uint128 userTokenAmount = StdPrecompiles.STABLECOIN_DEX.quoteSwapExactAmountOut({
            tokenIn: userToken,
            tokenOut: StdTokens.PATH_USD_ADDRESS,
            amountOut: uint128(_nativeFee)
        });

        ITIP20(userToken).transferFrom(msg.sender, address(this), userTokenAmount);
        ITIP20(userToken).approve(address(StdPrecompiles.STABLECOIN_DEX), userTokenAmount);
        StdPrecompiles.STABLECOIN_DEX.swapExactAmountOut({
            tokenIn: userToken,
            tokenOut: StdTokens.PATH_USD_ADDRESS,
            amountOut: uint128(_nativeFee),
            maxAmountIn: userTokenAmount
        });

        // Wrap PATH_USD into LZEndpointDollar and send to endpoint
        ITIP20(StdTokens.PATH_USD_ADDRESS).approve(address(nativeToken), _nativeFee);
        nativeToken.wrap(StdTokens.PATH_USD_ADDRESS, address(endpoint), _nativeFee);

        return 0;
    }
}
