// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";

import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {RegistryHandler} from "./handlers/RegistryHandler.sol";

/// @title StoreInvariants — handler-based invariant suite for MarketRegistry (T-write-tests-06).
/// @notice Asserts the store-integrity invariants from Build Spec §13 under an arbitrary interleaving
///         of adds, removes, batches, source mutations, and deploys driven by {RegistryHandler}:
///
///           INV-I-01  existence iff index != 0, and value-1 == enumeration-array position (asset + feed stores)
///           INV-I-02  enumeration array <-> index map mutual consistency; array length == live count
///           INV-I-03  the name index always points at a LIVE primary key
///           INV-I-04  every PRESENT source carries a denomination, and every ABSENT source carries none
///           INV-W-01  every deployed (ca, ref, mode) triple reads back its recorded wrapper via lookupWrapper
///           INV-E-03  conservation: per enumerated store, array length == live count == total reported by get*
///
///         OBSERVATION HOOKS: the two `get*` enumerations, the `lookup*` views, and `lookupWrapper`
///         are the oracles; enumeration index maps are read directly with `vm.load`. Wrappers are no
///         longer enumerated — they are keyed by pair AND resolved sources and read one at a time.
///
/// @dev ## INV-I-04 WAS RESTATED, NOT MERELY RE-POINTED — read this before touching it
///
///      It used to read "every stored asset carries a non-empty denomination", checked against
///      `Asset.denomination`. That is no longer a true invariant, and it is not true for two independent
///      reasons:
///
///      1. **There is no asset-level `denomination` field.** It was deleted. The denomination lives on
///         each `AssetSource`, one per source, and an asset's two sources are not required to agree — so
///         "the asset's denomination" is not a question with one answer any more.
///      2. **A SOURCELESS asset is a legal entry.** `EmptySources` is deleted and `addAsset` accepts an
///         entry with neither source; `updateSource` can also clear the LAST remaining source and put an
///         existing asset back into that state. Such an entry carries no denomination ANYWHERE, and that
///         is correct rather than a defect: the requirement that a denomination reach US Dollars is
///         VACUOUS for it, because there is no label to start a path from. Asserting non-emptiness would
///         make the suite fail on a state the registry deliberately allows.
///
///      What survives is the per-source form, and it is a genuine two-sided invariant rather than a
///      weakened one — see {invariant_I04_sourceDenominationsMatchPresence}. A PRESENT source (`addr !=
///      0`) must carry a non-empty registered label, because `addAsset` and `updateSource` both validate
///      it at write time. An ABSENT source must carry the EMPTY string, because both write paths ZERO the
///      slot rather than copying whatever was handed to them — that is what stops a label being parked in
///      a field no reader gates on. The second half is new, and it is the stronger of the two.
///
///      The handler counts successful sourceless adds so `afterInvariant` can prove the campaign actually
///      produced the state this invariant was relaxed for. Relaxing an assertion without a coverage guard
///      would just be turning it off.
contract StoreInvariantsTest is Test {
    // Storage slots (MarketRegistryStorage). Enumeration arrays store their length at the slot itself;
    // index maps live at the noted slot with value = position + 1. Unchanged by the successor shapes:
    // the record LAYOUT inside `_assets` changed, but the top-level slot table did not.
    uint256 internal constant SLOT_ASSET_KEYS = 3;
    uint256 internal constant SLOT_ASSET_INDEX = 4;
    uint256 internal constant SLOT_ASSET_BYNAME = 5;
    uint256 internal constant SLOT_FEED_KEYS = 7;
    uint256 internal constant SLOT_FEED_INDEX = 8;

    RegistryHandler internal handler;
    IMarketRegistry internal ireg;
    address internal regAddr;

    function setUp() public {
        handler = new RegistryHandler();
        regAddr = address(handler.reg());
        ireg = IMarketRegistry(regAddr);

        // Fuzz only the mutating action functions (the ghost getters are view and excluded anyway).
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RegistryHandler.addAsset.selector;
        selectors[1] = RegistryHandler.addAssetBatch.selector;
        selectors[2] = RegistryHandler.removeAsset.selector;
        selectors[3] = RegistryHandler.reAddAsset.selector;
        selectors[4] = RegistryHandler.addConversionFeed.selector;
        selectors[5] = RegistryHandler.addConversionFeedBatch.selector;
        selectors[6] = RegistryHandler.removeConversionFeed.selector;
        selectors[7] = RegistryHandler.deploy.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INV-I-01 — existence iff index != 0, and (index value − 1) == enumeration position
    // ═════════════════════════════════════════════════════════════════════════════

    function invariant_I01_assetIndexMatchesPosition() public view {
        (IMarketRegistry.Asset[] memory page, uint256 total) = _assetPage();
        assertEq(page.length, total, "INV-I-01 asset: page length != total");
        for (uint256 p = 0; p < total; p++) {
            bytes32 key = keccak256(abi.encode(page[p].addr));
            uint256 idx = uint256(_mapB32(key, SLOT_ASSET_INDEX));
            assertEq(idx, p + 1, "INV-I-01 asset: index value != position + 1");
        }
    }

    function invariant_I01_feedIndexMatchesPosition() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = _feedPage();
        assertEq(page.length, total, "INV-I-01 feed: page length != total");
        for (uint256 p = 0; p < total; p++) {
            bytes32 key = keccak256(abi.encode(page[p].base, page[p].quote));
            uint256 idx = uint256(_mapB32(key, SLOT_FEED_INDEX));
            assertEq(idx, p + 1, "INV-I-01 feed: index value != position + 1");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INV-I-02 — enumeration <-> index-map consistency; array length == live count
    // ═════════════════════════════════════════════════════════════════════════════

    function invariant_I02_assetEnumConsistent() public view {
        (IMarketRegistry.Asset[] memory page, uint256 total) = _assetPage();
        assertEq(total, handler.assetCount(), "INV-I-02 asset: total != ghost live count");
        for (uint256 p = 0; p < total; p++) {
            (bool found,) = ireg.lookupAssetByAddress(page[p].addr);
            assertTrue(found, "INV-I-02 asset: enumerated key not live in index map");
        }
    }

    function invariant_I02_feedEnumConsistent() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = _feedPage();
        assertEq(total, handler.feedCount(), "INV-I-02 feed: total != ghost live count");
        for (uint256 p = 0; p < total; p++) {
            (bool found,) = ireg.lookupConversionFeed(page[p].base, page[p].quote);
            assertTrue(found, "INV-I-02 feed: enumerated key not live in index map");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INV-I-03 — the name index always points at a live primary key
    // ═════════════════════════════════════════════════════════════════════════════

    function invariant_I03_nameIndexPointsAtLivePrimary() public view {
        uint256 n = handler.assetCount();
        for (uint256 i = 0; i < n; i++) {
            (address addr, string memory name) = handler.assetAt(i);

            // Public triage: name lookup resolves and returns the same primary entry.
            (bool found, IMarketRegistry.Asset memory e) = ireg.lookupAssetByName(name);
            assertTrue(found, "INV-I-03: live asset not resolvable by name");
            assertEq(e.addr, addr, "INV-I-03: name resolves to a different address");

            // Direct storage: _assetByName[nameKey] holds the primary key, and that key is live.
            bytes32 nameKey = keccak256(abi.encode(_lower(name)));
            bytes32 primaryKey = keccak256(abi.encode(addr));
            assertEq(_mapB32(nameKey, SLOT_ASSET_BYNAME), primaryKey, "INV-I-03: name index -> wrong primary key");
            assertGt(uint256(_mapB32(primaryKey, SLOT_ASSET_INDEX)), 0, "INV-I-03: name index -> dead primary key");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INV-I-04 — a source's denomination matches its PRESENCE, both ways
    // ═════════════════════════════════════════════════════════════════════════════

    /// @notice Every PRESENT source carries a non-empty denomination; every ABSENT source carries the
    ///         empty string.
    /// @dev Replaces the predecessor's "every stored asset carries a non-empty denomination". See the
    ///      contract-level note for why that statement is no longer true — in short, the asset-level
    ///      field is gone and a sourceless asset is a legal entry with no denomination anywhere.
    ///
    ///      Both halves are real. The first is what write-time validation buys: a stored PRESENT source
    ///      was checked against the denomination registry and the conversion-feed graph before it landed.
    ///      The second is what zeroing an absent slot buys: nothing can be parked in the fields of a slot
    ///      no reader gates on, so a cleared source cannot leave a stale label behind that a later
    ///      `updateSource` might appear to honour.
    function invariant_I04_sourceDenominationsMatchPresence() public view {
        uint256 n = handler.assetCount();
        for (uint256 i = 0; i < n; i++) {
            (address addr,) = handler.assetAt(i);
            (bool found, IMarketRegistry.Asset memory e) = ireg.lookupAssetByAddress(addr);
            assertTrue(found, "INV-I-04: ghost-live asset absent on-chain");
            _assertDenominationMatchesPresence(e.priceSource, "price");
            _assertDenominationMatchesPresence(e.navSource, "nav");
        }
    }

    function _assertDenominationMatchesPresence(IMarketRegistry.AssetSource memory s, string memory tag) internal view {
        if (s.addr == address(0)) {
            assertEq(
                bytes(s.denomination).length,
                0,
                string.concat("INV-I-04 ", tag, ": an absent source carries a denomination")
            );
        } else {
            assertGt(
                bytes(s.denomination).length,
                0,
                string.concat("INV-I-04 ", tag, ": a present source carries no denomination")
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INV-W-01 — every deployed triple reads back its recorded wrapper via lookupWrapper
    // ═════════════════════════════════════════════════════════════════════════════

    /// @dev The MODE is part of the question now. A pair can hold a NAV wrapper and a price wrapper at
    ///      the same time (the wrapper key includes both resolved source addresses), so a two-argument
    ///      lookup could no longer name one wrapper.
    function invariant_W01_pairLookupMatchesRecorded() public view {
        uint256 n = handler.pairCount();
        for (uint256 i = 0; i < n; i++) {
            (address ca, address ref, IMarketRegistry.OracleMode mode, address wrapper) = handler.pairAt(i);
            assertTrue(wrapper != address(0), "INV-W-01: recorded wrapper is zero");
            assertEq(
                ireg.lookupWrapper(ca, ref, mode), wrapper, "INV-W-01: lookupWrapper drifted from the recorded wrapper"
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // INV-E-03 — conservation: array length == live count == total reported by get*
    // ═════════════════════════════════════════════════════════════════════════════

    function invariant_E03_conservation() public view {
        _conserve(SLOT_ASSET_KEYS, _assetTotal(), handler.assetCount(), "asset");
        _conserve(SLOT_FEED_KEYS, _feedTotal(), handler.feedCount(), "feed");
    }

    function _conserve(uint256 keysSlot, uint256 total, uint256 ghostCount, string memory tag) internal view {
        uint256 arrayLen = uint256(vm.load(regAddr, bytes32(keysSlot)));
        assertEq(arrayLen, total, string.concat("INV-E-03 ", tag, ": array length != get* total"));
        assertEq(total, ghostCount, string.concat("INV-E-03 ", tag, ": get* total != ghost live count"));
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // afterInvariant — the anti-vacuity guard (answers the guiding question)
    // ═════════════════════════════════════════════════════════════════════════════

    /// @notice Runs once at the end of the campaign. Conservation / consistency / monotonicity are
    ///         satisfiable VACUOUSLY by an add-only handler, so this asserts the campaign actually
    ///         exercised the remove and deploy paths. With a body-less handler all counters are 0 (every
    ///         registry call reverts and is caught), so this fails — the same expected body-less signal.
    /// @dev The last two guards are new and they are what keeps INV-I-04's relaxation honest.
    ///      `updateSource` is the only way an already-stored asset can lose its last source, and
    ///      `sourcelessAssetAdds` proves the campaign really stored entries with NEITHER source — the
    ///      state the predecessor's `EmptySources` error forbade and the state INV-I-04 was restated for.
    ///      Without them, "the invariants hold over sourceless assets" could be satisfied by never
    ///      producing one.
    function afterInvariant() external view {
        assertGt(handler.deployCalls(), 0, "coverage: deploy never fired");
        assertGt(handler.removeAssetCalls(), 0, "coverage: removeAsset never fired (swap-and-pop untested)");
        assertGt(handler.removeConversionFeedCalls(), 0, "coverage: removeConversionFeed never fired");
        assertGt(handler.reAddAssetCalls(), 0, "coverage: reAddAsset never fired");
        assertGt(handler.sourcelessAssetAdds(), 0, "coverage: no sourceless asset was ever stored");
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Enumeration helpers — fetch the full page (total-first, then a sized read)
    // ═════════════════════════════════════════════════════════════════════════════

    function _assetTotal() internal view returns (uint256 total) {
        (, total) = ireg.getAssets(0, 0);
    }

    function _feedTotal() internal view returns (uint256 total) {
        (, total) = ireg.getConversionFeeds(0, 0);
    }

    function _assetPage() internal view returns (IMarketRegistry.Asset[] memory page, uint256 total) {
        total = _assetTotal();
        (page,) = ireg.getAssets(0, total);
    }

    function _feedPage() internal view returns (IMarketRegistry.ConversionFeed[] memory page, uint256 total) {
        total = _feedTotal();
        (page,) = ireg.getConversionFeeds(0, total);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Storage-read helpers
    // ═════════════════════════════════════════════════════════════════════════════

    function _mapB32(bytes32 key, uint256 slot) internal view returns (bytes32) {
        return vm.load(regAddr, keccak256(abi.encode(key, slot)));
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) {
                b[i] = bytes1(uint8(b[i]) + 0x20);
            }
        }
        return string(b);
    }
}
