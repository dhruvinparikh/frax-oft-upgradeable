// SPDX-License-Identifier: ISC
pragma solidity ^0.8.22;

import {
    OftRouteDeprecationBatchTest,
    IOAppView,
    IEndpointView,
    ILegacyHopView,
    IFraxtalHubView,
    SafeDelegateBatchTest
} from "./OftRouteDeprecationBatchTest.sol";
import {MeshCleanupPlasma} from "scripts/ops/DeprecateChain/MeshCleanupPlasma.sol";
import {MeshCleanupBlast} from "scripts/ops/DeprecateChain/MeshCleanupBlast.sol";
import {MeshCleanupFraxtal} from "scripts/ops/DeprecateChain/MeshCleanupFraxtal.sol";
import {MeshCleanupEthereum} from "scripts/ops/DeprecateChain/MeshCleanupEthereum.sol";
import {MeshCleanupEthereumHop} from "scripts/ops/DeprecateChain/MeshCleanupEthereumHop.sol";
import {MeshCleanupArbitrum} from "scripts/ops/DeprecateChain/MeshCleanupArbitrum.sol";
import {MeshCleanupBase} from "scripts/ops/DeprecateChain/MeshCleanupBase.sol";
import {MeshCleanupSei} from "scripts/ops/DeprecateChain/MeshCleanupSei.sol";
import {MeshCleanupXLayer} from "scripts/ops/DeprecateChain/MeshCleanupXLayer.sol";

contract MeshCleanupPlasmaTest is OftRouteDeprecationBatchTest {
    MeshCleanupPlasma internal h;
    address[6] internal ofts;
    address[4] internal hops;

    function setUp() public {
        vm.createSelectFork("https://rpc.plasma.to", 33064570);
        h = new MeshCleanupPlasma();
        _bind(h);
        ofts = [h.WFRAX_OFT(), h.SFRXUSD_OFT(), h.SFRXETH_OFT(), h.FRXUSD_OFT(), h.FRXETH_OFT(), h.FPI_OFT()];
        hops = [
            h.REMOTE_HOP_2025_10(),
            h.REMOTE_HOP_2025_12(),
            h.REMOTE_MINT_REDEEM_HOP_2025_10(),
            h.REMOTE_MINT_REDEEM_HOP_2025_12()
        ];
    }

    function _assertBefore() internal override {
        // Plasma still peers Fraxtal although Fraxtal dropped Plasma; the hops are live and unfunded.
        for (uint256 i = 0; i < ofts.length; i++) {
            _assertRouteDirty(ofts[i], h.FRAXTAL_EID(), true);
        }
        for (uint256 i = 0; i < hops.length; i++) {
            assertFalse(ILegacyHopView(hops[i]).paused(), "fork state drifted: hop already paused");
            assertEq(hops[i].balance, 0, "hop holds XPL: add recoverETH to the recipe");
        }
    }

    function _assertAfter() internal override {
        for (uint256 i = 0; i < ofts.length; i++) {
            _assertRouteSevered(ofts[i], h.FRAXTAL_EID());
        }
        for (uint256 i = 0; i < hops.length; i++) {
            _assertHopRetired(hops[i]);
        }
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < ofts.length; j++) {
                assertFalse(ILegacyHopView(hops[i]).approvedOft(ofts[j]), "OFT still approved on RemoteHop");
            }
            assertEq(ILegacyHopView(hops[i]).executorOptions(h.SOLANA_EID()).length, 0, "executor options remain");
        }
    }
}

contract MeshCleanupBlastTest is OftRouteDeprecationBatchTest {
    MeshCleanupBlast internal h;
    address[5] internal ofts;
    uint32[13] internal eids;

    function setUp() public {
        vm.createSelectFork("https://rpc.blast.io", 40601775);
        h = new MeshCleanupBlast();
        _bind(h);
        ofts = [h.WFRAX_OFT(), h.SFRXUSD_OFT(), h.SFRXETH_OFT(), h.FRXUSD_OFT(), h.FRXETH_OFT()];
        uint32[10] memory peered = h.peeredEids();
        for (uint256 j = 0; j < 10; j++) {
            eids[j] = peered[j];
        }
        eids[10] = h.ETHEREUM_EID();
        eids[11] = h.METIS_EID();
        eids[12] = h.FRAXTAL_EID();
    }

    function _peerExpected(address oft, uint32 eid) internal view returns (bool) {
        if (eid == h.METIS_EID() || eid == h.FRAXTAL_EID()) return false;
        if (eid == h.ETHEREUM_EID()) return oft != h.WFRAX_OFT();
        return true;
    }

    function _assertBefore() internal override {
        for (uint256 i = 0; i < ofts.length; i++) {
            for (uint256 j = 0; j < eids.length; j++) {
                _assertRouteDirty(ofts[i], eids[j], _peerExpected(ofts[i], eids[j]));
            }
        }
        (, bool fpiMetisDefault) = IEndpointView(endpoint).getReceiveLibrary(h.FPI_OFT(), h.METIS_EID());
        assertFalse(fpiMetisDefault, "fork state drifted: FPI/Metis receive lib already default");
        assertFalse(ILegacyHopView(h.REMOTE_MINT_REDEEM_HOP()).paused(), "fork state drifted: hop already paused");
        assertEq(h.REMOTE_MINT_REDEEM_HOP().balance, 0, "hop holds ETH: add recoverETH to the recipe");
        _assertLegacyLanesOpen(h, h.METIS_EID(), h.BASE_EID());
        _assertRoutesLive(h.BAD_FPI_OFT(), h.badFpiEids());
        _assertRoutesLive(h.LEGACY_FPI(), _three(h.ETHEREUM_EID(), h.METIS_EID(), h.BASE_EID()));
    }

    function _assertAfter() internal override {
        for (uint256 i = 0; i < ofts.length; i++) {
            for (uint256 j = 0; j < eids.length; j++) {
                _assertRouteSevered(ofts[i], eids[j]);
            }
        }
        for (uint256 j = 0; j < eids.length; j++) {
            assertEq(IEndpointView(endpoint).getSendLibrary(h.FPI_OFT(), eids[j]), blockedLibrary, "FPI send lib not blocked");
            (, bool isDefaultReceive) = IEndpointView(endpoint).getReceiveLibrary(h.FPI_OFT(), eids[j]);
            assertTrue(isDefaultReceive, "FPI receive lib not default");
            _assertZeroUlnConfig(h.FPI_OFT(), eids[j]);
        }
        _assertHopRetired(h.REMOTE_MINT_REDEEM_HOP());
        _assertLegacySpokeLanesBlocked(h, h.METIS_EID(), h.BASE_EID());
        _assertRoutesRetired(h.BAD_FPI_OFT(), h.badFpiEids());
        _assertRoutesRetired(h.LEGACY_FPI(), _three(h.ETHEREUM_EID(), h.METIS_EID(), h.BASE_EID()));
    }
}

contract MeshCleanupFraxtalTest is OftRouteDeprecationBatchTest {
    MeshCleanupFraxtal internal h;
    address[6] internal lockboxes;
    uint256 internal oldHubBalance;
    uint256 internal safeBalance;

    function setUp() public {
        vm.createSelectFork("https://rpc.frax.com", 41603615);
        h = new MeshCleanupFraxtal();
        _bind(h);
        lockboxes = [
            h.WFRAX_LOCKBOX(),
            h.SFRXUSD_LOCKBOX(),
            h.SFRXETH_LOCKBOX(),
            h.FRXUSD_LOCKBOX(),
            h.FRXETH_LOCKBOX(),
            h.FPI_LOCKBOX()
        ];
    }

    function _assertBefore() internal override {
        uint32[5] memory retired = h.retiredHubEids();
        for (uint256 i = 0; i < retired.length; i++) {
            assertTrue(
                IFraxtalHubView(h.FRAXTAL_MINT_REDEEM_HOP()).remoteHop(retired[i]) != bytes32(0),
                "fork state drifted: hub registration already cleared"
            );
        }
        for (uint256 i = 0; i < lockboxes.length; i++) {
            _assertRouteDirty(lockboxes[i], h.PLASMA_EID(), false);
            _assertRouteDirty(lockboxes[i], h.METIS_EID(), false);
            if (lockboxes[i] != h.FPI_LOCKBOX()) _assertRouteDirty(lockboxes[i], h.BLAST_EID(), false);
        }
        _assertOldHopV2Live(h.OLD_HOP_V2_HUB(), h.oldHopV2Eids(), h.lockboxes());
        oldHubBalance = h.OLD_HOP_V2_HUB().balance;
        safeBalance = h.safe().balance;
        assertTrue(oldHubBalance != 0, "fork state drifted: old hub already swept");
        _assertRoutesLive(h.BAD_FPI_OFT(), h.badFpiEids());
    }

    function _assertAfter() internal override {
        uint32[5] memory retired = h.retiredHubEids();
        for (uint256 i = 0; i < retired.length; i++) {
            assertEq(IFraxtalHubView(h.FRAXTAL_MINT_REDEEM_HOP()).remoteHop(retired[i]), bytes32(0), "hub still registered");
        }
        for (uint256 i = 0; i < lockboxes.length; i++) {
            _assertRouteSevered(lockboxes[i], h.PLASMA_EID());
            _assertRouteSevered(lockboxes[i], h.METIS_EID());
            _assertRouteSevered(lockboxes[i], h.BLAST_EID());
        }
        _assertOldHopV2Shutdown(h.OLD_HOP_V2_HUB(), h.oldHopV2Eids(), h.lockboxes());
        assertEq(h.safe().balance, safeBalance + oldHubBalance, "old hub FRAX not swept to the Safe");
        _assertRoutesRetired(h.BAD_FPI_OFT(), h.badFpiEids());
    }
}

contract MeshCleanupEthereumTest is OftRouteDeprecationBatchTest {
    MeshCleanupEthereum internal h;
    address[3] internal owned;

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", 26027887);
        h = new MeshCleanupEthereum();
        _bind(h);
        owned = [h.SFRXUSD_LOCKBOX(), h.SFRXETH_LOCKBOX(), h.FRXETH_LOCKBOX()];
    }

    function _assertBefore() internal override {
        for (uint256 i = 0; i < owned.length; i++) {
            _assertRouteDirty(owned[i], h.BLAST_EID(), false);
            _assertRouteDirty(owned[i], h.METIS_EID(), false);
        }
        _assertRouteDirty(h.FRXUSD_LOCKBOX(), h.BLAST_EID(), false);
        _assertRouteDirty(h.FRXUSD_LOCKBOX(), h.METIS_EID(), false);
        _assertRouteDirty(h.FPI_LOCKBOX(), h.METIS_EID(), false);
        // The legacy exit lanes must stay exactly as they are: peered, send-blocked.
        assertTrue(IOAppView(0x909DBdE1eBE906Af95660033e478D59EFe831fED).peers(h.BLAST_EID()) != bytes32(0));
        uint32[] memory solana = new uint32[](1);
        solana[0] = h.SOLANA_EID();
        _assertRoutesLive(h.BAD_FPI_ADAPTER(), solana);
        // Legacy FPI adapter: peered, send already blocked, receive still open.
        uint32[] memory legacy = _three(h.METIS_EID(), h.BASE_EID(), h.BLAST_EID());
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(IOAppView(h.LEGACY_FPI()).peers(legacy[i]) != bytes32(0), "fork state drifted: legacy FPI peer gone");
            assertEq(IEndpointView(endpoint).getSendLibrary(h.LEGACY_FPI(), legacy[i]), blockedLibrary, "fork state drifted: legacy FPI send open");
            (address rl,) = IEndpointView(endpoint).getReceiveLibrary(h.LEGACY_FPI(), legacy[i]);
            assertTrue(rl != blockedLibrary, "fork state drifted: legacy FPI receive already blocked");
        }
        // The seven EVM lanes of the bad adapter are already fully retired and must stay untouched.
        assertEq(IOAppView(h.BAD_FPI_ADAPTER()).peers(h.BLAST_EID()), bytes32(0));
        (address evmReceive,) = IEndpointView(endpoint).getReceiveLibrary(h.BAD_FPI_ADAPTER(), h.BLAST_EID());
        assertEq(evmReceive, blockedLibrary);
        // V1 RemoteHop: paused, but the rest of its wind-down never ran.
        assertTrue(ILegacyHopView(h.LEGACY_REMOTE_HOP()).paused(), "fork state drifted: V1 RemoteHop unpaused");
        assertTrue(ILegacyHopView(h.LEGACY_REMOTE_HOP()).fraxtalHop() != bytes32(0), "fork state drifted: wind-down already done");
        assertTrue(ILegacyHopView(h.LEGACY_REMOTE_HOP()).approvedOft(h.FRXUSD_LOCKBOX()), "fork state drifted: approvals gone");
        assertEq(h.LEGACY_REMOTE_HOP().balance, 0, "V1 RemoteHop holds ETH: add recoverETH to an EOA");
    }

    function _assertAfter() internal override {
        for (uint256 i = 0; i < owned.length; i++) {
            _assertRouteSevered(owned[i], h.BLAST_EID());
            _assertRouteSevered(owned[i], h.METIS_EID());
        }
        // frxUSD: libraries and DVN config reset; enforced options belong to the other owner Safe.
        _assertRouteSevered(h.FRXUSD_LOCKBOX(), h.BLAST_EID(), false);
        _assertRouteSevered(h.FRXUSD_LOCKBOX(), h.METIS_EID(), false);
        _assertRouteSevered(h.FPI_LOCKBOX(), h.METIS_EID());
        assertTrue(IOAppView(0x909DBdE1eBE906Af95660033e478D59EFe831fED).peers(h.BLAST_EID()) != bytes32(0));
        uint32[] memory solana = new uint32[](1);
        solana[0] = h.SOLANA_EID();
        _assertRoutesRetired(h.BAD_FPI_ADAPTER(), solana);
        (address evmReceive,) = IEndpointView(endpoint).getReceiveLibrary(h.BAD_FPI_ADAPTER(), h.BLAST_EID());
        assertEq(evmReceive, blockedLibrary);
        _assertRoutesRetired(h.LEGACY_FPI(), _three(h.METIS_EID(), h.BASE_EID(), h.BLAST_EID()));
        _assertHopRetired(h.LEGACY_REMOTE_HOP());
        assertFalse(ILegacyHopView(h.LEGACY_REMOTE_HOP()).approvedOft(h.FRXUSD_LOCKBOX()), "V1 RemoteHop approval remains");
        assertFalse(ILegacyHopView(h.LEGACY_REMOTE_HOP()).approvedOft(h.WFRAX_LOCKBOX()), "V1 RemoteHop approval remains");
        assertEq(ILegacyHopView(h.LEGACY_REMOTE_HOP()).executorOptions(h.SOLANA_EID()).length, 0, "V1 RemoteHop executor options remain");
    }
}

/// @dev Shared shape for the hop-only chains: one or two first-generation HopV2 spokes, swept to the Safe.
abstract contract OldHopV2SpokeTest is SafeDelegateBatchTest {
    address[] internal hops;
    uint32[] internal eids;
    address[] internal ofts;
    uint256 internal hopBalances;
    uint256 internal safeBalance;

    function _assertBefore() internal override {
        for (uint256 i = 0; i < hops.length; i++) {
            _assertOldHopV2Live(hops[i], eids, ofts);
            hopBalances += hops[i].balance;
        }
        safeBalance = helper.safe().balance;
    }

    function _assertAfter() internal override {
        for (uint256 i = 0; i < hops.length; i++) {
            _assertOldHopV2Shutdown(hops[i], eids, ofts);
        }
        assertEq(helper.safe().balance, safeBalance + hopBalances, "hop ETH not swept to the Safe");
    }
}

contract MeshCleanupArbitrumTest is OldHopV2SpokeTest {
    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 507543763);
        MeshCleanupArbitrum h = new MeshCleanupArbitrum();
        helper = h;
        hops.push(h.OLD_HOP_V2());
        eids.push(h.FRAXTAL_EID());
        ofts = h.ofts();
    }
}

contract MeshCleanupBaseTest is OftRouteDeprecationBatchTest {
    MeshCleanupBase internal h;
    address[2] internal hops;
    uint32[] internal hubEids;
    uint256 internal hopBalances;
    uint256 internal safeBalance;

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", 51614978);
        h = new MeshCleanupBase();
        _bind(h);
        hops = [h.OLD_HOP_V2(), h.OLDER_HOP_V2()];
        hubEids.push(h.FRAXTAL_EID());
    }

    function _assertBefore() internal override {
        for (uint256 i = 0; i < hops.length; i++) {
            _assertOldHopV2Live(hops[i], hubEids, h.ofts());
            hopBalances += hops[i].balance;
        }
        safeBalance = h.safe().balance;
        _assertLegacyLanesOpen(h, h.METIS_EID(), h.BLAST_EID());
        _assertRoutesLive(h.BAD_FPI_OFT(), h.badFpiEids());
        _assertRoutesLive(h.LEGACY_FPI(), _three(h.ETHEREUM_EID(), h.METIS_EID(), h.BLAST_EID()));
    }

    function _assertAfter() internal override {
        for (uint256 i = 0; i < hops.length; i++) {
            _assertOldHopV2Shutdown(hops[i], hubEids, h.ofts());
        }
        assertEq(h.safe().balance, safeBalance + hopBalances, "hop ETH not swept to the Safe");
        _assertLegacySpokeLanesBlocked(h, h.METIS_EID(), h.BLAST_EID());
        _assertRoutesRetired(h.BAD_FPI_OFT(), h.badFpiEids());
        _assertRoutesRetired(h.LEGACY_FPI(), _three(h.ETHEREUM_EID(), h.METIS_EID(), h.BLAST_EID()));
    }
}

contract MeshCleanupEthereumHopTest is OldHopV2SpokeTest {
    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io", 26027887);
        MeshCleanupEthereumHop h = new MeshCleanupEthereumHop();
        helper = h;
        hops.push(h.OLD_HOP_V2());
        eids.push(h.FRAXTAL_EID());
        ofts = h.lockboxes();
    }
}

/// @dev Spoke-only chains of the non-canonical FPI mesh.
abstract contract BadFpiSpokeTest is OftRouteDeprecationBatchTest {
    address internal badFpi;
    uint32[] internal eids;

    function _assertBefore() internal override {
        _assertRoutesLive(badFpi, eids);
    }

    function _assertAfter() internal override {
        _assertRoutesRetired(badFpi, eids);
    }
}

contract MeshCleanupSeiTest is BadFpiSpokeTest {
    function setUp() public {
        vm.createSelectFork("https://sei-evm-rpc.publicnode.com", 233357408);
        MeshCleanupSei h = new MeshCleanupSei();
        _bind(h);
        badFpi = h.BAD_FPI_OFT();
        eids = h.badFpiEids();
    }
}

contract MeshCleanupXLayerTest is BadFpiSpokeTest {
    function setUp() public {
        vm.createSelectFork("https://xlayerrpc.okx.com", 71256568);
        MeshCleanupXLayer h = new MeshCleanupXLayer();
        _bind(h);
        badFpi = h.BAD_FPI_OFT();
        eids = h.badFpiEids();
    }
}
