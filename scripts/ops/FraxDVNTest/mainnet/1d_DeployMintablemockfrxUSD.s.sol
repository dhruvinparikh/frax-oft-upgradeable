// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { DeployMintableMockFrax } from "./1a_DeployMintableMockFrax.s.sol";
import "scripts/DeployFraxOFTProtocol/DeployFraxOFTProtocol.s.sol";

// fraxtal : forge script ./scripts/ops/FraxDVNTest/mainnet/1d_DeployMintablemockfrxUSD.s.sol --rpc-url https://rpc.frax.com --verifier-url $FRAXSCAN_API_URL --etherscan-api-key $FRAXSCAN_API_KEY --verify --broadcast

contract DeployMintablemockfrxUSD is DeployMintableMockFrax {
    function deployFraxOFTUpgradeablesAndProxies() public override broadcastAs(oftDeployerPK) {
        // Implementation mock (0x8f1B9c1fd67136D525E14D96Efb3887a33f16250 if predeterministic)
        implementationMock = address(new ImplementationMock());

        // Deploy Mock frax USD
        deployFraxOFTUpgradeableAndProxy({ _name: "Mock frax USD", _symbol: "mockfrxUSD" });

        // Deploy OFT Wallet
        deployFraxOFTWalletUpgradeableAndProxy();
    }
}
