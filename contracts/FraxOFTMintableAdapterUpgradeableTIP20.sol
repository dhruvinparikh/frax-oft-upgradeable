// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { OFTAdapterUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/OFTAdapterUpgradeable.sol";
import { OAppSenderUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/OAppSenderUpgradeable.sol";
import { SupplyTrackingModule } from "contracts/modules/SupplyTrackingModule.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ILZEndpointDollar } from "contracts/interfaces/vendor/layerzero/ILZEndpointDollar.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IOFT, SendParam, OFTReceipt } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

contract FraxOFTMintableAdapterUpgradeableTIP20 is OFTAdapterUpgradeable, SupplyTrackingModule {
    error NativeTokenUnavailable();
    error OFTAltCore__msg_value_not_zero(uint256 _msg_value);
    error UnsupportedGasToken(address token);

    ILZEndpointDollar public immutable nativeToken;

    /// @notice Emitted when ERC20 tokens are recovered
    event RecoveredERC20(address indexed token, uint256 amount);

    constructor(address _token, address _lzEndpoint) OFTAdapterUpgradeable(_token, _lzEndpoint) {
        nativeToken = ILZEndpointDollar(IEndpointV2Alt(_lzEndpoint).nativeToken());
        _disableInitializers();
    }

    function version() public pure returns (string memory) {
        return "1.1.0";
    }

    /// @dev This method is called specifically when deploying a new OFT
    function initialize(address _delegate) external initializer {
        __OFTAdapter_init(_delegate);
        __Ownable_init();
        _transferOwnership(_delegate);
    }

    /// @notice Added to support tokens
    /// @param _tokenAddress The token to recover
    /// @param _tokenAmount The amount to recover
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        // Only the owner address can ever receive the recovery withdrawal
        SafeERC20.safeTransfer(IERC20(_tokenAddress), owner(), _tokenAmount);
        emit RecoveredERC20(_tokenAddress, _tokenAmount);
    }

    /// @notice Set the initial total supply for a given chain ID
    /// @dev added in v1.1.0
    function setInitialTotalSupply(uint32 _eid, uint256 _amount) external onlyOwner {
        _setInitialTotalSupply(_eid, _amount);
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

    /// @dev overrides OFTAdapterUpgradeable.sol to burn the tokens from the sender/track supply
    /// @dev added in v1.1.0
    function _debit(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        _addToTotalTransferTo(_dstEid, amountSentLD);

        ITIP20(address(innerToken)).transferFrom(msg.sender, address(this), amountSentLD);

        ITIP20(address(innerToken)).burn(amountSentLD);
    }

    /// @dev overrides OFTAdapterUpgradeable to mint the tokens to the sender/track supply
    /// @dev added in v1.1.0
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal override returns (uint256 amountReceivedLD) {
        _addToTotalTransferFrom(_srcEid, _amountLD);

        ITIP20(address(innerToken)).mint(_to, _amountLD);

        return _amountLD;
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

    /// @inheritdoc OAppSenderUpgradeable
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
