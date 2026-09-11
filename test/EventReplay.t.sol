// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Vm} from "forge-std/Test.sol";

import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {one} from "./helpers/ArrayHelpers.sol";
import {
    RegistryFixture,
    mkAsset,
    mkDualSourceAsset,
    mkFeed,
    mkPriceOnlyAsset,
    noSource
} from "./helpers/RegistryFixture.sol";

/// @title RegistryMirror — a registry rebuilt from nothing but the log
/// @notice Consumes `EntryAdded` / `EntryRemoved` / `MarketOracleDeployed` and reconstructs every
///         store. It has no reference to the live registry and never calls it: what it knows, it
///         learned from an event.
/// @dev This is the off-chain indexer, written in Solidity so the test can compare it against the
///      real thing field by field. It deliberately re-derives every storage key from the event
///      PAYLOAD and asserts the result matches the `keyHash` topic. That is the property under test —
///      a `keyHash` alone is a one-way hash, so if the payload could not reproduce it, an indexer
///      holding only the log would be stuck with a set of hashes it cannot name.
///
///      The array bookkeeping is intentionally NOT read from the log. It is recomputed here with the
///      same append-and-swap-and-pop helpers the registry uses, which is the claim being checked:
///      given the order of the events, enumeration order follows, and nothing extra has to be
///      emitted to pin it.
contract RegistryMirror {
    mapping(bytes32 keyHash => IMarketRegistry.Asset) internal _assets;
    bytes32[] internal _assetKeys;
    mapping(bytes32 keyHash => uint256) internal _assetIndex;
    mapping(bytes32 nameKey => bytes32 keyHash) internal _assetByName;

    mapping(bytes32 key => IMarketRegistry.ConversionFeed) internal _feeds;
    bytes32[] internal _feedKeys;
    mapping(bytes32 key => uint256) internal _feedIndex;

    address[] internal _denominationKeys;
    mapping(address unit => uint256) internal _denominationIndex;

    address[] internal _recipeKeys;
    mapping(address recipe => uint256) internal _recipeIndex;

    mapping(bytes32 wrapperKey => address wrapper) internal _wrappers;

    // ── the fold ──────────────────────────────────────────────────────────────

    /// @notice Apply one log record. Anything unrecognised is ignored, as an indexer would ignore it.
    ///         The emitter rides along because two registries sharing one factory each keep their own
    ///         wrapper record — an indexer folding logs from both must not let them collide.
    function applyEvent(address emitter, bytes32[] memory topics, bytes memory data) external {
        if (topics.length == 0) return;

        if (topics[0] == IMarketRegistry.EntryAdded.selector) {
            _added(IMarketRegistry.Namespace(uint8(uint256(topics[1]))), topics[2], abi.decode(data, (bytes)));
        } else if (topics[0] == IMarketRegistry.EntryRemoved.selector) {
            _removed(IMarketRegistry.Namespace(uint8(uint256(topics[1]))), topics[2], abi.decode(data, (bytes)));
        } else if (topics[0] == IMarketRegistry.MarketOracleDeployed.selector) {
            // The registry's own storage key folds in live wiring an indexer cannot see, so the mirror
            // keys on what the log carries: the pair and the mode the wrapper answers for.
            (uint8 mode,,,) = abi.decode(data, (uint8, address, address, address));
            address ca = address(uint160(uint256(topics[1])));
            address ref = address(uint160(uint256(topics[2])));
            _wrappers[keccak256(abi.encode(emitter, ca, ref, mode))] = address(uint160(uint256(topics[3])));
        }
    }

    function _added(IMarketRegistry.Namespace ns, bytes32 keyHash, bytes memory payload) private {
        if (ns == IMarketRegistry.Namespace.Asset) {
            IMarketRegistry.Asset memory a = abi.decode(payload, (IMarketRegistry.Asset));
            require(MarketRegistryLib.assetKey(a.addr) == keyHash, "asset key not derivable from payload");
            _assets[keyHash] = a;
            MarketRegistryLib.insertBytes32(_assetKeys, _assetIndex, keyHash);
            _assetByName[MarketRegistryLib.nameKey(a.name)] = keyHash;
        } else if (ns == IMarketRegistry.Namespace.ConversionFeed) {
            IMarketRegistry.ConversionFeed memory f = abi.decode(payload, (IMarketRegistry.ConversionFeed));
            require(MarketRegistryLib.feedKey(f.base, f.quote) == keyHash, "feed key not derivable from payload");
            _feeds[keyHash] = f;
            MarketRegistryLib.insertBytes32(_feedKeys, _feedIndex, keyHash);
        } else if (ns == IMarketRegistry.Namespace.Recipe) {
            address recipe = abi.decode(payload, (address));
            require(MarketRegistryLib.recipeKeyHash(recipe) == keyHash, "recipe key not derivable from payload");
            MarketRegistryLib.insertAddress(_recipeKeys, _recipeIndex, recipe);
        } else if (ns == IMarketRegistry.Namespace.Denomination) {
            address unit = abi.decode(payload, (address));
            require(bytes32(uint256(uint160(unit))) == keyHash, "denomination key not derivable from payload");
            MarketRegistryLib.insertAddress(_denominationKeys, _denominationIndex, unit);
        }
    }

    function _removed(IMarketRegistry.Namespace ns, bytes32 keyHash, bytes memory payload) private {
        if (ns == IMarketRegistry.Namespace.Asset) {
            address addr = abi.decode(payload, (address));
            require(MarketRegistryLib.assetKey(addr) == keyHash, "asset key not derivable from payload");
            // Name index first, then the record — the folded name key can only be recomputed from the
            // name the record still holds. Same ordering the registry itself depends on.
            delete _assetByName[MarketRegistryLib.nameKey(_assets[keyHash].name)];
            MarketRegistryLib.removeBytes32(_assetKeys, _assetIndex, keyHash);
            delete _assets[keyHash];
        } else if (ns == IMarketRegistry.Namespace.ConversionFeed) {
            (address base, address quote) = abi.decode(payload, (address, address));
            require(MarketRegistryLib.feedKey(base, quote) == keyHash, "feed key not derivable from payload");
            MarketRegistryLib.removeBytes32(_feedKeys, _feedIndex, keyHash);
            delete _feeds[keyHash];
        } else if (ns == IMarketRegistry.Namespace.Recipe) {
            address recipe = abi.decode(payload, (address));
            require(MarketRegistryLib.recipeKeyHash(recipe) == keyHash, "recipe key not derivable from payload");
            MarketRegistryLib.removeAddress(_recipeKeys, _recipeIndex, recipe);
        } else if (ns == IMarketRegistry.Namespace.Denomination) {
            address unit = abi.decode(payload, (address));
            require(bytes32(uint256(uint160(unit))) == keyHash, "denomination key not derivable from payload");
            MarketRegistryLib.removeAddress(_denominationKeys, _denominationIndex, unit);
        }
    }

    // ── reads, shaped like the registry's own enumeration ──────────────────────

    function assetCount() external view returns (uint256) {
        return _assetKeys.length;
    }

    function assetAt(uint256 i) external view returns (IMarketRegistry.Asset memory) {
        return _assets[_assetKeys[i]];
    }

    function assetByName(string memory name) external view returns (IMarketRegistry.Asset memory) {
        return _assets[_assetByName[MarketRegistryLib.nameKey(name)]];
    }

    function feedCount() external view returns (uint256) {
        return _feedKeys.length;
    }

    function feedAt(uint256 i) external view returns (IMarketRegistry.ConversionFeed memory) {
        return _feeds[_feedKeys[i]];
    }

    function denominationCount() external view returns (uint256) {
        return _denominationKeys.length;
    }

    function denominationAt(uint256 i) external view returns (address) {
        return _denominationKeys[i];
    }

    function recipeCount() external view returns (uint256) {
        return _recipeKeys.length;
    }

    function recipeAt(uint256 i) external view returns (address) {
        return _recipeKeys[i];
    }

    function wrapperFor(address registry, address ca, address ref, IMarketRegistry.OracleMode mode)
        external
        view
        returns (address)
    {
        return _wrappers[keccak256(abi.encode(registry, ca, ref, uint8(mode)))];
    }
}

/// @title EventReplayTest
/// @notice The event set's whole reason for being: replaying the log must rebuild the registry.
/// @dev One scenario drives every store through both verbs and through the paths that are easy to
///      get wrong — swap-and-pop removal, a label re-pointed by remove-then-add, an asset whose
///      absent source slot arrives full of junk, and a `deploy` whose wrapper key is built from
///      the mode and the resolved wiring rather than from the pair alone.
///
///      The comparison is deliberately made against the registry's ENUMERATION, not against a
///      hand-written expectation. A test that lists what it expects proves the scenario; comparing
///      the two sides proves the property.
contract EventReplayTest is RegistryFixture {
    RegistryMirror internal mirror;

    address internal tokA;
    address internal tokB;
    address internal tokC;
    address internal tokD;
    address internal vault;
    address internal gbpUnit;
    address internal gbpUnitReplacement;
    address internal wrapper;

    /// @dev Two contracts to approve as recipes. `addRecipes` only requires code at the address, so
    ///      the factories the fixture already deploys serve, and this suite does not have to pull in
    ///      a real recipe it never calls.
    address internal recipeOne;
    address internal recipeTwo;

    // ── the scenario ───────────────────────────────────────────────────────────

    /// @dev Recording starts BEFORE the registry exists, because `initialize` seeds the US Dollar and
    ///      Ether pseudo-units into the denomination store and those two writes are part of the state a
    ///      replay has to account for. An indexer starting at the deployment block sees them; so does
    ///      this.
    function setUp() public {
        vm.recordLogs();

        _deployRegistry(address(this));
        mirror = new RegistryMirror();

        recipeOne = address(wrapperFactory);
        recipeTwo = address(fixedRateOracleFactory);

        // Feeds and denominations first — every source an asset names is validated on the way in.
        _addEthUsdFeed();
        gbpUnit = makeAddr("gbpUnit");
        gbpUnitReplacement = makeAddr("gbpUnitReplacement");
        _registerDenominationWithUsdFeed(gbpUnit, makeAddr("gbpUsdAggregator"));
        _addFeed(USD_UNIT, ETH_UNIT, makeAddr("usdEthAggregator"));

        tokA = _newToken("AAA", 6);
        tokB = _newToken("BBB", 18);
        tokC = _newToken("CCC", 8);
        tokD = _newToken("DDD", 18);
        vault = _newToken("VLT", 18);

        // Four assets in ONE batch: four separate `EntryAdded` logs, not one for the call.
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](4);
        batch[0] = mkPriceOnlyAsset(tokA, "ALPHA", tokA, USD_UNIT);
        batch[1] = mkPriceOnlyAsset(tokB, "BRAVO", tokB, USD_UNIT);
        batch[2] = mkDualSourceAsset(tokC, "CHARLIE", tokC, USD_UNIT, vault, gbpUnit);
        batch[3] = _junkAbsentSourceAsset(tokD, "DELTA");
        iReg.addAssets(batch);

        // A wrapper, so the deploy record is in the replay too.
        wrapper = iReg.deploy(tokA, tokB, IMarketRegistry.OracleMode.PRICE, bytes32(0));

        // Now the removals — each one exercises swap-and-pop in a different store.
        iReg.removeAssets(one(tokB)); // DELTA swaps into BRAVO's slot
        iReg.removeConversionFeeds(one(gbpUnit), one(USD_UNIT));

        // A unit swapped for another the only way the registry allows: remove one, add the other.
        iReg.removeDenominations(one(gbpUnit));
        iReg.addDenominations(one(gbpUnitReplacement));

        address[] memory recipes = new address[](2);
        recipes[0] = recipeOne;
        recipes[1] = recipeTwo;
        iReg.addRecipes(recipes);
        iReg.removeRecipes(one(recipeOne));

        _replay();
    }

    /// @dev An asset whose ABSENT price slot carries a live-looking `sourceType`, `sourceInterface`
    ///      and denomination unit. All three are legal on the way in — presence is `addr != 0`, so nothing
    ///      validates a slot that is not there — and all three are discarded by the write. It exists
    ///      to pin that the LOG reports what was stored rather than what was submitted.
    function _junkAbsentSourceAsset(address addr, string memory name) internal returns (IMarketRegistry.Asset memory) {
        IMarketRegistry.AssetSource memory junk = IMarketRegistry.AssetSource({
            addr: address(0),
            sourceType: IMarketRegistry.SourceType.NAV,
            sourceInterface: IMarketRegistry.SourceInterface.ERC4626,
            denomination: makeAddr("notARegisteredUnit")
        });
        return mkAsset(addr, name, IMarketRegistry.AssetKind.ERC20, junk, noSource());
    }

    /// @dev Feed every log the registry emitted into the mirror, in order. Logs from anything else —
    ///      the token deployments, the wrapper factory — are skipped, exactly as an indexer watching
    ///      one address would skip them.
    function _replay() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(reg)) continue;
            mirror.applyEvent(logs[i].emitter, logs[i].topics, logs[i].data);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // The property
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Every asset, in the registry's own enumeration order, matches the replay field for
    ///         field — including the two source slots and their denomination strings.
    function test_replay_rebuildsAssetsInOrder() public view {
        (IMarketRegistry.Asset[] memory page, uint256 total) = iReg.getAssets(0, 100);
        assertEq(mirror.assetCount(), total, "asset count diverged");
        assertGt(total, 0, "scenario must leave assets behind");

        for (uint256 i = 0; i < total; ++i) {
            _assertAssetEq(mirror.assetAt(i), page[i], string.concat("asset ", vm.toString(i)));
        }
    }

    /// @notice The swap-and-pop that removing BRAVO caused is reproduced by event order alone.
    /// @dev Nothing in the log states an index. If enumeration order were not implied by the order of
    ///      the events, this is where it would show.
    function test_replay_reproducesSwapAndPopOrder() public view {
        (IMarketRegistry.Asset[] memory page,) = iReg.getAssets(0, 100);
        assertEq(page.length, 3, "one of the four assets was removed");
        assertEq(page[0].name, "ALPHA", "first slot unchanged");
        assertEq(page[1].name, "DELTA", "the last entry must have swapped into the freed slot");
        assertEq(page[2].name, "CHARLIE", "third slot unchanged");

        assertEq(mirror.assetAt(1).addr, page[1].addr, "replay did not reproduce the swap");
    }

    /// @notice The name index is replayable, which is only true because the name rides in the payload.
    function test_replay_rebuildsNameIndex() public view {
        (IMarketRegistry.Asset[] memory page, uint256 total) = iReg.getAssets(0, 100);
        for (uint256 i = 0; i < total; ++i) {
            (bool found, IMarketRegistry.Asset memory viaName) = iReg.lookupAssetByName(page[i].name);
            assertTrue(found, "registry lost its own name index");
            _assertAssetEq(mirror.assetByName(page[i].name), viaName, page[i].name);
        }

        // A name that was removed must resolve in NEITHER, or the mirror is holding a ghost.
        (bool stillThere,) = iReg.lookupAssetByName("BRAVO");
        assertFalse(stillThere, "removed name still resolves on the registry");
        assertEq(mirror.assetByName("BRAVO").addr, address(0), "removed name still resolves on the replay");
    }

    /// @notice Conversion feeds — the denomination hop graph — survive the round trip whole.
    function test_replay_rebuildsConversionFeeds() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = iReg.getConversionFeeds(0, 100);
        assertEq(mirror.feedCount(), total, "feed count diverged");
        assertGt(total, 0, "scenario must leave feeds behind");

        for (uint256 i = 0; i < total; ++i) {
            IMarketRegistry.ConversionFeed memory got = mirror.feedAt(i);
            string memory tag = string.concat("feed ", vm.toString(i));
            assertEq(got.base, page[i].base, string.concat(tag, ": base"));
            assertEq(got.quote, page[i].quote, string.concat(tag, ": quote"));
            assertEq(got.aggregatorAddress, page[i].aggregatorAddress, string.concat(tag, ": aggregator"));
        }
    }

    /// @notice Denominations, including the two `initialize` seeded and the unit swapped by a
    ///         remove-then-add pair.
    function test_replay_rebuildsDenominations() public view {
        (address[] memory page, uint256 total) = iReg.getDenominations(0, 100);
        assertEq(mirror.denominationCount(), total, "denomination count diverged");

        for (uint256 i = 0; i < total; ++i) {
            assertEq(mirror.denominationAt(i), page[i], string.concat("denomination ", vm.toString(i), ": unit"));
        }

        // The swap landed on both sides: the old unit is gone and the new one is registered.
        assertFalse(iReg.isDenomination(gbpUnit), "registry must have dropped the removed unit");
        assertTrue(iReg.isDenomination(gbpUnitReplacement), "registry must report the newly added unit");
    }

    /// @notice Recipes come back as ADDRESSES, which the old hash-only event made impossible.
    function test_replay_rebuildsRecipeAddresses() public view {
        (address[] memory page, uint256 total) = iReg.getRecipes(0, 100);
        assertEq(mirror.recipeCount(), total, "recipe count diverged");
        assertEq(total, 1, "one of the two recipes was removed");

        for (uint256 i = 0; i < total; ++i) {
            assertEq(mirror.recipeAt(i), page[i], "recipe address diverged");
        }
        assertEq(page[0], recipeTwo, "the survivor must be the one that was not removed");
    }

    /// @notice The wrapper record is replayable by (pair, mode) — the identity the log carries. The
    ///         registry's own key folds in live wiring, so it is a view rather than something to rebuild.
    function test_replay_rebuildsWrapperRecord() public view {
        assertEq(
            mirror.wrapperFor(address(reg), tokA, tokB, IMarketRegistry.OracleMode.PRICE),
            wrapper,
            "wrapper record not replayable"
        );
        assertTrue(wrapper != address(0), "scenario must have deployed a wrapper");
    }

    /// @notice An absent source arrives full of junk and is stored as zeros — and the LOG says zeros.
    /// @dev Without this the replay would rebuild `DELTA` with a `NAV` price slot quoting a unit that
    ///      was never registered, and every downstream consumer would inherit that fiction.
    function test_replay_absentSourceIsReportedAsStoredNotAsSubmitted() public view {
        (, IMarketRegistry.Asset memory stored) = iReg.lookupAssetByAddress(tokD);
        assertEq(stored.priceSource.denomination, address(0), "registry must zero an absent slot");

        IMarketRegistry.Asset memory replayed = mirror.assetByName("DELTA");
        assertEq(replayed.addr, tokD, "DELTA missing from the replay");
        assertEq(replayed.priceSource.addr, address(0), "absent slot must replay as absent");
        assertEq(replayed.priceSource.denomination, address(0), "junk denomination leaked into the log");
        assertEq(
            uint256(uint8(replayed.priceSource.sourceType)),
            uint256(uint8(IMarketRegistry.SourceType.PRICE)),
            "junk sourceType leaked into the log"
        );
        assertEq(
            uint256(uint8(replayed.priceSource.sourceInterface)),
            uint256(uint8(IMarketRegistry.SourceInterface.AGGREGATOR_V3)),
            "junk sourceInterface leaked into the log"
        );
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _assertAssetEq(IMarketRegistry.Asset memory got, IMarketRegistry.Asset memory want, string memory tag)
        internal
        pure
    {
        assertEq(got.addr, want.addr, string.concat(tag, ": addr"));
        assertEq(got.name, want.name, string.concat(tag, ": name"));
        assertEq(uint256(uint8(got.kind)), uint256(uint8(want.kind)), string.concat(tag, ": kind"));
        _assertSourceEq(got.priceSource, want.priceSource, string.concat(tag, ": priceSource"));
        _assertSourceEq(got.navSource, want.navSource, string.concat(tag, ": navSource"));
    }

    function _assertSourceEq(
        IMarketRegistry.AssetSource memory got,
        IMarketRegistry.AssetSource memory want,
        string memory tag
    ) internal pure {
        assertEq(got.addr, want.addr, string.concat(tag, ".addr"));
        assertEq(uint256(uint8(got.sourceType)), uint256(uint8(want.sourceType)), string.concat(tag, ".sourceType"));
        assertEq(
            uint256(uint8(got.sourceInterface)),
            uint256(uint8(want.sourceInterface)),
            string.concat(tag, ".sourceInterface")
        );
        assertEq(got.denomination, want.denomination, string.concat(tag, ".denomination"));
    }
}
