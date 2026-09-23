// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import {SafeBatchTest} from "./SafeBatchTest.sol";
import {OftConfigBatch} from "scripts/ops/SafeBatch/OftConfigBatch.sol";
import {Batch202609Plasma} from "scripts/ops/SafeBatch/Batch202609/Batch202609Plasma.sol";
import {Batch202609Blast} from "scripts/ops/SafeBatch/Batch202609/Batch202609Blast.sol";
import {Batch202609Fraxtal} from "scripts/ops/SafeBatch/Batch202609/Batch202609Fraxtal.sol";
import {Batch202609Ethereum} from "scripts/ops/SafeBatch/Batch202609/Batch202609Ethereum.sol";
import {Batch202609EthereumHop} from "scripts/ops/SafeBatch/Batch202609/Batch202609EthereumHop.sol";
import {Batch202609Arbitrum} from "scripts/ops/SafeBatch/Batch202609/Batch202609Arbitrum.sol";
import {Batch202609Base} from "scripts/ops/SafeBatch/Batch202609/Batch202609Base.sol";
import {Batch202609Sei} from "scripts/ops/SafeBatch/Batch202609/Batch202609Sei.sol";
import {Batch202609XLayer} from "scripts/ops/SafeBatch/Batch202609/Batch202609XLayer.sol";
import {Batch202609Katana} from "scripts/ops/SafeBatch/Batch202609/Batch202609Katana.sol";

/// @notice Pre-flight for the 2026-09 campaign. Each suite declares the accounts its batch may write
///         and the routes it may change; SafeBatchTest proves nothing else on the chain moves.
///         Delete this file once the batches have executed.
library Canonical {
    /// @dev The six canonical OFTs at their shared vanity addresses (most proxy chains).
    function ofts() internal pure returns (address[] memory list) {
        list = new address[](6);
        list[0] = 0x64445f0aecC51E94aD52d8AC56b7190e764E561a; // WFRAX
        list[1] = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0; // sfrxUSD
        list[2] = 0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45; // sfrxETH
        list[3] = 0x80Eede496655FB9047dd39d9f418d5483ED600df; // frxUSD
        list[4] = 0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050; // frxETH
        list[5] = 0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927; // FPI
    }

    function has(uint32[] memory arr, uint32 v) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == v) return true;
        }
        return false;
    }

    function has(address[] memory arr, address v) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == v) return true;
        }
        return false;
    }

    function concat(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }

    function one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }
}

contract Batch202609PlasmaTest is SafeBatchTest {
    using Canonical for address[];

    Batch202609Plasma internal h;

    function setUp() public {
        vm.createSelectFork("https://rpc.plasma.to", 33064570);
        h = new Batch202609Plasma();
        _bind(h);
    }

    function _auditedOfts() internal pure override returns (address[] memory) {
        return Canonical.ofts();
    }

    function _isExpectedRoute(address, uint32 eid) internal view override returns (bool) {
        return eid == h.FRAXTAL_EID();
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        address[] memory hops = new address[](4);
        hops[0] = h.REMOTE_HOP_2025_10();
        hops[1] = h.REMOTE_HOP_2025_12();
        hops[2] = h.REMOTE_MINT_REDEEM_HOP_2025_10();
        hops[3] = h.REMOTE_MINT_REDEEM_HOP_2025_12();
        list = _libs().concat(Canonical.ofts()).concat(hops);
    }

    function _libs() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (endpoint, sendUln, receiveUln);
    }
}

contract Batch202609BlastTest is SafeBatchTest {
    using Canonical for address[];

    Batch202609Blast internal h;

    function setUp() public {
        vm.createSelectFork("https://rpc.blast.io", 40601775);
        h = new Batch202609Blast();
        _bind(h);
    }

    function _auditedOfts() internal view override returns (address[] memory) {
        return Canonical.ofts().concat(h.legacyOfts()).concat(Canonical.one(h.LEGACY_FPI())).concat(
            Canonical.one(h.BAD_FPI_OFT())
        );
    }

    function _isExpectedRoute(address oft, uint32 eid) internal view override returns (bool) {
        if (oft == h.BAD_FPI_OFT()) return Canonical.has(h.badFpiEids(), eid);
        if (oft == h.LEGACY_FPI()) return eid == h.ETHEREUM_EID() || eid == h.METIS_EID() || eid == h.BASE_EID();
        if (Canonical.has(h.legacyOfts(), oft)) return eid == h.METIS_EID() || eid == h.BASE_EID();
        // Proxy OFTs: the ten one-way legacy-mesh peers plus Ethereum, Metis and Fraxtal.
        if (Canonical.has(_asUint32(h.peeredEids()), eid)) return true;
        return eid == h.ETHEREUM_EID() || eid == h.METIS_EID() || eid == h.FRAXTAL_EID();
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        list = _libs().concat(Canonical.ofts()).concat(h.legacyOfts()).concat(Canonical.one(h.LEGACY_FPI())).concat(
            Canonical.one(h.BAD_FPI_OFT())
        ).concat(Canonical.one(h.REMOTE_MINT_REDEEM_HOP()));
    }

    function _libs() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (endpoint, sendUln, receiveUln);
    }

    function _asUint32(uint32[10] memory fixedList) internal pure returns (uint32[] memory out) {
        out = new uint32[](10);
        for (uint256 i = 0; i < 10; i++) {
            out[i] = fixedList[i];
        }
    }
}

contract Batch202609FraxtalTest is SafeBatchTest {
    using Canonical for address[];

    Batch202609Fraxtal internal h;

    function setUp() public {
        vm.createSelectFork("https://rpc.frax.com", 41603615);
        h = new Batch202609Fraxtal();
        _bind(h);
    }

    function _auditedOfts() internal view override returns (address[] memory) {
        return h.lockboxes().concat(Canonical.one(h.BAD_FPI_OFT()));
    }

    function _isExpectedRoute(address oft, uint32 eid) internal view override returns (bool) {
        if (oft == h.BAD_FPI_OFT()) return Canonical.has(h.badFpiEids(), eid);
        if (eid == h.PLASMA_EID() || eid == h.METIS_EID()) return true;
        // Blast residue and the FRA-100 Katana DVN upgrade; FPI is already severed on both.
        if (eid == h.BLAST_EID() || eid == h.KATANA_EID()) return oft != h.FPI_LOCKBOX();
        return false;
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        address[] memory hops = new address[](3);
        hops[0] = h.FRAXTAL_MINT_REDEEM_HOP();
        hops[1] = h.OLD_HOP_V2_HUB();
        hops[2] = h.safe(); // recover() sweeps the old hub's FRAX here
        list = _libs().concat(h.lockboxes()).concat(Canonical.one(h.BAD_FPI_OFT())).concat(hops);
    }

    function _libs() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (endpoint, sendUln, receiveUln);
    }
}

contract Batch202609EthereumTest is SafeBatchTest {
    using Canonical for address[];

    Batch202609Ethereum internal h;

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", 26027887);
        h = new Batch202609Ethereum();
        _bind(h);
    }

    /// @dev Audits the five legacy OFTs too: their receive-only exit lanes must survive untouched.
    function _auditedOfts() internal view override returns (address[] memory) {
        return _lockboxes().concat(h.legacyOfts()).concat(Canonical.one(h.LEGACY_FPI())).concat(
            Canonical.one(h.BAD_FPI_ADAPTER())
        );
    }

    function _isExpectedRoute(address oft, uint32 eid) internal view override returns (bool) {
        if (oft == h.BAD_FPI_ADAPTER()) return eid == h.SOLANA_EID();
        if (oft == h.LEGACY_FPI()) return eid == h.METIS_EID() || eid == h.BASE_EID() || eid == h.BLAST_EID();
        if (oft == h.FPI_LOCKBOX()) return eid == h.METIS_EID();
        if (oft == h.WFRAX_LOCKBOX()) return false; // already clean
        if (Canonical.has(h.legacyOfts(), oft)) return false; // exit lanes stay
        return eid == h.METIS_EID() || eid == h.BLAST_EID();
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        list = _libs().concat(_lockboxes()).concat(h.legacyOfts()).concat(Canonical.one(h.LEGACY_FPI())).concat(
            Canonical.one(h.BAD_FPI_ADAPTER())
        ).concat(Canonical.one(h.LEGACY_REMOTE_HOP()));
    }

    function _lockboxes() internal view returns (address[] memory list) {
        list = new address[](6);
        list[0] = h.SFRXUSD_LOCKBOX();
        list[1] = h.SFRXETH_LOCKBOX();
        list[2] = h.FRXUSD_LOCKBOX();
        list[3] = h.FRXETH_LOCKBOX();
        list[4] = h.FPI_LOCKBOX();
        list[5] = h.WFRAX_LOCKBOX();
    }

    function _libs() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (endpoint, sendUln, receiveUln);
    }
}

contract Batch202609BaseTest is SafeBatchTest {
    using Canonical for address[];

    Batch202609Base internal h;

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", 51614978);
        h = new Batch202609Base();
        _bind(h);
    }

    /// @dev Audits Base's own canonical OFTs: none of them may move.
    function _auditedOfts() internal view override returns (address[] memory) {
        return h.ofts().concat(h.legacyOfts()).concat(Canonical.one(h.LEGACY_FPI())).concat(
            Canonical.one(h.BAD_FPI_OFT())
        );
    }

    function _isExpectedRoute(address oft, uint32 eid) internal view override returns (bool) {
        if (oft == h.BAD_FPI_OFT()) return Canonical.has(h.badFpiEids(), eid);
        if (oft == h.LEGACY_FPI()) return eid == h.ETHEREUM_EID() || eid == h.METIS_EID() || eid == h.BLAST_EID();
        if (Canonical.has(h.legacyOfts(), oft)) return eid == h.METIS_EID() || eid == h.BLAST_EID();
        return false;
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        address[] memory hops = new address[](2);
        hops[0] = h.OLD_HOP_V2();
        hops[1] = h.OLDER_HOP_V2();
        list = _libs().concat(h.legacyOfts()).concat(Canonical.one(h.LEGACY_FPI())).concat(
            Canonical.one(h.BAD_FPI_OFT())
        ).concat(hops);
    }

    function _libs() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (endpoint, sendUln, receiveUln);
    }
}

contract Batch202609KatanaTest is SafeBatchTest {
    using Canonical for address[];

    Batch202609Katana internal h;

    function setUp() public {
        vm.createSelectFork("https://rpc.katana.network", 43290445);
        h = new Batch202609Katana();
        _bind(h);
    }

    function _auditedOfts() internal view override returns (address[] memory) {
        return h.ofts().concat(Canonical.one(h.FPI_OFT()));
    }

    /// @dev FRA-100 upgrades the live Fraxtal lane on purpose; no other eid may move.
    function _isExpectedRoute(address, uint32 eid) internal view override returns (bool) {
        return eid == h.FRAXTAL_EID();
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        address[] memory hops = new address[](2);
        hops[0] = h.REMOTE_MINT_REDEEM_HOP();
        hops[1] = h.REMOTE_HOP_V2();
        list = _libs().concat(h.ofts()).concat(Canonical.one(h.FPI_OFT())).concat(hops);
    }

    function _libs() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (endpoint, sendUln, receiveUln);
    }
}

/// @dev Sei and X-Layer only retire the non-canonical FPI spoke; their canonical OFTs are audited to
///      prove they do not move.
abstract contract BadFpiSpokeTest is SafeBatchTest {
    using Canonical for address[];

    address internal badFpi;

    function _auditedOfts() internal view override returns (address[] memory) {
        return Canonical.ofts().concat(Canonical.one(badFpi));
    }

    function _isExpectedRoute(address oft, uint32) internal view override returns (bool) {
        return oft == badFpi;
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        list = new address[](4);
        (list[0], list[1], list[2], list[3]) = (endpoint, sendUln, receiveUln, badFpi);
    }
}

contract Batch202609SeiTest is BadFpiSpokeTest {
    function setUp() public {
        vm.createSelectFork("https://sei-evm-rpc.publicnode.com", 233509436);
        Batch202609Sei h = new Batch202609Sei();
        _bind(h);
        badFpi = h.BAD_FPI_OFT();
    }
}

contract Batch202609XLayerTest is BadFpiSpokeTest {
    function setUp() public {
        vm.createSelectFork("https://xlayerrpc.okx.com", 71256568);
        Batch202609XLayer h = new Batch202609XLayer();
        _bind(h);
        badFpi = h.BAD_FPI_OFT();
    }
}

/// @dev Hop-only batches: no LayerZero config at all, so only the write-account envelope applies.
contract Batch202609ArbitrumTest is SafeBatchTest {
    Batch202609Arbitrum internal h;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 507543763);
        h = new Batch202609Arbitrum();
        helper = h;
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        list = new address[](1);
        list[0] = h.OLD_HOP_V2();
    }
}

contract Batch202609EthereumHopTest is SafeBatchTest {
    Batch202609EthereumHop internal h;

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", 26027887);
        h = new Batch202609EthereumHop();
        helper = h;
    }

    function _expectedWriteAccounts() internal view override returns (address[] memory list) {
        list = new address[](1);
        list[0] = h.OLD_HOP_V2();
    }
}
