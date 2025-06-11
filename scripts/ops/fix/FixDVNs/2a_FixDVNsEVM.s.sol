// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

import "./FixDVNsInherited.s.sol";

// Reset the DVNs of a chain based on it's config (`config/`)
// forge script scripts/ops/fix/FixDVNs/2a_FixDVNsEVM.s.sol
contract FixDVNs is FixDVNsInherited {
    using stdJson for string;
    using Strings for uint256;

    function filename() public view override returns (string memory) {
        string memory root = vm.projectRoot();
        root = string.concat(root, "/scripts/ops/fix/FixDVNs/txs/");
        string memory name = string.concat((block.timestamp).toString(), "-2a_FixDVNsEVM-");
        name = string.concat(name, simulateConfig.chainid.toString());
        name = string.concat(name, ".json");

        return string.concat(root, name);
    }

    function run() public override {
        for (uint256 i = 0; i < expectedProxyOfts.length; i++) {
            proxyOfts.push(expectedProxyOfts[i]);
        }

        for (uint256 i = 0; i < proxyConfigs.length; i++) {
            for (uint256 j = 0; j < chainIds.length; j++) {
                // only fix DVNs for chains that are EVM-based
                if (chainIds[j] == 324 || chainIds[j] == 2741) {
                    // skip zksync and abstract, they have a separate script
                    continue;
                }

                if (proxyConfigs[i].chainid == chainIds[j]) {
                    fixDVNs(proxyConfigs[i]);
                }
            }
        }
    }

    function fixDVNs(L0Config memory _config) public simulateAndWriteTxs(_config) {
        for (uint256 i = 0; i < proxyConfigs.length; i++) {
            for (uint256 j = 0; j < chainIds.length; j++) {
                // skip if not a chain id configured or we're setting DVNs to self
                if (proxyConfigs[i].chainid != chainIds[j] || proxyConfigs[i].chainid == _config.chainid) continue;

                // skip if peer is not set for one OFT, which means all OFTs
                if (!hasPeer(connectedOfts[0], proxyConfigs[i])) {
                    continue;
                }

                // If not fraxtal, only fix the DVNs to fraxtal (to upgrade the hub-model)
                if (_config.chainid != 252 && proxyConfigs[i].chainid != 252) {
                    continue;
                }

                L0Config[] memory tempConfigs = new L0Config[](1);
                tempConfigs[0] = proxyConfigs[i];

                setDVNs({ _connectedConfig: _config, _connectedOfts: connectedOfts, _configs: tempConfigs });
            }
        }
    }

    function hasPeer(address _oft, L0Config memory _dstConfig) internal view returns (bool) {
        bytes32 peer = IOAppCore(_oft).peers(uint32(_dstConfig.eid));
        return peer != bytes32(0);
    }
}
