// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";

/// @title MarketRegistryStorage
/// @notice Every storage slot `MarketRegistry` owns, and the rules that govern them.
/// @dev Every store here has the SAME shape — a record mapping, a key array, and a position mapping —
///      and the SAME two verbs, `add*` and `remove*`. There is no update path anywhere in the
///      registry: editing an entry is removing it and adding it back, which the owner bundles into
///      one transaction. That is why no store needs an in-place write path, and why the only
///      ordering rules below are removal rules.
abstract contract MarketRegistryStorage {
    // ── assets ──────────────────────────────────────────────────────────────────

    /// @dev Slot 2. The asset records themselves, addressed by natural key.
    ///      Key: `keccak256(abi.encode(addr))` — `assetKey` in the library. There is no synthetic
    ///      entry id: the token ADDRESS is the whole identity.
    mapping(bytes32 keyHash => IMarketRegistry.Asset) internal _assets;

    /// @dev Slot 3. Every live asset key, in insertion order — the enumeration `getAssets` pages
    ///      over. Not sorted, and not stable across removals: `removeBytes32` swaps the tail key into
    ///      the freed position. An entry that is removed and re-added therefore lands at the END of
    ///      this array, so nothing may name an asset by its position.
    bytes32[] internal _assetKeys;

    /// @dev Slot 4. Position of each key in `_assetKeys`, stored as `index + 1` so 0 means absent.
    ///      This is the membership test every reader uses, including `isAsset`.
    mapping(bytes32 keyHash => uint256) internal _assetIndex;

    /// @dev Slot 5. Secondary index: asset name → the primary key in `_assets`.
    ///      Key: `keccak256(abi.encode(lowercasedName))` — `nameKey` in the library. The fold is
    ///      deliberately narrow: bytes 0x41..0x5A (ASCII A–Z) get +0x20 and every other byte passes
    ///      through, so it is case-insensitive for plain ASCII names and nothing more. Human triage
    ///      only; never a safety key.
    ///
    ///      Being DERIVED makes ordering matter on the way out: `_removeAsset` must clear this entry
    ///      BEFORE deleting the record in `_assets`, because the folded key can only be recomputed from
    ///      the name the record holds. Delete first and the entry here is orphaned with no way to find
    ///      it again. Readers guard against that anyway by confirming `_assetIndex[keyHash] != 0`.
    mapping(bytes32 nameKey => bytes32) internal _assetByName;

    // ── conversion feeds ────────────────────────────────────────────────────────

    /// @dev Slot 6. The conversion-feed records, addressed by natural key.
    ///      Key: `keccak256(abi.encode(base, quote))` — `feedKey` in the library. Direction is part of
    ///      the identity, and only the approved direction is stored; see
    ///      `IMarketRegistry.ConversionFeed`.
    ///
    ///      This store IS the denomination hop graph: each record is one directed edge, base unit →
    ///      quote unit, with an aggregator on it, and `MarketRegistryLib.resolvePath` walks these edges
    ///      to reach US Dollars. There is no adjacency list — see `resolvePath` for how the walk is
    ///      bounded, and why its candidates come from `_denominationKeys` (slot 12) rather than from
    ///      this store's own key array.
    mapping(bytes32 keyHash => IMarketRegistry.ConversionFeed) internal _feeds;

    /// @dev Slot 7. Every live feed key — the enumeration `getConversionFeeds` pages over. Same
    ///      swap-on-remove caveat as `_assetKeys`. `resolvePath` deliberately does NOT read this array.
    bytes32[] internal _feedKeys;

    /// @dev Slot 8. Position of each key in `_feedKeys`, stored as `index + 1` so 0 means absent.
    mapping(bytes32 keyHash => uint256) internal _feedIndex;

    // ── deployed wrappers ───────────────────────────────────────────────────────

    /// @dev Slot 9. The rate oracle `deploy` built for each (pair, mode, wiring) combination, or the
    ///      zero address if that combination was never deployed.
    ///      Key: `wrapperKey(ca, ref, mode)` — `keccak256(abi.encode(address(this), ca, ref, mode,
    ///      base, quote))` where `base` and `quote` are the two fully resolved `LegWiring` structs,
    ///      byte for byte what the factory is handed. Computed in the contract rather than in the
    ///      library. The registry's own address is included because the key seeds the factory's
    ///      `CREATE2` salt: the salt is `keccak256(abi.encode(key, oracleSalt))` with the caller's
    ///      `oracleSalt` mixed in, so the key fixes the cache entry and the salt only fixes where the
    ///      first deployment lands — see the note on `deploy`.
    ///
    ///      The ONE store with no owner verbs. `deploy` is its only writer and it is permissionless,
    ///      so there is no `addWrappers` and no `removeWrappers`: governance neither creates nor
    ///      retires an entry here. Re-keying is governance's only lever over this store, and the key
    ///      is deliberately exactly as fine as the wiring: an edit that changes what the factory would
    ///      be handed for a pair moves the pair to a new key and the old entry is simply never looked
    ///      up again, while an edit that changes nothing the factory sees keeps serving the same
    ///      wrapper. Nor is there a key array — a permissionless writer would pay an
    ///      extra `SSTORE` on every fresh build to serve a query the `MarketOracleDeployed` log
    ///      already answers, so enumeration is deliberately event-side only.
    mapping(bytes32 wrapperKey => address wrapper) internal _wrappers;

    // ── recipes ─────────────────────────────────────────────────────────────────

    /// @dev Slot 10. Position of each approved recipe in `_recipeKeys`, stored as `index + 1` so 0
    ///      means absent. This mapping IS the membership set — `isRecipe(r)` is `_recipeIndex[r] != 0`
    ///      — and there is no companion record mapping, because an approved recipe is nothing but its
    ///      address. Bands, formulas and metadata all live inside the recipe contract.
    mapping(address recipe => uint256) internal _recipeIndex;

    /// @dev Slot 11. Every approved recipe address, in insertion order — the enumeration `getRecipes`
    ///      pages over, and the whole of what it returns. Same swap-on-remove caveat as `_assetKeys`,
    ///      so a position is not a stable name for a recipe.
    address[] internal _recipeKeys;

    // ── denominations ───────────────────────────────────────────────────────────

    /// @dev Slot 12. Every registered denomination UNIT, in registration order — the enumeration
    ///      `getDenominations` pages over and the candidate list `MarketRegistryLib.resolvePath` walks
    ///      to find a two-hop intermediate.
    ///
    ///      A denomination is nothing but its unit address: a token, or a Chainlink `Denominations`
    ///      pseudo-address for a currency with no token of its own. There is no record mapping and no
    ///      label, for the same reason the recipe store has none — the address IS the entry. `_feeds`
    ///      is keyed on unit addresses too, so registering a unit is precisely the act of letting a
    ///      source quote in it and letting the bridge search try it as an intermediate.
    ///
    ///      Every present source's `denomination` must be in this set at WRITE time and again at
    ///      `deploy` time. Removing a unit that live assets still quote in is allowed and has teeth —
    ///      those assets keep their stored entry and start failing at `deploy` with
    ///      `UnregisteredDenomination`, whether or not the pair was deployed before, because the wrapper
    ///      record (slot 9) is keyed on the wiring and is not consulted until the unit has been checked.
    ///      `removeConversionFeeds` strands an asset whose only path to US Dollars ran through the
    ///      removed edge the same way.
    ///
    ///      No duplicates: `_addDenomination` rejects a unit already present, so the bridge search
    ///      never probes the same intermediate twice. Same swap-on-remove caveat as `_assetKeys`, so a
    ///      position is not a stable name for a denomination.
    address[] internal _denominationKeys;

    /// @dev Slot 13. Position of each unit in `_denominationKeys`, stored as `index + 1` so 0 means
    ///      absent. This mapping IS the membership set — `isDenomination(u)` is
    ///      `_denominationIndex[u] != 0` — and the same test gates every source write and every
    ///      `deploy`.
    mapping(address unit => uint256) internal _denominationIndex;

    // ── market bound ────────────────────────────────────────────────────────────
    //
    // The one slot that is not a store. Everything above is membership — a record mapping, a key
    // array, a position mapping, two verbs. This is a single number the owner sets in place, so it is
    // the one place in this contract with a genuine UPDATE path, and the header's "no in-place write
    // path" rule does not reach it. That is not an exception carved out for convenience: a scalar has
    // no natural key, so remove-then-add would mean deleting the bound and running with no bound at
    // all in between, which is precisely the state this slot exists to prevent.

    /// @dev Slot 14. Longest life a market created through the periphery may have, in seconds, counted
    ///      from the moment of creation. Set in the constructor and by `setMaxExpiryDuration`, never
    ///      zero — see `IMarketRegistry.ZeroBound` for why zero is a kill switch rather than a bound.
    uint256 internal _maxExpiryDuration;
}
