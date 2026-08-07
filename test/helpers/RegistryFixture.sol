// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";

import {FixedRateOracleFactory} from "../../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {MockERC20} from "../mocks/HostileAssets.sol";
import {MockWrapperFactory} from "../mocks/MockWrapperFactory.sol";
import {one} from "./ArrayHelpers.sol";

/// @title RegistryFixture — the ONE home for successor-registry test boilerplate
/// @notice File-level `Asset` / `AssetSource` / `ConversionFeed` builders, plus an abstract base
///         contract that stands a `MarketRegistry` up against a {MockWrapperFactory} and a real
///         {FixedRateOracleFactory}, and exposes the denomination-registry and conversion-feed helpers
///         every asset write now depends on.
///
/// @dev EXTEND THIS, DO NOT FORK IT. The successor shapes cost more boilerplate than their
///      predecessors did — an `Asset` now carries two four-field `AssetSource` structs, and every
///      source's `denomination` has to be a registered label with a dollar path in the conversion-feed
///      store BEFORE the asset naming it can be added. If each suite writes that out itself, the next
///      shape change is a twelve-file edit. So: new helpers land HERE, and a suite that needs a
///      variation adds a named builder rather than open-coding a struct literal.
///
///      ## Five things this file exists to absorb
///
///      1. **Presence is `addr != 0`.** There is no sources array and no length to shorten, so an
///         ABSENT slot is a zeroed struct — `noSource()`. `mkPriceOnlyAsset` / `mkNavOnlyAsset` /
///         `mkDualSourceAsset` / `mkSourcelessAsset` are the four shapes that follow from that,
///         spelled out so a suite never has to remember which field takes which `SourceType`.
///      2. **A SOURCELESS asset is a legal entry now.** Neither source present is accepted by
///         `addAsset` — the old `EmptySources` error is deleted and nothing replaced it. Such an
///         entry carries no denomination anywhere, so the reach-US-Dollars requirement is vacuous for
///         it rather than waived, and the only thing it cannot do is serve as a leg of `deploy`
///         (`MissingSource`). `mkSourcelessAsset` builds it.
///      3. **The denomination lives on the SOURCE, one per source.** `AssetSource.denomination` used
///         to be called `quoteUnit` and sat underneath a single asset-level `denomination`. That
///         asset-level field is GONE. Each of an asset's two sources now carries its own label and
///         **the two are not required to agree** — the two legs of a Morpho oracle resolve their
///         paths independently. `mkDualSourceAsset` therefore has a six-argument form that takes one
///         denomination per source; the five-argument form is only a convenience for the common case
///         where they happen to be the same.
///      4. **`sourceType` must match the field it sits in.** `mkPriceSource` always produces a
///         `PRICE` / `AGGREGATOR_V3` source and `mkNavSource` always produces a `NAV` / `ERC4626`
///         one, so the honest cases cannot accidentally trip `SourceTypeMismatch`. Deliberately
///         crossing them — a `NAV` source handed to the price field — is how the mismatch tests are
///         written, and `mkSource` is there for the cases that need every field spelled out.
///      5. **Write-time reachability.** `addAsset` refuses a PRESENT source whose `denomination` is
///         not a registered label, or whose unit cannot reach US Dollars inside the source's hop
///         budget (1 hop for `AGGREGATOR_V3`, 2 for `ERC4626`). `_registerDenominationWithUsdFeed`
///         does the two writes together, because doing only the first is the mistake that produces a
///         `NoConversionPathToUsd` a reader will blame on the registry.
///
///      ## Tokens should be CONTRACTS, and they must not be Phoenix mocks
///
///      `addAsset` itself no longer walks `asset()` — nothing is derived or pinned at write time any
///      more — so a bare `makeAddr` label is no longer rejected by the add path alone. Everything
///      DOWNSTREAM still needs real code: `deploy` re-reads each leg's live `decimals()`, and
///      `MarketRegistryLib.deriveDenomination` (still the on-chain authority on an asset's real
///      denomination, now reached from tests only) probes `asset()` through a `try`/`catch` where a
///      CODELESS target makes the ABI decode revert UNCATCHABLY and bubble out. `_newToken` deploys a
///      local {MockERC20} (real code, a settable `decimals()`, no `asset()`, so the probe catches and
///      the node is a leaf) and is the default stand-in for any token.
///
///      Do NOT reach for a Phoenix `DummyERC20` instead. Those mint on FALLBACK, so the registry's
///      `staticcall` probes burn essentially all the gas forwarded to them and the failure reads like a
///      registry bug rather than a fixture one. This is a recorded trap, not a preference.
///
///      ## The helpers are NOT pranked
///
///      Every `_add*` / `_register*` below calls the registry directly, so `msg.sender` is whatever the
///      test contract is. A suite whose registry is owned by the test contract (`_deployRegistry(
///      address(this))`) can use them as-is; a suite with a separate `owner` account must
///      `vm.prank(owner)` immediately before each one. Both idioms are in use and neither is wrong —
///      Governance.t.sol needs a distinct owner to have anything to test.

// ─────────────────────────────────────────────────────────────────────────────
// AssetSource builders
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Build one `AssetSource` with every field spelled out.
/// @dev `addr` is the aggregator (`AGGREGATOR_V3`) or the ERC-4626 vault (`ERC4626`); a zero `addr`
///      means the slot is ABSENT. `denomination` must be a REGISTERED denomination label with a
///      conversion-feed path to US Dollars inside the interface's hop budget — 1 hop for
///      `AGGREGATOR_V3`, 2 for `ERC4626` — because `addAsset` checks both at write time now.
///
///      Reach for this only when a test needs a combination the two shorthands below cannot express:
///      a deliberately mismatched `sourceType`, or a `NAV` source that declares `AGGREGATOR_V3`
///      (an aggregator publishing an exchange rate, which the enums exist to keep representable).
function mkSource(
    address addr,
    IMarketRegistry.SourceType sourceType,
    IMarketRegistry.SourceInterface sourceInterface,
    string memory denomination
) pure returns (IMarketRegistry.AssetSource memory) {
    return IMarketRegistry.AssetSource({
        addr: addr, sourceType: sourceType, sourceInterface: sourceInterface, denomination: denomination
    });
}

/// @notice The common price source: a Chainlink-style aggregator. Hop budget 1.
function mkPriceSource(address a, string memory denomination) pure returns (IMarketRegistry.AssetSource memory) {
    return mkSource(a, IMarketRegistry.SourceType.PRICE, IMarketRegistry.SourceInterface.AGGREGATOR_V3, denomination);
}

/// @notice The common net-asset-value source: an ERC-4626 vault. Hop budget 2.
function mkNavSource(address a, string memory denomination) pure returns (IMarketRegistry.AssetSource memory) {
    return mkSource(a, IMarketRegistry.SourceType.NAV, IMarketRegistry.SourceInterface.ERC4626, denomination);
}

/// @notice An ABSENT source slot.
/// @dev Presence is `addr != 0`, so a zeroed struct is the whole of "no source here". There is no
///      separate flag and no array length to shorten any more. The empty `denomination` is written
///      explicitly to document that an absent slot carries no label — `addAsset` never reads it.
function noSource() pure returns (IMarketRegistry.AssetSource memory s) {
    s.denomination = "";
}

// ─────────────────────────────────────────────────────────────────────────────
// Asset builders — the four presence shapes, plus the fully-explicit form
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Build an `Asset` entry with both source slots spelled out.
/// @dev There is no asset-level `denomination` parameter any more, because there is no asset-level
///      `denomination` FIELD any more. Each source carries its own label; pass `noSource()` for a slot
///      that should be absent, and `noSource()` for both to build a sourceless entry.
function mkAsset(
    address addr,
    string memory name,
    IMarketRegistry.AssetKind kind,
    IMarketRegistry.AssetSource memory priceSource,
    IMarketRegistry.AssetSource memory navSource
) pure returns (IMarketRegistry.Asset memory) {
    return IMarketRegistry.Asset({addr: addr, name: name, kind: kind, priceSource: priceSource, navSource: navSource});
}

/// @notice An `Asset` with a PRICE source and nothing in the NAV slot. `AssetKind.ERC20`.
/// @dev The commonest shape: one aggregator, one hop of bridge budget left in `feed2`. `denomination`
///      is the label that ONE source quotes in — it must be registered and must reach US Dollars in a
///      single hop.
function mkPriceOnlyAsset(address addr, string memory name, address source, string memory denomination)
    pure
    returns (IMarketRegistry.Asset memory)
{
    return mkAsset(addr, name, IMarketRegistry.AssetKind.ERC20, mkPriceSource(source, denomination), noSource());
}

/// @notice An `Asset` with a NAV source and nothing in the PRICE slot. `AssetKind.ERC4626`.
/// @dev EXACTLY ONE source is enough — the absent price slot is not a validation failure, it just
///      means the asset cannot serve `OracleMode.PRICE`. `denomination` is the label the VAULT's
///      underlying is quoted in (see `AssetSource`), with two hops of budget.
function mkNavOnlyAsset(address addr, string memory name, address vault, string memory denomination)
    pure
    returns (IMarketRegistry.Asset memory)
{
    return mkAsset(addr, name, IMarketRegistry.AssetKind.ERC4626, noSource(), mkNavSource(vault, denomination));
}

/// @notice An `Asset` carrying BOTH sources, each with its OWN denomination. `AssetKind.ERC4626`.
/// @dev THIS is the canonical dual-source builder, and the two denominations are separate parameters
///      on purpose: a price source and a NAV source on one asset are NOT required to name the same
///      label, because the two legs of a Morpho oracle resolve their conversion paths independently.
///      Each label is validated on its own at write time, against its own source's hop budget (1 hop
///      for the aggregator, 2 for the vault).
function mkDualSourceAsset(
    address addr,
    string memory name,
    address priceSourceAddr,
    string memory priceDenomination,
    address navVault,
    string memory navDenomination
) pure returns (IMarketRegistry.Asset memory) {
    return mkAsset(
        addr,
        name,
        IMarketRegistry.AssetKind.ERC4626,
        mkPriceSource(priceSourceAddr, priceDenomination),
        mkNavSource(navVault, navDenomination)
    );
}

/// @notice Convenience overload of {mkDualSourceAsset}: both sources share ONE denomination.
/// @dev For the common case only. It is a shorthand for the six-argument form with the same label
///      twice, NOT a rule — a test that wants the two sources to differ calls the six-argument form
///      (or `mkAsset` with two hand-built sources). Nothing in the registry requires agreement.
function mkDualSourceAsset(
    address addr,
    string memory name,
    address priceSourceAddr,
    address navVault,
    string memory denomination
) pure returns (IMarketRegistry.Asset memory) {
    return mkDualSourceAsset(addr, name, priceSourceAddr, denomination, navVault, denomination);
}

/// @notice An `Asset` with NEITHER source — a legal entry, not a rejected one. `AssetKind.ERC20`.
/// @dev The state `EmptySources` used to forbid. `addAsset` accepts it: with no source present there
///      is no `denomination` anywhere on the entry, so the registered-label and reach-US-Dollars
///      checks have nothing to run against and are vacuous rather than waived. Such an entry is an
///      approval record and nothing more — using it as a leg of `deploy` reverts
///      `MissingSource(addr, mode)` in BOTH oracle modes, and `lookupWrapper` reports the zero
///      address. A source can be written on later with `updateSource`, and cleared again back to this
///      state.
function mkSourcelessAsset(address addr, string memory name) pure returns (IMarketRegistry.Asset memory) {
    return mkSourcelessAsset(addr, name, IMarketRegistry.AssetKind.ERC20);
}

/// @notice {mkSourcelessAsset} with an explicit `AssetKind`.
/// @dev `kind` is descriptive metadata with no on-chain reader, so a sourceless `ERC4626` entry is
///      just as constructable as a sourceless `ERC20` one. This overload exists so a suite does not
///      have to fall back to `mkAsset` merely to change the label.
function mkSourcelessAsset(address addr, string memory name, IMarketRegistry.AssetKind kind)
    pure
    returns (IMarketRegistry.Asset memory)
{
    return mkAsset(addr, name, kind, noSource(), noSource());
}

// ─────────────────────────────────────────────────────────────────────────────
// ConversionFeed builder
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Build one `ConversionFeed` — one DIRECTED edge of the denomination hop graph.
/// @dev Direction is part of the natural key: `(base, quote)` and `(quote, base)` are two different
///      entries and neither implies the other, because `resolvePath` follows forward edges only.
///      `feedDecimals` is recorded verbatim and never validated against a live aggregator.
function mkFeed(address base, address quote, address aggregator, uint8 feedDecimals)
    pure
    returns (IMarketRegistry.ConversionFeed memory)
{
    return IMarketRegistry.ConversionFeed({
        base: base, quote: quote, aggregatorAddress: aggregator, feedDecimals: feedDecimals
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// The shared harness
// ─────────────────────────────────────────────────────────────────────────────

/// @title RegistryFixture
/// @notice Abstract base: a deployed `MarketRegistry` plus the state helpers every asset write needs.
/// @dev `reg` is the concrete contract (for `owner()` / `WRAPPER_FACTORY()` /
///      `FIXED_RATE_ORACLE_FACTORY()`), `iReg` the interface (for everything else). Those two names
///      are the harness convention in this repo already — keep them.
abstract contract RegistryFixture is Test {
    MarketRegistry internal reg;
    IMarketRegistry internal iReg;
    MockWrapperFactory internal wrapperFactory;

    /// @dev The REAL {FixedRateOracleFactory}, not a mock, recorded the same way `wrapperFactory` is.
    ///      There is nothing to stub: it has no admin surface, its `deploy` is one `CREATE2`, and its
    ///      `computeAddress` is pure arithmetic — a mock would only be able to lie about the address,
    ///      which is the one thing the registry's idempotency check depends on being true.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    /// @dev The two units `"USD"` and `"ETH"` are SEEDED to by the constructor. Taken from the library
    ///      rather than re-typed, so a change there cannot leave a suite asserting against a stale
    ///      sentinel.
    address internal constant USD_UNIT = MarketRegistryLib.USD_DENOMINATION;
    address internal constant ETH_UNIT = MarketRegistryLib.ETH_DENOMINATION;

    /// @dev The aggregator `_addEthUsdFeed` records on the `ETH → USD` edge, when no other is given.
    address internal ethUsdAggregator = address(uint160(uint256(keccak256("RegistryFixture.ethUsdAggregator"))));

    // ── deployment ────────────────────────────────────────────────────────────────

    /// @notice Deploy a {MockWrapperFactory}, a {FixedRateOracleFactory} and a `MarketRegistry` owned
    ///         by `initialOwner`, and record all three on the fixture.
    /// @dev The registry constructor takes THREE arguments now — `(initialOwner, wrapperFactory,
    ///      fixedRateOracleFactory)` — and zero-checks both factories. Every suite in this repository
    ///      stands its registry up through this helper, which is why the third argument is supplied
    ///      here once rather than at a dozen call sites.
    ///
    ///      The constructor seeds `"USD"` and `"ETH"` into the denomination registry, so a freshly
    ///      deployed registry already accepts a `"USD"`-quoted source (zero bridge hops) with no owner
    ///      action at all. `"ETH"` additionally needs its dollar edge before an `"ETH"`-quoted source is
    ///      writable — call `_addEthUsdFeed`.
    function _deployRegistry(address initialOwner) internal returns (MarketRegistry) {
        wrapperFactory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        reg = new MarketRegistry();
        reg.initialize(initialOwner, address(wrapperFactory), address(fixedRateOracleFactory));
        iReg = IMarketRegistry(address(reg));
        return reg;
    }

    // ── tokens ────────────────────────────────────────────────────────────────────

    /// @notice A local {MockERC20} with configurable decimals — the default stand-in for any token.
    /// @dev Real code, a `decimals()` the deploy path can read, and NO `asset()`, so the probe catches
    ///      and the node is a leaf. Never a Phoenix `DummyERC20`: those mint on fallback and the probe
    ///      burns all the forwarded gas against them.
    function _newToken(string memory symbol_, uint8 decimals_) internal returns (address) {
        return address(new MockERC20(symbol_, symbol_, decimals_));
    }

    /// @notice 18-decimal shorthand for `_newToken`.
    function _newToken(string memory symbol_) internal returns (address) {
        return _newToken(symbol_, 18);
    }

    // ── registry state (NOT pranked — see the file header) ────────────────────────

    /// @notice Add one directed conversion-feed edge.
    function _addFeed(address base, address quote, address aggregator, uint8 decimals_) internal {
        iReg.addConversionFeeds(one(mkFeed(base, quote, aggregator, decimals_)));
    }

    /// @notice The `ETH → USD` edge, which is what makes an `"ETH"`-quoted source writable at all.
    function _addEthUsdFeed() internal {
        _addFeed(ETH_UNIT, USD_UNIT, ethUsdAggregator, 8);
    }

    /// @notice Register a denomination label against the unit address it names.
    /// @dev Exact bytes and case-sensitive: registering `"USD"` does NOT make `"usd"` resolve.
    ///      Create-or-overwrite — re-registering an existing label re-points it rather than reverting.
    function _registerDenomination(string memory label, address unit) internal {
        iReg.addDenominations(one(label), one(unit));
    }

    /// @notice Register a denomination label AND the direct `unit → USD` edge that gives it a dollar
    ///         path, in one helper.
    /// @dev Both writes are needed before a source may quote `label`, and doing only the first is the
    ///      easy mistake: the label check passes and the PATH check fails with
    ///      `NoConversionPathToUsd`, which reads like a registry fault rather than a missing feed.
    ///      Feeds must exist BEFORE the assets that depend on them — that ordering is the whole
    ///      consequence of validating sources at write time.
    function _registerDenominationWithUsdFeed(string memory label, address unit, address aggregator) internal {
        _registerDenomination(label, unit);
        _addFeed(unit, USD_UNIT, aggregator, 8);
    }

    // ── read-back helpers ─────────────────────────────────────────────────────────

    /// @notice The stored `denomination` of ONE of a stored asset's two sources.
    /// @dev The asset-level `denomination` field is gone, so "the asset's denomination" is no longer a
    ///      question with one answer — each source carries its own and the two need not agree. The
    ///      `which` argument is therefore REQUIRED rather than defaulted: `SourceType.PRICE` reads
    ///      `priceSource.denomination`, `SourceType.NAV` reads `navSource.denomination`.
    ///
    ///      An ABSENT source reads back as the EMPTY STRING, and that is a real answer rather than an
    ///      error: `addAsset` zeroes an absent slot instead of copying it, so a sourceless asset
    ///      returns `""` for both source types. A suite that means "this slot is empty" should assert
    ///      on the stored `addr` being zero, not on this string.
    /// @param addr The asset's natural key.
    /// @param which Which of the two source slots to read.
    function _storedDenomination(address addr, IMarketRegistry.SourceType which) internal view returns (string memory) {
        (bool found, IMarketRegistry.Asset memory entry) = iReg.lookupAssetByAddress(addr);
        require(found, "asset not stored");
        return which == IMarketRegistry.SourceType.PRICE ? entry.priceSource.denomination : entry.navSource.denomination;
    }

    /// @dev String equality by hash.
    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
