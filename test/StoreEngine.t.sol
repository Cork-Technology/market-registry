// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title Store-engine swap-and-pop + absent-read suite
/// @notice The `index + 1` existence discipline and enumeration / index-map consistency under head,
///         middle and tail removal and under interleaving, plus reads returning zeroed / false for
///         absent keys.
/// @dev The conversion-feed store is the add / remove / re-add subject: it is bytes32-keyed
///      (`removeBytes32`, the same engine the asset store uses) and its entries need no denomination
///      registration and no probe-safe address, so the suite stays about the ENGINE rather than about
///      validation.
///
///      Feeds used to be distinguished by `chainId` over one fixed (base, quote) pair. `chainId` is
///      gone from the key, so they are distinguished by QUOTE address over one fixed base instead —
///      `_quoteOf(slot)` maps a small integer to a distinct quote address, and every helper below
///      speaks in those slot numbers. The engine behaviour under test is identical.
///
///      `MarketRegistryLib` now carries TWO pairs of engine helpers: `insertBytes32` / `removeBytes32`
///      for the hash-keyed stores (assets, conversion feeds) and the address twins `insertAddress` /
///      `removeAddress` for the recipe store, whose key IS an address. This suite drives the bytes32
///      pair through the conversion-feed store; the address pair is exercised by the recipe suite,
///      which is the only store that uses it.
///
///      The tail-removal case is the load-bearing one. Swap-and-pop must skip the "move the last
///      element into the freed slot and fix its index" step when the removed entry IS the last element
///      (idx == last). An implementation that runs the fix unconditionally — or that clears the removed
///      key's index BEFORE re-writing the moved key's index — resurrects the just-removed entry.
contract StoreEngineTest is Test {
    MarketRegistry internal registry;
    IMarketRegistry internal reg;
    MockWrapperFactory internal factory;

    /// @dev Supplied only because the registry constructor takes it and zero-checks it. Nothing in this
    ///      suite deploys a fixed-rate oracle.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    address internal owner = makeAddr("owner");

    /// @dev One fixed base; each feed is (FEED_BASE → quote(slot)).
    address internal constant FEED_BASE = address(0xBA5E);

    /// @dev Mirror of the live feed set (by slot), mutated in lockstep with the registry.
    uint64[] internal expectedSlots;

    function setUp() public {
        factory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        registry = new MarketRegistry();
        registry.initialize(owner, address(factory), address(fixedRateOracleFactory));
        reg = IMarketRegistry(address(registry));
    }

    // ── feed helpers ─────────────────────────────────────────────────────────────

    /// @dev A distinct, non-zero quote address per slot. Never `FEED_BASE`, and never zero.
    function _quoteOf(uint64 slot) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("StoreEngine.quote", slot)))));
    }

    function _addFeed(uint64 slot) internal {
        IMarketRegistry.ConversionFeed memory f;
        f.base = FEED_BASE;
        f.quote = _quoteOf(slot);
        f.aggregatorAddress = makeAddr(string(abi.encodePacked("agg", slot)));
        f.feedDecimals = 8;
        vm.prank(owner);
        reg.addConversionFeeds(one(f));
        expectedSlots.push(slot);
    }

    function _removeFeed(uint64 slot) internal {
        vm.prank(owner);
        reg.removeConversionFeeds(one(FEED_BASE), one(_quoteOf(slot)));
        _expectedRemoveSlot(slot);
    }

    function _expectedRemoveSlot(uint64 slot) internal {
        uint256 len = expectedSlots.length;
        for (uint256 i = 0; i < len; i++) {
            if (expectedSlots[i] == slot) {
                expectedSlots[i] = expectedSlots[len - 1];
                expectedSlots.pop();
                return;
            }
        }
        revert("slot not in expected set");
    }

    function _found(uint64 slot) internal view returns (bool found) {
        (found,) = reg.lookupConversionFeed(FEED_BASE, _quoteOf(slot));
    }

    /// @dev Full consistency oracle. Order-agnostic (swap-and-pop perturbs position). Asserts:
    ///      total == |expected|; the enumerated page is exactly the expected set (each expected member
    ///      present exactly once, no extras); every expected member reads found == true.
    function _assertFeedSetConsistent() internal view {
        uint256 n = expectedSlots.length;
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(0, n + 5);
        assertEq(total, n, "total != expected count");
        assertEq(page.length, n, "page length != expected count");

        for (uint256 i = 0; i < n; i++) {
            uint64 slot = expectedSlots[i];
            assertTrue(_found(slot), "expected member not found");
            uint256 seen;
            for (uint256 j = 0; j < page.length; j++) {
                if (page[j].quote == _quoteOf(slot)) seen++;
            }
            assertEq(seen, 1, "expected member not present exactly once in page");
        }
        // No extras: every enumerated element is an expected member.
        for (uint256 j = 0; j < page.length; j++) {
            bool inExpected;
            for (uint256 i = 0; i < n; i++) {
                if (_quoteOf(expectedSlots[i]) == page[j].quote) {
                    inExpected = true;
                    break;
                }
            }
            assertTrue(inExpected, "page contains an unexpected element");
        }
    }

    function _seedN(uint64 n) internal {
        for (uint64 s = 1; s <= n; s++) {
            _addFeed(s);
        }
    }

    // ── swap-and-pop on the feed store: head / middle / tail ──────────────────────

    /// @notice Tail removal: removing the last-inserted element must not move or re-index anything.
    function test_swapAndPop_tailRemoval_consistent() public {
        _seedN(5); // insertion order slots [1..5]; tail == 5
        _assertFeedSetConsistent();

        _removeFeed(5);

        assertFalse(_found(5), "tail resurrected: index not cleared on last-elem removal");
        _assertFeedSetConsistent();
    }

    /// @notice Head removal: the last element is swapped into slot 0 and its index fixed to 1.
    function test_swapAndPop_headRemoval_consistent() public {
        _seedN(5);
        _removeFeed(1); // head

        assertFalse(_found(1), "head still present");
        assertTrue(_found(5), "moved element lost after head removal");
        _assertFeedSetConsistent();
    }

    /// @notice Middle removal: the last element is swapped into the freed middle slot.
    function test_swapAndPop_middleRemoval_consistent() public {
        _seedN(5);
        _removeFeed(3); // middle

        assertFalse(_found(3), "middle still present");
        assertTrue(_found(5), "moved element lost after middle removal");
        _assertFeedSetConsistent();
    }

    /// @notice Single-element removal is the degenerate tail case (idx == last == 0).
    function test_swapAndPop_singleElementRemoval_consistent() public {
        _addFeed(1);
        _removeFeed(1);

        assertFalse(_found(1), "only element resurrected");
        (, uint256 total) = reg.getConversionFeeds(0, 10);
        assertEq(total, 0, "store not empty after removing sole element");
        _assertFeedSetConsistent();
    }

    /// @notice Deterministic head + middle + tail interleaving with a full consistency check after
    ///         every mutation, then a re-add to prove `index + 1` slots are reusable (no stale
    ///         tombstone).
    function test_swapAndPop_interleavedAddRemove_consistent() public {
        _seedN(5); // [1,2,3,4,5]
        _assertFeedSetConsistent();

        _removeFeed(1); // head
        _assertFeedSetConsistent();

        _removeFeed(4); // tail of the current array (5 already swapped to slot 0)
        _assertFeedSetConsistent();

        _removeFeed(3); // middle
        _assertFeedSetConsistent();

        // Re-add a previously removed slot — must slot back in cleanly (no durable tombstone).
        _addFeed(1);
        assertTrue(_found(1), "re-added feed not found");
        _assertFeedSetConsistent();

        // Add a fresh one after all the churn to confirm indexing still tracks length.
        _addFeed(9);
        _assertFeedSetConsistent();
    }

    // ── reads: zeroed / false when absent ─────────────────────────────────────────

    function test_reads_zeroedWhenAbsent_lookupConversionFeed() public {
        (bool found, IMarketRegistry.ConversionFeed memory f) =
            reg.lookupConversionFeed(makeAddr("nope"), makeAddr("nada"));
        assertFalse(found, "absent feed reported found");
        assertEq(f.base, address(0), "base not zeroed");
        assertEq(f.quote, address(0), "quote not zeroed");
        assertEq(f.aggregatorAddress, address(0), "aggregator not zeroed");
        assertEq(uint256(f.feedDecimals), 0, "decimals not zeroed");
    }

    /// @dev The asset-level `denomination` field is GONE, so there is no single string to check for
    ///      zeroing any more. The denomination now lives on each SOURCE, so the zeroed-read assertion
    ///      moved onto both source slots — `addr` and `denomination` on each of the two.
    function test_reads_zeroedWhenAbsent_lookupAssetByAddress() public {
        (bool found, IMarketRegistry.Asset memory a) = reg.lookupAssetByAddress(makeAddr("ghostAsset"));
        assertFalse(found, "absent asset reported found");
        assertEq(a.addr, address(0), "addr not zeroed");
        assertEq(a.name, "", "name not zeroed");
        assertEq(a.priceSource.addr, address(0), "price source addr not zeroed");
        assertEq(a.priceSource.denomination, "", "price source denomination not zeroed");
        assertEq(a.navSource.addr, address(0), "nav source addr not zeroed");
        assertEq(a.navSource.denomination, "", "nav source denomination not zeroed");
    }

    /// @notice An unregistered pair reads `address(0)` from `lookupWrapper` in BOTH modes — never
    ///         reverts.
    /// @dev `lookupWrapper` re-runs the same per-leg source resolution `deploy` does, so an
    ///      unregistered asset, a leg that cannot serve the mode, and a NAV-mode call with no NAV
    ///      source anywhere all have to come back as the zero address rather than as a revert. "There
    ///      is no wrapper for that" and "not deployed yet" are the same answer.
    function test_reads_zeroWhenAbsent_lookupWrapper() public {
        address ghostCa = makeAddr("ghostCa");
        address ghostRef = makeAddr("ghostRef");
        assertEq(
            reg.lookupWrapper(ghostCa, ghostRef, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "absent pair must read address(0) in PRICE mode"
        );
        assertEq(
            reg.lookupWrapper(ghostCa, ghostRef, IMarketRegistry.OracleMode.NAV),
            address(0),
            "absent pair must read address(0) in NAV mode"
        );
    }

    /// @notice An unregistered recipe address reads false — `isRecipe` never reverts.
    function test_reads_zeroWhenAbsent_recipeStore() public view {
        address ghost = address(0xBEEF);
        assertFalse(reg.isRecipe(ghost), "absent recipe reported registered");
    }

    /// @notice Live-read: a removal is visible to the very next read, and the removed key reads zeroed
    ///         — not stale.
    function test_reads_zeroedWhenAbsent_afterRemoval_liveRead() public {
        _addFeed(1);
        assertTrue(_found(1), "not found after add");
        _removeFeed(1);
        assertFalse(_found(1), "still found immediately after removal");
    }
}
