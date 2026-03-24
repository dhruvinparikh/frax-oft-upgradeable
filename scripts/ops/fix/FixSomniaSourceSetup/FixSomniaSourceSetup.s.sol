// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

import "scripts/FraxtalHub/2_SetupSourceFraxOFTFraxtalHub/SetupSourceFraxOFTFraxtalHub.sol";
import { SerializedTx, SafeTxUtil } from "scripts/SafeBatchSerialize.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

// Fix: re-generate failed Somnia source-setup txs as per-OFT Safe JSONs for msig execution.
// forge script scripts/ops/fix/FixSomniaSourceSetup/FixSomniaSourceSetup.s.sol --rpc-url $SOMNIA_RPC_URL
contract FixSomniaSourceSetup is SetupSourceFraxOFTFraxtalHub {
    SerializedTx[] public serializedTxsWfrax;
    SerializedTx[] public serializedTxssfrxUsd;
    SerializedTx[] public serializedTxssfrxEth;
    SerializedTx[] public serializedTxsfrxUsd;
    SerializedTx[] public serializedTxsfrxEth;
    SerializedTx[] public serializedTxsfpi;

    address internal constant SOMNIA_SAFE = 0x9527e19F55d1afCE9F1e9Edcea79552bF41983F9;

    constructor() {
        wfraxOft = 0x00000000E9CE0f293D1Ce552768b187eBA8a56D4;
        sfrxUsdOft = 0x00000000fD8C4B8A413A06821456801295921a71;
        sfrxEthOft = 0x00000000883279097A49dB1f2af954EAd0C77E3c;
        frxUsdOft = 0x00000000D61733e7A393A10A5B48c311AbE8f1E5;
        frxEthOft = 0x000000008c3930dCA540bB9B3A5D0ee78FcA9A4c;
        fpiOft = 0x00000000bC4aEF4bA6363a437455Cb1af19e2aEb;

        proxyOfts.push(wfraxOft);
        proxyOfts.push(sfrxUsdOft);
        proxyOfts.push(sfrxEthOft);
        proxyOfts.push(frxUsdOft);
        proxyOfts.push(frxEthOft);
        proxyOfts.push(fpiOft);
    }

    function run() public virtual override {
        super.run();
        _writePerOftJsons();
    }

    /// @notice Simulate all calls as the Somnia Safe instead of broadcasting.
    modifier broadcastAs(uint256) override {
        vm.createSelectFork(broadcastConfig.RPC);
        vm.startPrank(SOMNIA_SAFE);
        _;
        vm.stopPrank();
    }

    /// @notice Ownership/delegate transfers already executed on-chain; skip in JSON generation.
    function setPriviledgedRoles() public virtual override {}

    function pushSerializedTx(string memory _name, address _to, uint256 _value, bytes memory _data)
        public
        virtual
        override
    {
        bytes memory sliced = new bytes(_data.length - 4);
        for (uint256 i = 0; i < sliced.length; i++) {
            sliced[i] = _data[i + 4];
        }

        SerializedTx memory txObj = SerializedTx({ name: _name, to: _to, value: _value, data: _data });

        string memory tokenName = _resolveTokenName(_name, _to, sliced);

        if (isStringEqual(tokenName, "frxUSD")) {
            serializedTxsfrxUsd.push(txObj);
        } else if (isStringEqual(tokenName, "sfrxUSD")) {
            serializedTxssfrxUsd.push(txObj);
        } else if (isStringEqual(tokenName, "frxETH")) {
            serializedTxsfrxEth.push(txObj);
        } else if (isStringEqual(tokenName, "sfrxETH")) {
            serializedTxssfrxEth.push(txObj);
        } else if (isStringEqual(tokenName, "WFRAX")) {
            serializedTxsWfrax.push(txObj);
        } else if (isStringEqual(tokenName, "FPI")) {
            serializedTxsfpi.push(txObj);
        } else {
            revert("Token symbol not recognized");
        }
    }

    function _resolveTokenName(string memory _name, address _to, bytes memory _sliced)
        internal
        view
        returns (string memory)
    {
        address token;

        if (isStringEqual(_name, "setPeer") || isStringEqual(_name, "setEnforcedOptions")) {
            token = IOFT(_to).token();
        } else if (isStringEqual(_name, "setSendLibrary")) {
            (address oapp,,) = abi.decode(_sliced, (address, uint32, address));
            token = IOFT(oapp).token();
        } else if (isStringEqual(_name, "setReceiveLibrary")) {
            (address oapp,,, ) = abi.decode(_sliced, (address, uint32, address, uint256));
            token = IOFT(oapp).token();
        } else if (isStringEqual(_name, "setConfig")) {
            (address oapp,,) = abi.decode(_sliced, (address, address, bytes));
            token = IOFT(oapp).token();
        } else {
            revert("Unsupported tx name");
        }

        return IERC20Metadata(token).symbol();
    }

    function _writePerOftJsons() internal {
        if (serializedTxsWfrax.length > 0) {
            new SafeTxUtil().writeTxs(serializedTxsWfrax, _outputPath("wfrax"));
        }
        if (serializedTxssfrxUsd.length > 0) {
            new SafeTxUtil().writeTxs(serializedTxssfrxUsd, _outputPath("sfrxusd"));
        }
        if (serializedTxssfrxEth.length > 0) {
            new SafeTxUtil().writeTxs(serializedTxssfrxEth, _outputPath("sfrxeth"));
        }
        if (serializedTxsfrxUsd.length > 0) {
            new SafeTxUtil().writeTxs(serializedTxsfrxUsd, _outputPath("frxusd"));
        }
        if (serializedTxsfrxEth.length > 0) {
            new SafeTxUtil().writeTxs(serializedTxsfrxEth, _outputPath("frxeth"));
        }
        if (serializedTxsfpi.length > 0) {
            new SafeTxUtil().writeTxs(serializedTxsfpi, _outputPath("fpi"));
        }
    }

    function _outputPath(string memory tokenName) internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(),
            "/scripts/ops/fix/FixSomniaSourceSetup/txs/FixSomniaSourceSetup-",
            tokenName,
            ".json"
        );
    }
}