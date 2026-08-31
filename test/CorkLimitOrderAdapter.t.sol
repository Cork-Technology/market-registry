// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IPoolManager, Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {CorkLimitOrderAdapter} from "../src/CorkLimitOrderAdapter.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IOrderMixin} from "../src/interfaces/I1inchLimitOrderProtocol.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";
import {LiquidityPriceRecipe} from "../src/recipes/LiquidityPriceRecipe.sol";
import {FixedRateRecipe} from "../src/recipes/FixedRateRecipe.sol";
import {mkPriceOnlyAsset} from "./helpers/RegistryFixture.sol";
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

/// @dev The JIT suite runs the REAL `MarketRegistry` (assets, approved recipe, `deploy`) and the REAL
///      {LiquidityPriceRecipe}, with the wrapper factory mocked in `Fixed` mode so `deploy` hands back a
///      live {MockRateOracle}. Pool manager, controller, and LOP are mocks (see JITMocks.sol).
///
///      ## What changed in this suite, and why every change was forced
///
///      1. **The payload no longer carries a mode STRING.** `JITMarketParams` carries a `recipe`
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
///      5. **Assets carry their denomination on the SOURCE.** `"USD"` is seeded by the registry
///         constructor and resolves in zero hops, so `mkPriceOnlyAsset(..., "USD")` needs no
///         conversion feed.
///      6. **A payload's numbers are now bounded.** The expiry is checked against a governance-set
///         bound on the registry, and only on the fill that CREATES the market; the two fee fields are
///         checked against a constant on EVERY fill. The split is deliberate and the tests that pin it
///         are {test_marketCreatedUnderALooserBound_stillFillsAfterTightening} and
///         {test_reverts_whenFeeIsOutOfRangeOnAFillIntoAnExistingPool} — read those two together
///         before changing where any of these checks live. The fixture's `expiry` sits EXACTLY on the
///         registry's default bound, which is why {test_expiryExactlyAtTheBound_createsTheMarketAndFills}
///         states that out loud instead of leaving it as a coincidence.
contract CorkLimitOrderAdapterTest is Test {
    address internal constant BOND = address(0xB07D);
    address internal constant PREMIUM_TOKEN = address(0xFEE);

    /// @dev The rate the constraint is derived from at signing time, carried in `additionalData`. The
    ///      oracle starts here too, so the live rate sits inside the derived window.
    uint256 internal constant ANCHOR_RATE = 1e18;

    /// @dev The rate a fixed-rate ORDER names in `rateOverride`. Deliberately unrelated to
    ///      {ANCHOR_RATE}: a `FIXED` market's rate comes from the order, not from the pair's feed.
    uint256 internal constant FIXED_JIT_RATE = 2.5e18;

    address internal owner;
    MockERC20 internal collateral;
    MockERC20 internal referenceToken;
    MockRateOracle internal rateOracle;
    MockWrapperFactory internal wrapperFactory;
    MarketRegistry internal registry;
    LiquidityPriceRecipe internal recipe;
    FixedRateRecipe internal fixedRecipe;
    PermissiveRecipe internal permissiveRecipe;
    MockJITPoolManager internal poolManager;
    MockJITController internal controller;
    MockLimitOrderProtocol internal lop;
    CorkLimitOrderAdapter internal hook;
    uint256 internal expiry;

    function setUp() public {
        owner = makeAddr("owner");
        collateral = new MockERC20("USDC", 6, false);
        _wire();
    }

    /// @dev Wires the full harness around the current `collateral`: real registry (both assets
    ///      registered, one real {LiquidityPriceRecipe} approved, fixed wrapper = live mock rate oracle),
    ///      mock pool manager + controller + LOP, the hook, and BOND's funding/approval ceremony.
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

        vm.startPrank(owner);
        // `"USD"` is seeded by the constructor and reaches US Dollars in zero hops, so no conversion
        // feed is needed for either source.
        registry.addAssets(one(mkPriceOnlyAsset(address(collateral), "USDC", address(0xFEED01), "USD")));
        registry.addAssets(one(mkPriceOnlyAsset(address(referenceToken), "wstETH", address(0xFEED02), "USD")));
        registry.addRecipes(one(address(recipe)));
        registry.addRecipes(one(address(fixedRecipe)));
        permissiveRecipe = new PermissiveRecipe();
        registry.addRecipes(one(address(permissiveRecipe)));
        vm.stopPrank();

        poolManager = new MockJITPoolManager();
        controller = new MockJITController(poolManager);
        lop = new MockLimitOrderProtocol();
        hook = new CorkLimitOrderAdapter();
        hook.initialize(
            address(lop),
            IPoolManager(address(poolManager)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(registry))
        );
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
        params.recipe = address(fixedRecipe);
        params.rateOverride = FIXED_JIT_RATE;
        params.constraint = fixedRecipe.resolve(address(collateral), address(referenceToken), oracle, "");
        params.additionalData = "";
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
                        rateMin: params.constraint.rateMin,
                        rateMax: params.constraint.rateMax,
                        rateChangePerDayMax: params.constraint.rateChangePerDayMax,
                        rateChangeCapacityMax: params.constraint.rateChangeCapacityMax,
                        rateOracle: oracle
                    })
                )
            )
        );
    }

    /// @dev The default payload carries `enableJitMint: true`, so the maker path mints as it did
    ///      before the gate existed. Tests that exercise the gated-off maker path re-encode with
    ///      the flag cleared; the taker path ignores the flag either way.
    function _params() internal view returns (CorkLimitOrderAdapter.JITMarketParams memory) {
        return CorkLimitOrderAdapter.JITMarketParams({
            collateralAsset: address(collateral),
            referenceAsset: address(referenceToken),
            expiryTimestamp: expiry,
            recipe: address(recipe),
            rateOverride: 0, // a PRICE recipe takes its rate from the pair's wrapper, never from the order
            constraint: _constraint(),
            additionalData: abi.encode(ANCHOR_RATE),
            swapFeePercentage: 3e18,
            unwindSwapFeePercentage: 4e18,
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

    /// @dev A payload whose recipe accepts anything, so `verify` never rejects and the adapter's own
    ///      creation-time checks are what a test reaches. Same constraint and same oracle as the
    ///      {LiquidityPriceRecipe} payload, so it derives the SAME pool id.
    function _permissiveExtraData() internal view returns (bytes memory) {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.recipe = address(permissiveRecipe);
        return abi.encode(params, _noPermits());
    }

    /// @dev The market the hook must assemble: the constraint straight out of the payload (NOT derived
    ///      from the live rate any more), oracle = the fixed wrapper the registry deploys/records.
    function _expectedMarket() internal view returns (Market memory m) {
        IMarketRegistry.ResolvedConstraint memory c = _constraint();
        m = Market({
            collateralAsset: address(collateral),
            referenceAsset: address(referenceToken),
            expiryTimestamp: expiry,
            rateMin: c.rateMin,
            rateMax: c.rateMax,
            rateChangePerDayMax: c.rateChangePerDayMax,
            rateChangeCapacityMax: c.rateChangeCapacityMax,
            rateOracle: address(rateOracle)
        });
    }

    function _expectedPoolId() internal view returns (MarketId) {
        return MarketId.wrap(keccak256(abi.encode(_expectedMarket())));
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
        IDefaultCorkController ctrl = IDefaultCorkController(address(controller));
        IMarketRegistry reg = IMarketRegistry(address(registry));
        CorkLimitOrderAdapter fresh = new CorkLimitOrderAdapter();
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(0), pm, ctrl, reg);
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(lop), IPoolManager(address(0)), ctrl, reg);
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(lop), pm, IDefaultCorkController(address(0)), reg);
        vm.expectRevert(CorkLimitOrderAdapter.ZeroAddress.selector);
        fresh.initialize(address(lop), pm, ctrl, IMarketRegistry(address(0)));
    }

    // -- Maker path (preInteraction, ASK): JIT creation + JIT mint ------------------------------

    function test_preInteraction_createsMarketAndMintsToMaker() public {
        uint256 cstShares = 20_000e18;
        uint256 expectedCollateral = 20_000e6; // ceil(20_000e18 * 1e6 / 1e18)
        MarketId expectedId = _expectedPoolId();

        vm.expectEmit(true, true, false, true, address(hook));
        emit CorkLimitOrderAdapter.JITMarketCreated(
            expectedId, address(rateOracle), address(collateral), address(referenceToken), expiry, address(recipe)
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit CorkLimitOrderAdapter.JITMinted(expectedId, BOND, cstShares, expectedCollateral);
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, _extraData());

        // The pool was created through the controller with the carried constraints, the fees in
        // the right slots (unwind BEFORE swap in the params struct), and the whitelist disabled.
        assertEq(controller.createCalls(), 1, "one pool creation");
        assertEq(controller.lastSwapFeePercentage(), 3e18, "swap fee slot");
        assertEq(controller.lastUnwindSwapFeePercentage(), 4e18, "unwind fee slot");
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

        lop.callTakerInteraction(hook, _bidOrder(cstShares), BOND, 0, cstShares, _extraData());

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

        vm.expectEmit(true, true, false, true, address(hook));
        emit CorkLimitOrderAdapter.JITMarketCreated(
            expectedId, address(rateOracle), address(collateral), address(referenceToken), expiry, address(recipe)
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
        params.collateralAsset = address(rogue);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev REPLACES `test_reverts_whenModeUnknown`. A policy is named by a recipe CONTRACT ADDRESS now
    ///      rather than by a mode string, so "the order names a policy the registry does not know" is
    ///      step 1 of the four-step sequence failing: `isRecipe` returns false and the adapter reverts
    ///      `RecipeNotRegistered(recipe)`. `address(0)` is not exempt — see
    ///      {test_reverts_whenRecipeIsZero}, which lands on this same check.
    ///
    ///      The rogue carries the IDENTICAL policy to the approved one, since a `LiquidityPriceRecipe`'s
    ///      limits are constants. Membership is by ADDRESS, so that changes nothing: an unapproved
    ///      address is refused however familiar its numbers look.
    function test_reverts_whenRecipeNotRegistered() public {
        LiquidityPriceRecipe rogue = new LiquidityPriceRecipe();
        rogue.initialize(IMarketRegistry(address(registry)));
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.recipe = address(rogue);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.RecipeNotRegistered.selector, address(rogue)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The carried constraint is not one this recipe would ever have produced from the anchor it
    ///      declares, so `verify` returns false and the adapter names the rejection. This is now the
    ///      ONLY way to reach `RecipeRejectedConstraint` through {LiquidityPriceRecipe} — a stale rate no
    ///      longer does it, see {test_rateFarOutsideTheWindow_stillFills}.
    function test_reverts_whenConstraintDoesNotMatchTheRecipe() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.constraint.rateMax += 1; // one wei off the shape the recipe produces
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(
            abi.encodeWithSelector(CorkLimitOrderAdapter.RecipeRejectedConstraint.selector, address(recipe))
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(CorkLimitOrderAdapter.RecipeRejectedConstraint.selector, address(recipe))
        );
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
        params.recipe = address(0);
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
    ///      order before the adapter's own guard is reached. See
    ///      {test_reverts_whenRateIsZero_theRecipeRejectsItFirst}, which pins that ordering. A recipe
    ///      with no opinion about the live rate is the only way to reach this check.
    function test_reverts_whenRateIsZeroAtCreation() public {
        rateOracle.setRate(0);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _permissiveExtraData();
        vm.expectRevert(CorkLimitOrderAdapter.RateUnavailable.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The ordering the test above depends on, asserted rather than assumed. Through the REAL
    ///      recipe a zero rate never reaches the adapter's `RateUnavailable` guard: `verify` runs first
    ///      and a rate of zero is outside `[rateMin, rateMax]` for every window {LiquidityPriceRecipe}
    ///      produces, since its floor is one wei. So the rejection carries the recipe's selector.
    function test_reverts_whenRateIsZero_theRecipeRejectsItFirst() public {
        rateOracle.setRate(0);
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData();
        vm.expectRevert(
            abi.encodeWithSelector(CorkLimitOrderAdapter.RecipeRejectedConstraint.selector, address(recipe))
        );
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev The complement of the test above, and the behaviour the adapter documents explicitly: the
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
    ///         — a `FIXED` recipe deployed no oracle, so the adapter refused the creation outright.
    function test_fixedRecipe_rateOverride_deploysTheOracleAndCreatesTheMarket() public {
        uint256 cstShares = 1_000e18;
        address oracle = registry.predictFixedRateOracle(FIXED_JIT_RATE);
        assertEq(oracle.code.length, 0, "precondition: the oracle does not exist yet");

        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        MarketId expectedId = _fixedPoolId(params, oracle);

        vm.expectEmit(true, true, false, true, address(hook));
        emit CorkLimitOrderAdapter.JITMarketCreated(
            expectedId, oracle, address(collateral), address(referenceToken), expiry, address(fixedRecipe)
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
        params.rateOverride = FIXED_JIT_RATE;
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());

        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.UnexpectedRateOverride.selector, address(recipe)));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @notice A `FIXED` recipe with no rate named. There is no oracle to deploy for rate zero and no
    ///         other place the rate could come from, so the failure lands in `FixedRateOracle`'s own
    ///         constructor with its own selector rather than as a bare revert further down.
    function test_reverts_whenFixedRecipeCarriesNoRate() public {
        CorkLimitOrderAdapter.JITMarketParams memory params = _fixedParams();
        params.rateOverride = 0;
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());

        vm.expectRevert(IRateOracle.InvalidRate.selector);
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
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
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.ExpiryOutOfRange.selector, expiry, maxExpiry));
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
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.ExpiryOutOfRange.selector, expiry, maxExpiry));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "the incident payload must create nothing");
    }

    /// @dev The bound is read from the registry on every creating fill, not baked into the adapter at
    ///      deployment. Once the curator shortens the maximum market life, an expiry that was perfectly
    ///      fine a block ago is refused.
    function test_reverts_whenOwnerTightensTheBoundBelowTheOrdersExpiry() public {
        vm.prank(owner);
        registry.setMaxExpiryDuration(7 days);

        uint256 maxExpiry = block.timestamp + 7 days;
        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = _extraData(); // still the fixture's 30-day expiry
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.ExpiryOutOfRange.selector, expiry, maxExpiry));
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
    ///      the SAME pool rather than trying to make a new one.
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

    // -- Fee bounds ------------------------------------------------------------------------------

    /// @dev Five percent exactly. Inclusive, like the creation bound — the cap restates what phoenix
    ///      itself permits, so an order asking for exactly it is asking for something allowed.
    function test_swapFeeExactlyAtTheCap_createsTheMarket() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        assertEq(cap, 5e18, "the cap phoenix enforces, restated here for a better error");

        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.swapFeePercentage = cap;
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(params, _noPermits()));

        assertEq(controller.createCalls(), 1, "the highest permitted fee must be creatable");
        assertEq(controller.lastSwapFeePercentage(), cap, "the pool took the capped fee");
        _assertNoCustody();
    }

    function test_reverts_whenSwapFeeIsOneWeiOverTheCap() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.swapFeePercentage = cap + 1;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.SwapFeeOutOfRange.selector, cap + 1, cap));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev The second fee field gets its own selector, so a rejection says WHICH fee was wrong. That
    ///      is the entire reason the cap is restated in the adapter at all: phoenix rejects both with
    ///      one nameless error, four frames down.
    function test_unwindSwapFeeExactlyAtTheCap_createsTheMarket() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.unwindSwapFeePercentage = cap;
        lop.callPreInteraction(hook, _askOrder(1_000e18), 1_000e18, 0, abi.encode(params, _noPermits()));

        assertEq(controller.createCalls(), 1, "the highest permitted unwind fee must be creatable");
        assertEq(controller.lastUnwindSwapFeePercentage(), cap, "the pool took the capped unwind fee");
        _assertNoCustody();
    }

    function test_reverts_whenUnwindSwapFeeIsOneWeiOverTheCap() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.unwindSwapFeePercentage = cap + 1;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.UnwindSwapFeeOutOfRange.selector, cap + 1, cap));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev A "negative fee" from an off-chain layer arrives on-chain as exactly this. The field is
    ///      unsigned, so a minus sign that survived into the payload is not a small number, it is
    ///      `type(uint256).max`. Stopping the sign from getting there is the API's job (COR-117); this
    ///      is the shape it takes once it reaches the chain, and it is refused by name.
    ///
    ///      Driven through `takerInteraction` on purpose, so both hooks are covered. The fee check
    ///      lives in `_ensureMarket`, which both hooks enter, and this is what says so.
    function test_reverts_whenFeeIsUintMax_onTheTakerPath() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.swapFeePercentage = type(uint256).max;

        IOrderMixin.Order memory order = _bidOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(
            abi.encodeWithSelector(CorkLimitOrderAdapter.SwapFeeOutOfRange.selector, type(uint256).max, cap)
        );
        lop.callTakerInteraction(hook, order, BOND, 0, 1e18, extraData);

        assertEq(controller.createCalls(), 0, "no pool was created");
    }

    /// @dev THE REASON THE FEE BOUNDS RUN ON EVERY FILL RATHER THAN ONLY THE CREATING ONE. The fees are
    ///      read once, when the pool is created; a fill into a pool that already exists ignores them
    ///      entirely. So a nonsensical fee here changes no outcome — which is exactly why it would
    ///      otherwise be accepted in silence, leaving a signed order claiming it chose a fee that
    ///      nothing ever read.
    function test_reverts_whenFeeIsOutOfRangeOnAFillIntoAnExistingPool() public {
        lop.callPreInteraction(hook, _askOrder(5_000e18), 5_000e18, 0, _extraData());
        assertEq(controller.createCalls(), 1, "the first fill created the pool with fees in range");

        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.swapFeePercentage = cap + 1;

        IOrderMixin.Order memory order = _askOrder(5_000e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.SwapFeeOutOfRange.selector, cap + 1, cap));
        lop.callPreInteraction(hook, order, 5_000e18, 0, extraData);

        assertEq(controller.lastSwapFeePercentage(), 3e18, "the pool's own fee is untouched");
        assertEq(poolManager.cst().balanceOf(BOND), 5_000e18, "and the rejected fill minted nothing");
    }

    // -- The order the creation checks run in ----------------------------------------------------

    /// @dev A payload that is wrong in three ways at once reports the FEE. The fee bounds sit at the
    ///      very top of `_ensureMarket`, ahead of the recipe lookup and ahead of the expiry bound, so
    ///      the caller hears about the first thing that is wrong rather than the last. Pinning the
    ///      order means a future reshuffle has to be a decision instead of a side effect.
    function test_feeIsReportedBeforeTheOtherCreationChecks() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        expiry = block.timestamp + 3650 days; // far past the maximum market life

        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.recipe = address(0); // and it names no registered recipe either
        params.swapFeePercentage = cap + 1;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.SwapFeeOutOfRange.selector, cap + 1, cap));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
    }

    /// @dev And between the two fee fields, the swap fee is reported first.
    function test_swapFeeIsReportedBeforeTheUnwindFee() public {
        uint256 cap = hook.MAX_FEE_PERCENTAGE();
        CorkLimitOrderAdapter.JITMarketParams memory params = _params();
        params.swapFeePercentage = cap + 1;
        params.unwindSwapFeePercentage = cap + 1;

        IOrderMixin.Order memory order = _askOrder(1e18);
        bytes memory extraData = abi.encode(params, _noPermits());
        vm.expectRevert(abi.encodeWithSelector(CorkLimitOrderAdapter.SwapFeeOutOfRange.selector, cap + 1, cap));
        lop.callPreInteraction(hook, order, 1e18, 0, extraData);
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
