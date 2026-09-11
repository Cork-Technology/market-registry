// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IMarketRegistry
/// @notice On-chain approval record and oracle-deployment entrypoint for Cork markets.
interface IMarketRegistry {
    // ── enums ────────────────────────────────────────────────────────────────

    /// @notice Which store an `EntryAdded` / `EntryRemoved` event refers to.
    /// @dev This is the discriminator a replayer switches on to decode the event's payload, so it
    ///      lives on the interface rather than in a library — a consumer generating bindings from the
    ///      ABI needs it, and both `MarketRegistry` and its base `MarketRegistryRecipe` emit the
    ///      shared pair, so the type has to be visible to both.
    ///
    ///      Ordinals are wire format — an enum is a `uint8` on the wire, and indexers filter on the
    ///      topic. APPEND ONLY: reordering or inserting silently rewrites the meaning of every
    ///      historical log. `None` holds 0 so a zeroed ordinal never reads as a real store.
    enum Namespace {
        None,
        Asset,
        ConversionFeed,
        Recipe,
        Denomination
    }

    /// @notice Whether the token is a plain token or a tokenized vault.
    /// @dev Descriptive metadata with no on-chain reader — consumed off-chain from lookup
    ///      returns. Derivation itself decides whether to unwrap by probing `asset()` at
    ///      runtime, not by this label.
    enum AssetKind {
        ERC20,
        ERC4626
    }

    /// @notice What a source MEASURES.
    /// @dev `PRICE` is a market price of the asset itself. `NAV` is a net-asset-value conversion —
    ///      how much underlying one share is worth — read from a tokenized vault. The distinction
    ///      is not cosmetic: it decides which slot of the Morpho oracle the source is wired into,
    ///      and therefore how many bridge hops are left over (see `AssetSource.denomination`).
    ///
    ///      This ordinal is the discriminator for which of an `Asset`'s two named source fields a
    ///      source may be written to. `addAssets` rejects a source whose `sourceType` disagrees with
    ///      the field receiving it (`SourceTypeMismatch`) rather than silently filing it in the other
    ///      slot.
    enum SourceType {
        PRICE,
        NAV
    }

    /// @notice How a source is READ.
    /// @dev `AGGREGATOR_V3` is a Chainlink-style `latestRoundData()` feed; `ERC4626` is a tokenized
    ///      vault read through `convertToAssets`. Kept separate from `SourceType` on purpose: the
    ///      two are correlated in practice but not by definition, and collapsing them would make an
    ///      aggregator that happens to publish an exchange rate unrepresentable.
    ///
    ///      Anything that is neither shape needs a bespoke wrapper that presents one of these two
    ///      interfaces. That is deliberate — the registry does not grow an interface per oracle.
    enum SourceInterface {
        AGGREGATOR_V3,
        ERC4626
    }

    /// @notice Which kind of rate oracle `deploy` is being asked to build.
    /// @dev Maps one-for-one onto `SourceType`, and the caller is the limit-order adapter, which
    ///      derives the mode from its recipe's `IMarketRecipe.source()`. `RecipeSource.FIXED` has no
    ///      counterpart here on purpose — a fixed-rate market has no rate for an oracle to supply,
    ///      so its adapter skips `deploy` entirely rather than passing some placeholder mode.
    ///
    ///      The two modes differ in how tolerant they are, and the asymmetry is deliberate:
    ///
    ///      - `PRICE` — EVERY leg must have a price source. The NAV source is never read. A leg
    ///        without a price source reverts `MissingSource`.
    ///      - `NAV` — each leg independently uses its NAV source when present and falls back to its
    ///        price source otherwise, PLUS two guards: at least one leg must actually have a NAV
    ///        source (`NavModeWithoutNavSource`, because otherwise the caller should have asked for
    ///        `PRICE` and NAV mode would silently collapse into it), and every leg must resolve to
    ///        SOME source (`MissingSource`).
    ///
    ///      A mixed pair — vault on one leg, feed on the other — is therefore first-class, not a
    ///      tolerated edge case. The Morpho oracle's two sides are fully independent (each side is a
    ///      product of vault × feed1 × feed2 with absent pieces as identity elements), and its own
    ///      fork tests cover mixed configurations. Forbidding mixed would forbid pricing a
    ///      yield-bearing vault against native US-Dollar-Coin, which is the main thing net-asset-value
    ///      pricing was wanted for.
    ///
    ///      The fallback is not silent. The resolved source lands in the leg's wiring, which the
    ///      wrapper key and salt are derived from, and `MarketOracleDeployed` names it, so which
    ///      source each leg actually used is recorded on-chain.
    enum OracleMode {
        PRICE,
        NAV
    }

    // ── structs ──────────────────────────────────────────────────────────────

    /// @notice One way to read an asset's value.
    struct AssetSource {
        address addr; // the aggregator (AGGREGATOR_V3) or the ERC-4626 vault (NAV); 0 means absent
        SourceType sourceType; // what it measures; must match the field it is written to
        SourceInterface sourceInterface; // how it is read; sets the hop budget (1 feed / 2 vault)
        address denomination; // REGISTERED unit this source quotes in (a token or a Chainlink `Denominations`
        // pseudo-address); the conversion path's start node
    }

    /// @notice An approved token and the structural facts needed to read its value.
    struct Asset {
        address addr; // the token's on-chain address; the whole natural key
        string name; // human-readable label; case-insensitive triage key only
        AssetKind kind; // ERC20 or ERC4626 (descriptive; derivation probes asset() live)
        AssetSource priceSource; // the PRICE source; `addr == 0` means absent
        AssetSource navSource; // the NAV source; `addr == 0` means absent
    }

    /// @notice An approved conversion feed for a (base, quote) address pair — one edge of the
    ///         denomination hop graph.
    /// @dev The feed's decimals are not stored. Nothing on-chain needs them here: the Morpho oracle
    ///      constructor reads the aggregator's `decimals()` live at deploy time.
    struct ConversionFeed {
        address base; // token (or Denominations pseudo-address) the feed reports on
        address quote; // token (or Denominations pseudo-address) the value is in
        address aggregatorAddress; // on-chain aggregator address; re-read live at verify
    }

    /// @notice A rate constraint as four concrete rate quantities — what a recipe resolves to.
    struct ResolvedConstraint {
        uint256 rateMin; // lower limit of the rate; the caller clamps UP to this if the rate falls below
        uint256 rateMax; // upper limit of the rate; the caller clamps DOWN to this if the rate rises above
        uint256 rateChangePerDayMax; // absolute rate movement allowed per day
        uint256 rateChangeCapacityMax; // absolute ceiling on accumulated allowance; caps every change even
        // when rateChangePerDayMax alone would allow more
    }

    // ── events ───────────────────────────────────────────────────────────────
    //
    // Membership is reported through exactly ONE pair of events, and between them they carry every
    // byte of every membership store. That is the contract this pair exists to honour: an indexer
    // that reads `EntryAdded` and `EntryRemoved` from the deployment block forward, in log order,
    // can rebuild the asset, conversion-feed, recipe and denomination stores exactly, with no
    // `eth_call` anywhere. Nothing the owner writes is visible only through a view function.
    //
    // Two things sit outside this pair. The market bound is a scalar setting rather than a store and
    // so has no natural key to hash: `MaxExpiryDurationUpdated` carries it, constructor included, so
    // its starting value is in the log too, and the "no `eth_call` anywhere" promise holds for it.
    //
    // The wrapper record is the one exception to that promise. `deploy` writes it permissionlessly
    // rather than the owner, and `MarketOracleDeployed` carries the wrapper, the pair and the mode it
    // answers for, and the two resolved source addresses — so an indexer can replay the full HISTORY
    // of wrappers built for a `(pair, mode)`. What it cannot do is say which of them `deploy` serves
    // today: the storage key folds in the live wiring (denomination, bridge path, `decimals()` reads),
    // so one `(pair, mode)` can emit several deploy events over time, and the registry serves
    // whichever key matches the wiring in force now. The live answer needs a view call —
    // `lookupWrapper` or `wrapperKey`.
    //
    // Two things make that work, and the earlier hash-only pair had neither:
    //
    //   - The RECORD travels with the key. `keyHash` is a keccak hash, so it names an entry but
    //     cannot be turned back into one — an indexer holding only hashes cannot say which token was
    //     removed, let alone what its sources were. The trailing `bytes` field carries the natural
    //     key, and on an add the whole record.
    //   - EVERY store shares the pair, denominations included. One decoder, one ordered stream.
    //
    // The array bookkeeping behind each store — the key arrays and their index maps — is deliberately
    // not emitted, because it is already implied: inserts append and removals are swap-and-pop, both
    // fully determined by the order of these events.
    //
    // One event per ENTRY, never per call: a batch of five assets produces five `EntryAdded` logs. An
    // idempotent no-op produces none, because it changes nothing.

    /// @notice Emitted once for every entry added to a registry store.
    /// @dev The payload's shape is decided by `namespace`, and a replayer switches on it:
    ///
    ///      | namespace        | keyHash                             | entry                        |
    ///      |------------------|-------------------------------------|------------------------------|
    ///      | `Asset`          | `keccak256(abi.encode(addr))`       | `abi.encode(Asset)`          |
    ///      | `ConversionFeed` | `keccak256(abi.encode(base,quote))` | `abi.encode(ConversionFeed)` |
    ///      | `Recipe`         | `keccak256(abi.encode(recipe))`     | `abi.encode(address)`        |
    ///      | `Denomination`   | `bytes32(uint256(uint160(unit)))`   | `abi.encode(address)`        |
    ///
    ///      The asset payload is what makes the NAME index replayable: `_assetByName` is keyed on a
    ///      case-folded hash of the name, and the name only ever appears here. A denomination is
    ///      nothing but its unit address, so its key is that address left-padded to 32 bytes — not
    ///      hashed — and the payload repeats it so every namespace decodes the same way.
    /// @param namespace The store the entry belongs to.
    /// @param keyHash The store's key for this entry. For the recipe store this addresses nothing —
    ///        that store is keyed by the raw address — and exists so the topic layout is uniform.
    ///        For the denomination store it is the unit address itself, widened to 32 bytes.
    /// @param entry The record, ABI-encoded per the table above.
    event EntryAdded(Namespace indexed namespace, bytes32 indexed keyHash, bytes entry);

    /// @notice Emitted once for every entry removed from a registry store.
    /// @dev The payload carries the NATURAL KEY only, not the record being destroyed: a replayer
    ///      already holds that from the matching `EntryAdded`, and the natural key is the one thing
    ///      `keyHash` cannot give back.
    ///
    ///      | namespace        | key                            |
    ///      |------------------|--------------------------------|
    ///      | `Asset`          | `abi.encode(address)`          |
    ///      | `ConversionFeed` | `abi.encode(address,address)`  |
    ///      | `Recipe`         | `abi.encode(address)`          |
    ///      | `Denomination`   | `abi.encode(address)`          |
    ///
    ///      Editing is still two events. An asset corrected in place shows up as a removal followed
    ///      by an add, never as a second add quietly overwriting the first.
    /// @param namespace The store the entry belonged to.
    /// @param keyHash The store's key for the removed entry.
    /// @param key The natural key, ABI-encoded per the table above.
    event EntryRemoved(Namespace indexed namespace, bytes32 indexed keyHash, bytes key);

    /// @notice Emitted when `deploy` produces a fresh rate oracle for a (collateral, reference)
    ///         pair.
    /// @dev Emitted only on a fresh deploy. A repeat `deploy` for an already-recorded key returns
    ///      the stored wrapper without emitting or changing state (idempotent).
    ///
    ///      An indexer keys the wrapper record by `(emitter, ca, ref, mode)`: the emitting registry's
    ///      address must be part of it, because two registries sharing one factory each keep their own
    ///      record. The registry's own storage key is `wrapperKey(ca, ref, mode)`, which folds in the
    ///      fully resolved wiring — including live `decimals()` reads — and is therefore a view, not
    ///      something to rebuild from the log. The two source addresses are resolved at deploy time —
    ///      in NAV mode a leg falls back to its price source when it has none of its own. Emitting
    ///      them records which source each leg actually used, and `mode` records what was asked for,
    ///      so a NAV wrapper and a price wrapper for the same pair are distinguishable in the log.
    /// @param ca The collateral asset the oracle was deployed for.
    /// @param ref The reference asset the oracle prices against.
    /// @param wrapper The rate-oracle (`WrapperRateConsumer`) address the factory returned.
    /// @param mode The oracle mode the caller asked for.
    /// @param caSource The source address the collateral leg resolved to.
    /// @param refSource The source address the reference leg resolved to.
    /// @param caller The account that called `deploy`.
    event MarketOracleDeployed(
        address indexed ca,
        address indexed ref,
        address indexed wrapper,
        OracleMode mode,
        address caSource,
        address refSource,
        address caller
    );

    /// @notice Emitted when `deployFixedRateOracle` actually deploys a `FixedRateOracle`.
    /// @dev Emitted on a GENUINE deployment only. `deployFixedRateOracle` is idempotent: a repeat call
    ///      for a rate whose oracle already exists returns the existing address and emits nothing, the
    ///      same discipline `MarketOracleDeployed` follows for a repeat `deploy`.
    ///
    ///      An indexer therefore sees at most ONE of these per rate per registry, and its absence for
    ///      a rate does not mean no oracle exists for that rate — the factory could have been called
    ///      directly, bypassing the registry entirely. `predictFixedRateOracle(rate)` plus a code-length
    ///      check is the authoritative answer to "does it exist"; this event answers "did this registry
    ///      deploy it, and who asked".
    /// @param rate The fixed rate the oracle was deployed with (one reference-asset unit quoted in the
    ///        collateral asset, scaled to 1e18).
    /// @param oracle The deployed `FixedRateOracle` address.
    /// @param caller The account that called `deployFixedRateOracle`.
    event FixedRateOracleDeployed(uint256 indexed rate, address indexed oracle, address caller);

    /// @notice Emitted whenever the owner changes the longest market life a fill may create.
    /// @dev Also emitted once from the constructor for the starting value, so the bound's whole
    ///      history is in the log and an indexer never has to call a view function to learn where it
    ///      began. It sits outside the `EntryAdded`/`EntryRemoved` pair for the same reason
    ///      `MarketOracleDeployed` does: this is a scalar setting, not a membership store, and the
    ///      pair's namespace ordinals are wire format that must stay append-only.
    /// @param previousDuration The bound before this call, in seconds.
    /// @param newDuration The bound after this call, in seconds.
    event MaxExpiryDurationUpdated(uint256 previousDuration, uint256 newDuration);

    // ── errors ───────────────────────────────────────────────────────────────

    /// @notice An `add` targeted a natural key — or an asset name key — that already exists.
    error EntryAlreadyExists();

    /// @notice A `remove` targeted a natural key that is not present, or `deploy` was asked for an
    ///         asset that is not registered.
    error EntryNotFound();

    /// @notice Two parallel array arguments were not the same length.
    /// @dev Only a call whose key arrives as two separate arrays can raise this:
    ///      `removeConversionFeeds` (bases against quotes).
    error ArrayLengthMismatch();

    /// @notice A structural check failed: an address field was the zero address — or the factory
    ///         returned the zero address from `deploy`.
    error ZeroAddress();

    /// @notice A structural check failed: a required name was empty.
    error EmptyName();

    /// @notice A source's denomination unit is not in the denomination set.
    /// @param unit The unit address that is not registered.
    error UnregisteredDenomination(address unit);

    /// @notice No chain of approved conversion feeds carries `fromUnit` to US Dollars within
    ///         `maxHops`.
    /// @param fromUnit The unit address the walk started from.
    /// @param maxHops The hop budget that was exhausted (1 for an aggregator source, 2 for a vault).
    error NoConversionPathToUsd(address fromUnit, uint256 maxHops);

    /// @notice `deploy` was asked for a mode a leg cannot serve: the leg has no usable source.
    /// @param asset The leg that cannot serve the mode.
    /// @param mode The mode that was requested.
    error MissingSource(address asset, OracleMode mode);

    /// @notice `deploy` was asked for `OracleMode.NAV` but NEITHER leg has a NAV source.
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    error NavModeWithoutNavSource(address ca, address ref);

    /// @notice A source was written to the wrong field: its `sourceType` does not match the slot.
    /// @param expected The `SourceType` the receiving field requires.
    /// @param provided The `SourceType` the supplied source declared.
    error SourceTypeMismatch(SourceType expected, SourceType provided);

    /// @notice A recipe address is not in the registry's approved set.
    /// @param recipe The address that is not a registered recipe.
    error RecipeNotRegistered(address recipe);

    /// @notice `addRecipes` was given an address with no code at it.
    /// @param recipe The address with no code at it.
    error RecipeNotContract(address recipe);

    /// @notice `renounceOwnership` is disabled: the registry must never become ownerless.
    error RenounceDisabled();

    /// @notice A governance bound was set to zero.
    /// @dev Rejected because zero is not a tighter bound, it is a market-creation kill switch wearing
    ///      the same clothes — every expiry is past `block.timestamp + 0`. Pausing belongs to the
    ///      controller, which has a pause built for it and an event that says so. A zero here would
    ///      stop creation silently.
    error ZeroBound();

    // ── deploy entrypoint (permissionless) ─────────────────────────────────────

    /// @notice Deploy a rate oracle for a (collateral, reference) pair in one oracle mode, and
    ///         return its address.
    /// @param ca The collateral asset (quote slot).
    /// @param ref The reference asset (base slot).
    /// @param mode Which kind of rate oracle to build; the caller derives this from its recipe's
    ///        `IMarketRecipe.source()`.
    /// @param oracleSalt Caller-chosen entropy mixed into the CREATE2 salt of the wrapper and its Morpho
    ///        oracle. It has no part in the wrapper key: it matters only on the call that first builds
    ///        the pair, and every later call for the pair returns the recorded wrapper whatever salt it
    ///        carries. Zero is fine. It exists so that nobody can brick a pair by spending its CREATE2
    ///        salt ahead of time — the caller picks a different salt and the pair deploys.
    /// @return wrapper The rate-oracle (`WrapperRateConsumer`) address for this pair and mode.
    function deploy(address ca, address ref, OracleMode mode, bytes32 oracleSalt) external returns (address wrapper);

    /// @notice Deploy a `FixedRateOracle` for `rate` through the registry's immutable fixed-rate oracle
    ///         factory, and return its address.
    /// @param rate The fixed rate (one reference-asset unit quoted in the collateral asset, scaled to
    ///        1e18 — a rate of `0.8e18` means one reference unit is worth `0.8` collateral). A zero rate
    ///        reverts `IRateOracle.InvalidRate()`.
    /// @return oracle The `FixedRateOracle` for this rate — freshly deployed, or the one that already
    ///         existed.
    function deployFixedRateOracle(uint256 rate) external returns (address oracle);

    /// @notice The address `deployFixedRateOracle(rate)` resolves to, whether or not it exists yet.
    /// @param rate The fixed rate the oracle is keyed by.
    /// @return oracle The deterministic `FixedRateOracle` address for this rate.
    function predictFixedRateOracle(uint256 rate) external view returns (address oracle);

    // ── market bound (owner-set, read by the market-creation periphery) ────────
    //
    // One number, and it exists because a market is PERMANENT. Nothing on-chain stops a caller from
    // creating one that expires in the year 58527: the pool manager only asks that the expiry is in
    // the future. A single mistyped payload therefore mints a market that can never be corrected, for
    // the price of gas. This bound is where that stops. It lives here rather than on the
    // market-creation contract because that contract is deliberately ownerless and immutable — see
    // `CorkLimitOrderAdapter` — and this registry already has the owner, the events, and the Safe
    // behind it.
    //
    // The bound gates CREATION only. A market that was created while a looser bound was in force keeps
    // filling after a tightening: its parameters are already baked into its pool id, so re-checking
    // them would strand honest orders against a market nobody can now re-create, and would protect
    // nothing that is not already permanent.

    /// @notice Set the longest life, in seconds, a market created through the periphery may have.
    /// @dev Owner-only. Zero reverts `ZeroBound`. Measured as a DURATION from the moment of creation,
    ///      never an absolute timestamp — an absolute deadline silently becomes "no market at all"
    ///      the day it passes.
    /// @param newDuration The new bound in seconds.
    function setMaxExpiryDuration(uint256 newDuration) external;

    /// @notice The longest market life, in seconds, the periphery will create.
    /// @return The current bound in seconds.
    function maxExpiryDuration() external view returns (uint256);

    // ── membership mutation (owner-only) ───────────────────────────────────────
    //
    // Every store has exactly TWO verbs, `add*` and `remove*`, and every one of them takes ARRAYS.
    // There is no update path anywhere in this interface, and that is the design rather than an
    // omission:
    //
    //   - EDITING an entry is removing it and adding it back. The owner is a curator Safe in
    //     production, so the two calls are bundled into ONE transaction; if they are ever allowed to
    //     land in separate transactions the entry is genuinely absent in between, and anything that
    //     depends on it — `deploy`, most of all — fails for that window. Bundle them.
    //   - Order matters within the bundle: remove first, then add. The other way round reverts
    //     `EntryAlreadyExists`, which is loud and safe.
    //   - An earlier draft folded removal into an update by treating an all-zero payload as "delete".
    //     That is gone on purpose: it overloads data with control meaning, so an under-filled struct
    //     silently destroys a live entry. Removal now has its own name.
    //
    // Every call is ALL-OR-NOTHING. One bad element reverts the whole batch and nothing is written.

    /// @notice Add approved assets, validating every present source's own denomination in the same
    ///         write.
    /// @dev Owner-only. Reverts `EntryAlreadyExists` if an entry — or an asset NAME — is already
    ///      taken, `ZeroAddress` on a zero token address, `EmptyName` on an empty name, and
    ///      `SourceTypeMismatch` if a source lands in the wrong field. Every PRESENT source must
    ///      already reach US Dollars, so feeds and denominations must be added before the assets that
    ///      need them.
    ///
    ///      Enum ordinals on EVERY element are range-checked before the owner gate, so a malformed
    ///      call fails as malformed no matter who sent it.
    /// @param entries The asset entries to add.
    function addAssets(Asset[] calldata entries) external;

    /// @notice Remove approved assets by address.
    /// @dev Owner-only. Missing key reverts `EntryNotFound`.
    /// @param addrs The token addresses to remove.
    function removeAssets(address[] calldata addrs) external;

    /// @notice Add approved conversion feeds — the edges of the denomination hop graph.
    /// @dev Owner-only. Structural validation only: non-zero base, quote, and aggregator.
    ///      Duplicate natural key reverts `EntryAlreadyExists`. Direction is part of the identity;
    ///      the inverse edge is a separate entry.
    /// @param entries The conversion-feed entries to add.
    function addConversionFeeds(ConversionFeed[] calldata entries) external;

    /// @notice Remove approved conversion feeds by their (base, quote) pairs.
    /// @dev Owner-only. Missing key reverts `EntryNotFound`; mismatched array lengths revert
    ///      `ArrayLengthMismatch`. No cascade: an asset whose source `denomination` reached US Dollars
    ///      only through a removed edge keeps its stored entry and starts failing at `deploy` —
    ///      including for a pair that was deployed before, because the wrapper record is keyed on the
    ///      wiring and is not consulted until the path has resolved. Removing an edge the live assets
    ///      depend on is a governance action with teeth, not a cleanup.
    /// @param bases The feeds' base addresses.
    /// @param quotes The feeds' quote addresses, positionally paired with `bases`.
    function removeConversionFeeds(address[] calldata bases, address[] calldata quotes) external;

    /// @notice Register denomination units — the set of units a source may quote in, and the
    ///         candidates the two-hop bridge search walks.
    /// @dev Owner-only. A unit already registered reverts `EntryAlreadyExists`; a zero unit reverts
    ///      `ZeroAddress`.
    /// @param units The unit addresses to register: a token address, or a Chainlink `Denominations`
    ///        pseudo-address for a denomination with no token of its own.
    function addDenominations(address[] calldata units) external;

    /// @notice Remove denomination units.
    /// @dev Owner-only. A unit that is not registered reverts `EntryNotFound`. No cascade, and teeth
    ///      of its own: an asset whose source still quotes a removed unit keeps its stored entry and
    ///      starts failing at `deploy` with `UnregisteredDenomination`, whether or not the pair was
    ///      deployed before — see `removeConversionFeeds`. Removing a unit also shortens the candidate
    ///      list `MarketRegistryLib.resolvePath` walks, so a two-hop path that bridged through it
    ///      stops resolving.
    /// @param units The unit addresses to remove.
    function removeDenominations(address[] calldata units) external;

    /// @notice Approve recipe contracts.
    /// @dev Owner-only. Reverts `ZeroAddress` on a zero address, `RecipeNotContract` on an address
    ///      with no code, and `EntryAlreadyExists` on one already approved.
    /// @param recipes The recipe contracts implementing `IMarketRecipe`.
    function addRecipes(address[] calldata recipes) external;

    /// @notice Withdraw approval from recipe contracts.
    /// @dev Owner-only. An address that is not approved reverts `EntryNotFound`.
    /// @param recipes The recipe contracts to remove.
    function removeRecipes(address[] calldata recipes) external;

    // ── reads (unrestricted views) ─────────────────────────────────────────────

    /// @notice Look up an approved asset by address.
    /// @param addr The token address.
    /// @return found True if an entry exists for this address.
    /// @return entry The asset entry, zeroed if not found.
    function lookupAssetByAddress(address addr) external view returns (bool found, Asset memory entry);

    /// @notice Whether an address is an approved asset.
    /// @dev The cheap membership test — one storage read, and none of the strings a full lookup
    ///      copies into memory. Use this when the answer is only ever yes or no.
    /// @param addr The token address to test.
    /// @return True if the address is a registered asset.
    function isAsset(address addr) external view returns (bool);

    /// @notice Look up an approved asset by name, case-insensitively. Triage only.
    /// @dev Resolves the secondary name index. This is a convenience lookup, never a safety key.
    /// @param name The asset name (any case; folding covers the letters A–Z only).
    /// @return found True if an entry exists for this name.
    /// @return entry The asset entry, zeroed if not found.
    function lookupAssetByName(string calldata name) external view returns (bool found, Asset memory entry);

    /// @notice Look up an approved conversion feed by its (base, quote) address pair.
    /// @param base The feed's base address (or Denominations pseudo-address).
    /// @param quote The feed's quote address (or Denominations pseudo-address).
    /// @return found True if an entry exists for this natural key.
    /// @return entry The conversion-feed entry, zeroed if not found.
    function lookupConversionFeed(address base, address quote)
        external
        view
        returns (bool found, ConversionFeed memory entry);

    /// @notice Whether a unit address is a registered denomination.
    /// @dev One storage read. This is the same test `addAssets` and `deploy` apply to every present
    ///      source's `denomination`.
    /// @param unit The unit address to test.
    /// @return True if the unit is registered.
    function isDenomination(address unit) external view returns (bool);

    /// @notice The key `deploy(ca, ref, mode, anySalt)` records its wrapper under, and the value it mixes
    ///         the caller's `oracleSalt` into to get the factory salt.
    /// @dev `keccak256(abi.encode(registry, ca, ref, mode, base, quote))`, where `base` and `quote` are
    ///      the reference and collateral legs fully resolved to what the factory is handed: each a
    ///      `(vault, sample, feed1, feed2, tokenDecimals)` tuple. Because the key is derived from the
    ///      wiring rather than from the stored sources, it changes whenever a governance edit changes
    ///      what the factory would be given for this pair — a re-pointed feed, a removed denomination,
    ///      a token whose `decimals()` moved — and a wrapper is only ever served for the wiring it was
    ///      built with.
    ///
    ///      Reverts for every reason `deploy` would: `EntryNotFound` for an unregistered asset,
    ///      `MissingSource` for a leg that cannot serve the mode, `NavModeWithoutNavSource`,
    ///      `UnregisteredDenomination`, `NoConversionPathToUsd`, and whatever a token's `decimals()`
    ///      reverts with. Use `lookupWrapper` for a read that must not revert.
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    /// @param mode The oracle mode the wrapper is or would be built for.
    /// @return The wrapper key for this pair and mode, as of the current stores. The factory salt
    ///         for a given `oracleSalt` is `keccak256(abi.encode(key, oracleSalt))`.
    function wrapperKey(address ca, address ref, OracleMode mode) external view returns (bytes32);

    /// @notice The wrapper `deploy(ca, ref, mode, anySalt)` would return, or the zero address if there is none.
    /// @dev Never reverts. Anything that would make `wrapperKey` revert reads as the zero address
    ///      here, because "no wrapper can exist for that" and "not deployed yet" are the same answer.
    ///
    ///      That includes running out of gas: the key is derived through a self-call, so a caller
    ///      that sends too little gas for it reads zero as well. Zero is therefore "no wrapper found",
    ///      not proof that none exists. An on-chain integrator under a tight gas stipend should use
    ///      `wrapperKey`, which reverts instead.
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    /// @param mode The oracle mode the wrapper was built for.
    /// @return wrapper The recorded wrapper address, or `address(0)` if none.
    function lookupWrapper(address ca, address ref, OracleMode mode) external view returns (address wrapper);

    /// @notice Whether an address is an approved recipe contract.
    /// @param recipe The address to test.
    /// @return True if the address is a registered recipe.
    function isRecipe(address recipe) external view returns (bool);

    // ── enumeration (paginated) ────────────────────────────────────────────────

    /// @notice Page through the approved assets.
    /// @param offset Index of the first entry to return.
    /// @param limit Maximum number of entries to return.
    /// @return page The requested slice of asset entries (empty when offset is past the end).
    /// @return total The total number of assets.
    function getAssets(uint256 offset, uint256 limit) external view returns (Asset[] memory page, uint256 total);

    /// @notice Page through the approved conversion feeds.
    /// @param offset Index of the first entry to return.
    /// @param limit Maximum number of entries to return.
    /// @return page The requested slice of conversion-feed entries.
    /// @return total The total number of conversion feeds.
    function getConversionFeeds(uint256 offset, uint256 limit)
        external
        view
        returns (ConversionFeed[] memory page, uint256 total);

    /// @notice Page through the registered denomination units, in registration order.
    /// @param offset Index of the first entry to return.
    /// @param limit Maximum number of entries to return.
    /// @return page The requested slice of unit addresses (empty when offset is past the end).
    /// @return total The total number of registered denominations.
    function getDenominations(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page, uint256 total);

    /// @notice Page through the approved recipe contracts.
    /// @param offset Index of the first entry to return.
    /// @param limit Maximum number of entries to return.
    /// @return page The requested slice of recipe addresses (empty when offset is past the end).
    /// @return total The total number of registered recipes.
    function getRecipes(uint256 offset, uint256 limit) external view returns (address[] memory page, uint256 total);
}
