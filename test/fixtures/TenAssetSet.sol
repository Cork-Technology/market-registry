// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {MarketRegistryLib} from "../../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {MockERC20, MockVaultAsset, RevertingAsset} from "../mocks/HostileAssets.sol";

// The `Asset` / `AssetSource` / `ConversionFeed` builders and the registry harness live in ONE place —
// `test/helpers/RegistryFixture.sol`. They are imported here (and re-exported to this file's own
// importers) so the suites that already import them from this fixture keep working unchanged. Add new
// builders to RegistryFixture, never here.
import {
    RegistryFixture,
    mkAsset,
    mkDualSourceAsset,
    mkFeed,
    mkNavOnlyAsset,
    mkNavSource,
    mkPriceOnlyAsset,
    mkPriceSource,
    mkSource,
    mkSourcelessAsset,
    noSource
} from "../helpers/RegistryFixture.sol";
import {one} from "../helpers/ArrayHelpers.sol";

/// @title TenAssetSet — deterministic local replica of the real ten-asset topology
/// @notice Deploys the mock contracts and returns a dependency-ordered `Asset[]` plus the
///         denomination each entry's one PRESENT source declares, so a suite can seed the set and
///         assert what the registry stored with zero RPC dependency. The mainnet-fork variant lives in
///         `test/fork/`.
///
///         Topology (terminators first, then vault chains, the ACRDX-shaped leaf, the unregistered-
///         underlying vault):
///           terminators  USDC / USDe / USDS / AUSD → "USD" ;  WETH / wstETH → "ETH"
///                        (leaves: `asset()` reverts; the price source states the denomination)
///           vault chains sUSDe→USDe, sUSDS→USDS, AUSD-HYT→AUSD, vbUSDC→USDC  (1 hop)
///                        bbqUSDC→vbUSDC                                      (hop to an already
///                        registered entry)
///           acrdx        ACRDX-shaped leaf → "USD" stated on the price source, source never called
///           wUSDC        a vault whose underlying is a real but UNREGISTERED plain token
///
/// @dev Three things changed with the successor shape and all three are load-bearing here.
///
///      1. `chainId` is gone from `Asset`, so `build` takes no chain argument. There is no
///         foreign-chain entry to skip with any more.
///      2. `denomination` moved OFF the asset and ONTO each source, and `addAsset` no longer derives
///         anything. There is no caller-residual denomination to pass and no underlying-asset walk at
///         write time, so the `expected[]` array no longer means "what the walk will derive" — it now
///         means "the label the entry's present source states, which `addAsset` must store verbatim".
///         The VALUES are unchanged; only what they assert changed. Which slot to read it back from
///         follows the entry itself: bands 0–5 and 11 carry a PRICE source, bands 6–10 and 12 carry a
///         NAV source, and `entries[i].priceSource.addr != 0` is the reliable way to tell.
///      3. The old wUSDC "residual" case pointed its vault at a CODELESS address, then at a real but
///         unregistered token. It stays as the real-but-unregistered token, because the codeless form
///         makes `probeAsset`'s ABI decode revert UNCATCHABLY. What it no longer TESTS is a residual:
///         with nothing derived at write time there is no "the walk could not resolve" outcome for it
///         to produce. It is now simply one more vault-shaped entry whose underlying happens to be
///         unregistered, kept because `deriveDenomination` is still exercised directly by the walk
///         suites and this is the topology they need.
///
///      Every entry needs a source whose `denomination` is registered AND reaches US Dollars, so the
///      consuming test must have `USD_UNIT` / `ETH_UNIT` registered (`initialize` seeds both) and added
///      the `ETH → USD` conversion feed BEFORE seeding the two Ether-denominated terminators.
contract TenAssetSet {
    uint256 public constant COUNT = 13;

    /// @dev The two seeded pseudo-units every entry here quotes in.
    address internal constant USD_UNIT = MarketRegistryLib.USD_DENOMINATION;
    address internal constant ETH_UNIT = MarketRegistryLib.ETH_DENOMINATION;

    /// @notice Deploy the topology and return entries in dependency order + the denomination each
    ///         entry's present source states.
    /// @dev Split into per-band helpers so no single frame holds enough locals to hit "stack too
    ///      deep" under the default (non-`via_ir`) profile. `entries` / `expected` are memory
    ///      reference types, so the helpers mutate the caller's arrays in place.
    function build() external returns (IMarketRegistry.Asset[] memory entries, address[] memory expected) {
        entries = new IMarketRegistry.Asset[](COUNT);
        expected = new address[](COUNT);
        _terminators(entries, expected);
        _vaults(entries, expected);
        _acrdxAndUnregistered(entries, expected);
    }

    /// @dev Bands [0..5]: terminators. Leaves whose `asset()` reverts, each stating its denomination on
    ///      its price source. USDC/USDe/USDS/AUSD → US Dollars; WETH/wstETH → Ether (needs the ETH → USD
    ///      feed added first, or `addAsset` reverts `NoConversionPathToUsd`).
    function _terminators(IMarketRegistry.Asset[] memory entries, address[] memory expected) private {
        entries[0] = _leaf(address(new RevertingAsset()), "USDC", USD_UNIT);
        entries[1] = _leaf(address(new RevertingAsset()), "USDe", USD_UNIT);
        entries[2] = _leaf(address(new RevertingAsset()), "USDS", USD_UNIT);
        entries[3] = _leaf(address(new RevertingAsset()), "AUSD", USD_UNIT);
        entries[4] = _leaf(address(new RevertingAsset()), "WETH", ETH_UNIT);
        entries[5] = _leaf(address(new RevertingAsset()), "wstETH", ETH_UNIT);
        expected[0] = USD_UNIT;
        expected[1] = USD_UNIT;
        expected[2] = USD_UNIT;
        expected[3] = USD_UNIT;
        expected[4] = ETH_UNIT;
        expected[5] = ETH_UNIT;
    }

    /// @dev Bands [6..10]: vault chains whose `asset()` reaches a terminator this batch registered
    ///      earlier. bbqUSDC is two-level: its underlying is vbUSDC, one entry back. The chain matters
    ///      to `deriveDenomination`, which the walk suites call directly; `addAsset` itself only reads
    ///      the label stated on the NAV source.
    function _vaults(IMarketRegistry.Asset[] memory entries, address[] memory expected) private {
        entries[6] = _vault(address(new MockVaultAsset(entries[1].addr)), "sUSDe"); // → USDe
        entries[7] = _vault(address(new MockVaultAsset(entries[2].addr)), "sUSDS"); // → USDS
        entries[8] = _vault(address(new MockVaultAsset(entries[3].addr)), "AUSD-HYT"); // → AUSD
        entries[9] = _vault(address(new MockVaultAsset(entries[0].addr)), "vbUSDC"); // → USDC
        entries[10] = _vault(address(new MockVaultAsset(entries[9].addr)), "bbqUSDC"); // → vbUSDC
        expected[6] = USD_UNIT;
        expected[7] = USD_UNIT;
        expected[8] = USD_UNIT;
        expected[9] = USD_UNIT;
        expected[10] = USD_UNIT;
    }

    /// @dev Band [11]: ACRDX-shaped leaf — the denomination is stated on the price source and the
    ///      source is never called. Band [12]: wUSDC, a vault whose underlying is a real but
    ///      UNREGISTERED plain token, so a `deriveDenomination` walk hops once and terminates on
    ///      nothing registered.
    function _acrdxAndUnregistered(IMarketRegistry.Asset[] memory entries, address[] memory expected) private {
        entries[11] = _leaf(address(new RevertingAsset()), "ACRDX", USD_UNIT);
        expected[11] = USD_UNIT;

        address unregisteredUnderlying = address(new MockERC20("Unregistered", "UNREG", 6));
        address wUSDC = address(new MockVaultAsset(unregisteredUnderlying));
        entries[12] = _vault(wUSDC, "wUSDC");
        expected[12] = USD_UNIT;
    }

    /// @dev A leaf terminator: one PRICE source stating `denomination`, NAV slot absent.
    function _leaf(address addr, string memory name, address denomination)
        private
        pure
        returns (IMarketRegistry.Asset memory)
    {
        return mkPriceOnlyAsset(addr, name, addr, denomination);
    }

    /// @dev A vault: one NAV source quoting US Dollars, PRICE slot absent. The unit still has to be
    ///      registered and reachable, because `addAsset` validates every PRESENT source on its own.
    function _vault(address addr, string memory name) private pure returns (IMarketRegistry.Asset memory) {
        return mkNavOnlyAsset(addr, name, addr, USD_UNIT);
    }
}

/// @title WalkTestBase — walk / seed-ordering harness on top of {RegistryFixture}
/// @notice Deploys a `MarketRegistry` owned by the TEST CONTRACT (so `addAssets` is
///         reachable without pranking) and adds the walk-shaped conveniences on top of the shared
///         fixture's deployment, denomination and conversion-feed helpers.
/// @dev THE ORDERING RULE THIS HARNESS EXISTS TO ABSORB: an asset's sources are validated at WRITE
///      time, so a denomination unit must be registered and its dollar path must already be in the
///      conversion-feed store before any asset quoting it can be added. `setUp` therefore adds the
///      `ETH → USD` edge up front — without it, every Ether-quoted price source would revert
///      `NoConversionPathToUsd`.
///
///      Everything generic — `reg` / `iReg` / `wrapperFactory` / `fixedRateOracleFactory`, `USD_UNIT` /
///      `ETH_UNIT`, `_newToken`, `_addFeed`, `_registerDenomination`, `_storedDenomination`, `_eq` —
///      comes from {RegistryFixture}. Add generic helpers THERE; this contract holds only what is
///      specific to the walk suites.
///
///      ## The `EmptyDenomination` expectation is GONE, not re-pointed
///
///      This contract used to hold `bytes4 internal EMPTY_DENOMINATION =
///      IMarketRegistry.EmptyDenomination.selector`, described as "the only revert the walk itself can
///      produce". That selector is deleted from the interface, and the FAILURE STATE it named no longer
///      exists: it fired when the underlying-asset walk finished without producing an asset-level
///      denomination, and there is no asset-level denomination to produce. It was deliberately NOT
///      replaced with some other selector to keep the assertions alive — the closest surviving error,
///      `UnregisteredDenomination(address(0))`, answers a different question (is the unit a registered
///      one) and fires per source at write time rather than after a walk.
abstract contract WalkTestBase is RegistryFixture {
    function setUp() public virtual {
        _deployRegistry(address(this));

        // The one edge that makes Ether-quoted sources writable at all. US Dollars needs no edge: a
        // unit that already IS the dollar sentinel resolves in zero hops.
        _addEthUsdFeed();
    }

    // ── convenience builders (thin wrappers over the file-level free functions) ──

    function _sourceUSD(address a) internal pure returns (IMarketRegistry.AssetSource memory) {
        return mkPriceSource(a, USD_UNIT);
    }

    function _sourceQuote(address a, address q) internal pure returns (IMarketRegistry.AssetSource memory) {
        return mkPriceSource(a, q);
    }

    /// @dev An asset with a single PRICE source — the shape most walk cases need. The source carries
    ///      its own denomination, so there is no separate denomination argument any more.
    function _asset1(address addr, string memory name, IMarketRegistry.AssetSource memory source)
        internal
        pure
        returns (IMarketRegistry.Asset memory)
    {
        return mkAsset(addr, name, IMarketRegistry.AssetKind.ERC4626, source, noSource());
    }

    /// @dev An asset with both source slots filled. Each source brings its OWN denomination and the
    ///      two are not required to agree — build them with `_sourceQuote` / `mkNavSource` to make them
    ///      differ.
    function _asset2(
        address addr,
        string memory name,
        IMarketRegistry.AssetSource memory priceSource,
        IMarketRegistry.AssetSource memory navSource
    ) internal pure returns (IMarketRegistry.Asset memory) {
        return mkAsset(addr, name, IMarketRegistry.AssetKind.ERC4626, priceSource, navSource);
    }

    /// @dev Raw single-asset `addAssets` call that never bubbles, so a test can assert on EMPTY revert
    ///      data. Reverts with no selector at all are still reachable downstream (see `probeAsset`), and
    ///      an empty-data revert is not something `vm.expectRevert` can name.
    function _tryAddAsset(IMarketRegistry.Asset memory e) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(reg).call(abi.encodeWithSelector(IMarketRegistry.addAssets.selector, one(e)));
    }
}
