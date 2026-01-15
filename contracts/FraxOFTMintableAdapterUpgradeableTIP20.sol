// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { OFTAdapterUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/OFTAdapterUpgradeable.sol";
import { OAppSenderUpgradeable } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/OAppSenderUpgradeable.sol";
import { SupplyTrackingModule } from "contracts/modules/SupplyTrackingModule.sol";
import { ITIP20 } from "@tempo/interfaces/ITIP20.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { MessagingParams, MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract FraxOFTMintableAdapterUpgradeableTIP20 is OFTAdapterUpgradeable, SupplyTrackingModule {
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

    /// @notice Recover all tokens to owner
    /// @dev added in v1.1.0
    function recover() external onlyOwner {
        uint256 balance = innerToken.balanceOf(address(this));
        if (balance == 0) return;

        innerToken.transfer(owner(), balance);
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

    /// @inheritdoc OAppSenderUpgradeable
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
        } else {
            // Pull PATH_USD directly from user
            StdTokens.PATH_USD.transferFrom(msg.sender, address(this), _nativeFee);
        }

        // Transfer PATH_USD to endpoint (EndpointV2Alt._suppliedNative() checks its balance)
        StdTokens.PATH_USD.transfer(address(endpoint), _nativeFee);
        return 0;
    }
}
