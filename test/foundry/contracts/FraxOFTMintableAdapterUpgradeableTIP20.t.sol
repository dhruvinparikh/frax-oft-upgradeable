// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { FraxOFTMintableAdapterUpgradeableTIP20 } from "contracts/FraxOFTMintableAdapterUpgradeableTIP20.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { TransparentUpgradeableProxy } from "@fraxfinance/layerzero-v2-upgradeable/messagelib/contracts/upgradeable/proxy/TransparentUpgradeableProxy.sol";
import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SendParam, OFTReceipt } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";
import { TempoTestHelpers } from "test/foundry/helpers/TempoTestHelpers.sol";



/// @title FraxOFTMintableAdapterUpgradeableTIP20 Unit Tests
/// @dev Only LZ endpoint is mocked; Tempo precompiles are real
contract FraxOFTMintableAdapterUpgradeableTIP20Test is TempoTestHelpers {
    using OptionsBuilder for bytes;
    
    FraxOFTMintableAdapterUpgradeableTIP20 adapter;
    ITIP20 frxUsdToken;
    
    address proxyAdmin = address(0x9999);
    address contractOwner = address(this);
    address lzEndpoint = address(0x1234);
    
    address alice = vm.addr(0x41);
    address bob = vm.addr(0xb0b);
    
    // LayerZero EID constants
    uint32 constant SRC_EID = 30252; // Example: Tempo EID
    uint32 constant DST_EID = 30101; // Example: Ethereum EID
    
    function setUp() external {
        // Create TIP20 token with DEX pair
        frxUsdToken = _createTIP20WithDexPair("Frax USD", "frxUSD", keccak256("frxUSD-salt"));
        
        // Grant PATH_USD minting for liquidity provider
        _grantPathUsdIssuerRole(address(this));
        
        // Mock LZ endpoint
        vm.etch(lzEndpoint, hex"00");
        vm.mockCall(lzEndpoint, abi.encodeWithSignature("eid()"), abi.encode(SRC_EID));
        
        // Deploy implementation
        FraxOFTMintableAdapterUpgradeableTIP20 implementation = 
            new FraxOFTMintableAdapterUpgradeableTIP20(address(frxUsdToken), lzEndpoint);
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            FraxOFTMintableAdapterUpgradeableTIP20.initialize.selector,
            contractOwner
        );
        
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdmin,
            initData
        );
        
        adapter = FraxOFTMintableAdapterUpgradeableTIP20(address(proxy));
        
        // Grant ISSUER_ROLE to adapter
        _grantIssuerRole(address(frxUsdToken), address(adapter));
    }
    
    // ---------------------------------------------------
    // LayerZero Test Helpers
    // ---------------------------------------------------
    
    /// @dev Setup peer for destination chain
    function _setupPeer() internal {
        bytes32 peer = bytes32(uint256(uint160(address(0xDEAD))));
        adapter.setPeer(DST_EID, peer);
    }
    
    /// @dev Mock LZ endpoint send call
    function _mockLzEndpointSend(uint256 nativeFee) internal {
        vm.mockCall(
            lzEndpoint,
            abi.encodeWithSignature("send((uint32,bytes32,bytes,bytes,bool),address)"),
            abi.encode(MessagingReceipt({
                guid: bytes32(0),
                nonce: 1,
                fee: MessagingFee({ nativeFee: nativeFee, lzTokenFee: 0 })
            }))
        );
    }
    
    /// @dev Build a standard SendParam for tests
    function _buildSendParam(uint256 sendAmount) internal view returns (SendParam memory) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        return SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(bob))),
            amountLD: sendAmount,
            minAmountLD: sendAmount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
    }
    
    /// @dev Execute adapter.send with standard parameters
    function _executeSend(address sender, uint256 sendAmount, uint256 nativeFee) internal {
        SendParam memory sendParam = _buildSendParam(sendAmount);
        vm.deal(sender, nativeFee);
        vm.prank(sender);
        adapter.send{value: nativeFee}(
            sendParam,
            MessagingFee({ nativeFee: nativeFee, lzTokenFee: 0 }),
            sender
        );
    }
    
    // ---------------------------------------------------
    // Version Tests
    // ---------------------------------------------------
    
    function test_Version_returnsExpected() external {
        assertEq(adapter.version(), "1.1.0");
    }
    
    // ---------------------------------------------------
    // Token/Owner Tests  
    // ---------------------------------------------------
    
    function test_Token_returnsExpected() external {
        assertEq(adapter.token(), address(frxUsdToken));
    }
    
    function test_Owner_returnsExpected() external {
        assertEq(adapter.owner(), contractOwner);
    }
    
    // ---------------------------------------------------
    // Supply Tracking Tests
    // ---------------------------------------------------
    
    function test_SetInitialTotalSupply_succeeds() external {
        uint256 initialSupply = 1_000_000e6;
        
        adapter.setInitialTotalSupply(DST_EID, initialSupply);
        
        assertEq(adapter.initialTotalSupply(DST_EID), initialSupply);
        assertEq(adapter.totalTransferTo(DST_EID), 0);
    }
    
    function test_SetInitialTotalSupply_OnlyOwner() external {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setInitialTotalSupply(DST_EID, 1_000_000e6);
    }
    
    // ---------------------------------------------------
    // Recovery Tests
    // ---------------------------------------------------
    
    function test_Recover_transfersTokensToOwner() external {
        uint256 stuckBalance = 100e6;
        
        frxUsdToken.mint(address(adapter), stuckBalance);
        
        uint256 ownerBalanceBefore = frxUsdToken.balanceOf(contractOwner);
        
        adapter.recover();
        
        assertEq(frxUsdToken.balanceOf(contractOwner), ownerBalanceBefore + stuckBalance);
        assertEq(frxUsdToken.balanceOf(address(adapter)), 0);
    }
    
    function test_Recover_noopWhenBalanceZero() external {
        uint256 ownerBalanceBefore = frxUsdToken.balanceOf(contractOwner);
        
        adapter.recover();
        
        assertEq(frxUsdToken.balanceOf(contractOwner), ownerBalanceBefore);
    }
    
    // ---------------------------------------------------
    // _lzSend TIP20 Gas Token Swap Tests
    // ---------------------------------------------------
    
    /// @dev When user's gas token is innerToken, swap to PATH_USD should occur
    function test_LzSend_SwapsInnerTokenToPathUsd_WhenUserGasTokenIsInnerToken() external {
        uint256 sendAmount = 100e6;
        uint256 nativeFee = 20_000e6; // Must be >= MIN_ORDER_AMOUNT (10_000e6)
        
        _setUserGasToken(alice, address(frxUsdToken));
        frxUsdToken.mint(alice, sendAmount + nativeFee);
        _addDexLiquidity(address(frxUsdToken), nativeFee * 2);
        _setupPeer();
        
        vm.prank(alice);
        frxUsdToken.approve(address(adapter), type(uint256).max);
        
        _mockLzEndpointSend(nativeFee);
        
        uint256 aliceBalanceBefore = frxUsdToken.balanceOf(alice);
        _executeSend(alice, sendAmount, nativeFee);
        
        // _debit pulls sendAmount, _lzSend pulls nativeFee for swap
        assertEq(frxUsdToken.balanceOf(alice), aliceBalanceBefore - sendAmount - nativeFee);
    }
    
    /// @dev When user's gas token is PATH_USD, no swap should occur
    function test_LzSend_NoSwap_WhenUserGasTokenIsPathUsd() external {
        uint256 sendAmount = 100e6;
        uint256 nativeFee = 10e6;
        
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
        frxUsdToken.mint(alice, sendAmount);
        _setupPeer();
        
        vm.prank(alice);
        frxUsdToken.approve(address(adapter), type(uint256).max);
        
        _mockLzEndpointSend(nativeFee);
        
        uint256 aliceBalanceBefore = frxUsdToken.balanceOf(alice);
        _executeSend(alice, sendAmount, nativeFee);
        
        // No gas token deducted from alice's frxUSD (only sendAmount for _debit)
        assertEq(frxUsdToken.balanceOf(alice), aliceBalanceBefore - sendAmount);
    }

    /// @dev When user's gas token is any TIP20 (not PATH_USD), swap to PATH_USD should occur
    function test_LzSend_SwapsAnyTip20ToPathUsd() external {
        // Create another TIP20 token for gas payment
        ITIP20 otherToken = ITIP20(ITIP20Factory(address(StdPrecompiles.TIP20_FACTORY)).createToken(
            "Other Token",
            "OTHER",
            "USD",
            ITIP20(StdTokens.PATH_USD_ADDRESS),
            address(this),
            bytes32(uint256(2))
        ));
        ITIP20RolesAuth(address(otherToken)).grantRole(otherToken.ISSUER_ROLE(), address(this));
        StdPrecompiles.STABLECOIN_DEX.createPair(address(otherToken));
        
        uint256 sendAmount = 100e6;
        uint256 nativeFee = 20_000e6;
        
        _setUserGasToken(alice, address(otherToken));
        frxUsdToken.mint(alice, sendAmount);
        otherToken.mint(alice, nativeFee);
        _addDexLiquidity(address(otherToken), nativeFee * 2);
        _setupPeer();
        
        vm.startPrank(alice);
        frxUsdToken.approve(address(adapter), type(uint256).max);
        otherToken.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
        
        _mockLzEndpointSend(nativeFee);
        
        uint256 aliceFrxBalanceBefore = frxUsdToken.balanceOf(alice);
        uint256 aliceOtherBalanceBefore = otherToken.balanceOf(alice);
        
        _executeSend(alice, sendAmount, nativeFee);
        
        // frxUSD: only sendAmount deducted (for _debit)
        assertEq(frxUsdToken.balanceOf(alice), aliceFrxBalanceBefore - sendAmount);
        // otherToken: nativeFee deducted (for gas swap)
        assertEq(otherToken.balanceOf(alice), aliceOtherBalanceBefore - nativeFee);
    }
    
    // ---------------------------------------------------
    // _debit Tests
    // ---------------------------------------------------
    
    function test_Debit_BurnsTokensAndTracksSupply() external {
        uint256 sendAmount = 100e6;
        uint256 nativeFee = 10e6;
        
        _setUserGasToken(alice, StdTokens.PATH_USD_ADDRESS);
        frxUsdToken.mint(alice, sendAmount);
        _setupPeer();
        
        vm.prank(alice);
        frxUsdToken.approve(address(adapter), type(uint256).max);
        
        _mockLzEndpointSend(nativeFee);
        
        uint256 totalSupplyBefore = frxUsdToken.totalSupply();
        
        _executeSend(alice, sendAmount, nativeFee);
        
        assertEq(adapter.totalTransferTo(DST_EID), sendAmount);
        assertEq(frxUsdToken.totalSupply(), totalSupplyBefore - sendAmount);
    }
    
    // ---------------------------------------------------
    // Initialization Tests
    // ---------------------------------------------------
    
    function test_Implementation_CannotBeInitialized() external {
        FraxOFTMintableAdapterUpgradeableTIP20 newImpl = 
            new FraxOFTMintableAdapterUpgradeableTIP20(address(frxUsdToken), lzEndpoint);
        
        vm.expectRevert();
        newImpl.initialize(alice);
    }
    
    function test_Proxy_CannotBeReinitialized() external {
        vm.expectRevert();
        adapter.initialize(alice);
    }
}
