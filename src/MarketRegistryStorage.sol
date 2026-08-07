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
    ///      bounded, and why its candidates come from `_denominationKeys` (slot 13) rather than from
    ///      this store's own key array.
    mapping(bytes32 keyHash => IMarketRegistry.ConversionFeed) internal _feeds;

    /// @dev Slot 7. Every live feed key — the enumeration `getConversionFeeds` pages over. Same
    ///      swap-on-remove caveat as `_assetKeys`. `resolvePath` deliberately does NOT read this array.
    bytes32[] internal _feedKeys;

    /// @dev Slot 8. Position of each key in `_feedKeys`, stored as `index + 1` so 0 means absent.
    mapping(bytes32 keyHash => uint256) internal _feedIndex;

    // ── deployed wrappers ───────────────────────────────────────────────────────

    /// @dev Slot 9. The rate oracle `deploy` built for each (pair, resolved-sources) combination, or
    ///      the zero address if that combination was never deployed.
    ///      Key: `keccak256(abi.encode(ca, ref, caSource, refSource))`, computed inline rather than in
    ///      the library.
    ///
    ///      The ONE store with no owner verbs. `deploy` is its only writer and it is permissionless,
    ///      so there is no `addWrappers` and no `removeWrappers`: governance neither creates nor
    ///      retires an entry here. Nor is there a key array — a permissionless writer would pay an
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

    /// @dev Slot 12. The registered denomination labels: label hash → the unit address that label
    ///      names.
    ///      Key: `keccak256(bytes(label))` — the raw label bytes, NOT `abi.encode`d, and NOT folded
    ///      for case. Exact bytes, case-sensitive: `"USD"` and `"usd"` are different labels and only
    ///      the registered spelling resolves. A denomination selects which conversion feeds an asset
    ///      can bridge through, so it is a safety key and never gets `nameKey`'s case folding. Every
    ///      present source's `denomination` must resolve here at WRITE time — see
    ///      `IMarketRegistry.addDenominations` for the registration rules.
    ///
    ///      The unit address is the bridge between this store and the hop graph: `_feeds` is keyed on
    ///      unit ADDRESSES, so registering a label is precisely the act of connecting it to the graph.
    ///
    ///      Registration is add-only: a label that already exists is rejected rather than overwritten,
    ///      so RE-POINTING a label to a different unit is a removal followed by an add, and both halves
    ///      show up in the log. Removing a label that live assets still name in a source is allowed and
    ///      has teeth — those assets keep their stored entry and start failing at `deploy` with
    ///      `UnregisteredDenomination`, the same way `removeConversionFeeds` strands an asset whose only
    ///      path to US Dollars ran through the removed edge.
    mapping(bytes32 labelHash => address unit) internal _denominations;

    /// @dev Slot 13. Every registered denomination LABEL HASH, in registration order — the enumeration
    ///      `getDenominations` pages over and `MarketRegistryLib.resolvePath` walks to find a two-hop
    ///      intermediate. It exists because a mapping has no key list, so the store above cannot
    ///      otherwise be enumerated.
    ///
    ///      ## Label hashes, NOT unit addresses
    ///
    ///      Storing the unit addresses directly would be one SLOAD cheaper per candidate and it would be
    ///      WRONG. Two different labels MAY name the same unit, and the array must hold one entry per
    ///      LABEL so that removing one of those labels leaves the other's bridge intact. Resolving the
    ///      label hash through `_denominations` on every read keeps the array a list of labels and the
    ///      mapping the single authority on what each one currently means.
    ///
    ///      ## The invariants
    ///
    ///      One entry per LABEL, and no duplicates: `_addDenomination` rejects a label already present.
    ///      Every hash in this array resolves through `_denominations` to a NON-ZERO unit — the add path
    ///      rejects a zero unit, and the remove path clears the mapping entry and pops this array
    ///      together, so a hash can never outlive its unit. `resolvePath` depends on that pairing: a
    ///      stale hash resolving to zero would merely probe `feedKey(fromUnit, address(0))`, find
    ///      nothing, and continue, so the failure would be silent rather than loud.
    ///
    ///      Two different labels MAY still name the same unit; the search then probes that unit twice,
    ///      which wastes gas and changes no answer. Positions shift on removal, so nothing may name a
    ///      denomination by its index.
    bytes32[] internal _denominationKeys;

    /// @dev Slot 14. Position of each label hash in `_denominationKeys`, stored as `index + 1` so 0
    ///      means absent — the same shape every other store uses, and what makes `removeDenominations`
    ///      possible at all. Existence is this mapping, not `_denominations[labelHash] != address(0)`;
    ///      the two agree by the pairing invariant above, and readers that only need the unit (
    ///      `lookupDenomination`, `_requireDenomination`) may use the non-zero unit as the test.
    mapping(bytes32 labelHash => uint256) internal _denominationIndex;

    // ── market bound ────────────────────────────────────────────────────────────
    //
    // The one slot that is not a store. Everything above is membership — a record mapping, a key
    // array, a position mapping, two verbs. This is a single number the owner sets in place, so it is
    // the one place in this contract with a genuine UPDATE path, and the header's "no in-place write
    // path" rule does not reach it. That is not an exception carved out for convenience: a scalar has
    // no natural key, so remove-then-add would mean deleting the bound and running with no bound at
    // all in between, which is precisely the state this slot exists to prevent.

    /// @dev Slot 15. Longest life a market created through the periphery may have, in seconds, counted
    ///      from the moment of creation. Set in the constructor and by `setMaxExpiryDuration`, never
    ///      zero — see `IMarketRegistry.ZeroBound` for why zero is a kill switch rather than a bound.
    uint256 internal _maxExpiryDuration;
}
