// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {
    RegistryFixture,
    mkAsset,
    mkNavOnlyAsset,
    mkNavSource,
    mkPriceOnlyAsset,
    mkPriceSource,
    noSource
} from "./helpers/RegistryFixture.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title HopGraph.t.sol — the conversion-feed hop graph and the denomination paths through it
/// @notice Covers `MarketRegistryLib.resolvePath` end to end: the zero-hop dollar case, the one-hop
///         feed path, the two-hop vault path, the hop BUDGET (1 for `AGGREGATOR_V3`, 2 for `ERC4626`),
///         and every way a path can fail to exist. Also pins WHERE the failure lands: at `addAsset`,
///         at write time, not weeks later at `deploy`.
/// @dev `resolvePath` is `internal`, so nothing here calls it directly. It is observed two ways, and
///      both are used deliberately:
///
///      1. **Through `addAsset`.** `_validateSourcePath` calls `resolvePath` for every PRESENT source
///         with that source's own budget, so a reachable unit is a successful add and an unreachable one
///         is a `NoConversionPathToUsd` revert naming the unit AND the budget. The budget in the error
///         is what makes "1 for an aggregator, 2 for a vault" assertable rather than inferred.
///      2. **Through `deploy` and {MockWrapperFactory}.** The mock records all twelve factory
///         arguments, so the resolved path is readable as the `feed1` / `feed2` / `vault` / `sample`
///         the leg was actually wired with. That is the only way to see the ORDER of a two-hop path
///         (nearest the asset first) and the only way to see that a zero-hop leg leaves its bridge slot
///         empty.
///
///      ## The two-hop intermediate is any REGISTERED denomination, and four tests say so
///
///      `docs/decisions/denomination-and-hop-graph.md` §(d) specifies the two-hop search as "walk the
///      registered denominations; for each registered unit `u`, if `(from → u)` and `(u → USD)` both
///      exist, return that pair", with "registration order decides" as the tie-break. That is what
///      `resolvePath` does, over `_denominationKeys` (slot 13). An earlier cut probed Ether and nothing
///      else, because the denomination store had no key array to enumerate; the array is the whole of
///      what widened it.
///
///      Four tests hold the widened shape, and each one pins a different edge of it: a NON-Ether
///      intermediate resolves (`_nonEtherIntermediateResolves`); registration order — not edge-insertion
///      order — picks between two viable intermediates (`_registrationOrderDecides...`); the US Dollar
///      sentinel never contributes a hop (`_usdSentinelIsNeverAnIntermediate`); and an edge is still
///      never walked backwards, on the second hop as well as the first
///      (`_backwardEdgeThroughAnIntermediateIsNotFollowed`). The BOUND is the number of registered
///      denominations, so `setUp` registering nine of them is also the loop length every two-hop test
///      here runs against.
///
///      ## The denomination is a property of the SOURCE, so the path is resolved per source
///
///      `AssetSource.denomination` (previously `quoteUnit`) is now the only denomination there is — the
///      asset-level field is deleted. So `resolvePath` starts from the SELECTED source's own label, and
///      an asset carrying two sources may legitimately name two different labels and resolve two
///      independent paths. `test_hop_bothSourcesArePathChecked` is the case that pins this: it is
///      refused on the NAV source's label alone, while the price source's label was fine.
///
///      Every mock is local. `_newToken` deploys a {MockERC20}: real code and a readable `decimals()`,
///      which the deploy path re-reads live. Never a Phoenix `DummyERC20` — those mint on fallback and
///      burn the gas forwarded to them.
contract HopGraphTest is RegistryFixture {
    // ── units the suite bridges from ───────────────────────────────────────────────
    //
    // Token-backed labels register to a real token address; `"USD"` / `"ETH"` are seeded by the
    // constructor to their Chainlink `Denominations` pseudo-addresses.

    address internal usdcUnit; // "USDC" — one direct hop to US Dollars
    address internal usdtUnit; // "USDT" — one direct hop to US Dollars
    address internal stEthUnit; // "stETH" — no direct dollar edge; reaches US Dollars via Ether
    address internal midUnit; // "MID" — the NON-Ether intermediate: one direct hop to US Dollars
    address internal farUnit; // "FAR" — two hops from US Dollars, through "MID" and only through it
    address internal deepUnit; // "DEEP" — THREE hops (DEEP → FAR → MID → USD), so over budget always
    address internal orphanUnit; // "ORPHAN" — a registered label with no outgoing edge at all
    address internal inverseUnit; // "INVERSE" — only the WRONG-direction (USD → unit) edge exists

    // ── the aggregators sitting on each edge ───────────────────────────────────────

    address internal usdcUsdAgg = makeAddr("usdcUsdAggregator");
    address internal usdtUsdAgg = makeAddr("usdtUsdAggregator");
    address internal stEthEthAgg = makeAddr("stEthEthAggregator");
    address internal midUsdAgg = makeAddr("midUsdAggregator");
    address internal farMidAgg = makeAddr("farMidAggregator");

    function setUp() public {
        _deployRegistry(address(this));

        // The one edge every Ether-quoted source and every Ether-bridged two-hop path depends on.
        _addEthUsdFeed();

        // Token-backed units. `_registerDenominationWithUsdFeed` does the label AND the direct
        // `unit → USD` edge, which is what a one-hop budget needs.
        usdcUnit = _newToken("USDC", 6);
        usdtUnit = _newToken("USDT", 6);
        _registerDenominationWithUsdFeed("USDC", usdcUnit, usdcUsdAgg);
        _registerDenominationWithUsdFeed("USDT", usdtUnit, usdtUsdAgg);

        // Two hops through Ether: a `stETH → ETH` edge and NO direct `stETH → USD` edge.
        stEthUnit = _newToken("stETH", 18);
        _registerDenomination("stETH", stEthUnit);
        _addFeed(stEthUnit, ETH_UNIT, stEthEthAgg, 18);

        // A complete two-hop path whose intermediate is NOT Ether: `FAR → MID → USD`. Both units are
        // registered and both edges exist, and `FAR` has NO edge to Ether — so it resolves only if the
        // search really does walk the registered set.
        midUnit = _newToken("MID", 18);
        farUnit = _newToken("FAR", 18);
        _registerDenomination("MID", midUnit);
        _registerDenomination("FAR", farUnit);
        _addFeed(midUnit, USD_UNIT, midUsdAgg, 8);
        _addFeed(farUnit, midUnit, farMidAgg, 18);

        // One hop further out: `DEEP → FAR → MID → USD`. Three hops, so no budget reaches it — `DEEP`
        // is the unit that pins the CEILING now that `FAR` resolves.
        deepUnit = _newToken("DEEP", 18);
        _registerDenomination("DEEP", deepUnit);
        _addFeed(deepUnit, farUnit, makeAddr("deepFarAggregator"), 18);

        // A registered label with nothing leaving it, and one with only the inverse edge.
        orphanUnit = _newToken("ORPHAN", 18);
        _registerDenomination("ORPHAN", orphanUnit);
        inverseUnit = _newToken("INVERSE", 18);
        _registerDenomination("INVERSE", inverseUnit);
        _addFeed(USD_UNIT, inverseUnit, makeAddr("usdInverseAggregator"), 8); // WRONG direction on purpose
    }

    // ── level 0: already in US Dollars ─────────────────────────────────────────────

    /// @notice A source already quoting US Dollars resolves to an EMPTY path, so its bridge slot is
    ///         left as the zero address — which the Morpho oracle reads as the price 1.
    /// @dev Zero hops is a SUCCESS, not a miss, and this is where that is pinned. The assertion is on
    ///      the wiring rather than on the add: an add of a `"USD"`-quoted source succeeds either way,
    ///      so only the resolved `feed2` distinguishes "no bridge needed" from "a bridge nobody
    ///      noticed was missing".
    function test_hop_zeroHops_usdSourceLeavesTheBridgeSlotEmpty() public {
        (address ca, address caAgg) = _addPriceAsset("CADOLLAR", "USD");
        (address ref, address refAgg) = _addPriceAsset("REFDOLLAR", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        // REF is the oracle's BASE side and CA is its QUOTE side — orientation is load-bearing.
        assertEq(wrapperFactory.lastBaseFeed1(), refAgg, "base feed1 is the reference asset's aggregator");
        assertEq(wrapperFactory.lastQuoteFeed1(), caAgg, "quote feed1 is the collateral asset's aggregator");
        assertEq(wrapperFactory.lastBaseFeed2(), address(0), "a dollar-quoted leg needs no bridge");
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0), "a dollar-quoted leg needs no bridge");

        // No vault on either leg, so the conversion sample MUST be exactly 1: the Morpho oracle
        // requires it (`VAULT_CONVERSION_SAMPLE_IS_NOT_ONE`).
        assertEq(wrapperFactory.lastBaseVault(), address(0));
        assertEq(wrapperFactory.lastQuoteVault(), address(0));
        assertEq(wrapperFactory.lastBaseSample(), 1);
        assertEq(wrapperFactory.lastQuoteSample(), 1);
    }

    // ── level 1: one direct edge ────────────────────────────────────────────────────

    /// @notice A one-hop feed path: the source aggregator takes `feed1` and the single bridge hop lands
    ///         in `feed2`.
    /// @dev This is the whole of the budget-1 arithmetic made observable. The `"ETH"`-quoted aggregator
    ///      occupies `feed1` itself, so the one remaining slot carries the `ETH → USD` edge.
    function test_hop_oneHopFeedPath_bridgeLandsInFeed2() public {
        (address ca, address caAgg) = _addPriceAsset("CAETHER", "ETH");
        (address ref, address refAgg) = _addPriceAsset("REFDOLLAR2", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertEq(wrapperFactory.lastQuoteFeed1(), caAgg, "the source itself takes feed1");
        assertEq(wrapperFactory.lastQuoteFeed2(), ethUsdAggregator, "the one bridge hop takes feed2");
        assertEq(wrapperFactory.lastBaseFeed1(), refAgg);
        assertEq(wrapperFactory.lastBaseFeed2(), address(0), "the dollar leg still needs no bridge");
    }

    /// @notice A US-Dollar-Coin-denominated asset and a Tether-denominated asset each reach the SAME
    ///         common denomination — US Dollars — through their own conversion feeds.
    /// @dev The point of the hop graph in one test. Neither asset is dollar-quoted (one pins `"USDC"`,
    ///      the other `"USDT"`), yet the oracle's two sides are lifted to a single unit before the ratio
    ///      is taken, and each side is lifted by its OWN edge. Asserting the two `feed2` values are the
    ///      two DIFFERENT bridge aggregators is what proves each leg used its own path rather than one
    ///      leg's bridge being reused for both.
    function test_hop_usdCoinAndTetherAssets_reachACommonDenomination() public {
        (address ca, address caAgg) = _addPriceAsset("CAUSDC", "USDC");
        (address ref, address refAgg) = _addPriceAsset("REFUSDT", "USDT");

        // Each source states its own denomination, so the two assets genuinely start in different units.
        assertEq(_storedDenomination(ca, IMarketRegistry.SourceType.PRICE), "USDC");
        assertEq(_storedDenomination(ref, IMarketRegistry.SourceType.PRICE), "USDT");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertEq(wrapperFactory.lastQuoteFeed1(), caAgg);
        assertEq(wrapperFactory.lastQuoteFeed2(), usdcUsdAgg, "the collateral leg bridges USDC -> USD");
        assertEq(wrapperFactory.lastBaseFeed1(), refAgg);
        assertEq(wrapperFactory.lastBaseFeed2(), usdtUsdAgg, "the reference leg bridges USDT -> USD");
        assertTrue(usdcUsdAgg != usdtUsdAgg, "the two legs must have used different edges");
    }

    // ── level 2: two edges, bridging through Ether ──────────────────────────────────

    /// @notice A two-hop vault path fills BOTH feed slots, nearest-the-asset first, and puts the vault
    ///         in the orthogonal vault slot with a share-scaled conversion sample.
    /// @dev The budget-2 arithmetic made observable. An `ERC4626` source takes the VAULT slot rather
    ///      than a feed slot, so `feed1` and `feed2` are both free for the bridge: `stETH → ETH` in
    ///      `feed1` (nearest the asset) and `ETH → USD` in `feed2`. Order matters — swapping them
    ///      multiplies the wrong two numbers and nothing reverts.
    ///
    ///      The sample is `10 ** shareDecimals` read off the VAULT, not the token. Leaving `1` there is a
    ///      real bug: the vault's integer `convertToAssets(1 wei)` truncates to zero on an offset vault
    ///      and the oracle prices at zero.
    function test_hop_twoHopVaultPath_fillsBothFeedSlotsNearestFirst() public {
        (address ca, address caVault) = _addNavAsset("CASTETH", "stETH", 18);
        (address ref,) = _addPriceAsset("REFDOLLAR3", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV);

        assertEq(wrapperFactory.lastQuoteVault(), caVault, "an ERC4626 source occupies the vault slot");
        assertEq(wrapperFactory.lastQuoteSample(), 10 ** 18, "the sample is 10 ** shareDecimals");
        assertEq(wrapperFactory.lastQuoteFeed1(), stEthEthAgg, "feed1 is the hop nearest the asset");
        assertEq(wrapperFactory.lastQuoteFeed2(), ethUsdAggregator, "feed2 is the dollar bridge");
    }

    /// @notice A vault whose unit reaches US Dollars in ONE hop under-uses its budget of two: the single
    ///         edge lands in `feed1` and `feed2` stays empty.
    /// @dev Under-using the budget is fine and is the commonest real shape (a vault over native
    ///      US-Dollar-Coin). It also pins that the path length drives which slots are filled — the
    ///      budget is a ceiling, not a required length.
    function test_hop_vaultWithOneHopUnit_leavesFeed2Empty() public {
        (address ca, address caVault) = _addNavAsset("CAUSDCVAULT", "USDC", 18);
        (address ref,) = _addPriceAsset("REFDOLLAR4", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV);

        assertEq(wrapperFactory.lastQuoteVault(), caVault);
        assertEq(wrapperFactory.lastQuoteFeed1(), usdcUsdAgg, "the single hop takes feed1 on a vault leg");
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0), "the second slot stays empty");
    }

    /// @notice A dollar-quoted VAULT resolves to zero hops: the vault slot is filled and BOTH feed slots
    ///         stay empty, which the Morpho oracle reads as price 1 on each.
    function test_hop_vaultWithDollarUnit_leavesBothFeedSlotsEmpty() public {
        (address ca, address caVault) = _addNavAsset("CADOLLARVAULT", "USD", 6);
        (address ref,) = _addPriceAsset("REFDOLLAR5", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV);

        assertEq(wrapperFactory.lastQuoteVault(), caVault);
        assertEq(wrapperFactory.lastQuoteSample(), 10 ** 6, "the sample follows the vault's own decimals");
        assertEq(wrapperFactory.lastQuoteFeed1(), address(0));
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0));
    }

    /// @notice A NON-Ether intermediate resolves. `FAR` reaches US Dollars only through the registered
    ///         unit `MID`, and a vault quoting it both ADDS and DEPLOYS, with the two `MID` aggregators
    ///         in `feed1` and `feed2`.
    /// @dev The headline of the widened search, and the case an Ether-only probe cannot serve: `FAR` has
    ///      no `FAR → USD` edge and no `FAR → ETH` edge at all, so the only way to reach US Dollars from
    ///      it is to walk the registered denominations and find `MID`. Asserting the two aggregators
    ///      rather than just the successful add is what proves the path found is the `MID` one and that
    ///      it is wired nearest-the-asset first.
    function test_hop_twoHop_nonEtherIntermediateResolves() public {
        (address ca, address caVault) = _addNavAsset("CAFAR", "FAR", 18);
        (address ref,) = _addPriceAsset("REFDOLLAR8", "USD");

        assertEq(
            _storedDenomination(ca, IMarketRegistry.SourceType.NAV),
            "FAR",
            "the add is accepted at write time, not merely at deploy"
        );

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV);

        assertEq(wrapperFactory.lastQuoteVault(), caVault, "the vault still occupies the orthogonal slot");
        assertEq(wrapperFactory.lastQuoteFeed1(), farMidAgg, "feed1 is FAR -> MID, the hop nearest the asset");
        assertEq(wrapperFactory.lastQuoteFeed2(), midUsdAgg, "feed2 is MID -> USD, the dollar bridge");
    }

    /// @notice REMOVING the denomination a two-hop path bridges through breaks that path, even though
    ///         both conversion-feed edges are still approved.
    /// @dev The candidate list `resolvePath` walks is the DENOMINATION set, not the feed store — so a
    ///      label removal shrinks the search directly. This is the teeth on `removeDenominations`: the
    ///      `FAR → MID` and `MID → USD` edges survive untouched and are simply never tried, because
    ///      nothing names `MID` as a unit any more. The already-stored asset keeps its entry and starts
    ///      failing at `deploy`, exactly as removing an edge does.
    function test_hop_removingTheIntermediateDenominationBreaksTheTwoHopPath() public {
        (address ca,) = _addNavAsset("CAFAR", "FAR", 18);
        (address ref,) = _addPriceAsset("REFDOLLAR8", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV); // proves the path resolves first
        assertEq(wrapperFactory.lastQuoteFeed2(), midUsdAgg, "setup: the MID bridge should be in use");

        // A second FAR-quoted asset, stored while the path still resolves and deliberately NOT deployed
        // yet — `deploy` is idempotent, so an already-deployed pair would short-circuit and prove nothing.
        (address ca2,) = _addNavAsset("CAFAR2", "FAR", 18);

        iReg.removeDenominations(one("MID"));

        // Both conversion-feed edges survive untouched. It is the intermediate LABEL that is gone, and
        // that alone is enough: `resolvePath` walks the denomination set, so `MID` is never tried.
        (bool midUsdStillThere,) = iReg.lookupConversionFeed(midUnit, USD_UNIT);
        assertTrue(midUsdStillThere, "the MID -> USD edge must survive the label removal");
        (bool farMidStillThere,) = iReg.lookupConversionFeed(farUnit, midUnit);
        assertTrue(farMidStillThere, "the FAR -> MID edge must survive the label removal");

        // The stored asset keeps its entry and fails at deploy.
        assertTrue(iReg.isAsset(ca2), "the asset must survive the label removal");
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, farUnit, uint256(2)));
        iReg.deploy(ca2, ref, IMarketRegistry.OracleMode.NAV);

        // And a NEW FAR-quoted asset can no longer be written at all. The two tokens are deployed BEFORE
        // the cheatcode: a contract creation would consume the armed `expectRevert`.
        address token3 = _newToken("CAFAR3", 18);
        address vault3 = _newToken("CAFAR3Vault", 18);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, farUnit, uint256(2)));
        iReg.addAssets(one(mkNavOnlyAsset(token3, "CAFAR3", vault3, "FAR")));
    }

    /// @notice When two registered intermediates both complete a path, the EARLIER-REGISTERED one wins —
    ///         and reversing the registration order reverses the choice.
    /// @dev The tie-break the decision document specifies: "registered denominations are walked in
    ///      registration order and the first complete path wins". Two halves, because one half on its own
    ///      cannot tell registration order apart from anything else that happens to correlate with it.
    ///
    ///      In the first half the intermediates are registered A-then-B and the unit's edges are added
    ///      A-then-B, so A winning is consistent with either rule. In the second half the registration
    ///      order is REVERSED (D before C) while `_observeTwoHopChoice` still adds the edges C-then-D —
    ///      so D winning can only be registration order. It rules out edge-insertion order, and it rules
    ///      out any accident of address ordering, since the token addresses are `CREATE` hashes and carry
    ///      no relationship to either.
    function test_hop_twoHop_registrationOrderDecidesBetweenViableIntermediates() public {
        // ── half 1: registered A, then B ──────────────────────────────────────────
        address unitA = _newToken("INTERA", 18);
        address unitB = _newToken("INTERB", 18);
        address aUsdAgg = makeAddr("interAUsdAggregator");
        address bUsdAgg = makeAddr("interBUsdAggregator");
        _registerDenominationWithUsdFeed("INTERA", unitA, aUsdAgg);
        _registerDenominationWithUsdFeed("INTERB", unitB, bUsdAgg);

        address toAAgg = makeAddr("forkAbToAAggregator");
        address toBAgg = makeAddr("forkAbToBAggregator");
        (address feed1, address feed2) = _observeTwoHopChoice("FORKAB", unitA, toAAgg, unitB, toBAgg);

        assertEq(feed1, toAAgg, "the earlier-registered intermediate wins");
        assertEq(feed2, aUsdAgg, "and feed2 is that same intermediate's own dollar edge");

        // ── half 2: the same shape, registered D BEFORE C ─────────────────────────
        address unitC = _newToken("INTERC", 18);
        address unitD = _newToken("INTERD", 18);
        address cUsdAgg = makeAddr("interCUsdAggregator");
        address dUsdAgg = makeAddr("interDUsdAggregator");
        _registerDenominationWithUsdFeed("INTERD", unitD, dUsdAgg); // registered FIRST
        _registerDenominationWithUsdFeed("INTERC", unitC, cUsdAgg);

        address toCAgg = makeAddr("forkCdToCAggregator");
        address toDAgg = makeAddr("forkCdToDAggregator");
        // Edges are added C first, D second — the opposite of the registration order.
        (address feed1b, address feed2b) = _observeTwoHopChoice("FORKCD", unitC, toCAgg, unitD, toDAgg);

        assertEq(feed1b, toDAgg, "reversing the REGISTRATION order reverses the choice");
        assertEq(feed2b, dUsdAgg, "so the winner is not the first edge added, it is the first label registered");
    }

    /// @notice The US Dollar sentinel is never used as an intermediate. Even with a `USD → USD` edge
    ///         registered, a one-hop unit resolves to ONE hop and its second feed slot stays empty.
    /// @dev `resolvePath` skips `u == USD_DENOMINATION` inside the loop, and this test pins the OUTCOME
    ///      that skip guarantees rather than claiming to isolate the skip itself — which is not
    ///      isolatable, and saying so is more useful than pretending otherwise. A path through the
    ///      terminus would have to start with a `fromUnit → USD` edge, and that edge IS level 1's, so
    ///      level 1 always answers first and the loop never gets the chance. The skip makes the nonsense
    ///      pair `[fromUnit → USD, USD → USD]` unrepresentable instead of merely unreachable, and this
    ///      test is what would catch a future change that reordered the levels and made it reachable.
    ///
    ///      The `USD → USD` self-loop is genuinely addable: both endpoints are non-zero and the key is
    ///      well formed, so nothing in `addConversionFeed` refuses it.
    function test_hop_twoHop_usdSentinelIsNeverAnIntermediate() public {
        address usdSelfAgg = makeAddr("usdSelfLoopAggregator");
        _addFeed(USD_UNIT, USD_UNIT, usdSelfAgg, 8);

        // Budget 2 and a unit — `USDC` — that has a direct dollar edge, so the loop is reachable.
        (address ca, address caVault) = _addNavAsset("CAUSDCSENTINEL", "USDC", 18);
        (address ref,) = _addPriceAsset("REFDOLLAR9", "USD");

        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV);

        assertEq(wrapperFactory.lastQuoteVault(), caVault);
        assertEq(wrapperFactory.lastQuoteFeed1(), usdcUsdAgg, "one hop, answered at level 1");
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0), "the terminus contributes no second hop");
        assertTrue(wrapperFactory.lastQuoteFeed2() != usdSelfAgg, "the self-loop aggregator is never wired");
    }

    /// @notice An edge is never walked BACKWARDS, on the second hop as well as the first. A registered
    ///         intermediate reachable only by inverting an edge does not make a path.
    /// @dev The forward-only rule, stated against the widened search rather than against a unit with no
    ///      edges at all (which is what `test_hop_inverseEdgeIsNotFollowed` covers). `USDC → BACKWARD`
    ///      exists, so `BACKWARD → USDC → USD` is a complete path IF an edge may be traversed against
    ///      its direction — and `USDC` is registered, so the loop really does consider it as a candidate
    ///      and really does reject it. It must: the Morpho oracle multiplies the feeds it is handed and
    ///      cannot invert one, so the inverse has to be approved as its own entry.
    function test_hop_twoHop_backwardEdgeThroughAnIntermediateIsNotFollowed() public {
        address backwardUnit = _newToken("BACKWARD", 18);
        _registerDenomination("BACKWARD", backwardUnit);
        _addFeed(usdcUnit, backwardUnit, makeAddr("usdcBackwardAggregator"), 18); // WRONG direction on purpose

        address token = _newToken("BACKTOKEN", 18);
        address vault = _newToken("BACKVAULT", 18);

        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, backwardUnit, uint256(2))
        );
        iReg.addAssets(one(mkNavOnlyAsset(token, "BACKASSET", vault, "BACKWARD")));
    }

    /// @notice Ether itself cannot use the two-hop level — there is no `ETH → ETH` edge to take — so an
    ///         Ether-quoted source needs the DIRECT `ETH → USD` edge whatever its budget is.
    /// @dev The `u == fromUnit` skip inside `resolvePath`'s loop is what this lands on: Ether is a
    ///      registered label, so it is a candidate intermediate for every other unit, but it may not
    ///      bridge itself. Nothing about this is specific to Ether any more — it is the general
    ///      self-bridge guard, observed on the one unit a fresh registry already has a label for.
    ///      The assertion needs a registry WITHOUT the Ether dollar edge, so it stands up a second one
    ///      rather than trying to remove the edge this fixture's `setUp` depends on.
    function test_hop_etherUnitCannotBridgeThroughItself() public {
        // A LOCAL registry, not `_deployRegistry` — that helper overwrites the fixture's `reg` / `iReg`
        // fields, which would silently re-point every later helper call in the same test.
        MarketRegistry freshReg = new MarketRegistry();
        freshReg.initialize(address(this), address(new MockWrapperFactory()), address(fixedRateOracleFactory));
        IMarketRegistry fresh = IMarketRegistry(address(freshReg));
        address token = _newToken("ETHTOKEN", 18);
        address vault = _newToken("ETHVAULT", 18);

        // `"ETH"` is a seeded LABEL, so this gets past the registration check and fails on the PATH —
        // with the vault's full budget of 2, which is what makes the self-bridge guard visible.
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, ETH_UNIT, uint256(2)));
        fresh.addAssets(one(mkNavOnlyAsset(token, "ETHASSET", vault, "ETH")));
    }

    // ── the budget: 1 for AGGREGATOR_V3, 2 for ERC4626 ──────────────────────────────

    /// @notice The SAME denomination is refused on an `AGGREGATOR_V3` source and accepted on an `ERC4626`
    ///         one. One test, because the pair is the assertion: the budget is 1 and 2 respectively.
    /// @dev This is the third worked example in the decision document. `"stETH"` has no direct dollar
    ///      edge and reaches US Dollars only through Ether, so it needs two hops. An aggregator source
    ///      has already spent `feed1` on itself and has one hop left, so it fails — and the error NAMES
    ///      the budget it exhausted, which is what turns "the budget is 1" from a comment into an
    ///      assertion. A vault source spends the orthogonal vault slot instead, keeps both feed slots,
    ///      and the same unit resolves.
    function test_hop_budgetIsOneForAggregatorAndTwoForVault() public {
        address token = _newToken("BUDGETTOKEN", 18);

        // Budget 1 — the error carries `maxHops == 1`.
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, stEthUnit, uint256(1)));
        iReg.addAssets(one(mkPriceOnlyAsset(token, "BUDGETASSET", makeAddr("stEthPriceAgg"), "stETH")));

        // Budget 2 — the identical unit resolves.
        iReg.addAssets(one(mkNavOnlyAsset(token, "BUDGETASSET", _newToken("BUDGETVAULT", 18), "stETH")));
        assertEq(
            _storedDenomination(token, IMarketRegistry.SourceType.NAV),
            "stETH",
            "the vault's budget of 2 reaches US Dollars"
        );
    }

    /// @notice Three hops is over budget even for a vault: `resolvePath` stops at two and the error
    ///         names the budget of 2.
    /// @dev The ceiling, and it is a real ceiling rather than a limitation of the candidate set. `DEEP`
    ///      is three hops out — `DEEP → FAR → MID → USD` — with every edge present and every
    ///      intermediate registered, so nothing about the search is what refuses it. There is simply no
    ///      third level, because the budget is at most 2 and that is arithmetic from the Morpho oracle's
    ///      slot count. Contrast `test_hop_twoHop_nonEtherIntermediateResolves`, which adds the very next
    ///      unit in this chain and succeeds: the difference between the two is one hop, nothing else.
    function test_hop_exceedingTheBudget_revertsWithANamedSelector() public {
        address token = _newToken("OVERTOKEN", 18);
        address vault = _newToken("OVERVAULT", 18);

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, deepUnit, uint256(2)));
        iReg.addAssets(one(mkNavOnlyAsset(token, "OVERASSET", vault, "DEEP")));
    }

    // ── the failure lands at WRITE time ─────────────────────────────────────────────

    /// @notice A source with no dollar path fails LOUDLY at `addAsset`. Nothing is stored, so `deploy`
    ///         never gets the chance to be the one that discovers it.
    /// @dev The whole point of moving the check earlier (#75). The assertion has three parts and all
    ///      three are needed:
    ///
    ///      1. `addAsset` reverts `NoConversionPathToUsd`, naming the unit and the budget;
    ///      2. nothing was written — the asset is not in the store afterwards;
    ///      3. a later `deploy` for the pair therefore fails `EntryNotFound`, which is a DIFFERENT
    ///         error. If the write had been allowed through, `deploy` would be the first thing to raise
    ///         `NoConversionPathToUsd`, in a different transaction, probably sent by somebody who did
    ///         not make the mistake. Asserting the selector `deploy` raises is what distinguishes
    ///         "rejected at write time" from "rejected eventually".
    function test_hop_unreachableSource_failsAtAddAssetNotAtDeploy() public {
        address token = _newToken("ORPHANTOKEN", 18);
        (address ref,) = _addPriceAsset("REFDOLLAR6", "USD");

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, orphanUnit, uint256(1)));
        iReg.addAssets(one(mkPriceOnlyAsset(token, "ORPHANASSET", makeAddr("orphanAgg"), "ORPHAN")));

        (bool found,) = iReg.lookupAssetByAddress(token);
        assertFalse(found, "an unreachable source must leave nothing in the store");

        // Not `NoConversionPathToUsd`: there is no entry for `deploy` to trip over in the first place.
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        iReg.deploy(token, ref, IMarketRegistry.OracleMode.PRICE);
    }

    /// @notice Only FORWARD edges are followed. A `USD → unit` feed does not bridge `unit`.
    /// @dev Direction is part of the natural key and the Morpho oracle multiplies the feeds it is
    ///      handed — it cannot invert one — so the inverse edge is useless here and is not consulted.
    ///      The `INVERSE` unit has exactly one edge and it points the wrong way, at both budgets.
    function test_hop_inverseEdgeIsNotFollowed() public {
        address token = _newToken("INVTOKEN", 18);
        // Deployed UP FRONT: a `new` between `vm.expectRevert` and the call it guards is itself the
        // "next call" as far as the cheatcode is concerned, and swallows the expectation.
        address vault = _newToken("INVVAULT", 18);

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, inverseUnit, uint256(1)));
        iReg.addAssets(one(mkPriceOnlyAsset(token, "INVASSET", makeAddr("invAgg"), "INVERSE")));

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, inverseUnit, uint256(2)));
        iReg.addAssets(one(mkNavOnlyAsset(token, "INVASSET", vault, "INVERSE")));
    }

    /// @notice The REGISTRATION check runs before the PATH check: an unregistered label reports itself
    ///         as unregistered, not as unreachable.
    /// @dev Ordering matters for the reader of the revert. A typo'd label has no unit to resolve, so
    ///      reporting `NoConversionPathToUsd` for it would name the zero address and send whoever hit it
    ///      looking for a missing conversion feed instead of a missing registration.
    function test_hop_unregisteredLabel_reportsRegistrationNotReachability() public {
        address token = _newToken("TYPOTOKEN", 18);

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, "usdc"));
        iReg.addAssets(one(mkPriceOnlyAsset(token, "TYPOASSET", makeAddr("typoAgg"), "usdc")));
    }

    /// @notice BOTH sources are path-checked, not only the one a future `deploy` might select.
    /// @dev At `addAsset` the registry cannot know which mode a later `deploy` will ask for — the mode
    ///      comes from a recipe named in an order that does not exist yet — so checking only one source
    ///      would admit an asset that is half-usable. Here the price source is fine and the NAV source
    ///      is not, and the add is refused on the NAV source's own budget of 2.
    function test_hop_bothSourcesArePathChecked() public {
        address token = _newToken("HALFTOKEN", 18);
        IMarketRegistry.Asset memory e = mkAsset(
            token,
            "HALFASSET",
            IMarketRegistry.AssetKind.ERC4626,
            mkPriceSource(makeAddr("halfAgg"), "USD"), // reachable in zero hops
            mkNavSource(_newToken("HALFVAULT", 18), "ORPHAN") // unreachable at any budget
        );

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, orphanUnit, uint256(2)));
        iReg.addAssets(one(e));
    }

    /// @notice Removing a load-bearing edge does NOT cascade: the stored asset survives and starts
    ///         failing at `deploy` instead.
    /// @dev The one place where a path failure legitimately surfaces at deploy time, and the contrast
    ///      that makes `test_hop_unreachableSource_failsAtAddAssetNotAtDeploy` meaningful. Write-time
    ///      validation is a gate on the write, not a cache and not a subscription — `_wireLeg` re-runs
    ///      `resolvePath` against the graph as it stands at deploy time. Withdrawing an edge the live
    ///      assets depend on is a governance action with teeth.
    function test_hop_removingAnEdgeBreaksDeployButNotTheStoredAsset() public {
        (address ca,) = _addPriceAsset("CAETHER2", "ETH");
        (address ref,) = _addPriceAsset("REFDOLLAR7", "USD");

        iReg.removeConversionFeeds(one(ETH_UNIT), one(USD_UNIT));

        (bool found,) = iReg.lookupAssetByAddress(ca);
        assertTrue(found, "removal of an edge must not remove the assets that used it");
        assertEq(
            _storedDenomination(ca, IMarketRegistry.SourceType.PRICE),
            "ETH",
            "the stored source denomination is untouched"
        );

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, ETH_UNIT, uint256(1)));
        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);
    }

    // ── internal helpers ────────────────────────────────────────────────────────────

    /// @dev Add a price-source asset denominated in `denomination`, and return `(token, aggregator)`.
    ///      The token is a {MockERC20} because the deploy path re-reads its `decimals()` live. Nothing
    ///      is derived at write time any more — `addAsset` stores the label the source states, verbatim,
    ///      once it has checked that the label is registered and reaches US Dollars in one hop.
    function _addPriceAsset(string memory name, string memory denomination) internal returns (address, address) {
        address token = _newToken(name, 18);
        address aggregator = makeAddr(string.concat(name, "Aggregator"));
        iReg.addAssets(one(mkPriceOnlyAsset(token, name, aggregator, denomination)));
        return (token, aggregator);
    }

    /// @dev Register a fresh unit labelled `tag` with a complete two-hop path through BOTH `interA` and
    ///      `interB`, put a vault asset on it, deploy against a dollar reference, and return the
    ///      `(feed1, feed2)` the registry actually chose. The two candidate edges are added in argument
    ///      order — `interA` first — which is what lets the caller separate "the first edge added" from
    ///      "the first label registered" by varying only the registration order between calls.
    function _observeTwoHopChoice(string memory tag, address interA, address aggA, address interB, address aggB)
        internal
        returns (address feed1, address feed2)
    {
        address unit = _newToken(string.concat(tag, "UNIT"), 18);
        _registerDenomination(tag, unit);
        _addFeed(unit, interA, aggA, 18);
        _addFeed(unit, interB, aggB, 18);

        (address ca,) = _addNavAsset(string.concat("CA", tag), tag, 18);
        (address ref,) = _addPriceAsset(string.concat("REF", tag), "USD");
        iReg.deploy(ca, ref, IMarketRegistry.OracleMode.NAV);

        return (wrapperFactory.lastQuoteFeed1(), wrapperFactory.lastQuoteFeed2());
    }

    /// @dev Add a NAV-source asset denominated in `denomination`, and return `(token, vault)`. The vault
    ///      is a separate {MockERC20} because `_wireLeg` reads SHARE decimals off the source address
    ///      itself to build the conversion sample; `vaultDecimals` is what that sample is `10 **`.
    function _addNavAsset(string memory name, string memory denomination, uint8 vaultDecimals)
        internal
        returns (address, address)
    {
        address token = _newToken(name, 18);
        address vault = _newToken(string.concat(name, "Vault"), vaultDecimals);
        iReg.addAssets(one(mkNavOnlyAsset(token, name, vault, denomination)));
        return (token, vault);
    }
}
