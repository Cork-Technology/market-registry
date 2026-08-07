// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, stdError} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {
    mkAsset,
    mkDualSourceAsset,
    mkNavOnlyAsset,
    mkNavSource,
    mkPriceOnlyAsset,
    mkPriceSource,
    mkSourcelessAsset,
    noSource
} from "./fixtures/TenAssetSet.sol";
import {MockERC20} from "./mocks/HostileAssets.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title Asset-store STRUCTURAL suite
/// @notice Covers `addAssets`' structural checks, the per-source denomination rules, `removeAssets`'
///         ordering and no-cascade behaviour, the two asset lookups, `isAsset`, enumeration, editing an
///         asset by remove-then-add, and the out-of-range-enum panic (0x21). It does NOT assert
///         hop-graph reachability beyond the two write-time gates — the graph search itself lives in
///         `HopGraph.t.sol` — nor the `deriveDenomination` walk, which lives in `Walk.t.sol`.
///
/// @dev THE DENOMINATION LIVES ON THE SOURCE NOW, ONE PER SOURCE. `AssetSource.quoteUnit` was renamed
///      `denomination` and the asset-level `Asset.denomination` field was DELETED. Nothing is derived or
///      pinned at write time: `addAssets` stores each present source's own label verbatim, after checking
///      that label is registered and that the conversion-feed graph carries its unit to US Dollars
///      inside that source's hop budget (1 hop for an aggregator, 2 for an ERC-4626 vault). The two
///      sources of one asset are NOT required to name the same label, and one test below pins that.
///
///      A SOURCELESS ASSET IS LEGAL. Neither source present — both `addr == address(0)` — is accepted.
///      The old `EmptySources` error is deleted from the interface and nothing replaced it. Such an
///      entry holds no denomination anywhere, so the reach-US-Dollars requirement is vacuous for it
///      rather than waived, and an edit may take an asset back down to that state. What it
///      cannot do is serve as a leg of `deploy`, which reverts `MissingSource` — asserted in the deploy
///      suites, not here.
///
///      NO WALK MEANS NO WALK-NEUTRAL FIXTURES. The predecessor needed each fixture token to be walk-
///      neutral, first by stamping a foreign `chainId` and then by making every token a plain
///      {MockERC20} with no `asset()`. `addAssets` no longer probes `asset()` at all, so neutrality is
///      not a concern here. Tokens stay deployed {MockERC20} contracts anyway: `deploy` reads each leg's
///      live `decimals()` downstream, and `MarketRegistryLib.deriveDenomination` still probes `asset()`
///      through a `try`/`catch` where a CODELESS target makes the ABI decode revert UNCATCHABLY.
///
///      REMOVAL ORDERING — why `_removeAsset` must read the stored `name` BEFORE deleting the primary
///      record: the secondary name index (`_assetByName[nameKey] → keyHash`) is keyed on the FOLDED
///      name, which is only recoverable from the stored struct. Delete the record first and the name
///      is gone, its `nameKey` can no longer be computed, and the name entry is orphaned — pointing
///      at a dead primary key, with the folded name unusable for ever.
///      `test_removeAssets_happyPath_clearsEverything` proves the name key is cleared;
///      `test_removeAssets_nameReusableAfterRemoval` proves it is genuinely free for re-use.
contract AssetStoreTest is Test {
    MarketRegistry internal registry;
    IMarketRegistry internal reg;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    /// @dev Asset addresses. Contracts, not labels — see the contract-level note.
    address internal tokenA;
    address internal tokenB;

    /// @dev Non-zero placeholder SOURCE address. Sources are never called (their `denomination` is read
    ///      from calldata only), so a codeless address is fine here and only here.
    address internal constant SRC = address(0x5A25);

    /// @dev A registered label with NO conversion feed behind it, for the reachability cases.
    address internal constant GBP_UNIT = address(0x9BB);

    /// @dev The two seeded units, taken from the library so a change there cannot leave this suite
    ///      asserting against a stale sentinel.
    address internal constant USD_UNIT = MarketRegistryLib.USD_DENOMINATION;
    address internal constant ETH_UNIT = MarketRegistryLib.ETH_DENOMINATION;

    IMarketRegistry.Namespace internal constant NS_ASSET = IMarketRegistry.Namespace.Asset;

    MockWrapperFactory internal wrapperFactory;

    /// @dev The registry constructor takes a THIRD argument now — a fixed-rate-oracle factory, which it
    ///      zero-checks — so this suite deploys a real one. Nothing in the asset store reads it.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    function setUp() public {
        wrapperFactory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        registry = new MarketRegistry();
        registry.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
        reg = IMarketRegistry(address(registry));

        tokenA = address(new MockERC20("Token A", "AAA", 6));
        tokenB = address(new MockERC20("Token B", "BBB", 18));

        // "USD" and "ETH" are seeded by the constructor. "GBP" is registered but deliberately has no
        // path to US Dollars, which is what makes it the one case that separates "nobody governs that
        // label" from "the label is fine, the graph cannot carry it to US Dollars".
        vm.prank(owner);
        reg.addDenominations(one("GBP"), one(GBP_UNIT));

        // The one bridge edge this suite needs: without it an "ETH"-quoted source is unwritable, so the
        // edit and mixed-denomination cases below could not use Ether as their second unit.
        vm.prank(owner);
        reg.addConversionFeeds(
            one(
                IMarketRegistry.ConversionFeed({
                    base: ETH_UNIT, quote: USD_UNIT, aggregatorAddress: makeAddr("ethUsdAggregator"), feedDecimals: 8
                })
            )
        );
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev A structurally-valid asset: one price source quoting "USD" (zero bridge hops), NAV slot
    ///      absent. There is no asset-level denomination argument any more, because there is no
    ///      asset-level denomination FIELD any more.
    function _asset(address addr_, string memory name_) internal pure returns (IMarketRegistry.Asset memory) {
        return mkPriceOnlyAsset(addr_, name_, SRC, "USD");
    }

    function _keyHash(address addr_) internal pure returns (bytes32) {
        return keccak256(abi.encode(addr_));
    }

    function _add(IMarketRegistry.Asset memory e) internal {
        vm.prank(owner);
        reg.addAssets(one(e));
    }

    function _newToken(string memory symbol_) internal returns (address) {
        return address(new MockERC20(symbol_, symbol_, 18));
    }

    /// @dev The stored `denomination` of ONE of a stored asset's two source slots. Which slot is a
    ///      required argument, because "the asset's denomination" is no longer a question with a single
    ///      answer. An ABSENT slot reads back as the empty string.
    function _sourceDenomination(address addr_, IMarketRegistry.SourceType which)
        internal
        view
        returns (string memory)
    {
        (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(addr_);
        require(found, "asset not stored");
        return which == IMarketRegistry.SourceType.PRICE ? got.priceSource.denomination : got.navSource.denomination;
    }

    /// @dev Performs a raw low-level call into the registry and bubbles the revert data verbatim so
    ///      `vm.expectRevert` can match the exact panic/selector. Used only by the malformed-calldata
    ///      enum tests, where the corrupted ABI cannot be produced through the typed interface.
    function rawCall(bytes memory cd) external {
        (bool ok, bytes memory ret) = address(reg).call(cd);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ── addAsset: happy path ───────────────────────────────────────────────────

    function test_addAssets_happyPath_storesAndIndexes() public {
        IMarketRegistry.Asset memory e = _asset(tokenA, "USDC");
        bytes32 keyHash = _keyHash(tokenA);

        // EntryAdded on a fresh insert, carrying the whole record — an indexer replaying this log
        // alone must be able to rebuild the entry without calling back.
        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryAdded(NS_ASSET, keyHash, abi.encode(e));

        _add(e);

        // Retrievable by address, every field intact.
        (bool foundA, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertTrue(foundA, "not found by address");
        assertEq(got.addr, tokenA, "addr mismatch");
        assertEq(got.name, "USDC", "name mismatch");
        assertEq(uint256(uint8(got.kind)), uint256(uint8(IMarketRegistry.AssetKind.ERC20)), "kind mismatch");
        // The price slot is filled, and its denomination is stored VERBATIM — not derived, not rewritten.
        assertEq(got.priceSource.addr, SRC, "price source addr mismatch");
        assertEq(got.priceSource.denomination, "USD", "price source denomination not stored verbatim");
        assertEq(
            uint256(uint8(got.priceSource.sourceType)),
            uint256(uint8(IMarketRegistry.SourceType.PRICE)),
            "price source type mismatch"
        );
        // The NAV slot is absent: zeroed, string included.
        assertEq(got.navSource.addr, address(0), "absent NAV slot should be zeroed");
        assertEq(got.navSource.denomination, "", "absent NAV slot should have no denomination");

        // Retrievable by name (secondary index populated).
        (bool foundN, IMarketRegistry.Asset memory gotN) = reg.lookupAssetByName("USDC");
        assertTrue(foundN, "not found by name");
        assertEq(gotN.addr, tokenA, "name index points at wrong primary");

        // Enumeration reflects the single entry.
        (IMarketRegistry.Asset[] memory page, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 1, "total != 1");
        assertEq(page.length, 1, "page length != 1");
        assertEq(page[0].addr, tokenA, "enumerated addr mismatch");
    }

    /// @notice An asset may carry BOTH sources, and both are stored in their own named field.
    function test_addAssets_bothSources_storedInOwnFields() public {
        address navVault = _newToken("VLT");
        _add(mkDualSourceAsset(tokenA, "BOTH", SRC, navVault, "USD"));

        (, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertEq(got.priceSource.addr, SRC, "price slot wrong");
        assertEq(got.navSource.addr, navVault, "nav slot wrong");
        assertEq(
            uint256(uint8(got.navSource.sourceInterface)),
            uint256(uint8(IMarketRegistry.SourceInterface.ERC4626)),
            "nav interface not preserved"
        );
    }

    /// @notice The two sources of one asset may name DIFFERENT denominations, and both are stored
    ///         verbatim. Nothing compares them.
    /// @dev This is a deliberate rule, not a gap. The two legs of a Morpho oracle resolve their
    ///      conversion paths independently, so a price source publishing in Ether alongside a
    ///      net-asset-value source publishing in US Dollars is a legitimate asset, and forbidding it
    ///      would forbid exactly the mixed vault/feed pairs `OracleMode` exists to support. Each label
    ///      is validated on its OWN against its own source's hop budget: "ETH" needs the one bridge edge
    ///      `setUp` added (1 hop, within the aggregator's budget of 1) and "USD" needs none.
    function test_addAssets_sourcesMayNameDifferentDenominations() public {
        address navVault = _newToken("MIXVLT");
        _add(mkDualSourceAsset(tokenA, "MIXED", SRC, "ETH", navVault, "USD"));

        (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertTrue(found, "an asset whose two sources disagree on the label must be accepted");
        assertEq(got.priceSource.denomination, "ETH", "price source label not stored verbatim");
        assertEq(got.navSource.denomination, "USD", "nav source label not stored verbatim");
        assertEq(got.priceSource.addr, SRC, "price slot wrong");
        assertEq(got.navSource.addr, navVault, "nav slot wrong");
    }

    // ── addAsset: structural checks ────────────────────────────────────────────

    /// @notice Zero token address → ZeroAddress.
    function test_addAssets_zeroAddr_reverts() public {
        IMarketRegistry.Asset memory e = _asset(address(0), "USDC");
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        reg.addAssets(one(e));
    }

    /// @notice Empty name → EmptyName.
    function test_addAssets_emptyName_reverts() public {
        IMarketRegistry.Asset memory e = _asset(tokenA, "");
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EmptyName.selector);
        reg.addAssets(one(e));
    }

    /// @notice NEITHER source present → ACCEPTED, and the record reads back with both slots absent.
    /// @dev This case used to revert `EmptySources`, on the reasoning that an asset with no readable
    ///      source cannot be priced in either oracle mode. That error is DELETED and nothing replaced
    ///      it: the entry is now a legal approval record. It carries no denomination anywhere, so the
    ///      registered-label and reach-US-Dollars checks have nothing to run against and are vacuous
    ///      rather than waived. The original objection has not been dropped either — it moved to
    ///      `deploy`, which refuses such an asset as a leg with `MissingSource(asset, mode)` in BOTH
    ///      oracle modes. That refusal is asserted in the deploy suites; what is asserted here is only
    ///      that the WRITE lands and round-trips.
    function test_addAssets_noSources_accepted() public {
        IMarketRegistry.Asset memory e = mkSourcelessAsset(tokenA, "SOURCELESS");
        bytes32 keyHash = _keyHash(tokenA);

        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryAdded(NS_ASSET, keyHash, abi.encode(e));
        _add(e);

        (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertTrue(found, "a sourceless asset must be stored");
        assertEq(got.addr, tokenA, "addr mismatch");
        assertEq(got.name, "SOURCELESS", "name mismatch");

        // Both slots absent, both strings empty — an absent source is zeroed rather than copied.
        assertEq(got.priceSource.addr, address(0), "price slot should be absent");
        assertEq(got.priceSource.denomination, "", "absent price slot should carry no denomination");
        assertEq(got.navSource.addr, address(0), "nav slot should be absent");
        assertEq(got.navSource.denomination, "", "absent nav slot should carry no denomination");

        // Fully a member of the store: name index and enumeration both include it.
        (bool foundN, IMarketRegistry.Asset memory gotN) = reg.lookupAssetByName("SOURCELESS");
        assertTrue(foundN, "sourceless asset missing from the name index");
        assertEq(gotN.addr, tokenA, "name index points at wrong primary");
        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 1, "sourceless asset missing from enumeration");
    }

    /// @notice A sourceless asset may declare `AssetKind.ERC4626` just as well as `ERC20`.
    /// @dev `kind` is descriptive metadata with no on-chain reader beyond the enum range check, so the
    ///      sourceless rule is not quietly restricted to one kind.
    function test_addAssets_noSources_erc4626Kind_accepted() public {
        _add(mkSourcelessAsset(tokenA, "SOURCELESS4626", IMarketRegistry.AssetKind.ERC4626));

        (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertTrue(found, "a sourceless ERC-4626 entry must be stored");
        assertEq(uint256(uint8(got.kind)), uint256(uint8(IMarketRegistry.AssetKind.ERC4626)), "kind mismatch");
        assertEq(got.priceSource.addr, address(0), "price slot should be absent");
        assertEq(got.navSource.addr, address(0), "nav slot should be absent");
    }

    /// @notice EXACTLY ONE source is enough — a NAV-only asset is valid.
    /// @dev The predecessor's per-element "every source address must be non-zero" loop is gone, and
    ///      this is why: an absent source is no longer a source with a bad address, it is the absence
    ///      of one, and only the PRESENT slots are validated.
    function test_addAssets_navSourceOnly_accepted() public {
        address navVault = _newToken("VLT");
        _add(mkNavOnlyAsset(tokenA, "NAVONLY", navVault, "USD"));

        (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertTrue(found, "NAV-only asset should be accepted");
        assertEq(got.priceSource.addr, address(0), "price slot should stay empty");
        assertEq(got.navSource.addr, navVault, "nav slot not stored");
    }

    /// @notice A source in the WRONG field → SourceTypeMismatch(expected, provided).
    /// @dev Filing a source wherever its own `sourceType` pointed would let a caller submit two NAV
    ///      sources and have one silently overwrite the other, so the mismatch is rejected at the call
    ///      site instead of being routed around.
    function test_addAssets_navTypeInPriceField_reverts() public {
        IMarketRegistry.Asset memory e = mkAsset(
            tokenA,
            "WRONGFIELD",
            IMarketRegistry.AssetKind.ERC20,
            mkNavSource(SRC, "USD"), // NAV-typed source sitting in the PRICE field
            noSource()
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistry.SourceTypeMismatch.selector,
                IMarketRegistry.SourceType.PRICE,
                IMarketRegistry.SourceType.NAV
            )
        );
        reg.addAssets(one(e));
    }

    /// @notice The mirror case: a PRICE-typed source in the NAV field.
    function test_addAssets_priceTypeInNavField_reverts() public {
        IMarketRegistry.Asset memory e = mkAsset(
            tokenA,
            "WRONGFIELD2",
            IMarketRegistry.AssetKind.ERC20,
            noSource(),
            mkPriceSource(SRC, "USD") // PRICE-typed source sitting in the NAV field
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistry.SourceTypeMismatch.selector,
                IMarketRegistry.SourceType.NAV,
                IMarketRegistry.SourceType.PRICE
            )
        );
        reg.addAssets(one(e));
    }

    // ── addAsset: every PRESENT source's denomination must be a REGISTERED label ─
    //
    // These cases are the write-time half of #75, and they are the reason a denomination is a governed
    // fact rather than a free string. The predecessor accepted any label, then discovered the problem at
    // some later `deploy` in a different transaction — usually weeks later, usually to someone who had
    // not made the mistake. The check now runs once per PRESENT source, against that source's own label.

    /// @notice A source `denomination` that was never registered → UnregisteredDenomination(label),
    ///         naming the label byte-for-byte as supplied.
    function test_addAssets_unregisteredSourceDenomination_reverts() public {
        IMarketRegistry.Asset memory e = mkPriceOnlyAsset(tokenA, "UNREG", SRC, "MADEUP");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, "MADEUP"));
        reg.addAssets(one(e));
    }

    /// @notice An EMPTY source `denomination` lands on the same error, naming the empty string.
    /// @dev The empty string is simply not a registered label, so it needs no rule of its own — and it
    ///      is worth pinning that it needs none. The deleted `EmptyDenomination` error used to guard the
    ///      deleted asset-level field after a walk; this is a different question asked at a different
    ///      time, and it is the only one left.
    function test_addAssets_emptySourceDenomination_reverts() public {
        IMarketRegistry.Asset memory e = mkPriceOnlyAsset(tokenA, "EMPTYDENOM", SRC, "");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, ""));
        reg.addAssets(one(e));
    }

    /// @notice Registration is EXACT BYTES and case-sensitive: the constructor seeds `"USD"`, so a
    ///         lowercase `"usd"` is simply not a registered label and fails.
    /// @dev The contrast with `lookupAssetByName` is deliberate and worth pinning side by side. A NAME is
    ///      case-folded, because it is a human triage convenience and never a safety key. A DENOMINATION
    ///      is not, because it selects which conversion feeds a source may bridge through — folding it
    ///      would make `"usd"` and `"USD"` interchangeable safety keys on the strength of a typo.
    function test_addAssets_lowercaseUsdSourceDenomination_reverts() public {
        IMarketRegistry.Asset memory e = mkPriceOnlyAsset(tokenA, "LOWERUSD", SRC, "usd");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, "usd"));
        reg.addAssets(one(e));
    }

    /// @notice A registered label with no dollar path is refused —
    ///         NoConversionPathToUsd(unit, budget). "GBP" is registered by `setUp` and has no edge.
    /// @dev Two separate questions, and the error tells them apart: `UnregisteredDenomination` means
    ///      "nobody governs that label", `NoConversionPathToUsd` means "the label is fine, the graph
    ///      cannot carry it to US Dollars". The budget in the error is 1 because the source is an
    ///      `AGGREGATOR_V3`, which spends `feed1` on itself and leaves only `feed2`.
    function test_addAssets_unreachableSourceDenomination_reverts() public {
        IMarketRegistry.Asset memory e = mkPriceOnlyAsset(tokenA, "GBPQUOTED", SRC, "GBP");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, GBP_UNIT, uint256(1)));
        reg.addAssets(one(e));
    }

    /// @notice The reachability check runs on the NAV slot too, with the vault's larger budget of 2.
    /// @dev Both present sources are validated, each against its OWN hop budget. "GBP" has no edge at
    ///      all, so two hops do not help it — which is what makes it a clean witness that the NAV slot
    ///      is checked rather than skipped, and that the budget reported is the vault's 2 and not the
    ///      aggregator's 1.
    function test_addAssets_unreachableNavDenomination_reverts() public {
        address navVault = _newToken("GBPVLT");
        IMarketRegistry.Asset memory e = mkNavOnlyAsset(tokenA, "GBPNAV", navVault, "GBP");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, GBP_UNIT, uint256(2)));
        reg.addAssets(one(e));
    }

    // ── addAsset: duplicate rejection ──────────────────────────────────────────

    /// @notice An occupied primary key (the address alone, now) → EntryAlreadyExists. Uses a distinct
    ///         name so the primary-key check, not the name-key check, is the trigger.
    function test_addAssets_duplicateNaturalKey_reverts() public {
        _add(_asset(tokenA, "USDC"));

        IMarketRegistry.Asset memory dup = _asset(tokenA, "SOMETHINGELSE");
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        reg.addAssets(one(dup));
    }

    /// @notice An occupied folded-name key → EntryAlreadyExists. Uses a DIFFERENT address (so the
    ///         primary key is free) and a case-variant name, to prove the name key is the lowercased
    ///         fold rather than the raw bytes.
    function test_addAssets_duplicateName_reverts() public {
        _add(_asset(tokenA, "USDC"));

        IMarketRegistry.Asset memory dup = _asset(tokenB, "usdc");
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        reg.addAssets(one(dup));
    }

    // ── addAsset: out-of-range enums → Panic(0x21) ─────────────────────────────
    //
    // REGRESSION GUARD, AND THAT IS THE WHOLE POINT OF THESE TESTS.
    // `MarketRegistryLib.validateAssetEnums` reads its enum ordinals RAW from calldata at hard-coded
    // byte offsets. Nothing fails loudly if an offset goes stale: the read simply lands on a different
    // word, the range check silently stops checking the field it names, and the panic path quietly
    // stops working. The predecessor hard-coded 96 for `kind` against the head
    // `addr:0, chainId:32, name-offset:64, kind:96`; dropping `chainId` moved `kind` to 64. Deleting the
    // asset-level `denomination` then moved the two SOURCE offsets down one word each, 128/160 → 96/128,
    // while `kind` stayed put. These tests are the only thing that would catch either shift, or the next.

    /// @notice An out-of-range `AssetKind` ordinal reverts panic 0x21.
    function test_addAssets_invalidKindOrdinal_panics() public {
        bytes memory cd = _addAssetCalldata();
        _patchWord(cd, _kindOffset(cd), 2); // valid members: ERC20 = 0, ERC4626 = 1

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice An out-of-range `SourceType` ordinal inside a source reverts panic 0x21.
    function test_addAssets_invalidSourceTypeOrdinal_panics() public {
        bytes memory cd = _addAssetCalldata();
        _patchWord(cd, _priceSourceHeadOffset(cd) + 32, 2); // valid members: PRICE = 0, NAV = 1

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice An out-of-range `SourceInterface` ordinal inside a source reverts panic 0x21.
    function test_addAssets_invalidSourceInterfaceOrdinal_panics() public {
        bytes memory cd = _addAssetCalldata();
        _patchWord(cd, _priceSourceHeadOffset(cd) + 64, 7); // valid: AGGREGATOR_V3 = 0, ERC4626 = 1

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice The ABSENT source's enum words are range-checked too.
    /// @dev An honest encoder writes 0 into both, which is in range for both enums, so this costs
    ///      nothing on the happy path. A hostile encoder can write anything there, and those words are
    ///      read back by every consumer that decodes a stored `Asset`.
    function test_addAssets_invalidEnumInAbsentSource_panics() public {
        bytes memory cd = _addAssetCalldata();
        _patchWord(cd, _navSourceHeadOffset(cd) + 32, 3);

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice The enum range-check runs BEFORE the owner gate: a STRANGER gets panic 0x21, not
    ///         `OwnableUnauthorizedAccount`.
    /// @dev Deliberate ordering. A malformed enum ordinal is a malformed CALL and should fail as one
    ///      whoever sent it, rather than being masked by the authority error for a non-owner and only
    ///      revealing itself to the owner. Every other owner-only function gates first.
    function test_addAssets_invalidEnum_panicsBeforeOwnerGate() public {
        bytes memory cd = _addAssetCalldata();
        _patchWord(cd, _kindOffset(cd), 2);

        vm.prank(stranger);
        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    // ── addAsset: access control ───────────────────────────────────────────────

    /// @notice Non-owner caller → OwnableUnauthorizedAccount(caller).
    function test_addAssets_nonOwner_reverts() public {
        IMarketRegistry.Asset memory e = _asset(tokenA, "USDC");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.addAssets(one(e));
    }

    // ── removeAsset ────────────────────────────────────────────────────────────

    /// @notice Removal clears the primary record, the index, the name index, and enumeration. The
    ///         name-index clear is the load-bearing assertion for read-name-before-delete.
    function test_removeAssets_happyPath_clearsEverything() public {
        _add(_asset(tokenA, "USDC"));
        bytes32 keyHash = _keyHash(tokenA);

        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryRemoved(NS_ASSET, keyHash, abi.encode(tokenA));

        vm.prank(owner);
        reg.removeAssets(one(tokenA));

        // Primary record gone and zeroed.
        (bool foundA, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertFalse(foundA, "still found by address after removal");
        assertEq(got.addr, address(0), "addr not zeroed");
        assertEq(got.name, "", "name not zeroed");
        assertEq(got.priceSource.addr, address(0), "price source not zeroed");
        assertEq(got.priceSource.denomination, "", "price source denomination not zeroed");
        assertEq(got.navSource.addr, address(0), "nav source not zeroed");
        assertEq(got.navSource.denomination, "", "nav source denomination not zeroed");

        // Secondary name index cleared — proves read-name-before-delete ordering.
        (bool foundN,) = reg.lookupAssetByName("USDC");
        assertFalse(foundN, "name index orphaned: not cleared on removal");

        // Enumeration empty.
        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 0, "store not empty after removing sole entry");
    }

    /// @notice Removing an absent key → EntryNotFound.
    /// @dev The token is deployed on its OWN line, ahead of the cheatcodes. `_newToken` performs a
    ///      `CREATE`, and a `CREATE` inside the argument list would consume the `vm.prank` and be the
    ///      call `vm.expectRevert` matched against — so the test would fail with "did not revert" while
    ///      the code under test was never reached. Same reason in every case below that needs a token.
    function test_removeAssets_missing_reverts() public {
        address ghost = _newToken("GHOST");

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        reg.removeAssets(one(ghost));
    }

    /// @notice A removal is visible to the very next read and does not disturb siblings.
    function test_removeAssets_thenLookup_liveRead() public {
        _add(_asset(tokenA, "AAA"));
        _add(_asset(tokenB, "BBB"));

        (bool fa0,) = reg.lookupAssetByAddress(tokenA);
        (bool fb0,) = reg.lookupAssetByAddress(tokenB);
        assertTrue(fa0 && fb0, "setup: both assets should be present");

        vm.prank(owner);
        reg.removeAssets(one(tokenA));

        (bool fa1,) = reg.lookupAssetByAddress(tokenA);
        (bool fb1,) = reg.lookupAssetByAddress(tokenB);
        assertFalse(fa1, "removed asset still reads live");
        assertTrue(fb1, "sibling asset lost after unrelated removal");
    }

    /// @notice After removal the folded name is genuinely free: re-adding the same name at a fresh
    ///         address succeeds. If the name key were not cleared on removal, this would revert
    ///         EntryAlreadyExists.
    function test_removeAssets_nameReusableAfterRemoval() public {
        _add(_asset(tokenA, "USDC"));

        vm.prank(owner);
        reg.removeAssets(one(tokenA));

        _add(_asset(tokenB, "USDC")); // must NOT revert

        (bool foundN, IMarketRegistry.Asset memory gotN) = reg.lookupAssetByName("USDC");
        assertTrue(foundN, "name not reusable after removal");
        assertEq(gotN.addr, tokenB, "reused name resolves to wrong primary");
    }

    /// @notice Removing one asset removes ONLY that asset: sibling assets and other stores (a
    ///         conversion feed here) are untouched. No cascade.
    function test_removeAssets_noCascade() public {
        _add(_asset(tokenA, "AAA"));
        _add(_asset(tokenB, "BBB"));

        // Cross-store witness: a conversion feed that must survive the asset removal.
        address feedBase = makeAddr("feedBase");
        address feedQuote = makeAddr("feedQuote");
        vm.prank(owner);
        reg.addConversionFeeds(
            one(
                IMarketRegistry.ConversionFeed({
                    base: feedBase, quote: feedQuote, aggregatorAddress: makeAddr("agg"), feedDecimals: 8
                })
            )
        );

        vm.prank(owner);
        reg.removeAssets(one(tokenA));

        (bool fa,) = reg.lookupAssetByAddress(tokenA);
        (bool fb,) = reg.lookupAssetByAddress(tokenB);
        (bool ff,) = reg.lookupConversionFeed(feedBase, feedQuote);
        assertFalse(fa, "target asset should be gone");
        assertTrue(fb, "sibling asset cascaded away");
        assertTrue(ff, "conversion feed cascaded away");

        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 1, "asset count wrong after single removal (cascade suspected)");
    }

    // ── lookupAssetByName: A–Z fold ────────────────────────────────────────────

    /// @notice Name lookup folds A–Z to a–z: a mixed-case stored name resolves from any letter-case
    ///         variant of the same name.
    /// @notice `isAsset` is the cheap membership test: true for a stored asset, false for everything
    ///         else, and it never reverts.
    /// @dev It exists so a caller that only wants yes-or-no does not pay for `lookupAssetByAddress` to
    ///      copy the name and both denomination strings into memory. It must agree with the `found` flag
    ///      of that lookup in every case, which is what the two paired assertions below check.
    function test_isAsset_agreesWithLookup() public {
        address ghost = _newToken("GHOST");
        assertFalse(reg.isAsset(ghost), "an unregistered token is not an asset");
        assertFalse(reg.isAsset(address(0)), "the zero address is never an asset");

        _add(_asset(tokenA, "ISASSET"));
        assertTrue(reg.isAsset(tokenA), "a stored asset must report true");
        (bool found,) = reg.lookupAssetByAddress(tokenA);
        assertTrue(found, "isAsset and the lookup must agree after an add");

        vm.prank(owner);
        reg.removeAssets(one(tokenA));
        assertFalse(reg.isAsset(tokenA), "a removed asset must report false");
        (bool foundAfter,) = reg.lookupAssetByAddress(tokenA);
        assertFalse(foundAfter, "isAsset and the lookup must agree after a removal");
    }

    function test_lookupByName_caseInsensitive() public {
        _add(_asset(tokenA, "MixedUSDC"));

        (bool fLower, IMarketRegistry.Asset memory gLower) = reg.lookupAssetByName("mixedusdc");
        assertTrue(fLower, "lowercase variant not found");
        assertEq(gLower.addr, tokenA, "lowercase variant resolves to wrong asset");

        (bool fUpper, IMarketRegistry.Asset memory gUpper) = reg.lookupAssetByName("MIXEDUSDC");
        assertTrue(fUpper, "uppercase variant not found");
        assertEq(gUpper.addr, tokenA, "uppercase variant resolves to wrong asset");

        (bool fExact,) = reg.lookupAssetByName("MixedUSDC");
        assertTrue(fExact, "exact-case variant not found");
    }

    // ── editing an asset: remove, then add ─────────────────────────────────────
    //
    // There is no `updateSource` and no update path of any kind. Changing anything about a stored
    // asset — a source address, a label, the kind — is `removeAssets` followed by `addAssets`, which
    // the owner bundles into one transaction. These tests pin the consequences of that, and the
    // helper below is what a curator Safe's bundle looks like.

    /// @dev The edit primitive: remove the asset, add the replacement. Both calls from the owner, in
    ///      this order. The other order reverts `EntryAlreadyExists`, which the ordering test asserts.
    function _reAdd(address addr_, IMarketRegistry.Asset memory replacement) internal {
        vm.startPrank(owner);
        reg.removeAssets(one(addr_));
        reg.addAssets(one(replacement));
        vm.stopPrank();
    }

    /// @notice A re-add replaces exactly what the replacement entry states — both sources, whether or
    ///         not they changed.
    /// @dev The cost of losing `updateSource`: an edit is a WHOLE-ENTRY write, so the caller must
    ///      resupply the source it did not mean to touch. Here only the price source is meant to move,
    ///      and the NAV source is carried across unchanged because the caller carries it.
    function test_reAdd_replacesPriceSource_navCarriedAcross() public {
        address navVault = _newToken("VLT");
        _add(
            mkAsset(
                tokenA,
                "UPD",
                IMarketRegistry.AssetKind.ERC4626,
                mkPriceSource(SRC, "USD"),
                mkNavSource(navVault, "USD")
            )
        );

        address newAgg = makeAddr("newAggregator");
        _reAdd(
            tokenA,
            mkAsset(
                tokenA,
                "UPD",
                IMarketRegistry.AssetKind.ERC4626,
                mkPriceSource(newAgg, "ETH"),
                mkNavSource(navVault, "USD")
            )
        );

        (, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertEq(got.priceSource.addr, newAgg, "price source not replaced");
        assertEq(got.priceSource.denomination, "ETH", "price source denomination not replaced");
        assertEq(got.navSource.addr, navVault, "nav source not carried across");
        assertEq(got.navSource.denomination, "USD", "nav denomination not carried across");
    }

    /// @notice An edit that only adds a NAV source keeps the price source, because the replacement
    ///         states both.
    function test_reAdd_addsNavSource() public {
        _add(_asset(tokenA, "UPD2"));

        address newVault = _newToken("NV2");
        _reAdd(tokenA, mkDualSourceAsset(tokenA, "UPD2", SRC, "USD", newVault, "USD"));

        (, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertEq(got.navSource.addr, newVault, "nav source not written");
        assertEq(got.priceSource.addr, SRC, "price source not carried across");
    }

    /// @notice The add half of an edit runs the SAME write-time validation as any other add, so an
    ///         edit cannot install a source a fresh add would have refused.
    /// @dev This is what folding the update path into add/remove buys: there is no second write path
    ///      that could drift from the first, and therefore no way AROUND write-time validation. "GBP"
    ///      is a registered label with no conversion feed behind it, so the label check passes and the
    ///      PATH check fails.
    function test_reAdd_unreachableUnit_reverts() public {
        _add(_asset(tokenA, "UPD3"));

        vm.startPrank(owner);
        reg.removeAssets(one(tokenA));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, GBP_UNIT, uint256(1)));
        reg.addAssets(one(mkPriceOnlyAsset(tokenA, "UPD3", SRC, "GBP")));
        vm.stopPrank();
    }

    /// @notice An UNREGISTERED label is refused too, naming the label.
    function test_reAdd_unregisteredLabel_reverts() public {
        _add(_asset(tokenA, "UPD4"));

        vm.startPrank(owner);
        reg.removeAssets(one(tokenA));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, "MADEUP"));
        reg.addAssets(one(mkPriceOnlyAsset(tokenA, "UPD4", SRC, "MADEUP")));
        vm.stopPrank();
    }

    /// @notice An edit can drop a source: the replacement simply leaves that slot absent, and the
    ///         stored slot comes back zeroed, string included.
    function test_reAdd_droppingNavSource_clearsSlot() public {
        address navVault = _newToken("VLT");
        _add(
            mkAsset(
                tokenA,
                "UPD5",
                IMarketRegistry.AssetKind.ERC4626,
                mkPriceSource(SRC, "USD"),
                mkNavSource(navVault, "USD")
            )
        );

        _reAdd(tokenA, mkPriceOnlyAsset(tokenA, "UPD5", SRC, "USD"));

        (, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertEq(got.navSource.addr, address(0), "nav slot not cleared");
        assertEq(got.navSource.denomination, "", "cleared slot must not keep its denomination");
        assertEq(got.priceSource.addr, SRC, "price source must survive the drop");
    }

    /// @notice Dropping the LAST remaining source is allowed and leaves a legal sourceless asset.
    /// @dev An entry with neither source is a state `addAssets` accepts outright — the old
    ///      `EmptySources` error is deleted — so an edit that arrives at it is accepted for the same
    ///      reason. The asset stays a member of the store and simply stops resolving as a leg of
    ///      `deploy` (`MissingSource`) until a source is added back, which the second half of this
    ///      test does.
    function test_reAdd_droppingLastSource_leavesSourcelessAsset() public {
        _add(_asset(tokenA, "UPD6"));

        _reAdd(tokenA, mkSourcelessAsset(tokenA, "UPD6"));

        (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(tokenA);
        assertTrue(found, "the asset must survive losing its last source");
        assertEq(got.priceSource.addr, address(0), "price slot not cleared");
        assertEq(got.priceSource.denomination, "", "cleared slot must not keep its denomination");
        assertEq(got.navSource.addr, address(0), "nav slot should still be absent");

        // Still enumerable and still reachable by name — the record exists, it is just empty.
        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 1, "the sourceless asset should still be enumerated");
        (bool foundN,) = reg.lookupAssetByName("UPD6");
        assertTrue(foundN, "name index should still resolve");

        // And a source can be put straight back on with another edit.
        _reAdd(tokenA, _asset(tokenA, "UPD6"));
        assertEq(_sourceDenomination(tokenA, IMarketRegistry.SourceType.PRICE), "USD", "source not restorable");
    }

    /// @notice ORDER MATTERS inside the bundle. Add-then-remove reverts on the add, so a
    ///         backwards bundle fails loudly instead of deleting the asset it was meant to edit.
    /// @dev The whole safety argument for dropping the update path rests on this being loud.
    function test_reAdd_addBeforeRemove_revertsAlreadyExists() public {
        _add(_asset(tokenA, "UPD7"));

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        reg.addAssets(one(mkPriceOnlyAsset(tokenA, "UPD7", makeAddr("other"), "USD")));
    }

    /// @notice Between the remove and the add the asset is genuinely absent — which is exactly why the
    ///         two calls must be bundled into one transaction.
    function test_reAdd_assetIsAbsentBetweenTheTwoCalls() public {
        _add(_asset(tokenA, "UPD8"));

        vm.prank(owner);
        reg.removeAssets(one(tokenA));

        assertFalse(reg.isAsset(tokenA), "asset must read absent in the gap");
        (bool found,) = reg.lookupAssetByAddress(tokenA);
        assertFalse(found, "lookup must miss in the gap");

        vm.prank(owner);
        reg.addAssets(one(_asset(tokenA, "UPD8")));
        assertTrue(reg.isAsset(tokenA), "asset must be back after the add");
    }

    /// @notice An edit may change the NAME, because the remove clears the name index before the add
    ///         writes the new one. The old name stops resolving in the same transaction.
    function test_reAdd_canRenameAndTheOldNameStopsResolving() public {
        _add(_asset(tokenA, "OLDNAME"));

        _reAdd(tokenA, _asset(tokenA, "NEWNAME"));

        (bool foundNew,) = reg.lookupAssetByName("NEWNAME");
        assertTrue(foundNew, "new name must resolve");
        (bool foundOld,) = reg.lookupAssetByName("OLDNAME");
        assertFalse(foundOld, "old name must stop resolving");
    }

    /// @notice A re-add moves the asset to the END of the enumeration, because the remove swap-pops
    ///         and the add pushes.
    /// @dev Positions were never stable, but an edit is the easiest way to move one — so nothing may
    ///      name an asset by its index in `getAssets`.
    function test_reAdd_movesTheAssetToTheEndOfEnumeration() public {
        address tokenC = _newToken("TKC");
        _add(_asset(tokenA, "FIRST"));
        _add(_asset(tokenC, "SECOND"));

        _reAdd(tokenA, _asset(tokenA, "FIRST"));

        (IMarketRegistry.Asset[] memory page,) = reg.getAssets(0, 10);
        assertEq(page[0].addr, tokenC, "the survivor should have been swapped down into slot 0");
        assertEq(page[1].addr, tokenA, "the re-added asset should sit at the end");
    }

    /// @notice Both halves of an edit are owner-only.
    /// @dev The second token is deployed BEFORE the cheatcodes: `_newToken` is a contract creation, and
    ///      a creation would consume the prank meant for the `addAssets` call.
    function test_reAdd_nonOwner_reverts() public {
        _add(_asset(tokenA, "UPD9"));
        address other = _newToken("OTHER");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.removeAssets(one(tokenA));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.addAssets(one(_asset(other, "OTHER")));
    }

    // ── calldata surgery helpers (enum panic tests) ────────────────────────────
    //
    // `Asset`'s ABI head is FIVE words, because `name` and BOTH `AssetSource` members are dynamic (each
    // source contains a string), so each contributes an OFFSET word. The asset-level `denomination` used
    // to sit between `kind` and `priceSource` and contributed a sixth; deleting it moved the two source
    // offsets down one word each and left `kind` exactly where it was:
    //
    //     addr:0 · name-offset:32 · kind:64 · priceSource-offset:96 · navSource-offset:128
    //
    // The argument is now an ARRAY of assets, so the tuple no longer sits at a fixed byte. Walking in
    // from the selector: byte 4 holds the offset to the array data; the array's length word sits at
    // `4 + word(4)`; the element-offset region starts one word after that; and element 0's own offset
    // is relative to the start of THAT region. So the head of the one asset in a one-element array is
    //
    //     region = 4 + word(4) + 32   ·   tupleHead = region + word(region)
    //
    // which `_tupleHead` computes rather than hard-codes, because the answer changed once already when
    // the single-asset `addAsset` became the array-taking `addAssets` and a stale constant here does
    // not fail loudly — it lands on a different word and an out-of-range enum then PASSES the check.
    //
    // From the tuple head onward everything is as it was: an offset inside a tuple is relative to the
    // start of that tuple's encoding, so a source head sits at `tupleHead + word(tupleHead +
    // <offsetWord>)`, and each source head is four words: addr:0 · sourceType:32 · sourceInterface:64 ·
    // denomination-offset:96.

    function _tupleHead(bytes memory cd) internal pure returns (uint256) {
        uint256 region = 4 + _readWord(cd, 4) + 32;
        return region + _readWord(cd, region);
    }

    function _addAssetCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IMarketRegistry.addAssets.selector, one(_asset(tokenA, "USDC")));
    }

    function _kindOffset(bytes memory cd) internal pure returns (uint256) {
        return _tupleHead(cd) + 64;
    }

    function _priceSourceHeadOffset(bytes memory cd) internal pure returns (uint256) {
        uint256 head = _tupleHead(cd);
        return head + _readWord(cd, head + 96);
    }

    function _navSourceHeadOffset(bytes memory cd) internal pure returns (uint256) {
        uint256 head = _tupleHead(cd);
        return head + _readWord(cd, head + 128);
    }

    function _readWord(bytes memory cd, uint256 byteOffset) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(cd, add(0x20, byteOffset)))
        }
    }

    function _patchWord(bytes memory cd, uint256 byteOffset, uint256 value) internal pure {
        assembly {
            mstore(add(cd, add(0x20, byteOffset)), value)
        }
    }
}
