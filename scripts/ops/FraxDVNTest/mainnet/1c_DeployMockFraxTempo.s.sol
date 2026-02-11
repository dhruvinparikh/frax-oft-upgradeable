// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { DeployMockFrax } from "./1b_DeployMockFrax.s.sol";
import "scripts/DeployFraxOFTProtocol/DeployFraxOFTProtocol.s.sol";
import { FraxOFTUpgradeableTempo } from "contracts/FraxOFTUpgradeableTempo.sol";
import { FraxOFTUpgradeable } from "contracts/FraxOFTUpgradeable.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

// tempo : forge script ./scripts/ops/FraxDVNTest/mainnet/1c_DeployMockFraxTempo.s.sol --rpc-url $TEMPO_RPC_URL --verify --broadcast

contract DeployMockFraxTempo is DeployMockFrax {
    function setUp() public virtual override {
        StdPrecompiles.TIP_FEE_MANAGER.setUserToken(StdTokens.PATH_USD_ADDRESS);
        super.setUp();
    }

    function deployFraxOFTUpgradeablesAndProxies() public override broadcastAs(oftDeployerPK) {
        // Implementation mock
        implementationMock = address(new ImplementationMock());

        // Deploy Mock Frax using Tempo variant
        deployFraxOFTUpgradeableAndProxy({ _name: "Mock Frax", _symbol: "mFRAX" });

        // Deploy OFT Wallet
        deployFraxOFTWalletUpgradeableAndProxy();
    }

    /// @notice Deploy FraxOFTUpgradeableTempo instead of FraxOFTUpgradeable
    function deployFraxOFTUpgradeableAndProxy(
        string memory _name,
        string memory _symbol
    ) public override returns (address implementation, address proxy) {
        proxyAdmin = mFraxProxyAdmin;

        // Use FraxOFTUpgradeableTempo instead of FraxOFTUpgradeable
        implementation = address(new FraxOFTUpgradeableTempo(broadcastConfig.endpoint));
        /// @dev: create semi-pre-deterministic proxy address, then initialize with correct implementation
        proxy = address(new TransparentUpgradeableProxy(implementationMock, vm.addr(oftDeployerPK), ""));
        /// @dev: broadcastConfig deployer is temporary OFT owner until setPriviledgedRoles()
        bytes memory initializeArgs = abi.encodeWithSelector(
            FraxOFTUpgradeable.initialize.selector,
            _name,
            _symbol,
            vm.addr(configDeployerPK)
        );
        TransparentUpgradeableProxy(payable(proxy)).upgradeToAndCall({
            newImplementation: implementation,
            data: initializeArgs
        });
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
}
