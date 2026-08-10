// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";

import {FixedRateOracleFactory} from "../../../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../../../src/MarketRegistry.sol";
import {IMarketRegistry} from "../../../src/interfaces/IMarketRegistry.sol";
import {
    mkDualSourceAsset,
    mkFeed,
    mkNavOnlyAsset,
    mkNavSource,
    mkPriceOnlyAsset,
    mkPriceSource,
    mkSourcelessAsset,
    noSource
} from "../../helpers/RegistryFixture.sol";
import {MockWrapperFactory, MockToken} from "../../mocks/MockWrapperFactory.sol";
import {one} from "../../helpers/ArrayHelpers.sol";

/// @title RegistryHandler — stateful-fuzz driver for the MarketRegistry invariant suite.
/// @notice Reaches every mutating function of the registry the store invariants depend on — addAsset /
///         removeAsset / addAssetBatch / reAddAsset, addConversionFeed / removeConversionFeed /
///         addConversionFeedBatch, deploy — and keeps ghost variables that mirror the EXPECTED live set of
///         each enumerated store plus the set of deployed (ca, ref, mode) triples and their recorded
///         wrappers. The invariant contract compares the ghosts (and direct `vm.load` reads) against the
///         two `get*` enumerations, the lookup views, and `lookupWrapper`.
///
///         `deploy(ca, ref, mode)` takes two REGISTERED assets and reads their live `decimals()`, so this
///         handler keeps a small POOL of {MockToken} assets registered and PROTECTED from removal and
///         from source mutation, guaranteeing `deploy` always has valid targets. Every deploy runs
///         through one deterministic {MockWrapperFactory}, so a given (pair, resolved-sources)
///         combination lands at a stable wrapper — and a repeat deploy of the same combination is an
///         idempotent no-op that returns the recorded address.
///
///         DESIGN — why removes and deploys really fire: conservation and enumeration consistency
///         hold VACUOUSLY for an add-only handler, so removes and deploys are a first-class fraction
///         of the action mix; `afterInvariant` (in the invariant contract) HARD-ASSERTS that deploy,
///         removeAsset, and removeConversionFeed each fired at least once.
///
///         ROBUSTNESS: every registry call is wrapped in try/catch and ghosts update only on
///         success. Structural rejections are caught and simply do not advance state.
///
/// @dev ## What the successor shapes changed here, and why each change was forced
///
///      1. **`chainId` is gone** from `Asset`, from `ConversionFeed`, from every natural key and from
///         every signature. The predecessor stamped a FOREIGN chain id on every fuzz-added entry so the
///         write-time denomination walk would be skipped; there is no walk on the add path any more and
///         no chain field to stamp, so `FOREIGN_CHAIN` is deleted outright rather than relocated.
///         `removeAsset(addr)`, `removeConversionFeed(base, quote)` and the two ghost key derivations
///         all lost their chain argument with it.
///      2. **The registry constructor takes THREE arguments** — owner, wrapper factory, fixed-rate
///         oracle factory — and zero-checks both factories, so the handler deploys a real
///         {FixedRateOracleFactory} alongside the mock wrapper factory.
///      3. **`deploy` takes an `OracleMode`** and wrappers are keyed by `(registry, ca, ref, caSource,
///         refSource)`, so one pair can hold a NAV wrapper AND a price wrapper at once. The ghost pair
///         record therefore carries the MODE, and `lookupWrapper` is asked for it.
///      4. **The denomination lives on each SOURCE**, is validated at write time, and there is no
///         asset-level field. Every source this handler builds quotes `"USD"`, which the registry
///         constructor seeds and which reaches US Dollars in ZERO hops — so no conversion feed has to
///         exist first, and the fuzz-added feeds (whose base/quote are unregistered pseudo-units)
///         cannot make an asset write succeed or fail.
///      5. **A SOURCELESS asset is a legal entry.** `EmptySources` is deleted. So {_buildAsset} emits
///         four shapes, one of them sourceless, and {reAddAsset} can re-add a fuzz-added asset with no
///         source and turn it back into one. That is deliberate: the store invariants must hold over
///         sourceless entries, and the one invariant that assumed otherwise was restated in the
///         invariant contract (see `invariant_I04_presentSourcesCarryADenomination`).
contract RegistryHandler is Test {
    // ── system under test ──────────────────────────────────────────────────────
    MarketRegistry public reg;
    IMarketRegistry public ireg;
    /// @dev The one deterministic factory the deploy path runs through.
    MockWrapperFactory public factory;
    /// @dev The real fixed-rate oracle factory the third constructor argument requires. Nothing in
    ///      this handler calls it — it exists because the registry refuses a zero one.
    FixedRateOracleFactory public fixedRateOracleFactory;

    /// @notice The denomination label every source this handler builds quotes in.
    /// @dev `"USD"` is seeded by the registry constructor and its unit IS the US Dollar sentinel, so
    ///      `resolvePath` returns an empty path and no conversion feed has to exist for a write to
    ///      succeed. Using anything else would couple every asset add to the feed store the fuzzer is
    ///      simultaneously adding to and removing from.
    string internal constant DENOM = "USD";

    // Bounded universes.
    uint256 internal constant ASSET_POOL = 24;
    uint256 internal constant FEED_POOL = 24;
    uint256 internal constant DEPLOY_POOL = 5; // MockToken assets kept registered for `deploy`

    // ── deploy pool (protected assets with real code) ─────────────────────────────
    //
    // "Protected" is expressed by ONE mechanism and no other: a deploy-pool asset is recorded with
    // `removable == false`, so its key never enters `_rmKeys`, and `removeAsset` / `reAddAsset` both
    // pick exclusively from that list. There is deliberately no separate protection flag — a second
    // representation of the same fact would be a thing to keep in step, and a reader could mistake it
    // for the guard when it is not.
    address[] internal _deployPool;

    // ── ghost: assets ────────────────────────────────────────────────────────────
    struct AssetRec {
        address addr;
        string name;
    }

    bytes32[] internal _aKeys; // live asset keys (handler-side swap-and-pop)
    mapping(bytes32 => bool) internal _aLive;
    mapping(bytes32 => uint256) internal _aPos;
    mapping(bytes32 => AssetRec) internal _aRec;
    mapping(bytes32 => bytes32) internal _aNameKey; // assetKey -> nameKey
    mapping(bytes32 => bool) internal _nameLive; // nameKey -> live

    // Removable (non-protected) asset keys — `removeAsset` and `reAddAsset` pick from here so they
    // reliably land on a fuzz-added asset rather than skipping on a protected deploy-pool asset.
    bytes32[] internal _rmKeys;
    mapping(bytes32 => uint256) internal _rmPos;
    mapping(bytes32 => bool) internal _rmLive;

    // ── ghost: feeds ───────────────────────────────────────────────────────────
    struct FeedRec {
        address base;
        address quote;
    }

    bytes32[] internal _fKeys;
    mapping(bytes32 => bool) internal _fLive;
    mapping(bytes32 => uint256) internal _fPos;
    mapping(bytes32 => FeedRec) internal _fRec;

    // ── ghost: deployed (ca, ref, mode) triples and their recorded wrappers ──────
    struct PairRec {
        address ca;
        address ref;
        IMarketRegistry.OracleMode mode;
        address wrapper;
    }

    PairRec[] internal _pairs;
    mapping(bytes32 => bool) internal _pairSeen; // pairKey => already recorded

    // ── success-only call counters (afterInvariant coverage guard) ───────────────
    uint256 public addAssetCalls;
    uint256 public addAssetBatchCalls;
    uint256 public removeAssetCalls;
    uint256 public reAddAssetCalls;
    uint256 public addConversionFeedCalls;
    uint256 public addConversionFeedBatchCalls;
    uint256 public removeConversionFeedCalls;
    uint256 public deployCalls;

    /// @notice How many SOURCELESS assets were successfully added.
    /// @dev The anti-vacuity guard for the one shape that used to be rejected outright. A sourceless
    ///      entry is legal now (`EmptySources` is deleted), and the store invariants are supposed to hold
    ///      over it — so `afterInvariant` asserts this counter moved, otherwise "the invariants hold over
    ///      sourceless assets" would be satisfied by never producing one.
    uint256 public sourcelessAssetAdds;

    constructor() {
        factory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        // Handler is the owner, so no pranking is needed anywhere below.
        reg = new MarketRegistry();
        reg.initialize(address(this), address(factory), address(fixedRateOracleFactory));
        ireg = IMarketRegistry(address(reg));

        // Register the protected deploy pool. Each is a {MockToken} answering `decimals()`, which
        // `_wireLeg` reads live on both legs (and again off the VAULT on an ERC-4626 leg). Alternating
        // shapes keep BOTH oracle modes reachable: `PRICE` needs a price source on every leg, and `NAV`
        // additionally needs at least one real NAV source across the two legs.
        for (uint256 i = 0; i < DEPLOY_POOL; i++) {
            address t = address(new MockToken(uint8(6 + i)));
            string memory name = string.concat("Pool", vm.toString(i));
            ireg.addAssets(
                one(
                    i % 2 == 0
                        // Dual source: usable as a leg in PRICE mode and in NAV mode.
                        ? mkDualSourceAsset(t, name, t, t, DENOM)
                        // Price only: usable in PRICE mode, and in NAV mode by falling back.
                        : mkPriceOnlyAsset(t, name, t, DENOM)
                )
            );
            _recordAsset(t, name, false); // protected: never enters `_rmKeys`
            _deployPool.push(t);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Asset actions
    // ═════════════════════════════════════════════════════════════════════════════

    function addAsset(uint256 seed, uint8 shapeSeed) external {
        uint256 slot = bound(seed, 0, ASSET_POOL - 1);
        address a = _poolAddr("asset", slot);
        string memory name = _assetName(slot);
        IMarketRegistry.Asset memory e = _buildAsset(a, name, shapeSeed);
        bool sourceless = _isSourceless(e);
        try ireg.addAssets(one(e)) {
            _recordAsset(a, name, true);
            addAssetCalls++;
            if (sourceless) sourcelessAssetAdds++;
        } catch {}
    }

    function addAssetBatch(uint256 seed, uint8 countSeed) external {
        uint256 c = bound(countSeed, 1, 4);
        uint256 base = bound(seed, 0, ASSET_POOL - 1);
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](c);
        address[] memory addrs = new address[](c);
        string[] memory names = new string[](c);
        for (uint256 j = 0; j < c; j++) {
            uint256 slot = (base + j) % ASSET_POOL; // distinct within the batch (c <= pool)
            addrs[j] = _poolAddr("asset", slot);
            names[j] = _assetName(slot);
            batch[j] = _buildAsset(addrs[j], names[j], uint8(slot));
        }
        try ireg.addAssets(batch) {
            for (uint256 j = 0; j < c; j++) {
                _recordAsset(addrs[j], names[j], true);
                if (_isSourceless(batch[j])) sourcelessAssetAdds++;
            }
            addAssetBatchCalls++;
        } catch {}
    }

    function removeAsset(uint256 seed) external {
        uint256 n = _rmKeys.length; // removable (non-protected) assets only
        if (n == 0) return;
        bytes32 key = _rmKeys[bound(seed, 0, n - 1)];
        AssetRec memory r = _aRec[key];
        try ireg.removeAssets(one(r.addr)) {
            _removeAssetGhost(key);
            removeAssetCalls++;
        } catch {}
    }

    /// @notice EDIT one of a fuzz-added asset's entries: remove it and add it straight back in a
    ///         different shape, which is the only way to change a stored asset now that there is no
    ///         update path.
    /// @dev Deliberately restricted to REMOVABLE assets: editing a deploy-pool asset down to sourceless
    ///      would make `deploy` revert `MissingSource` for every pair involving it, and the coverage
    ///      guard in `afterInvariant` would start failing for a reason that has nothing to do with the
    ///      invariants.
    ///
    ///      A shape with no source is a first-class case — an entry may be edited down to SOURCELESS,
    ///      which is exactly the state the store invariants have to keep holding over. That is why this
    ///      action exists at all: it is the only way the fuzzer reaches a previously-sourced asset that
    ///      has become sourceless.
    ///
    ///      The two calls are NOT wrapped in one `try`. If the remove succeeds and the add reverts, the
    ///      asset is genuinely gone and the ghost state must say so — which is precisely the hazard of
    ///      an unbundled edit, and worth having the invariants run over.
    function reAddAsset(uint256 seed, uint8 shapeSeed) external {
        uint256 n = _rmKeys.length;
        if (n == 0) return;
        bytes32 key = _rmKeys[bound(seed, 0, n - 1)];
        AssetRec memory r = _aRec[key];

        try ireg.removeAssets(one(r.addr)) {
            _removeAssetGhost(key);
        } catch {
            return;
        }

        IMarketRegistry.Asset memory e = _buildAsset(r.addr, r.name, shapeSeed);
        bool sourceless = _isSourceless(e);
        try ireg.addAssets(one(e)) {
            _recordAsset(r.addr, r.name, true);
            reAddAssetCalls++;
            if (sourceless) sourcelessAssetAdds++;
        } catch {}
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Conversion-feed actions
    // ═════════════════════════════════════════════════════════════════════════════

    function addConversionFeed(uint256 seed) external {
        uint256 slot = bound(seed, 0, FEED_POOL - 1);
        (address base, address quote) = _feedPair(slot);
        IMarketRegistry.ConversionFeed memory e = _buildFeed(base, quote, slot);
        try ireg.addConversionFeeds(one(e)) {
            _recordFeed(base, quote);
            addConversionFeedCalls++;
        } catch {}
    }

    function addConversionFeedBatch(uint256 seed, uint8 countSeed) external {
        uint256 c = bound(countSeed, 1, 4);
        uint256 base = bound(seed, 0, FEED_POOL - 1);
        IMarketRegistry.ConversionFeed[] memory batch = new IMarketRegistry.ConversionFeed[](c);
        address[] memory bases = new address[](c);
        address[] memory quotes = new address[](c);
        for (uint256 j = 0; j < c; j++) {
            uint256 slot = (base + j) % FEED_POOL;
            (bases[j], quotes[j]) = _feedPair(slot);
            batch[j] = _buildFeed(bases[j], quotes[j], slot);
        }
        try ireg.addConversionFeeds(batch) {
            for (uint256 j = 0; j < c; j++) {
                _recordFeed(bases[j], quotes[j]);
            }
            addConversionFeedBatchCalls++;
        } catch {}
    }

    function removeConversionFeed(uint256 seed) external {
        uint256 n = _fKeys.length;
        if (n == 0) return;
        bytes32 key = _fKeys[bound(seed, 0, n - 1)];
        FeedRec memory r = _fRec[key];
        try ireg.removeConversionFeeds(one(r.base), one(r.quote)) {
            _removeFeedGhost(key);
            removeConversionFeedCalls++;
        } catch {}
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Deploy action
    // ═════════════════════════════════════════════════════════════════════════════

    /// @dev The mode is fuzzed, so both wrapper families are exercised. A `NAV` request for a pair where
    ///      neither leg carries a NAV source reverts `NavModeWithoutNavSource` and is caught — the
    ///      alternating deploy-pool shapes make that the minority case rather than the rule.
    function deploy(uint256 seed, uint8 modeSeed) external {
        uint256 n = _deployPool.length;
        address ca = _deployPool[bound(seed, 0, n - 1)];
        address ref = _deployPool[bound(seed / 7, 0, n - 1)];
        IMarketRegistry.OracleMode mode = IMarketRegistry.OracleMode(bound(modeSeed, 0, 1));
        try ireg.deploy(ca, ref, mode) returns (address w) {
            deployCalls++;
            // Record the triple→wrapper the first time it deploys; a repeat is an idempotent no-op that
            // returns the same recorded address.
            bytes32 pk = keccak256(abi.encode(ca, ref, mode));
            if (!_pairSeen[pk]) {
                _pairSeen[pk] = true;
                _pairs.push(PairRec({ca: ca, ref: ref, mode: mode, wrapper: w}));
            }
        } catch {}
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Ghost read surface (view -> excluded from the fuzz target set)
    // ═════════════════════════════════════════════════════════════════════════════

    function assetCount() external view returns (uint256) {
        return _aKeys.length;
    }

    function assetAt(uint256 i) external view returns (address addr, string memory name) {
        AssetRec memory r = _aRec[_aKeys[i]];
        return (r.addr, r.name);
    }

    function feedCount() external view returns (uint256) {
        return _fKeys.length;
    }

    function feedAt(uint256 i) external view returns (address base, address quote) {
        FeedRec memory r = _fRec[_fKeys[i]];
        return (r.base, r.quote);
    }

    function pairCount() external view returns (uint256) {
        return _pairs.length;
    }

    function pairAt(uint256 i)
        external
        view
        returns (address ca, address ref, IMarketRegistry.OracleMode mode, address wrapper)
    {
        PairRec memory r = _pairs[i];
        return (r.ca, r.ref, r.mode, r.wrapper);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Builders
    // ═════════════════════════════════════════════════════════════════════════════

    /// @dev One of FOUR presence shapes, so the fuzzer covers every combination the successor `Asset`
    ///      admits — including the SOURCELESS one, which the deleted `EmptySources` error used to
    ///      forbid and which `addAsset` now accepts. A sourceless entry carries no denomination
    ///      anywhere, and that is a legitimate stored state rather than a defect.
    ///
    ///      The address is a bare pseudo-address with no code, and that is fine HERE: `addAsset` no
    ///      longer probes `asset()`, so nothing external is called on a fuzz-added asset. Only the
    ///      protected deploy pool needs real code, because only `deploy` reads `decimals()`.
    function _buildAsset(address a, string memory name, uint8 shapeSeed)
        internal
        view
        returns (IMarketRegistry.Asset memory e)
    {
        uint256 shape = bound(shapeSeed, 0, 3);
        if (shape == 0) return mkPriceOnlyAsset(a, name, a, DENOM);
        if (shape == 1) return mkNavOnlyAsset(a, name, a, DENOM);
        if (shape == 2) return mkDualSourceAsset(a, name, a, a, DENOM);
        return mkSourcelessAsset(a, name); // NEITHER source — legal, and the point
    }

    /// @dev Absence is `addr == 0` and nothing else, on both slots.
    function _isSourceless(IMarketRegistry.Asset memory e) internal pure returns (bool) {
        return e.priceSource.addr == address(0) && e.navSource.addr == address(0);
    }

    function _buildFeed(address base, address quote, uint256 slot)
        internal
        pure
        returns (IMarketRegistry.ConversionFeed memory e)
    {
        e = mkFeed(base, quote, _poolAddr("agg", slot), 8);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Ghost bookkeeping
    // ═════════════════════════════════════════════════════════════════════════════

    function _recordAsset(address a, string memory name, bool removable) internal {
        bytes32 key = _assetKey(a);
        if (_aLive[key]) return; // guard: a successful add means the key was free
        _aLive[key] = true;
        _aPos[key] = _aKeys.length;
        _aKeys.push(key);
        _aRec[key] = AssetRec({addr: a, name: name});
        bytes32 nk = _nameKey(name);
        _aNameKey[key] = nk;
        _nameLive[nk] = true;
        if (removable) {
            _rmLive[key] = true;
            _rmPos[key] = _rmKeys.length;
            _rmKeys.push(key);
        }
    }

    function _removeAssetGhost(bytes32 key) internal {
        uint256 p = _aPos[key];
        uint256 last = _aKeys.length - 1;
        bytes32 lastKey = _aKeys[last];
        _aKeys[p] = lastKey;
        _aPos[lastKey] = p;
        _aKeys.pop();
        delete _aPos[key];
        _aLive[key] = false;
        _nameLive[_aNameKey[key]] = false;

        // Mirror the removal in the removable-key list (removed assets are always removable).
        if (_rmLive[key]) {
            uint256 rp = _rmPos[key];
            uint256 rlast = _rmKeys.length - 1;
            bytes32 rlastKey = _rmKeys[rlast];
            _rmKeys[rp] = rlastKey;
            _rmPos[rlastKey] = rp;
            _rmKeys.pop();
            delete _rmPos[key];
            _rmLive[key] = false;
        }
    }

    function _recordFeed(address base, address quote) internal {
        bytes32 key = _feedKey(base, quote);
        if (_fLive[key]) return;
        _fLive[key] = true;
        _fPos[key] = _fKeys.length;
        _fKeys.push(key);
        _fRec[key] = FeedRec({base: base, quote: quote});
    }

    function _removeFeedGhost(bytes32 key) internal {
        uint256 p = _fPos[key];
        uint256 last = _fKeys.length - 1;
        bytes32 lastKey = _fKeys[last];
        _fKeys[p] = lastKey;
        _fPos[lastKey] = p;
        _fKeys.pop();
        delete _fPos[key];
        _fLive[key] = false;
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Pure key derivations (mirror the contract formulas — no chain component)
    // ═════════════════════════════════════════════════════════════════════════════

    function _assetKey(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(a));
    }

    function _feedKey(address base, address quote) internal pure returns (bytes32) {
        return keccak256(abi.encode(base, quote));
    }

    function _nameKey(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encode(_lower(name)));
    }

    /// @dev A–Z -> a–z fold, letters 0x41..0x5A only.
    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) {
                b[i] = bytes1(uint8(b[i]) + 0x20);
            }
        }
        return string(b);
    }

    function _poolAddr(string memory tag, uint256 slot) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(tag, slot)))));
    }

    function _feedPair(uint256 slot) internal pure returns (address base, address quote) {
        base = _poolAddr("feedBase", slot);
        quote = _poolAddr("feedQuote", slot);
    }

    function _assetName(uint256 slot) internal pure returns (string memory) {
        // Uppercase prefix so the A-Z name fold (INV-I-03) is actually exercised.
        return string.concat("Asset", vm.toString(slot));
    }
}
