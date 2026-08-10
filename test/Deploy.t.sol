// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Vm} from "forge-std/Test.sol";

import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {RegistryFixture, mkNavOnlyAsset, mkPriceOnlyAsset, mkSourcelessAsset} from "./helpers/RegistryFixture.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title DeployTest
/// @notice The permissionless `deploy(ca, ref, mode)` path: the registration gate (both assets must be
///         registered), the non-zero return gate, the key-and-mode-keyed recording, the idempotent
///         short-circuit, the factory reentrancy path, the US-Dollar bridge wiring, and the event
///         surface.
///
///         IDEMPOTENCY (the reason this suite exists): a wrapper is recorded under
///         `keccak256(abi.encode(address(this), ca, ref, caSource, refSource))` — the two source
///         addresses are the ones the requested `OracleMode` actually resolved to, and the registry's
///         own address keeps a redeployed registry from re-deriving a salt an earlier registry already
///         spent at the shared factory. A repeat `deploy` that resolves to the same sources returns the
///         stored address with NO external call, NO write, and NO event. `MarketOracleDeployed` is
///         emitted ONLY on a fresh deploy.
///
///         The wrapper factory is the FIRST of the two immutable constructor arguments (there is no
///         owner-managed allowlist). `deploy` re-reads each asset's LIVE `decimals()`, and a vault leg
///         additionally reads `decimals()` off the vault, so every asset used as a `ca` / `ref` here is a
///         real contract that answers `decimals()`.
///
///         ## What moved in this revision, and where the two deleted errors went
///
///         `MissingConversionFeed` and `UnsupportedDenomination` are GONE from the interface, and the
///         two cases that named them are not the same tests any more:
///
///         - `MissingConversionFeed("ETH")` → `NoConversionPathToUsd(unit, maxHops)`, which carries the
///           resolved UNIT and the hop budget instead of a label, and can now describe a two-hop miss.
///           More importantly the check MOVED EARLIER: `addAsset` validates every present source's
///           dollar path at WRITE time, so an asset whose bridge does not exist can no longer be stored
///           at all. Both halves are asserted below — the write-time refusal, and the deploy-time
///           failure that is still reachable when the bridge edge is REMOVED after the asset was added.
///         - `UnsupportedDenomination("GBP")` → `UnregisteredDenomination(label)`, which asks the
///           registry's denomination store rather than a hard-coded two-string table. It fires at
///           `addAsset`, and a label can never become unregistered afterwards (registration overwrites
///           and there is no removal path), so this failure is no longer reachable from `deploy` at all.
///           The test asserts the write-time refusal and that `deploy` then reports the asset as simply
///           unknown.
///
///         ## And a sourceless asset is now legal, so `deploy` is the only thing standing in its way
///
///         An asset with NEITHER source is accepted by `addAsset` (`EmptySources` is deleted). The whole
///         of the protection against one reaching an oracle lives in per-leg selection, so both oracle
///         modes are covered here: `MissingSource(asset, mode)` in `PRICE` mode and in `NAV` mode alike.
contract DeployTest is RegistryFixture {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // Deploy-path assets. Each one's PRICE source address is the token itself, so a wiring assertion can
    // name the token where it expects that leg's `feed1`.
    address internal ca; // 6 decimals, "USD"
    address internal ref; // 18 decimals, "USD"

    function setUp() public {
        _deployRegistry(owner);

        ca = _newToken("CA", 6);
        ref = _newToken("REF", 18);
        _addAsset(mkPriceOnlyAsset(ca, "CA", ca, "USD"));
        _addAsset(mkPriceOnlyAsset(ref, "REF", ref, "USD"));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    /// @dev The fixture's state helpers are deliberately unpranked, and this suite's registry has a
    ///      SEPARATE owner, so every owner write goes through one of these two wrappers.
    function _addAsset(IMarketRegistry.Asset memory a) internal {
        vm.prank(owner);
        iReg.addAssets(one(a));
    }

    function _addEthUsdEdgeAsOwner() internal {
        vm.prank(owner);
        _addEthUsdFeed();
    }

    /// @dev The deterministic wrapper the mock factory returns for a pair AND a resolved-source pair.
    ///      The source addresses are part of the salt now, which is exactly why a `NAV` wrapper and a
    ///      `PRICE` wrapper for one pair no longer collide.
    function _predict(address ca_, address ref_, address caSource, address refSource) internal view returns (address) {
        return wrapperFactory.predictWrapperFor(address(iReg), ca_, ref_, caSource, refSource);
    }

    /// @dev The price-mode shorthand for the two setUp assets, whose sources are the tokens themselves.
    function _predictPrice(address ca_, address ref_) internal view returns (address) {
        return _predict(ca_, ref_, ca_, ref_);
    }

    // ── deploy_happyPath_recordsAndEmits ─────────────────────────────────────────

    function test_deploy_happyPath_recordsAndEmits() public {
        address predicted = _predictPrice(ca, ref);

        // A fresh deploy emits MarketOracleDeployed and records the wrapper under the pair-and-source key.
        // Both legs' sources are the tokens themselves here, so the two source fields echo the pair.
        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.MarketOracleDeployed(ca, ref, predicted, IMarketRegistry.OracleMode.PRICE, ca, ref, alice);

        vm.prank(alice);
        address w = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertEq(w, predicted, "returned wrapper must equal the factory's deterministic address");
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            predicted,
            "wrapper must be recorded for the pair and mode"
        );
    }

    // ── deploy_secondRegistry_samePair_distinctWrapper ───────────────────────────

    /// @notice Two registry instances sharing ONE factory must never derive the same salt for the same
    ///         pair — that is what the registry's own address in the key buys. Without it, a redeployed
    ///         registry's first `deploy` of an already-built pair would replay the spent salt and the
    ///         real factory's `CREATE2` would revert with no error data.
    function test_deploy_secondRegistry_samePair_distinctWrapper() public {
        vm.prank(alice);
        address first = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        // A second registry against the SAME factory, holding the same assets with the same sources.
        MarketRegistry freshReg = new MarketRegistry();
        freshReg.initialize(address(this), address(wrapperFactory), address(fixedRateOracleFactory));
        IMarketRegistry fresh = IMarketRegistry(address(freshReg));
        fresh.addAssets(one(mkPriceOnlyAsset(ca, "CA", ca, "USD")));
        fresh.addAssets(one(mkPriceOnlyAsset(ref, "REF", ref, "USD")));

        address second = fresh.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertTrue(first != second, "same pair through a second registry must land on a fresh salt");
        assertEq(
            second,
            wrapperFactory.predictWrapperFor(address(fresh), ca, ref, ca, ref),
            "the second registry's wrapper must be keyed by ITS address"
        );
        // Each registry answers for its own record only.
        assertEq(iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), first);
        assertEq(fresh.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), second);
    }

    // ── deploy_unregisteredAsset_revertsEntryNotFound ─────────────────────────────

    /// @notice An unregistered `ref` reverts `EntryNotFound` — asset registration is the only pre-flight
    ///         gate (the factory is immutable, so there is no allowlist to fail).
    function test_deploy_unregisteredRef_revertsEntryNotFound() public {
        address strayRef = makeAddr("strayRef");
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        vm.prank(alice);
        iReg.deploy(ca, strayRef, IMarketRegistry.OracleMode.PRICE);
    }

    /// @notice An unregistered `ca` reverts `EntryNotFound`.
    function test_deploy_unregisteredCa_revertsEntryNotFound() public {
        address strayCa = makeAddr("strayCa");
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        vm.prank(alice);
        iReg.deploy(strayCa, ref, IMarketRegistry.OracleMode.PRICE);
    }

    // ── deploy_zeroAddressReturn_revertsNoStateChange (ZeroAddress) ───────────────

    function test_deploy_zeroAddressReturn_revertsNoStateChange() public {
        wrapperFactory.setMode(MockWrapperFactory.Mode.ZeroWrapper);

        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        vm.prank(alice);
        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        // No wrapper recorded: the zero-return gate fires before the write.
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "no wrapper may be recorded on a zero return"
        );
    }

    // ── deploy_repeat_samePair_idempotentNoop ────────────────────────────────────
    // A repeat for the same pair and mode returns the SAME recorded address with no event.

    function test_deploy_repeat_samePair_idempotentNoop() public {
        address predicted = _predictPrice(ca, ref);

        vm.prank(alice);
        address first = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        assertEq(first, predicted, "first deploy address");
        assertEq(iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), first, "recorded after first deploy");

        // Repeat with the SAME pair and mode but a different caller.
        vm.recordLogs();
        vm.prank(bob);
        address second = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(second, first, "repeat must return the SAME recorded address");
        assertFalse(_sawDeployed(logs), "repeat deploy must NOT emit MarketOracleDeployed -- it is an idempotent no-op");
    }

    // ── deploy_delistedAsset_resolutionRunsFirst ──────────────────────────────────

    /// @notice De-listing a leg breaks even a REPEAT `deploy`: leg resolution runs BEFORE the idempotency
    ///         short-circuit, so the call reverts `EntryNotFound` instead of handing back the wrapper it
    ///         already recorded. Re-listing the asset with the same source restores the recorded wrapper
    ///         unchanged — the record itself was never touched.
    /// @dev This is the OPPOSITE of the predecessor's behaviour, and the reversal is forced rather than
    ///      incidental. The wrapper key is derived from the two RESOLVED SOURCE ADDRESSES now, so there is
    ///      no key to look up until both legs have been resolved: the short-circuit cannot precede
    ///      resolution any more. The consequence worth pinning is that withdrawing approval actually
    ///      withdraws it — a de-listed asset stops answering through `deploy` and `lookupWrapper` — while
    ///      the historical record survives, because removal withdraws approval rather than unwinding
    ///      history.
    function test_deploy_delistedAsset_repeatRevertsEntryNotFound() public {
        vm.prank(alice);
        address w = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        vm.prank(owner);
        iReg.removeAssets(one(ca));

        // The repeat no longer short-circuits: resolution comes first and fails.
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        vm.prank(bob);
        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        // And the read agrees, without reverting.
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "a de-listed leg must read as no wrapper"
        );

        // Re-listing with the SAME source resolves to the same key, so the untouched record reappears and
        // a further deploy is once again a silent no-op.
        _addAsset(mkPriceOnlyAsset(ca, "CA", ca, "USD"));
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            w,
            "the recorded wrapper must survive the removal and reappear on re-listing"
        );

        vm.recordLogs();
        vm.prank(bob);
        address again = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(again, w, "the re-listed pair must short-circuit onto the original wrapper");
        assertFalse(_sawDeployed(logs), "a short-circuit must emit nothing");
    }

    // ── deploy_reentrantFactory_noPartialState ────────────────────────────────────
    // Nothing about the outer deploy is written before the factory call. The reentrant factory runs a
    // nested deploy for a SECOND pair; both pairs end up recorded independently.

    function test_deploy_reentrantFactory_noPartialState() public {
        // A second registered pair for the nested deploy.
        address ca2 = _newToken("CA2", 8);
        address ref2 = _newToken("REF2", 8);
        _addAsset(mkPriceOnlyAsset(ca2, "CA2", ca2, "USD"));
        _addAsset(mkPriceOnlyAsset(ref2, "REF2", ref2, "USD"));

        address shared = makeAddr("sharedWrapper");
        wrapperFactory.configureReentrant(
            iReg, ca2, ref2, IMarketRegistry.OracleMode.PRICE, ca, ref, IMarketRegistry.OracleMode.PRICE, shared
        );

        vm.recordLogs();
        vm.prank(alice);
        address w = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Observed FROM INSIDE the factory call: the outer pair had not been recorded yet.
        assertFalse(
            wrapperFactory.outerRecordedAtEntry(),
            "outer deploy recorded its pair before the factory call (partial state)"
        );

        // Net effect: both keys record the same wrapper address (wrappers are keyed by pair + sources).
        assertEq(w, shared, "outer must return the reentrant factory's address");
        assertEq(iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), shared, "outer pair must be recorded");
        assertEq(
            iReg.lookupWrapper(ca2, ref2, IMarketRegistry.OracleMode.PRICE), shared, "nested pair must be recorded"
        );

        // MarketOracleDeployed fired exactly twice — one fresh deploy per key (nested + outer).
        uint256 deployedCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reg) && logs[i].topics[0] == IMarketRegistry.MarketOracleDeployed.selector) {
                ++deployedCount;
            }
        }
        assertEq(deployedCount, 2, "MarketOracleDeployed must fire once per fresh key (nested + outer)");
    }

    // ── deploy_distinctPairs_recordTwoWrappers ────────────────────────────────────
    // Distinct (ca, ref) pairs land at distinct deterministic wrappers; each pair records its own.

    function test_deploy_distinctPairs_recordTwoWrappers() public {
        address third = _newToken("THIRD", 18);
        _addAsset(mkPriceOnlyAsset(third, "THIRD", third, "USD"));

        vm.prank(alice);
        address first = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        vm.prank(alice);
        address second = iReg.deploy(ca, third, IMarketRegistry.OracleMode.PRICE);

        assertTrue(first != second, "distinct pairs must land at distinct wrappers");
        assertEq(iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), first, "first pair recorded");
        assertEq(iReg.lookupWrapper(ca, third, IMarketRegistry.OracleMode.PRICE), second, "second pair recorded");
    }

    // ── deploy_arbitraryReturn_recordedVerbatim ───────────────────────────────────
    // A well-formed arbitrary non-zero return is accepted verbatim; the registry only rejects zero.

    function test_deploy_arbitraryReturn_recordedVerbatim() public {
        address chosen = address(0xC0FFEE);
        wrapperFactory.setFixedWrapper(chosen);

        vm.prank(alice);
        address returned = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertEq(returned, chosen, "registry records the factory's arbitrary return verbatim");
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            chosen,
            "arbitrary non-zero return is recorded"
        );
    }

    // ── deploy_race_twoCallersSamePair ────────────────────────────────────────────
    // Two different callers, same pair and mode. First fresh (MarketOracleDeployed / alice); second is
    // the idempotent short-circuit (no event), returning the same address.

    function test_deploy_race_twoCallersSamePair() public {
        address predicted = _predictPrice(ca, ref);

        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.MarketOracleDeployed(ca, ref, predicted, IMarketRegistry.OracleMode.PRICE, ca, ref, alice);
        vm.prank(alice);
        address a = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        // Second caller short-circuits: same address, no event.
        vm.recordLogs();
        vm.prank(bob);
        address b = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(a, b, "both callers must resolve to the same wrapper");
        assertFalse(_sawDeployed(logs), "the second caller is an idempotent no-op and must emit nothing");
    }

    // ── deploy_simulateAsPreview ──────────────────────────────────────────────────
    // Off-chain address prediction dry-runs this same function: the address a caller would predict (by
    // simulating deploy) matches the on-chain result, and the simulation leaves no state behind.

    function test_deploy_simulateAsPreview() public {
        address predicted = _predictPrice(ca, ref);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        address previewed = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        assertEq(previewed, predicted, "simulated deploy must return the deterministic address");
        vm.revertToState(snap);

        // The preview left no trace.
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "dry-run must not persist a wrapper"
        );

        // The real call yields the exact address the preview predicted.
        vm.prank(alice);
        address actual = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
        assertEq(actual, previewed, "real deploy must match the previewed address");
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), actual, "real deploy records the wrapper"
        );
    }

    // ── deploy_revertingFactory_bubbles ───────────────────────────────────────────

    function test_deploy_revertingFactory_bubbles() public {
        wrapperFactory.setMode(MockWrapperFactory.Mode.Revert);
        vm.expectRevert(MockWrapperFactory.FactoryReverted.selector);
        vm.prank(alice);
        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
    }

    // ── sourceless legs: MissingSource in BOTH oracle modes ───────────────────────
    // A sourceless asset is a LEGAL registry entry now, so `deploy`'s per-leg selection is the only thing
    // standing between one and an oracle. Both modes have to land on the same error, and they reach it by
    // different routes: `PRICE` reads `priceSource` and finds nothing, while `NAV` finds no NAV source,
    // falls through to `priceSource`, and finds nothing there either.

    /// @notice `PRICE` mode: a sourceless leg reverts `MissingSource(asset, PRICE)` on either side of the
    ///         pair, and `lookupWrapper` reports the zero address rather than reverting.
    function test_deploy_sourcelessAsset_priceMode_revertsMissingSource() public {
        address bare = _newToken("BARE", 18);
        _addAsset(mkSourcelessAsset(bare, "BARE"));

        // As the collateral leg.
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistry.MissingSource.selector, bare, IMarketRegistry.OracleMode.PRICE)
        );
        vm.prank(alice);
        iReg.deploy(bare, ref, IMarketRegistry.OracleMode.PRICE);

        // And as the reference leg.
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistry.MissingSource.selector, bare, IMarketRegistry.OracleMode.PRICE)
        );
        vm.prank(alice);
        iReg.deploy(ca, bare, IMarketRegistry.OracleMode.PRICE);

        assertEq(
            iReg.lookupWrapper(bare, ref, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "a sourceless leg must read as no wrapper, not revert"
        );

        // The factory was never reached, so nothing was built for either orientation.
        assertEq(wrapperFactory.callCount(), 0, "a sourceless leg must be refused before the factory call");
    }

    /// @notice `NAV` mode: the same asset reverts `MissingSource(asset, NAV)`.
    /// @dev Two things are pinned here rather than one. First, NAV mode reaches the error by a DIFFERENT
    ///      route — it looks for a NAV source, finds none, falls back to the price source, and finds none
    ///      there either — so it needs its own case and cannot be inferred from the `PRICE` one. Second,
    ///      `MissingSource` fires AHEAD of the cross-leg `NavModeWithoutNavSource` guard, because per-leg
    ///      selection runs before it. The first call below has a genuine NAV source on the other leg (so
    ///      only the sourceless leg can fail); the second has a price-only other leg, which is exactly the
    ///      shape `NavModeWithoutNavSource` describes — and `MissingSource` still wins.
    function test_deploy_sourcelessAsset_navMode_revertsMissingSource() public {
        address bare = _newToken("BARE", 18);
        _addAsset(mkSourcelessAsset(bare, "BARE"));

        address vaultRef = _newToken("VREF", 18);
        _addAsset(mkNavOnlyAsset(vaultRef, "VREF", vaultRef, "USD"));

        // Against a leg that DOES have a NAV source: the sourceless leg is the only possible failure.
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistry.MissingSource.selector, bare, IMarketRegistry.OracleMode.NAV)
        );
        vm.prank(alice);
        iReg.deploy(bare, vaultRef, IMarketRegistry.OracleMode.NAV);

        // Against a price-only leg: per-leg selection still fires first, so this is MissingSource and NOT
        // NavModeWithoutNavSource.
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistry.MissingSource.selector, bare, IMarketRegistry.OracleMode.NAV)
        );
        vm.prank(alice);
        iReg.deploy(bare, ref, IMarketRegistry.OracleMode.NAV);

        assertEq(
            iReg.lookupWrapper(bare, vaultRef, IMarketRegistry.OracleMode.NAV),
            address(0),
            "a sourceless leg must read as no wrapper in NAV mode too"
        );
        assertEq(wrapperFactory.callCount(), 0, "a sourceless leg must be refused before the factory call");
    }

    // ── US-Dollar-bridge wiring (deploy converges every side to US Dollars) ───────
    // Each side's `*Feed2` bridges the SELECTED SOURCE's own denomination to US Dollars: `address(0)` for
    // a US-Dollar source, or the approved denomination→USD conversion feed's aggregator otherwise.

    /// @notice A USD/USD market wires BOTH feed2 slots to address(0) — the byte-for-byte-unchanged path,
    ///         asserted explicitly so a regression in the US-Dollar branch cannot hide.
    function test_deploy_usdUsdPair_bothFeed2Zero() public {
        vm.prank(alice);
        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertEq(wrapperFactory.lastBaseFeed2(), address(0), "USD REF must wire baseFeed2 = address(0)");
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0), "USD CA must wire quoteFeed2 = address(0)");
        // feed1 on each side is still the asset's own aggregator (its selected source's addr).
        assertEq(wrapperFactory.lastBaseFeed1(), ref, "baseFeed1 must be REF's aggregator");
        assertEq(wrapperFactory.lastQuoteFeed1(), ca, "quoteFeed1 must be CA's aggregator");
        // Feed-shaped legs take no vault slot, and the conversion sample MUST then be exactly 1.
        assertEq(wrapperFactory.lastBaseVault(), address(0), "a feed-shaped REF leg takes no vault slot");
        assertEq(wrapperFactory.lastQuoteVault(), address(0), "a feed-shaped CA leg takes no vault slot");
        assertEq(wrapperFactory.lastBaseSample(), 1, "the sample must be exactly 1 with no vault");
        assertEq(wrapperFactory.lastQuoteSample(), 1, "the sample must be exactly 1 with no vault");
    }

    /// @notice REF's source denominated "ETH" (with an approved ETH→USD feed) + CA's "USD": the REF side
    ///         gets the ETH→USD aggregator as baseFeed2; the USD CA side stays address(0).
    function test_deploy_ethRef_usdCa_bridgesBaseFeed2() public {
        _addEthUsdEdgeAsOwner();
        address ethRef = _newToken("ETHREF", 18);
        _addAsset(mkPriceOnlyAsset(ethRef, "ETHREF", ethRef, "ETH"));

        vm.prank(alice);
        iReg.deploy(ca, ethRef, IMarketRegistry.OracleMode.PRICE);

        assertEq(
            wrapperFactory.lastBaseFeed2(), ethUsdAggregator, "ETH REF must bridge baseFeed2 to the ETH/USD aggregator"
        );
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0), "USD CA must keep quoteFeed2 = address(0)");
        assertEq(wrapperFactory.lastBaseFeed1(), ethRef, "baseFeed1 must be the ETH REF's own aggregator");
        assertEq(wrapperFactory.lastQuoteFeed1(), ca, "quoteFeed1 must be the USD CA's own aggregator");
    }

    /// @notice Both REF's and CA's sources denominated "ETH" (ETH→USD feed approved): BOTH feed2 slots
    ///         carry the ETH→USD aggregator.
    function test_deploy_ethRef_ethCa_bridgesBothFeed2() public {
        _addEthUsdEdgeAsOwner();
        address ethRef = _newToken("ETHREF", 18);
        address ethCa = _newToken("ETHCA", 6);
        _addAsset(mkPriceOnlyAsset(ethRef, "ETHREF", ethRef, "ETH"));
        _addAsset(mkPriceOnlyAsset(ethCa, "ETHCA", ethCa, "ETH"));

        vm.prank(alice);
        iReg.deploy(ethCa, ethRef, IMarketRegistry.OracleMode.PRICE);

        assertEq(
            wrapperFactory.lastBaseFeed2(), ethUsdAggregator, "ETH REF must bridge baseFeed2 to the ETH/USD aggregator"
        );
        assertEq(
            wrapperFactory.lastQuoteFeed2(), ethUsdAggregator, "ETH CA must bridge quoteFeed2 to the ETH/USD aggregator"
        );
        assertEq(wrapperFactory.lastBaseFeed1(), ethRef, "baseFeed1 must be the ETH REF's own aggregator");
        assertEq(wrapperFactory.lastQuoteFeed1(), ethCa, "quoteFeed1 must be the ETH CA's own aggregator");
    }

    // ── the two DELETED errors, and what replaced each of them ────────────────────

    /// @notice `MissingConversionFeed` case, part 1 of 2 — the failure MOVED to write time. An asset whose
    ///         source is denominated "ETH" while no ETH→USD edge exists can no longer be STORED: `addAsset`
    ///         reverts `NoConversionPathToUsd(ETH_UNIT, 1)`, so `deploy` never gets the chance to trip
    ///         over it.
    /// @dev This replaces `test_deploy_ethRef_noConversionFeed_revertsMissingConversionFeed`. Two changes
    ///      compose here. The error was renamed and re-shaped — `NoConversionPathToUsd` carries the
    ///      resolved UNIT address and the exhausted hop budget instead of a label, because it can now
    ///      describe a two-hop miss that a single-feed error could not. And `addAsset` now validates every
    ///      present source's dollar path itself, which is the whole point of the revision: the predecessor
    ///      accepted the entry and discovered the problem at some later `deploy`, in a different
    ///      transaction, usually to somebody who had not made the mistake. The hop budget in the error is
    ///      `1` because the source is an `AGGREGATOR_V3`, which has already consumed `feed1`.
    function test_addAssets_unreachableDenomination_revertsAtWriteTime() public {
        address ethRef = _newToken("ETHREF", 18);

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, ETH_UNIT, uint256(1)));
        _addAsset(mkPriceOnlyAsset(ethRef, "ETHREF", ethRef, "ETH"));

        // Nothing was stored, so the pair is simply unknown to `deploy`.
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        vm.prank(alice);
        iReg.deploy(ca, ethRef, IMarketRegistry.OracleMode.PRICE);
    }

    /// @notice `MissingConversionFeed` case, part 2 of 2 — the deploy-time failure that IS still
    ///         reachable. Remove the bridge edge after the asset was accepted and `deploy` reverts
    ///         `NoConversionPathToUsd(ETH_UNIT, 1)`, before the factory is called and with nothing
    ///         recorded.
    /// @dev This is the surviving half of the original test's intent: the bridge lookup is a storage read
    ///      that happens ahead of the external call, so a failed `deploy` writes nothing. Removing a
    ///      conversion feed the live assets depend on is deliberately a governance action with teeth —
    ///      there is no cascade, so the asset keeps its stored entry and starts failing here.
    function test_deploy_bridgeFeedRemoved_revertsNoConversionPathToUsd() public {
        _addEthUsdEdgeAsOwner();
        address ethRef = _newToken("ETHREF", 18);
        _addAsset(mkPriceOnlyAsset(ethRef, "ETHREF", ethRef, "ETH"));

        // Withdraw the only ETH → USD edge. No cascade: the asset entry stays.
        vm.prank(owner);
        iReg.removeConversionFeeds(one(ETH_UNIT), one(USD_UNIT));
        (bool stillThere,) = iReg.lookupAssetByAddress(ethRef);
        assertTrue(stillThere, "removing a feed must not cascade to the assets that used it");

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, ETH_UNIT, uint256(1)));
        vm.prank(alice);
        iReg.deploy(ca, ethRef, IMarketRegistry.OracleMode.PRICE);

        assertEq(wrapperFactory.callCount(), 0, "resolution must fail BEFORE the factory is called");
        assertEq(
            iReg.lookupWrapper(ca, ethRef, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "a failed deploy must record nothing"
        );
    }

    /// @notice `UnsupportedDenomination` case — replaced by `UnregisteredDenomination(label)` at WRITE
    ///         time. A source naming a label the registry has never registered ("GBP") is refused by
    ///         `addAsset`, so the asset does not exist and `deploy` reports `EntryNotFound`.
    /// @dev This replaces `test_deploy_unrecognizedDenomination_revertsUnsupportedDenomination`. The old
    ///      error asked "is this one of two hard-coded strings"; the new one asks "is this label in the
    ///      registry's denomination store", which is a governed set the owner maintains. It cannot be
    ///      asserted at `deploy` time any more, and that is a fact about the design rather than a gap in
    ///      the test: `registerDenomination` OVERWRITES and there is no removal path, so a label that was
    ///      registered when the asset was written can never become unregistered afterwards. Write time is
    ///      the only place this failure exists. Registering the label — with a dollar edge — makes the very
    ///      same asset acceptable, which is asserted below so the test says what the rule IS and not only
    ///      what it forbids.
    function test_addAssets_unregisteredDenomination_revertsUnregisteredDenomination() public {
        address gbpRef = _newToken("GBPREF", 18);

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, "GBP"));
        _addAsset(mkPriceOnlyAsset(gbpRef, "GBPREF", gbpRef, "GBP"));

        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        vm.prank(alice);
        iReg.deploy(ca, gbpRef, IMarketRegistry.OracleMode.PRICE);

        // Register the label and give it a dollar edge, and the identical entry is accepted and deployable.
        address gbpUnit = makeAddr("gbpUnit");
        address gbpUsdAgg = makeAddr("gbpUsdAggregator");
        // Two owner writes in one helper (the label and its dollar edge), so this needs a start/stop
        // prank rather than a single-call `vm.prank`.
        vm.startPrank(owner);
        _registerDenominationWithUsdFeed("GBP", gbpUnit, gbpUsdAgg);
        vm.stopPrank();
        _addAsset(mkPriceOnlyAsset(gbpRef, "GBPREF", gbpRef, "GBP"));

        vm.prank(alice);
        iReg.deploy(ca, gbpRef, IMarketRegistry.OracleMode.PRICE);
        assertEq(wrapperFactory.lastBaseFeed2(), gbpUsdAgg, "the newly registered label must bridge through its edge");
    }

    // ── shared log scan ──────────────────────────────────────────────────────────

    function _sawDeployed(Vm.Log[] memory logs) internal view returns (bool sawDeployed) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reg)) continue;
            if (logs[i].topics[0] == IMarketRegistry.MarketOracleDeployed.selector) sawDeployed = true;
        }
    }
}
