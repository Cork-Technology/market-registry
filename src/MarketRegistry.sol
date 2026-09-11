// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFixedRateOracleFactory} from "./interfaces/IFixedRateOracleFactory.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {IVersion} from "./interfaces/IVersion.sol";
import {IWrapperFactory} from "./interfaces/IWrapperFactory.sol";
import {MarketRegistryLib} from "./MarketRegistryLib.sol";
import {MarketRegistryRecipe} from "./MarketRegistryRecipe.sol";

/// @title MarketRegistry
/// @notice The approval record and oracle-deployment entrypoint.
contract MarketRegistry is MarketRegistryRecipe, Initializable, IVersion {
    /// @notice The one `WrapperRateConsumerFactory` this registry builds every oracle through.
    /// @dev Set once through `initialize` rather than a constructor, so the creation code carries no arguments and
    ///      the registry lands on the same CREATE2 address on every chain. Deployed through `AtomicDeployer`, which
    ///      initializes in the deployment transaction.
    address public WRAPPER_FACTORY;

    /// @notice The one `FixedRateOracleFactory` this registry deploys every fixed-rate oracle through.
    /// @dev Set once through `initialize`; see `WRAPPER_FACTORY`.
    address public FIXED_RATE_ORACLE_FACTORY;

    /// @notice The market life this registry starts life bounding to: one month.
    /// @dev The pilot's number, not a permanent one — governance moves it with `setMaxExpiryDuration`
    ///      as longer-dated coverage is actually wanted. Starting tight is the safe direction: a bound
    ///      that is too tight rejects an honest order loudly, and one that is too loose mints a market
    ///      that outlives everyone who could complain about it.
    uint256 public constant DEFAULT_MAX_EXPIRY_DURATION = 30 days;

    // ── leg resolution (internal shapes) ────────────────────────────────────────

    /// @dev Which source one leg resolved to, and where to find it again. Produced by `_selectLeg`
    ///      using STORAGE READS ONLY — no external call — so an unregistered asset or a leg that cannot
    ///      serve the mode is refused before the registry touches another contract.
    ///
    ///      `useNav` records which FIELD was selected, not how the source is read. Those are different
    ///      questions: a `NAV` source may legitimately declare `SourceInterface.AGGREGATOR_V3` (an
    ///      aggregator that publishes an exchange rate), and it is the INTERFACE that decides whether
    ///      the source occupies the vault slot or a feed slot. `_wireLeg` reads the interface back out
    ///      of storage rather than caching a second flag here.
    struct LegSelection {
        bytes32 assetKey; // the leg's asset key, so `_wireLeg` can re-read the chosen source
        address source; // the resolved source address; lands in the leg's wiring and is named in `MarketOracleDeployed`
        bool useNav; // true when the NAV field was selected, false when the price field was
    }

    /// @dev One side of the Morpho oracle, fully resolved. Bundled into a struct so the twelve-argument
    ///      factory call can be assembled from two memory pointers instead of ten live locals — see
    ///      the stack-limit note on the contract.
    ///
    ///      This struct IS the wrapper's identity. The key `deploy` records under is a hash of the mode
    ///      and both legs' wiring, byte for byte what the factory is handed, so every field here is a
    ///      field a governance edit can re-key a pair on. Add a field and the key moves with it.
    struct LegWiring {
        address vault; // the ERC-4626 vault, or `address(0)` for a feed-shaped leg
        uint256 sample; // `10 ** shareDecimals` with a vault; EXACTLY 1 without one (the oracle requires it)
        address feed1; // the source aggregator, or the first bridge hop on a vault leg
        address feed2; // the bridge hop; `address(0)` when the leg's unit is already US Dollars
        uint256 tokenDecimals; // the token's own decimals; DEAD on a vault leg (the factory derives them)
    }

    /// @dev The deploying `AtomicDeployer` is a placeholder owner only: it calls `initialize` in the same
    ///      transaction, which hands ownership to the real owner. Keeping the constructor argument-free is what
    ///      keeps the creation code — and so the CREATE2 address — identical on every chain.
    constructor() Ownable(msg.sender) {}

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    /// @param initialOwner The owner (a curator Safe in production).
    /// @param wrapperFactory The `WrapperRateConsumerFactory` every oracle is built through.
    /// @param fixedRateOracleFactory The `FixedRateOracleFactory` every fixed-rate oracle is deployed
    function initialize(address initialOwner, address wrapperFactory, address fixedRateOracleFactory)
        external
        initializer
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (wrapperFactory == address(0)) revert ZeroAddress();
        if (fixedRateOracleFactory == address(0)) revert ZeroAddress();
        _transferOwnership(initialOwner);
        WRAPPER_FACTORY = wrapperFactory;
        FIXED_RATE_ORACLE_FACTORY = fixedRateOracleFactory;

        // The two Chainlink pseudo-units every registry starts with: the US-Dollar terminus every
        // bridge walk ends at, and Ether as the first bridge candidate.
        _addDenomination(MarketRegistryLib.USD_DENOMINATION);
        _addDenomination(MarketRegistryLib.ETH_DENOMINATION);

        // Through the same setter the owner uses, so the starting value is emitted rather than
        // silently written. A replayer that only reads logs must never have to guess where the bound
        // began.
        _setMaxExpiryDuration(DEFAULT_MAX_EXPIRY_DURATION);
    }

    /// @dev Disabled outright: the registry must never become ownerless. Every mutation here is
    ///      owner-only, so an ownerless registry is a frozen one — no new asset, no feed, no recipe,
    ///      and no way back.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }

    // ── deploy entrypoint (permissionless) ─────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    /// @dev Ordering here is the whole design of the function, so read it in order:
    ///
    ///      1. Resolve each leg's source, per leg. Storage reads only — no external call.
    ///      2. Apply the one CROSS-leg guard: in `NAV` mode at least one leg must have brought a real
    ///         NAV source. Without it a NAV-mode call with no NAV source anywhere would resolve to
    ///         exactly the wiring `PRICE` mode resolves to, and — because the mode is in the key —
    ///         build a second wrapper that is a price oracle in all but name. Refusing tells the
    ///         caller to ask for `PRICE`.
    ///      3. Wire both legs in full — denomination check, bridge path, vault and token decimals —
    ///         and derive the key from the mode and that wiring. The key is exactly as fine as the
    ///         arguments the factory receives: a governance edit that changes what the factory would
    ///         be handed for this pair moves the pair to a new key, and one that changes nothing the
    ///         factory sees keeps serving the same wrapper. So a removed feed or denomination makes a
    ///         repeat `deploy` fail with the same error a first `deploy` would, instead of serving a wrapper
    ///         built for wiring governance has since withdrawn; and a re-added feed re-keys and
    ///         rebuilds. The registry's own address is in the hash because the key seeds the
    ///         factory salt and the record of past deployments lives HERE, not in the factory: a
    ///         redeployed registry pointed at the same factory starts with an empty record, and
    ///         without its address in the salt its first `deploy` of an already-built pair would
    ///         re-derive the old salt and revert on the `CREATE2` collision with no error data.
    ///      4. Short-circuit on a recorded key. No write, no event, no factory call. A cache hit
    ///         still pays for the wiring reads — two token `decimals()`, the vault `decimals()` on a
    ///         vault leg, the denomination check and the path walk — which is the price of a key
    ///         that cannot go stale.
    ///      5. Mix the caller's `oracleSalt` into the key to get the factory salt, then build, record
    ///         and emit. The salt is NOT part of the key. The key answers "which wrapper serves this
    ///         pair"; the salt answers "where does it land". A salt that is a pure function of the key
    ///         can be spent by anyone ahead of time at the permissionless Morpho factory, and the
    ///         registry would then collide on it forever. With the caller's entropy in the salt, a
    ///         pre-spent salt costs the caller one failed call and a new salt, not the pair.
    ///
    ///      All of the resolution happens BEFORE the factory is called, so a `deploy` that fails on an
    ///      unreachable denomination writes nothing at all.
    function deploy(address ca, address ref, OracleMode mode, bytes32 oracleSalt)
        external
        override
        returns (address wrapper)
    {
        (address caSource, address refSource, LegWiring memory base, LegWiring memory quote) =
            _resolvePair(ca, ref, mode);
        bytes32 key = _wrapperKey(ca, ref, mode, base, quote);

        wrapper = _wrappers[key];
        if (wrapper != address(0)) return wrapper;

        wrapper = _callFactory(base, quote, keccak256(abi.encode(key, oracleSalt)));
        if (wrapper == address(0)) revert ZeroAddress();

        _wrappers[key] = wrapper;
        emit MarketOracleDeployed(ca, ref, wrapper, mode, caSource, refSource, msg.sender);
    }

    // ── fixed-rate oracle entrypoint (permissionless, stateless) ───────────────
    function deployFixedRateOracle(uint256 rate) external override returns (address oracle) {
        oracle = IFixedRateOracleFactory(FIXED_RATE_ORACLE_FACTORY).computeAddress(rate);

        // Already deployed at its deterministic address: hand it back rather than letting the factory's
        // CREATE2 collide and revert with no error data. No write and no event — a repeat call is a
        // no-op, matching `deploy`'s short-circuit.
        if (oracle.code.length != 0) return oracle;

        // A zero rate reaches HERE and reverts `IRateOracle.InvalidRate()` from the oracle's
        // constructor, because the predicted address for rate 0 can never hold code. See the trace above
        // before reordering these two statements.
        oracle = IFixedRateOracleFactory(FIXED_RATE_ORACLE_FACTORY).deploy(rate);
        emit FixedRateOracleDeployed(rate, oracle, msg.sender);
    }

    /// @inheritdoc IMarketRegistry
    function predictFixedRateOracle(uint256 rate) external view override returns (address oracle) {
        oracle = IFixedRateOracleFactory(FIXED_RATE_ORACLE_FACTORY).computeAddress(rate);
    }

    // ── market bound (owner-set) ───────────────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    function setMaxExpiryDuration(uint256 newDuration) external override onlyOwner {
        _setMaxExpiryDuration(newDuration);
    }

    /// @inheritdoc IMarketRegistry
    function maxExpiryDuration() external view override returns (uint256) {
        return _maxExpiryDuration;
    }

    function _setMaxExpiryDuration(uint256 newDuration) private {
        if (newDuration == 0) revert ZeroBound();
        emit MaxExpiryDurationUpdated(_maxExpiryDuration, newDuration);
        _maxExpiryDuration = newDuration;
    }

    // ── membership mutation (owner-only) ───────────────────────────────────────
    //
    // Two verbs per store, both taking arrays, and no update path anywhere — see the note on
    // `IMarketRegistry`'s mutation section for why an edit is a remove plus an add rather than a
    // third verb. Every one of these is all-or-nothing: the loops have no per-element error
    // handling, so one bad entry reverts the batch and nothing is written.

    /// @inheritdoc IMarketRegistry
    /// @dev Two passes, and the split is the point. The enum range-check runs over EVERY element
    ///      first, then the owner check, then the writes.
    ///
    ///      The owner check is called explicitly rather than via the `onlyOwner` modifier because a
    ///      malformed enum ordinal is a malformed call and should fail as one no matter who sent it,
    ///      instead of being masked by the authority error for a stranger and only surfacing for the
    ///      owner. Do not fold this back into a modifier, and do not merge the two loops — merging
    ///      would let element 0's ordinals be checked while element 1's are not, which is the same
    ///      hole in a different place.
    function addAssets(IMarketRegistry.Asset[] calldata entries) external override {
        uint256 len = entries.length;
        for (uint256 i = 0; i < len; ++i) {
            if (MarketRegistryLib.validateAssetEnums(entries[i]) == type(uint256).max) revert();
        }
        _checkOwner();
        for (uint256 i = 0; i < len; ++i) {
            _addAsset(entries[i]);
        }
    }

    /// @inheritdoc IMarketRegistry
    function removeAssets(address[] calldata addrs) external override onlyOwner {
        uint256 len = addrs.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeAsset(addrs[i]);
        }
    }

    /// @inheritdoc IMarketRegistry
    function addConversionFeeds(IMarketRegistry.ConversionFeed[] calldata entries) external override onlyOwner {
        uint256 len = entries.length;
        for (uint256 i = 0; i < len; ++i) {
            _addConversionFeed(entries[i]);
        }
    }

    /// @inheritdoc IMarketRegistry
    function removeConversionFeeds(address[] calldata bases, address[] calldata quotes) external override onlyOwner {
        uint256 len = bases.length;
        if (len != quotes.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len; ++i) {
            _removeConversionFeed(bases[i], quotes[i]);
        }
    }

    /// @inheritdoc IMarketRegistry
    function addDenominations(address[] calldata units) external override onlyOwner {
        uint256 len = units.length;
        for (uint256 i = 0; i < len; ++i) {
            _addDenomination(units[i]);
        }
    }

    /// @inheritdoc IMarketRegistry
    function removeDenominations(address[] calldata units) external override onlyOwner {
        uint256 len = units.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeDenomination(units[i]);
        }
    }

    // ── reads (unrestricted views) ─────────────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    function lookupAssetByAddress(address addr)
        external
        view
        override
        returns (bool found, IMarketRegistry.Asset memory entry)
    {
        bytes32 keyHash = MarketRegistryLib.assetKey(addr);
        if (_assetIndex[keyHash] != 0) {
            found = true;
            entry = _assets[keyHash];
        }
    }

    /// @inheritdoc IMarketRegistry
    function isAsset(address addr) external view override returns (bool) {
        return _assetIndex[MarketRegistryLib.assetKey(addr)] != 0;
    }

    /// @inheritdoc IMarketRegistry
    /// @dev Confirms `_assetIndex[keyHash] != 0` as well as the name mapping being non-zero. The name
    ///      index is derived, so a reader must never trust it alone.
    function lookupAssetByName(string calldata name)
        external
        view
        override
        returns (bool found, IMarketRegistry.Asset memory entry)
    {
        bytes32 keyHash = _assetByName[MarketRegistryLib.nameKey(name)];
        if (keyHash != bytes32(0) && _assetIndex[keyHash] != 0) {
            found = true;
            entry = _assets[keyHash];
        }
    }

    /// @inheritdoc IMarketRegistry
    function lookupConversionFeed(address base, address quote)
        external
        view
        override
        returns (bool found, IMarketRegistry.ConversionFeed memory entry)
    {
        bytes32 key = MarketRegistryLib.feedKey(base, quote);
        if (_feedIndex[key] != 0) {
            found = true;
            entry = _feeds[key];
        }
    }

    /// @inheritdoc IMarketRegistry
    function isDenomination(address unit) external view override returns (bool) {
        return _denominationIndex[unit] != 0;
    }

    /// @inheritdoc IMarketRegistry
    /// @dev The one resolver behind `deploy`, exposed as a view. It reverts for every reason `deploy`
    ///      would, and for the same reason: an integrator who predicts the wrapper address from this
    ///      key must learn that the pair is not deployable the same way a deployer would.
    function wrapperKey(address ca, address ref, OracleMode mode) external view override returns (bytes32) {
        (,, LegWiring memory base, LegWiring memory quote) = _resolvePair(ca, ref, mode);
        return _wrapperKey(ca, ref, mode, base, quote);
    }

    /// @inheritdoc IMarketRegistry
    /// @dev Answers for exactly the wrapper `deploy(ca, ref, mode, anySalt)` would return, because it derives
    ///      the same key. It never reverts: an unregistered asset, a leg that cannot serve the mode, a
    ///      NAV-mode call with no NAV source anywhere, a removed denomination or feed, and a token whose
    ///      `decimals()` cannot be read all mean "there is no wrapper for that", which is the same
    ///      answer as "not deployed yet" and is correctly reported as the zero address. The self-call
    ///      is what turns every one of those reverts into that answer without a second resolver that
    ///      could drift from the first. The same catch swallows an out-of-gas inside the self-call, so
    ///      a gas-starved caller also reads zero; zero means "not found", never "proven absent".
    function lookupWrapper(address ca, address ref, OracleMode mode) external view override returns (address wrapper) {
        try this.wrapperKey(ca, ref, mode) returns (bytes32 key) {
            wrapper = _wrappers[key];
        } catch {
            wrapper = address(0);
        }
    }

    // ── enumeration (paginated) ────────────────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    function getAssets(uint256 offset, uint256 limit)
        external
        view
        override
        returns (IMarketRegistry.Asset[] memory page, uint256 total)
    {
        total = _assetKeys.length;
        (uint256 start, uint256 count) = MarketRegistryLib.pageBounds(total, offset, limit);
        page = new IMarketRegistry.Asset[](count);
        for (uint256 i = 0; i < count; ++i) {
            page[i] = _assets[_assetKeys[start + i]];
        }
    }

    /// @inheritdoc IMarketRegistry
    function getConversionFeeds(uint256 offset, uint256 limit)
        external
        view
        override
        returns (IMarketRegistry.ConversionFeed[] memory page, uint256 total)
    {
        total = _feedKeys.length;
        (uint256 start, uint256 count) = MarketRegistryLib.pageBounds(total, offset, limit);
        page = new IMarketRegistry.ConversionFeed[](count);
        for (uint256 i = 0; i < count; ++i) {
            page[i] = _feeds[_feedKeys[start + i]];
        }
    }

    /// @inheritdoc IMarketRegistry
    function getDenominations(uint256 offset, uint256 limit)
        external
        view
        override
        returns (address[] memory page, uint256 total)
    {
        total = _denominationKeys.length;
        (uint256 start, uint256 count) = MarketRegistryLib.pageBounds(total, offset, limit);
        page = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            page[i] = _denominationKeys[start + i];
        }
    }

    // ── internals: leg resolution and the factory call ──────────────────────────

    /// @dev Everything `deploy` needs to know about a pair short of whether it was built before: the
    ///      two resolved sources (for the event) and the two fully wired legs (for the key and the
    ///      factory). Shared by `deploy` and `wrapperKey` so the key a reader derives is the key
    ///      `deploy` records under — one body, so the two cannot drift apart.
    function _resolvePair(address ca, address ref, OracleMode mode)
        private
        view
        returns (address caSource, address refSource, LegWiring memory base, LegWiring memory quote)
    {
        LegSelection memory caSel = _selectLeg(ca, mode);
        LegSelection memory refSel = _selectLeg(ref, mode);

        // Guard 1 of `OracleMode.NAV`: without it, a NAV-mode call in which NEITHER leg has a NAV
        // source would fall back to the price source on both legs and produce byte-for-byte the
        // wiring `PRICE` mode produces, under a name claiming otherwise. Refusing tells the caller to
        // ask for `PRICE`.
        if (mode == OracleMode.NAV && !caSel.useNav && !refSel.useNav) {
            revert NavModeWithoutNavSource(ca, ref);
        }

        (base, quote) = _wirePair(ca, ref, caSel, refSel);
        caSource = caSel.source;
        refSource = refSel.source;
    }

    /// @dev Per-leg source selection. Reverts with the selector naming what went wrong; `lookupWrapper`
    ///      turns that revert into the zero address by catching it around `wrapperKey`.
    function _selectLeg(address asset, OracleMode mode) private view returns (LegSelection memory sel) {
        sel.assetKey = MarketRegistryLib.assetKey(asset);
        if (_assetIndex[sel.assetKey] == 0) revert EntryNotFound();

        IMarketRegistry.Asset storage a = _assets[sel.assetKey];

        if (mode == OracleMode.NAV) {
            address nav = a.navSource.addr;
            if (nav != address(0)) {
                sel.source = nav;
                sel.useNav = true;
                return sel;
            }
            // Fall through to this leg's price source. Not silent: the source lands in the leg's
            // wiring, which the key and salt are derived from, and `MarketOracleDeployed` names it,
            // so the fallback is recorded on-chain.
        }

        sel.source = a.priceSource.addr;
        if (sel.source == address(0)) revert MissingSource(asset, mode);
    }

    /// @dev Turn both selections into the two sides of the Morpho oracle.
    ///
    ///      ## Orientation is fixed: REF is base, CA is quote
    ///
    ///      Preserved verbatim from the predecessor. `baseFeed1` comes from the REFERENCE asset,
    ///      `quoteFeed1` from the COLLATERAL asset, and the decimals arguments follow the same
    ///      assignment. Swapping it inverts every price this registry produces, silently.
    ///
    ///      ALL resolution — bridge feeds, vault decimals, token decimals — happens here, BEFORE the
    ///      key is derived and BEFORE `_callFactory`. So what is keyed is what is built, and a build
    ///      that fails on an unreachable or unregistered denomination has deployed nothing and written
    ///      nothing.
    function _wirePair(address ca, address ref, LegSelection memory caSel, LegSelection memory refSel)
        private
        view
        returns (LegWiring memory base, LegWiring memory quote)
    {
        base = _wireLeg(refSel, ref);
        quote = _wireLeg(caSel, ca);
    }

    /// @dev The wrapper record's key, which also seeds the factory salt. Hashes the registry, the pair, the mode and
    ///      the two wired legs in full — see `deploy` for why each of those is in it.
    function _wrapperKey(address ca, address ref, OracleMode mode, LegWiring memory base, LegWiring memory quote)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), ca, ref, mode, base, quote));
    }

    function _wireLeg(LegSelection memory sel, address token) private view returns (LegWiring memory w) {
        IMarketRegistry.AssetSource storage src =
            sel.useNav ? _assets[sel.assetKey].navSource : _assets[sel.assetKey].priceSource;

        // The unit must still be registered at deploy time. `addAssets` already checked this;
        // re-checking costs one `SLOAD` and covers a unit the owner has removed since.
        address unit = src.denomination;
        _requireDenomination(unit);

        w.tokenDecimals = IERC20Metadata(token).decimals();

        if (src.sourceInterface == IMarketRegistry.SourceInterface.ERC4626) {
            w.vault = sel.source;
            // Shares, so it scales in SHARE decimals — read off the vault, which is an ERC-20.
            w.sample = 10 ** uint256(IERC20Metadata(sel.source).decimals());
            address[] memory hops = MarketRegistryLib.resolvePath(_feedIndex, _feeds, _denominationKeys, unit, 2);
            if (hops.length > 0) w.feed1 = hops[0];
            if (hops.length > 1) w.feed2 = hops[1];
        } else {
            w.vault = address(0);
            w.sample = 1; // MANDATORY with no vault, not degenerate — the oracle requires exactly 1.
            w.feed1 = sel.source;
            // Budget 1: `feed1` is taken by the source, so the single bridge hop goes to `feed2`. An
            // empty path means the unit already IS US Dollars, and a zero feed reads as the price 1.
            address[] memory hops = MarketRegistryLib.resolvePath(_feedIndex, _feeds, _denominationKeys, unit, 1);
            if (hops.length > 0) w.feed2 = hops[0];
        }
    }

    function _callFactory(LegWiring memory base, LegWiring memory quote, bytes32 salt)
        private
        returns (address wrapper)
    {
        (wrapper,) = IWrapperFactory(WRAPPER_FACTORY)
            .createWrapperRateConsumer(
                base.vault,
                base.sample,
                base.feed1,
                base.feed2,
                base.tokenDecimals,
                quote.vault,
                quote.sample,
                quote.feed1,
                quote.feed2,
                quote.tokenDecimals,
                salt,
                salt
            );
    }

    // ── internals: denominations ────────────────────────────────────────────────

    /// @dev A duplicate is rejected rather than ignored, so the bridge search never carries the same
    ///      candidate twice and every add lands in the log exactly once.
    function _addDenomination(address unit) private {
        if (unit == address(0)) revert ZeroAddress();
        if (_denominationIndex[unit] != 0) revert EntryAlreadyExists();

        MarketRegistryLib.insertAddress(_denominationKeys, _denominationIndex, unit);
        emit EntryAdded(Namespace.Denomination, _denominationKeyHash(unit), abi.encode(unit));
    }

    function _removeDenomination(address unit) private {
        if (_denominationIndex[unit] == 0) revert EntryNotFound();

        MarketRegistryLib.removeAddress(_denominationKeys, _denominationIndex, unit);
        emit EntryRemoved(Namespace.Denomination, _denominationKeyHash(unit), abi.encode(unit));
    }

    /// @dev The event key for a denomination is the unit address itself, widened to 32 bytes — see
    ///      the `EntryAdded` table on the interface.
    function _denominationKeyHash(address unit) private pure returns (bytes32) {
        return bytes32(uint256(uint160(unit)));
    }

    function _requireDenomination(address unit) private view {
        if (_denominationIndex[unit] == 0) revert UnregisteredDenomination(unit);
    }

    function _validateSourcePath(IMarketRegistry.AssetSource calldata source) private view {
        address unit = source.denomination;
        _requireDenomination(unit);
        uint256 budget = source.sourceInterface == IMarketRegistry.SourceInterface.ERC4626 ? 2 : 1;
        MarketRegistryLib.resolvePath(_feedIndex, _feeds, _denominationKeys, unit, budget);
    }

    // ── internals: stores ───────────────────────────────────────────────────────

    function _addConversionFeed(IMarketRegistry.ConversionFeed calldata e) internal {
        if (e.base == address(0) || e.quote == address(0) || e.aggregatorAddress == address(0)) {
            revert ZeroAddress();
        }
        bytes32 key = MarketRegistryLib.feedKey(e.base, e.quote);
        if (_feedIndex[key] != 0) revert EntryAlreadyExists();
        _feeds[key] = e;
        MarketRegistryLib.insertBytes32(_feedKeys, _feedIndex, key);
        emit EntryAdded(Namespace.ConversionFeed, key, abi.encode(e));
    }

    function _removeConversionFeed(address base, address quote) private {
        bytes32 key = MarketRegistryLib.feedKey(base, quote);
        if (_feedIndex[key] == 0) revert EntryNotFound();
        MarketRegistryLib.removeBytes32(_feedKeys, _feedIndex, key);
        delete _feeds[key];
        emit EntryRemoved(Namespace.ConversionFeed, key, abi.encode(base, quote));
    }

    function _addAsset(IMarketRegistry.Asset calldata e) internal {
        if (e.addr == address(0)) revert ZeroAddress();
        if (bytes(e.name).length == 0) revert EmptyName();

        // Presence is `addr != 0`, and there is NO minimum. An asset with neither source is accepted —
        // see the sourceless-asset note above. Each `if` below is therefore the whole of the gate: an
        // absent source is skipped, so nothing validates a zero-address source and nothing reads the
        // enum ordinals or the `denomination` unit sitting behind it.
        bool hasPrice = e.priceSource.addr != address(0);
        bool hasNav = e.navSource.addr != address(0);

        if (hasPrice) {
            if (e.priceSource.sourceType != IMarketRegistry.SourceType.PRICE) {
                revert SourceTypeMismatch(IMarketRegistry.SourceType.PRICE, e.priceSource.sourceType);
            }
            _validateSourcePath(e.priceSource);
        }
        if (hasNav) {
            if (e.navSource.sourceType != IMarketRegistry.SourceType.NAV) {
                revert SourceTypeMismatch(IMarketRegistry.SourceType.NAV, e.navSource.sourceType);
            }
            _validateSourcePath(e.navSource);
        }

        bytes32 keyHash = MarketRegistryLib.assetKey(e.addr);
        if (_assetIndex[keyHash] != 0) revert EntryAlreadyExists();

        bytes32 nameKey = MarketRegistryLib.nameKey(e.name);
        if (_assetByName[nameKey] != 0) revert EntryAlreadyExists();

        IMarketRegistry.Asset storage s = _assets[keyHash];
        s.addr = e.addr;
        s.name = e.name;
        s.kind = e.kind;

        _writeSource(s.priceSource, e.priceSource);
        _writeSource(s.navSource, e.navSource);

        MarketRegistryLib.insertBytes32(_assetKeys, _assetIndex, keyHash);
        _assetByName[nameKey] = keyHash;

        // The STORED record, read back, not the submitted one. An absent source is normalised to zeros
        // on the way in, so a caller may hand over a slot whose `addr` is zero while its enums and
        // denomination hold anything at all. Emitting the argument would put that noise in the log and
        // a replay would rebuild an entry the registry never held.
        emit EntryAdded(Namespace.Asset, keyHash, abi.encode(s));
    }

    /// @dev The name index is cleared BEFORE the record, because the folded name key can only be
    ///      recomputed from the name the record holds. See slot 5.
    function _removeAsset(address addr) private {
        bytes32 keyHash = MarketRegistryLib.assetKey(addr);
        if (_assetIndex[keyHash] == 0) revert EntryNotFound();

        bytes32 nameKey = MarketRegistryLib.nameKey(_assets[keyHash].name);
        delete _assetByName[nameKey];
        MarketRegistryLib.removeBytes32(_assetKeys, _assetIndex, keyHash);
        delete _assets[keyHash];
        emit EntryRemoved(Namespace.Asset, keyHash, abi.encode(addr));
    }

    function _writeSource(IMarketRegistry.AssetSource storage dst, IMarketRegistry.AssetSource calldata src) private {
        if (src.addr == address(0)) {
            dst.addr = address(0);
            dst.sourceType = IMarketRegistry.SourceType.PRICE; // ordinal 0
            dst.sourceInterface = IMarketRegistry.SourceInterface.AGGREGATOR_V3; // ordinal 0
            dst.denomination = address(0);
            return;
        }
        dst.addr = src.addr;
        dst.sourceType = src.sourceType;
        dst.sourceInterface = src.sourceInterface;
        dst.denomination = src.denomination;
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.5.0";
    }
}
