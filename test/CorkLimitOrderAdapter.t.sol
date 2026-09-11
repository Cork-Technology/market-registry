// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IErrors} from "contracts/interfaces/IErrors.sol";
import {IPoolManager, Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {CorkLimitOrderAdapter} from "../src/CorkLimitOrderAdapter.sol";
import {CorkMarketCreator} from "../src/CorkMarketCreator.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {ICorkMarketCreator} from "../src/interfaces/ICorkMarketCreator.sol";
import {IOrderMixin} from "../src/interfaces/I1inchLimitOrderProtocol.sol";
import {IMarketRecipe} from "../src/interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";
import {ApySpreadImpairmentRecipe} from "../src/recipes/ApySpreadImpairmentRecipe.sol";
import {LiquidityPriceRecipe} from "../src/recipes/LiquidityPriceRecipe.sol";
import {FixedRateRecipe} from "../src/recipes/FixedRateRecipe.sol";
import {mkNavOnlyAsset, mkPriceOnlyAsset} from "./helpers/RegistryFixture.sol";
import {
    MockERC20,
    MockJITController,
    MockJITPoolManager,
    MockLimitOrderProtocol,
    MockRateOracle,
    OrderBuilder,
    PermissiveRecipe
} from "./mocks/JITMocks.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @dev The JIT suite runs the REAL `MarketRegistry` (assets, approved recipe, `deploy`), the REAL
///      {LiquidityPriceRecipe}, and the REAL {CorkMarketCreator} the adapter creates its pools
///      through, with the wrapper factory mocked in `Fixed` mode so `deploy` hands back a live
///      {MockRateOracle}. Pool manager, controller, and LOP are mocks (see JITMocks.sol).
///
///      THE CREATION CHECKS ARE THE CREATOR'S NOW, AND THIS SUITE STILL DRIVES THEM THROUGH THE FILL.
///      The adapter hands the payload's market to `CorkMarketCreator.createNewPool` and carries no
///      creation logic of its own, so every "reverts" test below on an asset, recipe, constraint,
///      expiry, fee, or rate expects the creator's selector, and what it proves is that the creator's
///      rejection reaches the fill unchanged. The creator's own suite (`CorkMarketCreator.t.sol`)
///      pins the checks themselves.
///
///      ## What changed in this suite, and why every change was forced
///
///      1. **The payload no longer carries a mode STRING.** The market description carries a `recipe`
///         CONTRACT ADDRESS plus the four rate limits as a `ResolvedConstraint`, derived off-chain.
///         `IMarketRegistry.ConstraintBands` and `registry.applyBands` are both gone; the limits come
///         from {LiquidityPriceRecipe}, whose four numbers are compile-time constants, and {_constraint}
///         restates them so this suite has its own statement of what an honest order carries.
///      2. **Market identity no longer follows the rate.** The constraint is fixed at signing time, so
///         moving the rate no longer moves the pool id. `test_rateMove_derivesNewMarket` asserted the
///         opposite and has been rewritten into its inverse — see
///         {test_rateMove_insideWindow_reusesTheSameMarket}.
///      3. **A stale rate blocks a fill, but ordinary movement does not.** {LiquidityPriceRecipe.verify}
///         requires the LIVE rate to sit inside the carried window — see
///         {test_reverts_whenRateMovesOutsideTheWindow} and its complement
///         {test_rateMovesInsideTheWindow_stillFills}. `RecipeRejectedConstraint` is reachable that way
///         and also by a constraint of the wrong SHAPE, see
///         {test_reverts_whenConstraintDoesNotMatchTheRecipe}.
///      4. **The registry constructor takes a third argument** (the fixed-rate oracle factory). This
///         suite constructs its registry by hand rather than through `RegistryFixture`, because it
///         needs the wrapper factory pinned to a live rate oracle BEFORE any asset is added, so the
///         third argument is supplied here.
///      5. **Assets carry their denomination on the SOURCE.** The US Dollar sentinel is seeded by
///         `initialize` and resolves in zero hops, so `mkPriceOnlyAsset(..., USD_DENOMINATION)` needs
///         no conversion feed.
///      6. **A payload's numbers are now bounded.** The expiry is checked against a governance-set
///         bound on the registry, and only on the fill that CREATES the market; the two fee fields are
///         checked against the creator's constant on EVERY fill, before the pool is even derived. The split is
///         deliberate and the tests that pin it are
///         {test_marketCreatedUnderALooserBound_stillFillsAfterTightening} and
///         {test_reverts_whenFeeIsOutOfRange_beforeThePoolIsDerived} — read those two together before
///         changing where any of these checks live. The fixture's `expiry` sits EXACTLY on the
///         registry's default bound, which is why {test_expiryExactlyAtTheBound_createsTheMarketAndFills}
///         states that out loud instead of leaving it as a coincidence.
///      7. **Fees are market identity.** Phoenix fixes both pool fees at creation and hashes them into
///         the pool id, so the expected market restated by {_expectedMarket} carries them, and
///         {test_differentFee_derivesADifferentPool} pins that an order naming another fee lands in
///         another pool.
contract CorkLimitOrderAdapterTest is Test {
    address internal constant BOND = address(0xB07D);
    address internal constant PREMIUM_TOKEN = address(0xFEE);

    /// @dev The rate the constraint is derived from at signing time, carried in `extraData`. The
    ///      oracle starts here too, so the live rate sits inside the derived window.
    uint256 internal constant ANCHOR_RATE = 1e18;

    /// @dev The rate a fixed-rate ORDER names in `rateOverride`. Deliberately unrelated to
    ///      {ANCHOR_RATE}: a `FIXED` market's rate comes from the order, not from the pair's feed.
    uint256 internal constant FIXED_JIT_RATE = 2.5e18;

    /// @dev The life an impairment order declares in its payload, and the fixture's market life. The
    ///      two are equal on purpose: the impairment band is sized by the declared life, so the honest
    ///      payload declares exactly the life the market has.
    uint256 internal constant IMPAIRMENT_DURATION = 30 days;

    /// @dev Ten percent a year, on the percentage scale (`1e18` = 1%).
    uint256 internal constant IMPAIRMENT_SPREAD = 10e18;

    /// @dev The two pool fees an honest order carries, on the percentage scale (`1e18` = 1%). Both
    ///      are part of the pool id, so they appear in every restated market below.
    uint256 internal constant SWAP_FEE = 3e18;
    uint256 internal constant UNWIND_FEE = 4e18;

    address internal owner;
    MockERC20 internal collateral;
    MockERC20 internal referenceToken;
    /// @dev A reference asset with a NAV source and NO price source, so a NAV recipe can be exercised
    ///      through the registry's real leg selection rather than through a fallback.
    MockERC20 internal navReferenceToken;
    MockRateOracle internal rateOracle;
    MockWrapperFactory internal wrapperFactory;
    MarketRegistry internal registry;
    LiquidityPriceRecipe internal recipe;
    FixedRateRecipe internal fixedRecipe;
    ApySpreadImpairmentRecipe internal impairmentRecipe;
    PermissiveRecipe internal permissiveRecipe;
    MockJITPoolManager internal poolManager;
    MockJITController internal controller;
    MockLimitOrderProtocol internal lop;
    CorkMarketCreator internal creator;
    CorkLimitOrderAdapter internal hook;
    uint256 internal expiry;

    function setUp() public {
        owner = makeAddr("owner");
        collateral = new MockERC20("USDC", 6, false);
        _wire();
    }

    /// @dev Wires the full harness around the current `collateral`: real registry (three assets
    ///      registered: price-only USDC and wstETH plus NAV-only sUSDe; three real recipes approved:
    ///      {LiquidityPriceRecipe}, {FixedRateRecipe} and {ApySpreadImpairmentRecipe}, plus the
    ///      {PermissiveRecipe} test double; fixed wrapper = live mock rate oracle), mock pool manager +
    ///      controller + LOP, the real creator wired to them, the hook wired to the creator, and BOND's
    ///      funding/approval ceremony.
    function _wire() internal {
        referenceToken = new MockERC20("wstETH", 18, false);
        rateOracle = new MockRateOracle(ANCHOR_RATE);

        wrapperFactory = new MockWrapperFactory();
        wrapperFactory.setFixedWrapper(address(rateOracle));
        registry = new MarketRegistry();
        registry.initialize(owner, address(wrapperFactory), address(new FixedRateOracleFactory()));
        recipe = new LiquidityPriceRecipe();
        recipe.initialize(IMarketRegistry(address(registry)));
        fixedRecipe = new FixedRateRecipe();
        fixedRecipe.initialize(IMarketRegistry(address(registry)));
        impairmentRecipe = new ApySpreadImpairmentRecipe();
        impairmentRecipe.initialize(IMarketRegistry(address(registry)));
        navReferenceToken = new MockERC20("sUSDe", 18, false);
        MockERC20 navVault = new MockERC20("sUSDe-vault", 18, false);

        vm.startPrank(owner);
        // The US Dollar sentinel is seeded by `initialize` and reaches US Dollars in zero hops, so no
        // conversion feed is needed for either source.
        address usd = MarketRegistryLib.USD_DENOMINATION;
        registry.addAssets(one(mkPriceOnlyAsset(address(collateral), "USDC", address(0xFEED01), usd)));
        registry.addAssets(one(mkPriceOnlyAsset(address(referenceToken), "wstETH", address(0xFEED02), usd)));
        registry.addRecipes(one(address(recipe)));
        registry.addRecipes(one(address(fixedRecipe)));
        registry.addAssets(one(mkNavOnlyAsset(address(navReferenceToken), "sUSDe", address(navVault), usd)));
        registry.addRecipes(one(address(impairmentRecipe)));
        permissiveRecipe = new PermissiveRecipe();
        registry.addRecipes(one(address(permissiveRecipe)));
        vm.stopPrank();

        poolManager = new MockJITPoolManager();
        controller = new MockJITController(poolManager);
        lop = new MockLimitOrderProtocol();
        creator = new CorkMarketCreator();
        creator.initialize(
            IPoolManager(address(poolManager)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(registry))
        );
        hook = new CorkLimitOrderAdapter();
        hook.initialize(address(lop), IPoolManager(address(poolManager)), ICorkMarketCreator(address(creator)));
        expiry = block.timestamp + 30 days;

        collateral.mint(BOND, 50_000e6);
        // Direct allowance write: a high-level approve() on a no-return-data token reverts at
        // the caller's decode, and _wire runs for both token flavors.
        collateral.setAllowance(BOND, address(hook), type(uint256).max);
    }

    /// @dev The constraint an honest order carries, written out as literals. Its predecessor called
    ///      `MarketRegistryLib.applyBands` with the same four percentages the recipe held, which was
    ///      the right call when those percentages were constructor arguments this file supplied. They
    ///      are the recipe's own constants now, so a re-derivation would silently follow any change to
    ///      them; an independent restatement fails instead, which is the point of a test.
    function _constraint() internal pure returns (IMarketRegistry.ResolvedConstraint memory c) {
        c.rateMin = 1; // one wei, flat, at every anchor
        c.rateMax = 2 * ANCHOR_RATE; // 100% above the anchor
        c.rateChangePerDayMax = ANCHOR_RATE; // 100% of the anchor per day
        c.rateChangeCapacityMax = 3 * ANCHOR_RATE; // 300% accumulated
    }

    /// @dev The fixed-rate payload: the order names the rate, so the constraint comes from the recipe
    ///      reading the oracle that rate derives to. The oracle need not exist yet — `resolve` is asked
    ///      after the fixture deploys it, exactly as an order-building agent would.
    function _fixedParams() internal returns (CorkLimitOrderAdapter.JITMarketParams memory params) {
        address oracle = registry.deployFixedRateOracle(FIXED_JIT_RATE);
        params = _params();
        params.market.recipe = address(fixedRecipe);
        params.market.rateOverride = FIXED_JIT_RATE;
        params.market.constraint = fixedRecipe.resolve(address(collateral), address(referenceToken), oracle, "");
        params.market.extraData = "";
    }

    /// @dev The pool id a fixed-rate payload derives to. Same field order as {_expectedMarket}; only
    ///      the oracle differs, because a `FIXED` market adopts the rate the order named rather than
    ///      the pair's wrapper.
    function _fixedPoolId(CorkLimitOrderAdapter.JITMarketParams memory params, address oracle)
        internal
        view
        returns (MarketId)
    {
        return MarketId.wrap(
            keccak256(
                abi.encode(
                    Market({
                        collateralAsset: address(collateral),
                        referenceAsset: address(referenceToken),
                        expiryTimestamp: expiry,
                        rateMin: params.market.constraint.rateMin,
                        rateMax: params.market.constraint.rateMax,
                        rateChangePerDayMax: params.market.constraint.rateChangePerDayMax,
                        rateChangeCapacityMax: params.market.constraint.rateChangeCapacityMax,
                        rateOracle: oracle,
                        swapFeePercentage: params.market.swapFeePercentage,
                        unwindSwapFeePercentage: params.market.unwindSwapFeePercentage
                    })
                )
            )
        );
    }

    /// @dev The impairment payload: a NAV recipe against the NAV-only reference asset, declaring a
    ///      life of {IMPAIRMENT_DURATION} at {IMPAIRMENT_SPREAD}. The constraint is what `resolve`
    ///      hands back for the carried anchor, which is also the rate the fixture's oracle reports, so
    ///      the live rate sits at the window's midpoint.
    function _impairmentParams() internal view returns (CorkLimitOrderAdapter.JITMarketParams memory params) {
        return _impairmentParams(IMPAIRMENT_DURATION);
    }

    /// @dev Same payload with the declared life chosen by the test.
    function _impairmentParams(uint256 durationSeconds)
        internal
        view
        returns (CorkLimitOrderAdapter.JITMarketParams memory params)
    {
        bytes memory data = abi.encode(ANCHOR_RATE, durationSeconds, IMPAIRMENT_SPREAD);
        params = _params();
        params.market.referenceAsset = address(navReferenceToken);
        params.market.recipe = address(impairmentRecipe);
        params.market.constraint =
            impairmentRecipe.resolve(address(collateral), address(navReferenceToken), address(0), data);
        params.market.extraData = data;
    }

    /// @dev The default payload carries `enableJitMint: true`, so the maker path mints as it did
    ///      before the gate existed. Tests that exercise the gated-off maker path re-encode with
    ///      the flag cleared; the taker path ignores the flag either way. The market sits NESTED
    ///      inside the payload as the creator's own `MarketParams`: what the adapter decodes is
    ///      what it hands the creator, untouched.
    function _params() internal view returns (CorkLimitOrderAdapter.JITMarketParams memory) {
        return CorkLimitOrderAdapter.JITMarketParams({
            market: ICorkMarketCreator.MarketParams({
                collateralAsset: address(collateral),
                referenceAsset: address(referenceToken),
                expiryTimestamp: expiry,
                recipe: address(recipe),
                rateOverride: 0, // a PRICE recipe takes its rate from the pair's wrapper, never from the order
                constraint: _constraint(),
                extraData: abi.encode(ANCHOR_RATE),
                oracleSalt: bytes32(0),
                swapFeePercentage: SWAP_FEE,
                unwindSwapFeePercentage: UNWIND_FEE
            }),
            enableJitMint: true
        });
    }

    /// @dev An empty permit array: no permits carried. The mock cST is a plain MockERC20 with
    ///      no `permit`, so the mock suite always drives the no-permit path; the permit-specific
    ///      test below carries one on purpose.
    function _noPermits() internal pure returns (CorkLimitOrderAdapter.PermitParams[] memory p) {}

    function _extraData() internal view returns (bytes memory) {
        return abi.encode(_params(), _noPermits());
    }

    /// @dev Same payload with the maker-side mint gate set explicitly.
    function _extraData(bool enableJitMint) internal view returns (bytes memory) {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.enableJitMint = enableJitMint;
        return abi.encode(params, _noPermits());
    }

    /// @dev A payload whose recipe accepts anything, so `verify` never rejects and the creator's own
    ///      creation-time checks are what a test reaches. Same constraint and same oracle as the
    ///      {LiquidityPriceRecipe} payload, so it derives the SAME pool id.
    function _permissiveExtraData() internal view returns (bytes memory) {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.recipe = address(permissiveRecipe);
        return abi.encode(params, _noPermits());
    }

    /// @dev The market the hook must assemble: the constraint straight out of the payload (NOT derived
    ///      from the live rate any more), oracle = the fixed wrapper the registry deploys/records, and
    ///      the two fees last, because phoenix hashes them into the id.
    function _expectedMarket() internal view returns (Market memory m) {
        return _expectedMarket(SWAP_FEE, UNWIND_FEE);
    }

    /// @dev Same market with the fees chosen by the test.
    function _expectedMarket(uint256 swapFee, uint256 unwindFee) internal view returns (Market memory m) {
        IMarketRegistry.ResolvedConstraint memory c = _constraint();
        m = Market({
            collateralAsset: address(collateral),
            referenceAsset: address(referenceToken),
            expiryTimestamp: expiry,
            rateMin: c.rateMin,
            rateMax: c.rateMax,
            rateChangePerDayMax: c.rateChangePerDayMax,
            rateChangeCapacityMax: c.rateChangeCapacityMax,
            rateOracle: address(rateOracle),
            swapFeePercentage: swapFee,
            unwindSwapFeePercentage: unwindFee
        });
    }

    function _expectedPoolId() internal view returns (MarketId) {
        return MarketId.wrap(keccak256(abi.encode(_expectedMarket())));
    }

    function _expectedPoolId(uint256 swapFee, uint256 unwindFee) internal view returns (MarketId) {
        return MarketId.wrap(keccak256(abi.encode(_expectedMarket(swapFee, unwindFee))));
    }

    /// @dev ASK shape: BOND is the maker selling cST for the premium token.
    function _askOrder(uint256 cstShares) internal view returns (IOrderMixin.Order memory) {
        return OrderBuilder.build(BOND, address(poolManager.cst()), PREMIUM_TOKEN, cstShares, 0);
    }

    /// @dev BID shape (someone else's buy order): BOND is the taker delivering cST.
    function _bidOrder(uint256 cstShares) internal view returns (IOrderMixin.Order memory) {
        return OrderBuilder.build(address(0xA11CE), PREMIUM_TOKEN, address(poolManager.cst()), 0, cstShares);
    }

    // -- Authorization ------------------------------------------------------------------------

    function test_reverts_whenCallerIsNotLop() public {
        IOrderMixin.Order memory order = _askOrder(20_000e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(CorkLimitOrderAdapter.OnlyLimitOrderProtocol.selector);
        hook.preInteraction(order, "", bytes32(0), address(0), 20_000e18, 0, 0, extraData);
    }

    function test_constructor_zeroAddressReverts() public {
        IPoolManager pm = IPoolManager(address(poolManager));
        ICorkMarketCreator mc = ICorkMarketCreator(address(creator));
        CorkLimitOrderAdapter fresh = new CorkLimitOrderAdapter();
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(0), pm, mc);
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(lop), IPoolManager(address(0)), mc);
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(lop), pm, ICorkMarketCreator(address(0)));
    }

    // -- The creator is the creation path ------------------------------------------------------

    /// @dev THE POINT OF THE REFACTOR, PINNED. The adapter hands the creator the payload's market
    ///      exactly as the maker signed it — the nested struct, verbatim, no field copied or
    ///      re-assembled on the way — once per fill, on both hooks. A copy would be a second place
    ///      where a field could go missing or get reordered, and the whole reason the creator exists
    ///      is that there is ONE such place.
    function test_fill_handsTheCarriedMarketToTheCreatorVerbatim() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.oracleSalt = keccak256("maker-chosen entropy");
        params.market.extraData = abi.encode(ANCHOR_RATE);
        bytes memory expectedCall = abi.encodeCall(ICorkMarketCreator.createNewPool, (params.market));

        vm.expectCall(address(creator), expectedCall, 2);
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(params, _noPermits()));
        lop.callTakerInteraction(hook, _bidOrder(500e18), BOND, 0, 500e18, abi.encode(params, _noPermits()));

        assertEq(controller.createCalls(), 1, "the pool was created through the creator, once");
        assertEq(poolManager.cst().balanceOf(BOND), 1_500e18, "both fills minted into it");
        _assertNoCustody();
    }

    /// @dev A pool created AHEAD of the fill through the creator directly is the pool the fill
    ///      finds: no second creation, the mint lands in it. The mirror of this test lives in the
    ///      creator's suite; this side says the adapter has no creation path of its own to fall
    ///      back on.
    function test_poolCreatedThroughTheCreatorDirectly_isThePoolTheFillFinds() public {
        (MarketId poolId,,) = creator.createNewPool(_params().market);
        assertEq(
            MarketId.unwrap(poolId), MarketId.unwrap(_expectedPoolId()), "the direct call derived the fixture's pool"
        );
        assertEq(controller.createCalls(), 1, "created directly");

        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, _extraData());

        assertEq(controller.createCalls(), 1, "the fill found the pool and created nothing");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertEq(poolManager.cst().balanceOf(BOND), 1_000e18, "the fill minted into it");
        _assertNoCustody();
    }

    // -- Maker path (preInteraction, ASK): JIT creation + JIT mint ------------------------------

    function test_preInteraction_createsMarketAndMintsToMaker() public {
        uint256 cstShares = 20_000e18;
        uint256 expectedCollateral = 20_000e6; // ceil(20_000e18 * 1e6 / 1e18)
        MarketId expectedId = _expectedPoolId();

        vm.expectEmit(true, true, true, true, address(creator));
        emit ICorkMarketCreator.MarketCreated(
            expectedId,
            address(rateOracle),
            address(collateral),
            address(referenceToken),
            expiry,
            address(recipe),
            SWAP_FEE,
            UNWIND_FEE,
            address(hook)
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit CorkLimitOrderAdapter.JITMinted(expectedId, BOND, cstShares, expectedCollateral);
        // Built through the adapter's own encoder, so the hook is proven to accept what the
        // helper produces. Most other tests keep raw `abi.encode`; both must agree.
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, hook.encodeExtraData(_params(), _noPermits()));

        // The pool was created through the controller with the carried constraints, each fee in
        // its own slot of the market struct, and the whitelist disabled.
        assertEq(controller.createCalls(), 1, "one pool creation");
        assertEq(controller.lastSwapFeePercentage(), SWAP_FEE, "swap fee slot");
        assertEq(controller.lastUnwindSwapFeePercentage(), UNWIND_FEE, "unwind fee slot");
        assertEq(controller.lastIsWhitelistEnabled(), false, "whitelist must be disabled");

        Market memory created = poolManager.market(expectedId);
        Market memory expected = _expectedMarket();
        assertEq(created.rateMin, expected.rateMin, "floor: one wei");
        assertEq(created.rateMax, expected.rateMax, "ceiling: twice the anchor");
        assertEq(created.rateOracle, address(rateOracle), "pool adopts the registry wrapper");

        // The registry recorded the pair's PRICE-mode wrapper (idempotent from now on). The mode
        // argument is required: one pair can hold a NAV wrapper and a price wrapper at once.
        assertEq(
            registry.lookupWrapper(address(collateral), address(referenceToken), IMarketRegistry.OracleMode.PRICE),
            address(rateOracle)
        );

        assertEq(poolManager.cst().balanceOf(BOND), cstShares, "maker must hold the fresh cST");
        assertEq(poolManager.cpt().balanceOf(BOND), cstShares, "maker must hold the cPT leg");
        assertEq(collateral.balanceOf(BOND), 50_000e6 - expectedCollateral, "maker pays the collateral");
        _assertNoCustody();
    }

    function test_secondFill_reusesExistingMarket() public {
        lop.callPreInteraction(hook, _askOrder(10_000e18), 10_000e18, 0, _extraData());
        lop.callPreInteraction(hook, _askOrder(10_000e18), 10_000e18, 0, _extraData());

        assertEq(controller.createCalls(), 1, "second fill must not re-create the pool");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertEq(poolManager.cst().balanceOf(BOND), 20_000e18, "both fills minted");
        assertEq(collateral.balanceOf(BOND), 50_000e6 - 20_000e6, "both fills paid");
        _assertNoCustody();
    }

    /// @dev REPLACES `test_rateMove_derivesNewMarket`, which asserted that market identity FOLLOWED the
    ///      rate. It no longer does, and closing that was the point of the payload change: the four
    ///      constraint fields are derived off-chain and carried in the order, so the pool id — and with
    ///      it the `CREATE2`-predicted cST/cPT addresses every resting order was signed against — is
    ///      fixed the moment the order is signed. Asserting the old behaviour would now be asserting a
    ///      bug, so this asserts its inverse: a rate move the approved bands still admit changes
    ///      nothing about the market.
    function test_rateMove_insideWindow_reusesTheSameMarket() public {
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _extraData());
        MarketId firstId = _expectedPoolId();

        // Still inside [rateMin, rateMax] = [1, 2e18].
        rateOracle.setRate(1.05e18);
        assertEq(
            MarketId.unwrap(_expectedPoolId()), MarketId.unwrap(firstId), "the pool id must NOT move with the rate"
        );

        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _extraData());
        assertEq(controller.createCalls(), 1, "a moved rate must not create a second pool");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "both fills minted into the same pool");
        _assertNoCustody();
    }

    // -- Taker path (takerInteraction, lifting a BID) -------------------------------------------

    function test_takerInteraction_createsMarketAndMintsToTaker() public {
        uint256 cstShares = 7_500e18;
        uint256 expectedCollateral = 7_500e6;

        // Same as the maker test: payload built by the adapter's encoder, not raw `abi.encode`.
        lop.callTakerInteraction(
            hook, _bidOrder(cstShares), BOND, 0, cstShares, hook.encodeExtraData(_params(), _noPermits())
        );

        assertEq(controller.createCalls(), 1, "taker path creates the pool too");
        assertEq(poolManager.cst().balanceOf(BOND), cstShares, "taker must hold the fresh cST");
        assertEq(poolManager.cpt().balanceOf(BOND), cstShares, "taker must hold the cPT leg");
        assertEq(collateral.balanceOf(BOND), 50_000e6 - expectedCollateral, "taker pays the collateral");
        _assertNoCustody();
    }

    // -- The JIT-mint gate ----------------------------------------------------------------------

    /// @dev Gated off, the maker path is a pure market-creation hook: the pool comes into
    ///      existence, but no collateral is pulled and nothing is minted.
    function test_preInteraction_gatedOff_createsMarketWithoutMinting() public {
        uint256 cstShares = 20_000e18;
        MarketId expectedId = _expectedPoolId();

        vm.expectEmit(true, true, true, true, address(creator));
        emit ICorkMarketCreator.MarketCreated(
            expectedId,
            address(rateOracle),
            address(collateral),
            address(referenceToken),
            expiry,
            address(recipe),
            SWAP_FEE,
            UNWIND_FEE,
            address(hook)
        );
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, _extraData(false));

        assertEq(controller.createCalls(), 1, "market creation is not gated");
        assertEq(poolManager.market(expectedId).collateralAsset, address(collateral), "pool exists");

        assertEq(poolManager.cst().balanceOf(BOND), 0, "gated off: nothing minted");
        assertEq(poolManager.cpt().balanceOf(BOND), 0, "gated off: no cPT leg either");
        assertEq(collateral.balanceOf(BOND), 50_000e6, "gated off: no collateral pulled");
        _assertNoCustody();
    }

    /// @dev A maker that gated the mint off for the creating fill can still mint on a later one:
    ///      the second fill reuses the pool the first created.
    function test_preInteraction_gatedOff_thenOn_mintsIntoTheExistingPool() public {
        lop.callPreInteraction(hook, _askOrder(10_000e18), 10_000e18, 0, _extraData(false));
        lop.callPreInteraction(hook, _askOrder(10_000e18), 10_000e18, 0, _extraData(true));

        assertEq(controller.createCalls(), 1, "the second fill reuses the first fill's pool");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "only the ungated fill minted");
        assertEq(collateral.balanceOf(BOND), 50_000e6 - 10_000e6, "only the ungated fill paid");
        _assertNoCustody();
    }

    /// @dev The order/market identity guard is not part of the mint, so it still fires when the
    ///      mint is gated off — a gated fill cannot be used to create a pool the signed order
    ///      has nothing to do with.
    function test_preInteraction_gatedOff_stillEnforcesOrderNotForPool() public {
        IOrderMixin.Order memory foreign = OrderBuilder.build(BOND, address(0xDEAD), address(0xBEEF), 1e18, 1e18);
        bytes memory extraData = _extraData(false);
        vm.expectRevert(CorkLimitOrderAdapter.OrderNotForPool.selector);
        lop.callPreInteraction(hook, foreign, 1e18, 1e18, extraData);
    }

    /// @dev The gate is maker-side only. A taker attaching this hook is asking for the mint, so
    ///      the flag is ignored — `false` here must still mint.
    function test_takerInteraction_ignoresGate_andMintsAnyway() public {
        uint256 cstShares = 7_500e18;
        uint256 expectedCollateral = 7_500e6;

        lop.callTakerInteraction(hook, _bidOrder(cstShares), BOND, 0, cstShares, _extraData(false));

        assertEq(controller.createCalls(), 1, "taker path creates the pool too");
        assertEq(poolManager.cst().balanceOf(BOND), cstShares, "taker mints despite the cleared flag");
        assertEq(collateral.balanceOf(BOND), 50_000e6 - expectedCollateral, "taker pays the collateral");
        _assertNoCustody();
    }

    // -- Guards ---------------------------------------------------------------------------------

    function test_reverts_orderNotForPool() public {
        IOrderMixin.Order memory foreign = OrderBuilder.build(BOND, address(0xDEAD), address(0xBEEF), 1e18, 1e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(CorkLimitOrderAdapter.OrderNotForPool.selector);
        lop.callPreInteraction(hook, foreign, 1e18, 1e18, extraData);
    }

    function test_reverts_whenAssetNotRegistered() public {
        MockERC20 rogue = new MockERC20("ROGUE", 18, false);
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.collateralAsset = address(rogue);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev REPLACES `test_reverts_whenModeUnknown`. A policy is named by a recipe CONTRACT ADDRESS now
    ///      rather than by a mode string, so "the order names a policy the registry does not know" is
    ///      step 1 of the four-step sequence failing: `isRecipe` returns false and the creator reverts
    ///      `RecipeNotRegistered(recipe)`, which the fill passes on unchanged. `address(0)` is not exempt — see
    ///      {test_reverts_whenRecipeIsZero}, which lands on this same check.
    ///
    ///      The rogue carries the IDENTICAL policy to the approved one, since a `LiquidityPriceRecipe`'s
    ///      limits are constants. Membership is by ADDRESS, so that changes nothing: an unapproved
    ///      address is refused however familiar its numbers look.
    function test_reverts_whenRecipeNotRegistered() public {
        LiquidityPriceRecipe rogue = new LiquidityPriceRecipe();
        rogue.initialize(IMarketRegistry(address(registry)));
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.recipe = address(rogue);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.RecipeNotRegistered.selector, address(rogue)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The carried constraint is not one this recipe would ever have produced from the anchor it
    ///      declares, so `verify` returns false and the creator names the rejection, through the fill. This is now the
    ///      ONLY way to reach `RecipeRejectedConstraint` through {LiquidityPriceRecipe} — a stale rate no
    ///      longer does it, see {test_rateFarOutsideTheWindow_stillFills}.
    function test_reverts_whenConstraintDoesNotMatchTheRecipe() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.constraint.rateMax += 1; // one wei off the shape the recipe produces
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.RecipeRejectedConstraint.selector, address(recipe)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The staleness check, asserted at the ADAPTER level because it is only visible end to end.
    ///      {LiquidityPriceRecipe.verify} requires the LIVE rate to sit inside the carried window, so a rate
    ///      that has left the window since signing stops the fill at step 4.
    ///
    ///      What the check is really preventing: the pool's window would top out at `2e18` while the
    ///      oracle reports `5e18`, so `ConstraintRateAdapter._calculate` would clamp and the pool would
    ///      price at its own pinned ceiling rather than at the market, permanently.
    function test_reverts_whenRateMovesOutsideTheWindow() public {
        rateOracle.setRate(5 * ANCHOR_RATE); // far above the 2e18 ceiling the anchor derives

        IOrderMixin.Order memory order = _askOrder(1_000e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.RecipeRejectedConstraint.selector, address(recipe)));
        lop.callPreInteraction(hook, order, 1_000e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "a stale constraint must not create a pool");
    }

    /// @dev The complement: a rate that MOVED but is still inside the carried window fills normally.
    ///      Without this, the test above would pass just as well against a recipe that rejected every
    ///      rate change, and the point is that the constraint is fixed at signing time and survives
    ///      ordinary movement.
    function test_rateMovesInsideTheWindow_stillFills() public {
        rateOracle.setRate(15 * ANCHOR_RATE / 10); // 1.5e18: moved, still under the 2e18 ceiling

        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, _extraData());

        assertEq(controller.createCalls(), 1, "movement inside the window does not block creation");
        assertEq(poolManager.market(_expectedPoolId()).rateMax, 2 * ANCHOR_RATE, "the pool took the carried ceiling");
        assertEq(poolManager.cst().balanceOf(BOND), 1_000e18, "and the mint went through");
        _assertNoCustody();
    }

    /// @dev There is no unverified path. An order that names no recipe is not a special case — it
    ///      fails the same membership check as any other unregistered address, because `addRecipe`
    ///      refuses to store `address(0)` in the first place.
    function test_reverts_whenRecipeIsZero() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.recipe = address(0);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.RecipeNotRegistered.selector, address(0)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev REPLACES `test_reverts_whenRateIsZero`. `RateUnavailable` is still the selector, but the
    ///      reason narrowed: it no longer guards constraint derivation (there is none on-chain), it
    ///      guards CREATION — a pool is permanent and creating one around an oracle reporting nothing
    ///      bakes in a dead rate source.
    ///
    ///      Driven through {PermissiveRecipe}, because it has to be: {LiquidityPriceRecipe.verify} reads the
    ///      live rate and a zero rate is outside every window it can produce, so step 4 rejects the
    ///      order before the creator's own guard is reached. See
    ///      {test_reverts_whenRateIsZero_theRecipeRejectsItFirst}, which pins that ordering. A recipe
    ///      with no opinion about the live rate is the only way to reach this check.
    function test_reverts_whenRateIsZeroAtCreation() public {
        rateOracle.setRate(0);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _permissiveExtraData();
        vm.expectRevert(ICorkMarketCreator.RateUnavailable.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The ordering the test above depends on, asserted rather than assumed. Through the REAL
    ///      recipe a zero rate never reaches the creator's `RateUnavailable` guard: `verify` runs first
    ///      and a rate of zero is outside `[rateMin, rateMax]` for every window {LiquidityPriceRecipe}
    ///      produces, since its floor is one wei. So the rejection carries the recipe's selector.
    function test_reverts_whenRateIsZero_theRecipeRejectsItFirst() public {
        rateOracle.setRate(0);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.RecipeRejectedConstraint.selector, address(recipe)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The complement of the test above, and the behaviour the creator documents explicitly: the
    ///      rate is read on the CREATION branch only. A fill into a pool that already exists never
    ///      touches the oracle, so a rate that has since gone to zero cannot fail it.
    function test_rateIsNotReadWhenTheMarketAlreadyExists() public {
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _permissiveExtraData());
        assertEq(controller.createCalls(), 1, "first fill created the pool");

        rateOracle.setRate(0);
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _permissiveExtraData());

        assertEq(controller.createCalls(), 1, "no second pool");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "the second fill minted with a dead oracle");
        _assertNoCustody();
    }

    // -- The fixed-rate path (`rateOverride`) ---------------------------------------------------

    /// @notice The whole point of `rateOverride`: a `FIXED` recipe's market takes its rate from the
    ///         ORDER, and the registry turns that number into a real, permanently immutable
    ///         `FixedRateOracle` before the pool is created. The predecessor could not get here at all
    ///         — a `FIXED` recipe deployed no oracle, so the creation was refused outright.
    function test_fixedRecipe_rateOverride_deploysTheOracleAndCreatesTheMarket() public {
        uint256 cstShares = 1_000e18;
        address oracle = registry.predictFixedRateOracle(FIXED_JIT_RATE);
        assertEq(oracle.code.length, 0, "precondition: the oracle does not exist yet");

        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        MarketId expectedId = _fixedPoolId(params, oracle);

        vm.expectEmit(true, true, true, true, address(creator));
        emit ICorkMarketCreator.MarketCreated(
            expectedId,
            oracle,
            address(collateral),
            address(referenceToken),
            expiry,
            address(fixedRecipe),
            SWAP_FEE,
            UNWIND_FEE,
            address(hook)
        );
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, abi.encode(params, _noPermits()));

        assertGt(oracle.code.length, 0, "the fill deployed the oracle the order named");
        assertEq(controller.createCalls(), 1, "one pool creation");
        assertEq(poolManager.market(expectedId).rateOracle, oracle, "the pool adopted the fixed-rate oracle");
        assertEq(poolManager.cst().balanceOf(BOND), cstShares, "and the maker's mint went through");
    }

    /// @notice The oracle is keyed by the rate, so a second order at the same rate re-uses it. Nothing
    ///         is redeployed and nothing about the market moves.
    function test_fixedRecipe_secondFillAtTheSameRate_reusesTheOracleAndTheMarket() public {
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(_fixedParams(), _noPermits()));
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(_fixedParams(), _noPermits()));

        assertEq(controller.createCalls(), 1, "no second pool");
        assertEq(poolManager.cst().balanceOf(BOND), 2_000e18, "both fills minted");
    }

    /// @notice A `rateOverride` a recipe does not read is REJECTED, not ignored. A `PRICE` market's
    ///         rate is a fact about the pair, so a number in the payload claiming to have chosen it
    ///         would be false provenance in a signed order.
    function test_reverts_whenRateOverrideIsCarriedByANonFixedRecipe() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.rateOverride = FIXED_JIT_RATE;
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());

        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.UnexpectedRateOverride.selector, address(recipe)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @notice A `FIXED` recipe with no rate named. There is no oracle to deploy for rate zero and no
    ///         other place the rate could come from, so the failure lands in `FixedRateOracle`'s own
    ///         constructor with its own selector rather than as a bare revert further down.
    function test_reverts_whenFixedRecipeCarriesNoRate() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        params.market.rateOverride = 0;
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());

        vm.expectRevert(IRateOracle.InvalidRate.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    // -- The asset gate on the fixed-rate path ----------------------------------------------------
    //
    // The price and net-asset-value paths go through `MarketRegistry.deploy`, which refuses any token
    // the registry has not approved. The fixed-rate path never hands the pair to the registry, so the
    // creator gates both assets itself, in `_ensureMarket`, before the recipe is even looked up. Each
    // "reverts" test below created a pool (or got as far as the mint) before that gate existed.

    /// @dev A rogue collateral asset through the FIXED recipe on the maker path. Before the gate this
    ///      got past `createNewPool` and only died inside the mint.
    function test_reverts_whenCollateralNotRegistered_onTheFixedPath() public {
        MockERC20 rogue = new MockERC20("ROGUE", 18, false);
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        params.market.collateralAsset = address(rogue);

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool over an unregistered collateral asset");
    }

    /// @dev A rogue reference asset through the FIXED recipe. Before the gate this CREATED the pool:
    ///      the reference asset is never touched by the mint, so nothing downstream noticed.
    function test_reverts_whenReferenceNotRegistered_onTheFixedPath() public {
        MockERC20 rogue = new MockERC20("ROGUE", 18, false);
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        params.market.referenceAsset = address(rogue);

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool over an unregistered reference asset");
    }

    /// @dev The same gate on the taker path. Both hooks call the creator, and this says so.
    function test_reverts_whenCollateralNotRegistered_onTheFixedPath_takerSide() public {
        MockERC20 rogue = new MockERC20("ROGUE", 18, false);
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        params.market.collateralAsset = address(rogue);

        IOrderMixin.Order memory order = _bidOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callTakerInteraction(hook, order, BOND, 0, 1e18, extraData);

        assertEq(controller.createCalls(), 0, "no pool over an unregistered collateral asset");
    }

    /// @dev The gate sits ahead of the recipe lookup. An order wrong in both ways reports the PAIR,
    ///      so the check cannot depend on which recipe branch would have been taken.
    function test_assetGateFiresBeforeTheRecipeMembershipCheck() public {
        MockERC20 rogueCa = new MockERC20("ROGUE-CA", 18, false);
        MockERC20 rogueRef = new MockERC20("ROGUE-REF", 18, false);
        FixedRateRecipe rogueRecipe = new FixedRateRecipe();
        rogueRecipe.initialize(IMarketRegistry(address(registry)));

        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        params.market.collateralAsset = address(rogueCa);
        params.market.referenceAsset = address(rogueRef);
        params.market.recipe = address(rogueRecipe);

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev Delisting has teeth on the fixed path now. Before the gate, `removeAssets` was inert here:
    ///      new fixed-rate markets kept forming on a delisted asset.
    function test_reverts_whenAssetDelisted_onTheFixedPath() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        vm.prank(owner);
        registry.removeAssets(one(address(referenceToken)));

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "a delisted asset must not gain new fixed-rate markets");
    }

    /// @dev Control for the gate: an honest FIXED-recipe fill over two registered assets still creates
    ///      its pool and mints, on both hooks. Guards against over-tightening.
    function test_fixedRecipe_registeredPair_stillCreatesThePool_control() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        address oracle = registry.predictFixedRateOracle(FIXED_JIT_RATE);
        MarketId expectedId = _fixedPoolId(params, oracle);

        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(params, _noPermits()));
        assertEq(controller.createCalls(), 1, "the honest maker-side fill created the pool");
        assertEq(poolManager.market(expectedId).rateOracle, oracle, "over the registered pair");

        lop.callTakerInteraction(hook, _bidOrder(500e18), BOND, 0, 500e18, abi.encode(params, _noPermits()));
        assertEq(controller.createCalls(), 1, "the honest taker-side fill reused it");
        assertEq(poolManager.cst().balanceOf(BOND), 1_500e18, "both fills minted");
        _assertNoCustody();
    }

    function test_reverts_whenMintPaused() public {
        poolManager.setPaused(true);
        // Build args BEFORE arming expectRevert: _askOrder does an external cst() staticcall.
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(CorkLimitOrderAdapter.MintUnavailable.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    function test_reverts_onMintAmountDrift() public {
        poolManager.setDriftBps(100); // mint tries to spend 1% more than previewMint quoted
        IOrderMixin.Order memory order = _askOrder(20_000e18);
        bytes memory extraData = _extraData();
        // The exact-allowance pull fails first inside the pool manager's collateral pull; drift
        // can never spend extra.
        vm.expectRevert(bytes("MockJITPoolManager: pull failed"));
        lop.callPreInteraction(hook, order, 20_000e18, 0, extraData);
    }

    // -- Creation bound: the maximum market life ------------------------------------------------

    /// @dev The fixture's expiry sits EXACTLY on the registry's starting bound, and this test says so
    ///      out loud rather than relying on it. Every other test in this suite fills at that expiry, so
    ///      a change to either number would quietly move the whole suite off the boundary with nothing
    ///      failing — the case most worth covering is the one an accident walks away from in silence.
    function test_expiryExactlyAtTheBound_createsTheMarketAndFills() public {
        assertEq(registry.maxExpiryDuration(), 30 days, "the registry's starting maximum market life");
        assertEq(expiry, block.timestamp + registry.maxExpiryDuration(), "the fixture must sit ON the bound");

        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, _extraData());

        assertEq(controller.createCalls(), 1, "the longest permitted market must be creatable");
        assertEq(poolManager.market(_expectedPoolId()).expiryTimestamp, expiry, "the pool took the carried expiry");
        assertEq(poolManager.cst().balanceOf(BOND), 1_000e18, "and the mint went through");
        _assertNoCustody();
    }

    /// @dev One second past the bound. The revert names both numbers, so an order-building agent learns
    ///      what it may ask for and not merely that it asked wrong.
    function test_reverts_whenExpiryIsOneSecondPastTheBound() public {
        uint256 maxExpiry = block.timestamp + registry.maxExpiryDuration();
        expiry = maxExpiry + 1;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.ExpiryOutOfRange.selector, expiry, maxExpiry));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev THE JULY 28 INCIDENT, AS A TEST. `1785000000000` is an ordinary expiry expressed in
    ///      MILLISECONDS instead of seconds — the shape an off-chain layer hands over when nobody
    ///      divided by a thousand. It used to go straight through, because nothing anywhere looked at
    ///      how LARGE the number was: phoenix only asks that the expiry be in the future, and a
    ///      millisecond timestamp is very comfortably in the future. The result was a permanent market
    ///      expiring in the year 58527, for about twenty cents, with nothing able to retire it.
    function test_reverts_whenExpiryIsInMilliseconds() public {
        uint256 maxExpiry = block.timestamp + registry.maxExpiryDuration();
        expiry = 1785000000000;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.ExpiryOutOfRange.selector, expiry, maxExpiry));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "the incident payload must create nothing");
    }

    /// @dev The bound is read from the registry on every creating fill, not baked into the creator at
    ///      deployment. Once the curator shortens the maximum market life, an expiry that was perfectly
    ///      fine a block ago is refused.
    function test_reverts_whenOwnerTightensTheBoundBelowTheOrdersExpiry() public {
        vm.prank(owner);
        registry.setMaxExpiryDuration(7 days);

        uint256 maxExpiry = block.timestamp + 7 days;
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData(); // still the fixture's 30-day expiry
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.ExpiryOutOfRange.selector, expiry, maxExpiry));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev The other direction, and the reason the bound is governance-set rather than a constant:
    ///      longer-dated coverage becomes signable the moment the curator allows it, with no adapter
    ///      redeployment involved.
    function test_ownerLoosensTheBound_longerDatedMarketBecomesCreatable() public {
        expiry = block.timestamp + 90 days;

        vm.prank(owner);
        registry.setMaxExpiryDuration(365 days);

        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, _extraData());

        assertEq(controller.createCalls(), 1, "the loosened bound admits the longer-dated market");
        assertEq(poolManager.market(_expectedPoolId()).expiryTimestamp, expiry, "the pool took the 90-day expiry");
        _assertNoCustody();
    }

    /// @dev THE REASON THE EXPIRY BOUND SITS ON THE CREATION BRANCH ALONE. A market is permanent, so a
    ///      later tightening cannot un-create one that already exists — re-checking on every fill would
    ///      achieve nothing except stranding the honest orders already resting against it. So a market
    ///      created while a looser bound was in force keeps filling afterwards, and keeps filling into
    ///      the SAME pool rather than trying to make a new one. The rule lives in the creator now; this
    ///      test says the fill inherits it.
    function test_marketCreatedUnderALooserBound_stillFillsAfterTightening() public {
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _extraData());
        assertEq(controller.createCalls(), 1, "the first fill created the pool");

        vm.prank(owner);
        registry.setMaxExpiryDuration(1 days);

        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _extraData());

        assertEq(controller.createCalls(), 1, "the tightened bound must not re-create the pool");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "both fills minted into it");
        assertEq(collateral.balanceOf(BOND), 50_000e6 - 10_000e6, "both fills paid");
        _assertNoCustody();
    }

    /// @dev THE SAME GRANDFATHERING RULE, SEEN THROUGH A RECIPE. The impairment recipe carries the
    ///      market's life in its payload and used to re-check it against the registry bound inside
    ///      `verify`, on every fill. That contradicted the creation-only rule the creator enforces
    ///      above: tightening the bound stranded every resting impairment order at once, permanently,
    ///      because the constraint is part of the pool id and cannot be re-signed under the new bound
    ///      without naming a different market. Now the recipe applies the bound in `resolve` only.
    function test_impairmentMarketCreatedUnderALooserBound_stillFillsAfterTightening() public {
        assertEq(registry.maxExpiryDuration(), IMPAIRMENT_DURATION, "fixture precondition: the life sits on the bound");
        bytes memory extraData = abi.encode(_impairmentParams(), _noPermits());

        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, extraData);
        assertEq(controller.createCalls(), 1, "the first fill created the pool");

        vm.prank(owner);
        registry.setMaxExpiryDuration(1 days);

        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, extraData);

        assertEq(controller.createCalls(), 1, "the tightened bound must not re-create the pool");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "both fills minted into it");
        _assertNoCustody();
    }

    /// @dev Control for the test above: the impairment payload is a real NAV-recipe fill, created
    ///      through the registry's NAV leg selection, not a payload the creator waves through.
    function test_impairmentPayload_createsANavMarketAndFills() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _impairmentParams();
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(params, _noPermits()));

        assertEq(controller.createCalls(), 1, "one pool creation");
        assertEq(
            registry.lookupWrapper(address(collateral), address(navReferenceToken), IMarketRegistry.OracleMode.NAV),
            address(rateOracle),
            "the registry recorded the pair's NAV wrapper"
        );
        assertEq(poolManager.cst().balanceOf(BOND), 1_000e18, "the maker holds the fresh cST");
        _assertNoCustody();
    }

    /// @dev THE BAND IS BOUND TO THE MARKET'S LIFE, through the fill. The impairment payload
    ///      declares a 30-day life, which sizes its band; the market it names lives one hour. On the
    ///      creating fill the creator hands the recipe the expiry, and the recipe refuses the claim.
    ///      Nothing is created.
    function test_reverts_whenImpairmentDeclaredLifeOutlivesTheMarket() public {
        expiry = block.timestamp + 1 hours;
        bytes memory extraData = abi.encode(_impairmentParams(), _noPermits());

        IOrderMixin.Order memory order = _askOrder(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(ICorkMarketCreator.RecipeRejectedConstraint.selector, address(impairmentRecipe))
        );
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");

        // Control: the honest payload for a one-hour market declares one hour, and creates it.
        lop.callPreInteraction(hook, _askOrder(1e18), 1e18, 0, abi.encode(_impairmentParams(1 hours), _noPermits()));
        assertEq(controller.createCalls(), 1, "the honest payload creates the pool");
        _assertNoCustody();
    }

    /// @dev THE LIFE RULE IS CREATION-ONLY, seen through the fill. The market is created with a
    ///      declared life equal to its whole life; a day later the remaining life is shorter than the
    ///      declared one, and the resting order must keep filling into the pool it created. A payload
    ///      that would CREATE a market at that moment with the same declared life is still refused,
    ///      which is what shows the rule is skipped by the flag and not gone.
    function test_impairmentLaterFill_doesNotRecheckTheLife() public {
        bytes memory extraData = abi.encode(_impairmentParams(), _noPermits());
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, extraData);
        assertEq(controller.createCalls(), 1, "the first fill created the pool");

        vm.warp(block.timestamp + 1 days);
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, extraData);
        assertEq(controller.createCalls(), 1, "the later fill reused the pool");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "both fills minted into it");

        // Control: a different expiry names a different pool, so this fill would create one, and the
        // 30-day claim no longer fits the 28 days that market would live.
        expiry = expiry - 1 days;
        bytes memory fresh = abi.encode(_impairmentParams(), _noPermits());
        IOrderMixin.Order memory order = _askOrder(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(ICorkMarketCreator.RecipeRejectedConstraint.selector, address(impairmentRecipe))
        );
        lop.callPreInteraction(hook, order, 1e18, 0, fresh);
        _assertNoCustody();
    }

    // -- Fees follow phoenix's rule; this adapter adds none of its own --------------------------

    /// @dev THE FEE RULE IS PHOENIX'S. A fee of 100% or more is refused by the controller with
    ///      phoenix's own `InvalidFees`, four frames down; the adapter neither restates the rule nor
    ///      renames the error. The mock controller enforces exactly phoenix's `PoolLib.initialize`
    ///      check so the selector here is the real one.
    function test_swapFeeAtOneHundredPercent_revertsWithPhoenixInvalidFees() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.swapFeePercentage = 100e18;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IErrors.InvalidFees.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    function test_unwindSwapFeeAtOneHundredPercent_revertsWithPhoenixInvalidFees() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.unwindSwapFeePercentage = 100e18;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IErrors.InvalidFees.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev And anything below 100% is creatable: there is no five-percent cap of this repository's
    ///      own any more. Fifty percent, well past the old cap and well under phoenix's bound.
    function test_feeAboveTheOldFivePercentCap_createsTheMarket() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.swapFeePercentage = 50e18;
        params.market.unwindSwapFeePercentage = 100e18 - 1;
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(params, _noPermits()));

        assertEq(controller.createCalls(), 1, "a fee phoenix accepts is creatable here");
        assertEq(controller.lastSwapFeePercentage(), 50e18, "the pool took the swap fee");
        assertEq(controller.lastUnwindSwapFeePercentage(), 100e18 - 1, "and the unwind fee");
        _assertNoCustody();
    }

    /// @dev A "negative fee" from an off-chain layer arrives on-chain as exactly this. The field is
    ///      unsigned, so a minus sign that survived into the payload is not a small number, it is
    ///      `type(uint256).max`. Stopping the sign from getting there is the API's job; this
    ///      is the shape it takes once it reaches the chain, and phoenix refuses it.
    ///
    ///      Driven through `takerInteraction` on purpose, so both hooks are covered: both enter
    ///      `_ensureMarket`, and creation is where phoenix's rule fires.
    function test_reverts_whenFeeIsUintMax_onTheTakerPath() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.swapFeePercentage = type(uint256).max;

        IOrderMixin.Order memory order = _bidOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IErrors.InvalidFees.selector);
        lop.callTakerInteraction(hook, order, BOND, 0, 1e18, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev FEES ARE MARKET IDENTITY. Phoenix hashes both fees into the pool id, so an order that
    ///      names another fee is not a fill into the same pool with a fee that nothing reads — it is
    ///      a fill into ANOTHER pool, created on the spot with the fee the order named. REPLACES
    ///      `test_reverts_whenFeeIsOutOfRangeOnAFillIntoAnExistingPool`, whose premise (a fill into
    ///      an existing pool ignores the fees) no longer holds.
    function test_differentFee_derivesADifferentPool() public {
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _extraData());
        assertEq(controller.createCalls(), 1, "the first fill created the pool at the fixture's fees");

        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.market.swapFeePercentage = SWAP_FEE - 1e18;
        MarketId otherId = _expectedPoolId(SWAP_FEE - 1e18, UNWIND_FEE);
        assertNotEq(MarketId.unwrap(otherId), MarketId.unwrap(_expectedPoolId()), "another fee, another id");

        vm.expectEmit(true, true, true, true, address(creator));
        emit ICorkMarketCreator.MarketCreated(
            otherId,
            address(rateOracle),
            address(collateral),
            address(referenceToken),
            expiry,
            address(recipe),
            SWAP_FEE - 1e18,
            UNWIND_FEE,
            address(hook)
        );
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, abi.encode(params, _noPermits()));

        assertEq(controller.createCalls(), 2, "the second fill created a second pool");
        assertEq(poolManager.marketCount(), 2, "two markets registered");
        assertEq(poolManager.market(otherId).swapFeePercentage, SWAP_FEE - 1e18, "the new pool took the new fee");
        assertEq(poolManager.market(_expectedPoolId()).swapFeePercentage, SWAP_FEE, "the first pool kept its own");
        assertEq(poolManager.cst().balanceOf(BOND), 10_000e18, "both fills minted");
        _assertNoCustody();
    }

    // -- Carried permits (PermitParams) -----------------------------------------------------------

    /// @dev A carried permit that fails to execute must revert the whole fill: the allowance
    ///      the order depends on could not be granted, so there is nothing for the LOP's pull
    ///      to find. The mock cST has no `permit` function at all, standing in for any failed
    ///      permit execution; the missing selector reverts with empty data.
    function test_carriedPermitFailure_revertsTheFill() public {
        CorkLimitOrderAdapter.PermitParams[] memory permits = new CorkLimitOrderAdapter.PermitParams[](1);
        permits[0].token = address(poolManager.cst());
        permits[0].value = 1e18;
        permits[0].deadline = block.timestamp + 1 days;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(_params(), permits);

        vm.expectRevert(bytes(""));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev A permit whose allowance is ALREADY in place is skipped, so a front-runner who
    ///      consumed the public signature (granting exactly what the maker intended) cannot
    ///      brick the order. The mock cST still has no `permit` function — the fill completing
    ///      proves the adapter never called it.
    function test_carriedPermit_skippedWhenAllowanceAlreadyInPlace() public {
        CorkLimitOrderAdapter.PermitParams[] memory permits = new CorkLimitOrderAdapter.PermitParams[](1);
        permits[0].token = address(poolManager.cst());
        permits[0].value = 1e18;
        permits[0].deadline = block.timestamp + 1 days;

        poolManager.cst().setAllowance(BOND, address(lop), 1e18);

        lop.callPreInteraction(hook, _askOrder(1e18), 1e18, 0, abi.encode(_params(), permits));

        assertEq(controller.createCalls(), 1, "the fill went through without executing the permit");
        assertEq(poolManager.cst().balanceOf(BOND), 1e18, "and the mint went through");
        _assertNoCustody();
    }

    // -- Payload layout helpers (encodeExtraData / decodeExtraData) ------------------------------

    /// @dev A payload with nothing trivial in it: non-empty nested `extraData`, a non-zero
    ///      salt, the mint gate set, and two carried permits with distinct fields, so a swapped or
    ///      dropped field in either helper shows up as an inequality below.
    function _richPayload()
        internal
        view
        returns (
            CorkLimitOrderAdapter.JITMarketParams memory market,
            CorkLimitOrderAdapter.PermitParams[] memory permits
        )
    {
        market = _params();
        market.market.extraData = abi.encode(ANCHOR_RATE, uint256(7 days), bytes("nested"));
        market.market.oracleSalt = keccak256("salt");
        market.market.rateOverride = 123;
        market.enableJitMint = true;

        permits = new CorkLimitOrderAdapter.PermitParams[](2);
        permits[0] = CorkLimitOrderAdapter.PermitParams({
            token: address(poolManager.cst()),
            value: 1e18,
            deadline: block.timestamp + 1 days,
            v: 27,
            r: keccak256("r0"),
            s: keccak256("s0")
        });
        permits[1] = CorkLimitOrderAdapter.PermitParams({
            token: address(collateral),
            value: type(uint256).max,
            deadline: block.timestamp + 2 days,
            v: 28,
            r: keccak256("r1"),
            s: keccak256("s1")
        });
    }

    function test_extraData_roundTrip_returnsEveryField() public view {
        (CorkLimitOrderAdapter.JITMarketParams memory market, CorkLimitOrderAdapter.PermitParams[] memory permits) =
            _richPayload();

        (CorkLimitOrderAdapter.JITMarketParams memory m, CorkLimitOrderAdapter.PermitParams[] memory p) =
            hook.decodeExtraData(hook.encodeExtraData(market, permits));

        assertEq(m.market.collateralAsset, market.market.collateralAsset, "collateralAsset");
        assertEq(m.market.referenceAsset, market.market.referenceAsset, "referenceAsset");
        assertEq(m.market.expiryTimestamp, market.market.expiryTimestamp, "expiryTimestamp");
        assertEq(m.market.recipe, market.market.recipe, "recipe");
        assertEq(m.market.rateOverride, market.market.rateOverride, "rateOverride");
        assertEq(m.market.constraint.rateMin, market.market.constraint.rateMin, "rateMin");
        assertEq(m.market.constraint.rateMax, market.market.constraint.rateMax, "rateMax");
        assertEq(m.market.constraint.rateChangePerDayMax, market.market.constraint.rateChangePerDayMax, "perDay");
        assertEq(m.market.constraint.rateChangeCapacityMax, market.market.constraint.rateChangeCapacityMax, "capacity");
        assertEq(m.market.extraData, market.market.extraData, "extraData");
        assertEq(m.market.oracleSalt, market.market.oracleSalt, "oracleSalt");
        assertEq(m.market.swapFeePercentage, market.market.swapFeePercentage, "swapFee");
        assertEq(m.market.unwindSwapFeePercentage, market.market.unwindSwapFeePercentage, "unwindFee");
        assertEq(m.enableJitMint, market.enableJitMint, "enableJitMint");

        assertEq(p.length, permits.length, "permit count");
        for (uint256 i = 0; i < permits.length; i++) {
            assertEq(p[i].token, permits[i].token, "permit token");
            assertEq(p[i].value, permits[i].value, "permit value");
            assertEq(p[i].deadline, permits[i].deadline, "permit deadline");
            assertEq(p[i].v, permits[i].v, "permit v");
            assertEq(p[i].r, permits[i].r, "permit r");
            assertEq(p[i].s, permits[i].s, "permit s");
        }
    }

    /// @dev The helper is nothing more than `abi.encode(market, permits)`: an integrator that
    ///      already encodes by hand produces the same bytes, byte for byte.
    function test_encodeExtraData_equalsRawAbiEncode() public view {
        (CorkLimitOrderAdapter.JITMarketParams memory market, CorkLimitOrderAdapter.PermitParams[] memory permits) =
            _richPayload();
        assertEq(hook.encodeExtraData(market, permits), abi.encode(market, permits), "helper == abi.encode");
        assertEq(hook.encodeExtraData(_params(), _noPermits()), _extraData(), "fixture payload too");
    }

    /// @dev Bytes that are not a payload do not decode. A raw `abi.decode` failure reverts with
    ///      empty data.
    function test_decodeExtraData_revertsOnGarbage() public {
        bytes memory garbage = hex"deadbeef";
        vm.expectRevert(bytes(""));
        hook.decodeExtraData(garbage);
    }

    function test_version() public view {
        assertEq(hook.version(), "0.4.0");
    }

    // -- Non-standard ERC20 collateral -----------------------------------------------------------

    function test_worksWith_noReturnDataCollateral() public {
        collateral = new MockERC20("USDT-style", 6, true);
        _wire();

        uint256 cstShares = 1_000e18;
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, _extraData());
        assertEq(poolManager.cst().balanceOf(BOND), cstShares, "no-return-data CA must still mint");
        _assertNoCustody();
    }

    /// @dev The hook must end every fill with zero balances and zero dangling allowance —
    ///      capital only transits.
    function _assertNoCustody() internal view {
        assertEq(collateral.balanceOf(address(hook)), 0, "hook must hold no CA");
        assertEq(poolManager.cst().balanceOf(address(hook)), 0, "hook must hold no cST");
        assertEq(poolManager.cpt().balanceOf(address(hook)), 0, "hook must hold no cPT");
        assertEq(collateral.allowance(address(hook), address(poolManager)), 0, "no dangling allowance");
    }
}
