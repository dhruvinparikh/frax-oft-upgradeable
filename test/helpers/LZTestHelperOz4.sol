// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { MessagingFee, MessagingReceipt, MessagingParams } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Minimal OZ4-compatible EndpointV2Alt mock (ERC20 native) for tests
contract EndpointV2AltMockOz4 {
    uint32 public immutable eid;
    uint64 public nonce;
    uint256 public lastNativeFee;
    mapping(address => address) public delegates;

    address public immutable nativeErc20;

    constructor(uint32 _eid, address _altToken) {
        eid = _eid;
        nativeErc20 = _altToken;
    }

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        require(msg.value == 0, "LZ_OnlyAltToken");
        nonce++;
        lastNativeFee = ITIP20(nativeErc20).balanceOf(address(this));
        return
            MessagingReceipt({
                guid: bytes32(uint256(nonce)),
                nonce: nonce,
                fee: MessagingFee({ nativeFee: lastNativeFee, lzTokenFee: 0 })
            });
    }

    function nativeToken() external view returns (address) {
        return nativeErc20;
    }
}

/// @notice Lightweight helper to deploy alt endpoints without touching prod contracts
contract LZTestHelperOz4 is Test {
    function createAltEndpoint(uint32 _eid, address _altToken) public returns (EndpointV2AltMockOz4 ep) {
        ep = new EndpointV2AltMockOz4(_eid, _altToken);
    }
}
