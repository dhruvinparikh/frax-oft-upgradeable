// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { OFTAdapterUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/OFTAdapterUpgradeable.sol";
import { OAppSenderUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/OAppSenderUpgradeable.sol";
import { SupplyTrackingModule } from "contracts/modules/SupplyTrackingModule.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { MessagingParams, MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Interface for EndpointV2Alt's nativeToken function
interface IEndpointV2Alt {
    function nativeToken() external view returns (address);
}

contract FraxOFTMintableAdapterUpgradeableTIP20 is OFTAdapterUpgradeable, SupplyTrackingModule {
    /// @notice Emitted when ERC20 tokens are recovered
    event RecoveredERC20(address indexed token, uint256 amount);

    constructor(address _token, address _lzEndpoint) OFTAdapterUpgradeable(_token, _lzEndpoint) {
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

    /// @inheritdoc OAppSenderUpgradeable
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
