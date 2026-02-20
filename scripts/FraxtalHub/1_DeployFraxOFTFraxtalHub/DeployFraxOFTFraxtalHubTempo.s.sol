// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

import { DeployFraxOFTFraxtalHub } from "./DeployFraxOFTFraxtalHub.s.sol";
import "scripts/DeployFraxOFTProtocol/DeployFraxOFTProtocol.s.sol";
import { FraxOFTUpgradeableTempo } from "contracts/FraxOFTUpgradeableTempo.sol";
import { FraxOFTUpgradeable } from "contracts/FraxOFTUpgradeable.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { FraxOFTMintableAdapterUpgradeableTIP20 } from "contracts/FraxOFTMintableAdapterUpgradeableTIP20.sol";
import { FrxUSDPolicyAdminTempo } from "contracts/frxUsd/FrxUSDPolicyAdminTempo.sol";
import { console } from "frax-std/FraxTest.sol";

// Deploy everything with a hub model vs. a spoke model where the only peer is Fraxtal
// Uses FraxOFTUpgradeableTempo for Tempo chain deployments
// frxUSD TIP20 is already deployed, this script deploys the FraxOFTMintableAdapterUpgradeableTIP20 adapter
// tempo : forge script scripts/FraxtalHub/1_DeployFraxOFTFraxtalHub/DeployFraxOFTFraxtalHubTempo.s.sol --rpc-url $TEMPO_RPC_URL --broadcast --verify
contract DeployFraxOFTFraxtalHubTempo is DeployFraxOFTFraxtalHub {
    /// @notice The already-deployed frxUSD TIP20 token address on Tempo
    address public constant FRXUSD_TIP20 = 0x20C0000000000000000000003554d28269E0f3c2;

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    address public policyAdminImplementation;
    address public policyAdminProxy;

    /// @notice Deploy FraxOFTUpgradeableTempo instead of FraxOFTUpgradeable
    function deployFraxOFTUpgradeableAndProxy(
        string memory _name,
        string memory _symbol
    ) public virtual override returns (address implementation, address proxy) {
        // Use FraxOFTUpgradeableTempo instead of FraxOFTUpgradeable
        implementation = address(new FraxOFTUpgradeableTempo(broadcastConfig.endpoint));

        /// @dev: broadcastConfig deployer is temporary OFT owner until setPriviledgedRoles()
        bytes memory initializeArgs = abi.encodeWithSelector(
            FraxOFTUpgradeable.initialize.selector,
            _name,
            _symbol,
            vm.addr(configDeployerPK)
        );

        /// @dev: deploy deterministic proxy via Nick's CREATE2
        proxy = deployCreate2({
            _salt: _symbol,
            _initCode: abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(implementationMock, vm.addr(oftDeployerPK), "")
            )
        });

        // Upgrade to real implementation and initialize
        TransparentUpgradeableProxy(payable(proxy)).upgradeToAndCall({
            newImplementation: implementation,
            data: initializeArgs
        });

        // Transfer admin to proxyAdmin
        TransparentUpgradeableProxy(payable(proxy)).changeAdmin(proxyAdmin);

        proxyOfts.push(proxy);

        // State checks
        require(isStringEqual(FraxOFTUpgradeable(proxy).name(), _name), "OFT name incorrect");
        require(isStringEqual(FraxOFTUpgradeable(proxy).symbol(), _symbol), "OFT symbol incorrect");
        require(address(FraxOFTUpgradeable(proxy).endpoint()) == broadcastConfig.endpoint, "OFT endpoint incorrect");
        require(
            EndpointV2(broadcastConfig.endpoint).delegates(proxy) == vm.addr(configDeployerPK),
            "Endpoint delegate incorrect"
        );
        require(FraxOFTUpgradeable(proxy).owner() == vm.addr(configDeployerPK), "OFT owner incorrect");
    }

    /// @notice Deploy FraxOFTMintableAdapterUpgradeableTIP20 for the existing frxUSD TIP20 token
    /// @dev Follows the pattern from DeployFraxUSDSepoliaHubMintableTempoTestnet.s.sol
    function deployFrxUsdOFTUpgradeableAndProxy()
        public
        virtual
        override
        returns (address implementation, address proxy)
    {
        ITIP20 token = ITIP20(FRXUSD_TIP20);

        implementation = address(new FraxOFTMintableAdapterUpgradeableTIP20(address(token), broadcastConfig.endpoint));

        /// @dev: broadcastConfig deployer is temporary OFT owner until setPriviledgedRoles()
        bytes memory initializeArgs = abi.encodeWithSelector(
            FraxOFTMintableAdapterUpgradeableTIP20.initialize.selector,
            vm.addr(configDeployerPK)
        );

        /// @dev: deploy deterministic proxy via Nick's CREATE2
        proxy = deployCreate2({
            _salt: "frxUSD",
            _initCode: abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(implementationMock, vm.addr(oftDeployerPK), "")
            )
        });

        // Upgrade to real implementation and initialize
        TransparentUpgradeableProxy(payable(proxy)).upgradeToAndCall({
            newImplementation: implementation,
            data: initializeArgs
        });

        // Transfer admin to proxyAdmin
        TransparentUpgradeableProxy(payable(proxy)).changeAdmin(proxyAdmin);

        proxyOfts.push(proxy);
        frxUsdOft = proxy;

        // Grant ISSUER_ROLE to the adapter so it can mint/burn
        // ITIP20RolesAuth(address(token)).grantRole(ISSUER_ROLE, proxy);
        // add console log to manually grant role as token owner is not same as deployer
        console.log("1. Please grant ISSUER_ROLE to the adapter with the following command:");
        console.log("   ITIP20RolesAuth(%s).grantRole(ISSUER_ROLE, %s)", address(token), proxy);
        // print ISSUER_ROLE for convenience
        console.log("   ISSUER_ROLE:", vm.toString(ISSUER_ROLE));
        // print to transfer ownership of token to tempo msig as well
        console.log("2. Please transfer ownership of the token to the Tempo multisig");

        // Deploy FrxUSDPolicyAdminTempo for freeze/thaw management
        (policyAdminImplementation, policyAdminProxy) = deployFrxUSDPolicyAdminTempo(address(token));

        // Log deployed addresses
        console.log("FraxOFTMintableAdapterUpgradeableTIP20 proxy:", proxy);
        console.log("FraxOFTMintableAdapterUpgradeableTIP20 implementation:", implementation);
        console.log("TIP20 frxUSD:", address(token));
        console.log("FrxUSDPolicyAdminTempo implementation:", policyAdminImplementation);
        console.log("FrxUSDPolicyAdminTempo proxy:", policyAdminProxy);
        console.log("Policy ID:", FrxUSDPolicyAdminTempo(policyAdminProxy).policyId());

        // State checks
        require(
            isStringEqual(ITIP20(FraxOFTMintableAdapterUpgradeableTIP20(proxy).token()).name(), "Frax USD"),
            "OFT name incorrect"
        );
        require(
            isStringEqual(ITIP20(FraxOFTMintableAdapterUpgradeableTIP20(proxy).token()).symbol(), "frxUSD"),
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
        // ITIP20(token).changeTransferPolicyId(newPolicyId);
        // console log to manually change transfer policy as token owner is not same as deployer
        console.log("3. Please change the transfer policy of the token to the new policy with the following command:");
        console.log("   ITIP20(%s).changeTransferPolicyId(%s)", token, newPolicyId);

        // State checks
        require(newPolicyId > 1, "Policy ID should be > 1");
        require(FrxUSDPolicyAdminTempo(proxy).owner() == vm.addr(configDeployerPK), "PolicyAdmin owner incorrect");
    }
}
