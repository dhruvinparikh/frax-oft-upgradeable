// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { DeployMockFrax } from "./1b_DeployMockFrax.s.sol";
import "scripts/DeployFraxOFTProtocol/DeployFraxOFTProtocol.s.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { FraxOFTMintableAdapterUpgradeableTIP20 } from "contracts/FraxOFTMintableAdapterUpgradeableTIP20.sol";
import { FrxUSDPolicyAdminTempo } from "contracts/frxUsd/FrxUSDPolicyAdminTempo.sol";

// # Set environment variables
// export TEMPO_RPC_URL=https://user:pass@rpc.tempo.xyz
// export VERIFIER_URL=https://user:pass@contracts.tempo.xyz/v2/contract
 
// # Run all tests on Tempo's testnet
// forge test
 
// # Deploy a simple contract
// forge create src/Mail.sol:Mail \
//   --rpc-url $TEMPO_RPC_URL \
//   --interactive \
//   --broadcast \
//   --verify \
//   --constructor-args 0x20c000000000000000000000033abb6ac7d235e5
 
// # Deploy a simple contract with custom fee token
// forge create src/Mail.sol:Mail \
//   --fee-token <FEE_TOKEN_ADDRESS> \
//   --rpc-url $TEMPO_RPC_URL \
//   --interactive \
//   --broadcast \
//   --verify \
//   --constructor-args 0x20c000000000000000000000033abb6ac7d235e5
 
// # Run a deployment script and verify on Tempo's explorer
// forge script script/Mail.s.sol \
//   --sig "run(string)" <SALT> \
//   --rpc-url $TEMPO_RPC_URL \
//   --interactive \
//   --sender <YOUR_WALLET_ADDRESS> \
//   --broadcast \
//   --verify
 
// # Run a deployment script with custom fee token and verify on Tempo's explorer
// forge script script/Mail.s.sol \
//   --fee-token <FEE_TOKEN_ADDRESS> \
//   --sig "run(string)" <SALT> \
//   --rpc-url $TEMPO_RPC_URL \
//   --interactive \
//   --sender <YOUR_WALLET_ADDRESS> \
//   --broadcast \
//   --verify

contract DeployMintablemockfrxUSDTempo is DeployMockFrax {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    address public policyAdminImplementation;
    address public policyAdminProxy;

    function setUp() public virtual override {
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(StdTokens.PATH_USD_ADDRESS);
        super.setUp();
    }

    /// @inheritdoc DeployFraxOFTProtocol
    function deployFrxUsdOFTUpgradeableAndProxy() public override returns (address implementation, address proxy) {
        // Create TIP20 token via factory
        address tokenAddr = StdPrecompiles.TIP20_FACTORY.createToken({
            name: "Mock Frax USD",
            symbol: "mockfrxUSD",
            currency: "USD",
            quoteToken: StdTokens.PATH_USD,
            admin: vm.addr(oftDeployerPK),
            salt: bytes32(0)
        });
        ITIP20 token = ITIP20(tokenAddr);

        implementation = address(new FraxOFTMintableAdapterUpgradeableTIP20(address(token), broadcastConfig.endpoint));
        /// @dev: create semi-pre-deterministic proxy address, then initialize with correct implementation
        proxy = address(new TransparentUpgradeableProxy(implementationMock, vm.addr(oftDeployerPK), ""));

        /// @dev: broadcastConfig deployer is temporary OFT owner until setPriviledgedRoles()
        bytes memory initializeArgs = abi.encodeWithSelector(
            FraxOFTMintableAdapterUpgradeableTIP20.initialize.selector,
            vm.addr(configDeployerPK)
        );
        TransparentUpgradeableProxy(payable(proxy)).upgradeToAndCall({
            newImplementation: implementation,
            data: initializeArgs
        });
        TransparentUpgradeableProxy(payable(proxy)).changeAdmin(proxyAdmin);

        proxyOfts.push(proxy);

        ITIP20RolesAuth(address(token)).grantRole(ISSUER_ROLE, proxy);

        // Deploy FrxUSDPolicyAdminTempo for freeze/thaw management
        (policyAdminImplementation, policyAdminProxy) = deployFrxUSDPolicyAdminTempo(address(token));

        // Log deployed addresses
        console.log("FraxOFTMintableAdapterUpgradeableTIP20 proxy:", proxy);
        console.log("FraxOFTMintableAdapterUpgradeableTIP20 implementation:", implementation);
        console.log("TIP20 mockfrxUSD:", address(token));
        console.log("FrxUSDPolicyAdminTempo implementation:", policyAdminImplementation);
        console.log("FrxUSDPolicyAdminTempo proxy:", policyAdminProxy);
        console.log("Policy ID:", FrxUSDPolicyAdminTempo(policyAdminProxy).policyId());

        // State checks
        require(
            isStringEqual(ITIP20(address(FraxOFTMintableAdapterUpgradeableTIP20(proxy).token())).name(), "Mock Frax USD"),
            "OFT name incorrect"
        );
        require(
            isStringEqual(ITIP20(address(FraxOFTMintableAdapterUpgradeableTIP20(proxy).token())).symbol(), "mockfrxUSD"),
            "OFT symbol incorrect"
        );
        require(
            address(FraxOFTMintableAdapterUpgradeableTIP20(proxy).endpoint()) == broadcastConfig.endpoint,
            "OFT endpoint incorrect"
        );
        require(
            EndpointV2(broadcastConfig.endpoint).delegates(proxy) == vm.addr(configDeployerPK),
            "Endpoint delegate incorrect"
        );
        require(
            FraxOFTMintableAdapterUpgradeableTIP20(proxy).owner() == vm.addr(configDeployerPK),
            "OFT owner incorrect"
        );
    }

    function deployFrxUSDPolicyAdminTempo(address token) internal returns (address implementation, address proxy) {
        // Deploy implementation
        implementation = address(new FrxUSDPolicyAdminTempo());

        // Deploy proxy
        proxy = address(new TransparentUpgradeableProxy(implementationMock, vm.addr(oftDeployerPK), ""));

        // Initialize - this creates a BLACKLIST policy in TIP-403 Registry
        bytes memory initializeArgs = abi.encodeWithSelector(
            FrxUSDPolicyAdminTempo.initialize.selector,
            vm.addr(configDeployerPK)
        );
        TransparentUpgradeableProxy(payable(proxy)).upgradeToAndCall({
            newImplementation: implementation,
            data: initializeArgs
        });
        TransparentUpgradeableProxy(payable(proxy)).changeAdmin(proxyAdmin);

        // Get the policy ID from the deployed policy admin
        uint64 newPolicyId = FrxUSDPolicyAdminTempo(proxy).policyId();

        // Set the TIP20 token's transfer policy to use our blacklist policy
        ITIP20(token).changeTransferPolicyId(newPolicyId);

        // State checks
        require(newPolicyId > 1, "Policy ID should be > 1");
        require(FrxUSDPolicyAdminTempo(proxy).owner() == vm.addr(configDeployerPK), "PolicyAdmin owner incorrect");
    }
}
