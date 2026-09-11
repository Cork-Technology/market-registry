// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, Vm} from "forge-std/Test.sol";
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IErrors} from "contracts/interfaces/IErrors.sol";
import {IPoolManager, Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {CorkLimitOrderAdapter} from "../src/CorkLimitOrderAdapter.sol";
import {CorkMarketCreator} from "../src/CorkMarketCreator.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {ICorkMarketCreator} from "../src/interfaces/ICorkMarketCreator.sol";
import {IOrderMixin} from "../src/interfaces/I1inchLimitOrderProtocol.sol";
import {IMarketRecipe} from "../src/interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
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

/// @dev The creator suite runs the SAME harness as `CorkLimitOrderAdapter.t.sol`: the REAL
///      `MarketRegistry` with three real recipes and the {PermissiveRecipe} double approved, the
///      wrapper factory mocked in `Fixed` mode so `deploy` hands back a live {MockRateOracle}, and
///      the mock pool manager, controller, and limit order protocol from JITMocks.sol. The adapter is
///      wired too, and wired TO this creator, because the point of this contract is parity with the
///      fill: the pool a caller creates here is the pool a later fill finds, and the pool a fill
///      created is the pool a later call here looks up. The two parity tests at the end pin that in
///      both directions. Now that the adapter calls this contract rather than carrying a copy of
///      it, they are regression tests: they would only fail if the adapter grew a creation path of
///      its own again, or stopped handing the payload through unchanged.
contract CorkMarketCreatorTest is Test {
    address internal constant BOND = address(0xB07D);
    address internal constant PREMIUM_TOKEN = address(0xFEE);
    address internal constant SMART_ACCOUNT = address(0x5AFE);

    /// @dev The rate the constraint is derived from at signing time, carried in `extraData`. The
    ///      oracle starts here too, so the live rate sits inside the derived window.
    uint256 internal constant ANCHOR_RATE = 1e18;

    /// @dev The rate a fixed-rate caller names in `rateOverride`. Deliberately unrelated to
    ///      {ANCHOR_RATE}: a `FIXED` market's rate comes from the caller, not from the pair's feed.
    uint256 internal constant FIXED_RATE = 2.5e18;

    /// @dev The impairment recipe's declared life and spread, as in the adapter suite.
    uint256 internal constant IMPAIRMENT_DURATION = 30 days;
    uint256 internal constant IMPAIRMENT_SPREAD = 10e18;

    /// @dev The two pool fees an honest caller carries, on the percentage scale (`1e18` = 1%). Both
    ///      are part of the pool id, so they appear in every restated market below.
    uint256 internal constant SWAP_FEE = 3e18;
    uint256 internal constant UNWIND_FEE = 4e18;
    bytes32 internal constant ORACLE_SALT = keccak256("caller-chosen entropy");

    address internal owner;
    MockERC20 internal collateral;
    MockERC20 internal referenceToken;
    MockERC20 internal navReferenceToken;
    MockERC20 internal navVault;
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
    CorkLimitOrderAdapter internal hook;
    CorkMarketCreator internal creator;
    uint256 internal expiry;

    function setUp() public {
        owner = makeAddr("owner");
        collateral = new MockERC20("USDC", 6, false);
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
        navVault = new MockERC20("sUSDe-vault", 18, false);

        vm.startPrank(owner);
        address usd = MarketRegistryLib.USD_DENOMINATION;
        registry.addAssets(one(mkPriceOnlyAsset(address(collateral), "USDC", address(0xFEED01), usd)));
        registry.addAssets(one(mkPriceOnlyAsset(address(referenceToken), "wstETH", address(0xFEED02), usd)));
        registry.addAssets(one(mkNavOnlyAsset(address(navReferenceToken), "sUSDe", address(navVault), usd)));
        registry.addRecipes(one(address(recipe)));
        registry.addRecipes(one(address(fixedRecipe)));
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

        // The adapter's fills pull collateral from BOND; the creator never touches a token.
        collateral.mint(BOND, 50_000e6);
        collateral.setAllowance(BOND, address(hook), type(uint256).max);
    }

    // ─────────────────────────────── Payload helpers ────────────────────────────

    /// @dev The constraint an honest caller carries, restated as literals rather than re-derived from
    ///      the recipe, for the same reason the adapter suite does it: a restatement fails when the
    ///      recipe's constants move; a re-derivation would follow them in silence.
    function _constraint() internal pure returns (IMarketRegistry.ResolvedConstraint memory c) {
        c.rateMin = 1;
        c.rateMax = 2 * ANCHOR_RATE;
        c.rateChangePerDayMax = ANCHOR_RATE;
        c.rateChangeCapacityMax = 3 * ANCHOR_RATE;
    }

    function _params() internal view returns (ICorkMarketCreator.MarketParams memory) {
        return ICorkMarketCreator.MarketParams({
            collateralAsset: address(collateral),
            referenceAsset: address(referenceToken),
            expiryTimestamp: expiry,
            recipe: address(recipe),
            rateOverride: 0,
            constraint: _constraint(),
            extraData: abi.encode(ANCHOR_RATE),
            oracleSalt: ORACLE_SALT,
            swapFeePercentage: SWAP_FEE,
            unwindSwapFeePercentage: UNWIND_FEE
        });
    }

    /// @dev The fixed-rate payload: the caller names the rate, so the constraint comes from the recipe
    ///      reading the oracle that rate derives to, exactly as an order-building agent would.
    function _fixedParams() internal returns (ICorkMarketCreator.MarketParams memory params) {
        address oracle = registry.deployFixedRateOracle(FIXED_RATE);
        params = _params();
        params.recipe = address(fixedRecipe);
        params.rateOverride = FIXED_RATE;
        params.constraint = fixedRecipe.resolve(address(collateral), address(referenceToken), oracle, "");
        params.extraData = "";
    }

    /// @dev The impairment payload: a NAV recipe against the NAV-only reference asset.
    function _impairmentParams() internal view returns (ICorkMarketCreator.MarketParams memory params) {
        bytes memory data = abi.encode(ANCHOR_RATE, IMPAIRMENT_DURATION, IMPAIRMENT_SPREAD);
        params = _params();
        params.referenceAsset = address(navReferenceToken);
        params.recipe = address(impairmentRecipe);
        params.constraint = impairmentRecipe.resolve(address(collateral), address(navReferenceToken), address(0), data);
        params.extraData = data;
    }

    /// @dev The adapter's payload for the SAME market as {_params}: the creator's params nested
    ///      whole, plus the fill-only mint flag. What the parity tests hand the adapter.
    function _adapterExtraData() internal view returns (bytes memory) {
        CorkLimitOrderAdapter.JITMarketParams memory params =
            CorkLimitOrderAdapter.JITMarketParams({market: _params(), enableJitMint: true});
        CorkLimitOrderAdapter.PermitParams[] memory noPermits;
        return abi.encode(params, noPermits);
    }

    /// @dev ASK shape: BOND is the maker selling cST for the premium token.
    function _askOrder(uint256 cstShares) internal view returns (IOrderMixin.Order memory) {
        return OrderBuilder.build(BOND, address(poolManager.cst()), PREMIUM_TOKEN, cstShares, 0);
    }

    /// @dev The pool the creator must derive, computed independently of it: constraint straight out
    ///      of the payload, oracle = the wrapper the registry hands out, fees last, id = keccak256 of
    ///      the `Market` bytes in phoenix field order.
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

    function _expectedPoolId(uint256 swapFee, uint256 unwindFee) internal view returns (MarketId) {
        return MarketId.wrap(keccak256(abi.encode(_expectedMarket(swapFee, unwindFee))));
    }

    function _expectedPoolId() internal view returns (MarketId) {
        return _expectedPoolId(SWAP_FEE, UNWIND_FEE);
    }

    /// @dev The exact `verify` calldata the creator must produce for `_params()`: the pair, the
    ///      registry wrapper, the expiry, the flag, the carried constraint, and the extra bytes.
    function _verifyCall(bool creating) internal view returns (bytes memory) {
        return abi.encodeCall(
            IMarketRecipe.verify,
            (
                address(collateral),
                address(referenceToken),
                address(rateOracle),
                expiry,
                creating,
                _constraint(),
                abi.encode(ANCHOR_RATE)
            )
        );
    }

    // ─────────────────────────────── Creation ────────────────────────────────

    function test_createsTheMarket_andReturnsPoolIdAndShares() public {
        vm.expectEmit(true, true, true, true, address(creator));
        emit ICorkMarketCreator.MarketCreated(
            _expectedPoolId(),
            address(rateOracle),
            address(collateral),
            address(referenceToken),
            expiry,
            address(recipe),
            SWAP_FEE,
            UNWIND_FEE,
            SMART_ACCOUNT
        );

        vm.prank(SMART_ACCOUNT);
        (MarketId poolId, address cst, address cpt) = creator.createNewPool(_params());

        assertEq(MarketId.unwrap(poolId), MarketId.unwrap(_expectedPoolId()), "pool id");
        assertEq(cst, address(poolManager.cst()), "cst");
        assertEq(cpt, address(poolManager.cpt()), "cpt");
        assertEq(controller.createCalls(), 1, "one creation");
        assertFalse(controller.lastIsWhitelistEnabled(), "whitelist disabled");
        // The fees reach the controller INSIDE the market struct, each in its own slot.
        assertEq(controller.lastSwapFeePercentage(), SWAP_FEE, "swap fee");
        assertEq(controller.lastUnwindSwapFeePercentage(), UNWIND_FEE, "unwind fee");

        Market memory created = poolManager.market(poolId);
        assertEq(created.rateMin, 1, "floor: one wei");
        assertEq(created.rateMax, 2 * ANCHOR_RATE, "ceiling: twice the anchor");
        assertEq(created.rateOracle, address(rateOracle), "pool adopts the registry wrapper");
    }

    function test_secondCallIsALookup_sameReturnsNoSecondCreation() public {
        (MarketId first,,) = creator.createNewPool(_params());

        vm.recordLogs();
        (MarketId second, address cst, address cpt) = creator.createNewPool(_params());

        assertEq(MarketId.unwrap(first), MarketId.unwrap(second), "same pool id");
        assertEq(cst, address(poolManager.cst()), "cst still returned");
        assertEq(cpt, address(poolManager.cpt()), "cpt still returned");
        assertEq(controller.createCalls(), 1, "no second creation");
        assertFalse(_sawMarketCreated(vm.getRecordedLogs()), "a lookup emits nothing");
    }

    /// @dev Fees are market identity: the same market with other fees is another pool.
    function test_differentFees_deriveADifferentPool() public {
        (MarketId first,,) = creator.createNewPool(_params());

        ICorkMarketCreator.MarketParams memory params = _params();
        params.swapFeePercentage = SWAP_FEE + 1;
        (MarketId second,,) = creator.createNewPool(params);

        assertEq(MarketId.unwrap(first), MarketId.unwrap(_expectedPoolId()), "first pool id");
        assertEq(MarketId.unwrap(second), MarketId.unwrap(_expectedPoolId(SWAP_FEE + 1, UNWIND_FEE)), "second pool id");
        assertNotEq(MarketId.unwrap(first), MarketId.unwrap(second), "two different pools");
        assertEq(controller.createCalls(), 2, "two creations");
        assertEq(poolManager.market(second).swapFeePercentage, SWAP_FEE + 1, "the second pool took its own fee");
    }

    function test_fixedRecipe_deploysTheFixedRateOracle() public {
        address oracle = registry.predictFixedRateOracle(FIXED_RATE);
        ICorkMarketCreator.MarketParams memory params = _fixedParams();

        (MarketId poolId,,) = creator.createNewPool(params);

        assertGt(oracle.code.length, 0, "oracle actually deployed");
        Market memory created = poolManager.market(poolId);
        assertEq(created.rateOracle, oracle, "market adopted the fixed-rate oracle");
        assertEq(created.rateMin, FIXED_RATE, "the constraint the fixed recipe produced");
        assertEq(controller.createCalls(), 1, "one creation");
    }

    /// @dev Step 3's mode mapping: a PRICE recipe asks the registry for a PRICE oracle, a NAV recipe
    ///      for a NAV one. The real registry records each wrapper under its mode, so the recorded
    ///      key is the proof.
    function test_recipeSource_selectsTheOracleMode() public {
        creator.createNewPool(_params());
        assertEq(
            registry.lookupWrapper(address(collateral), address(referenceToken), IMarketRegistry.OracleMode.PRICE),
            address(rateOracle),
            "a PRICE recipe records a PRICE wrapper"
        );
        assertEq(
            registry.lookupWrapper(address(collateral), address(referenceToken), IMarketRegistry.OracleMode.NAV),
            address(0),
            "and no NAV wrapper"
        );

        creator.createNewPool(_impairmentParams());
        assertEq(
            registry.lookupWrapper(address(collateral), address(navReferenceToken), IMarketRegistry.OracleMode.NAV),
            address(rateOracle),
            "a NAV recipe records a NAV wrapper"
        );
        assertEq(controller.createCalls(), 2, "two different pools");
    }

    /// @dev The caller's salt is mixed into the wrapper's CREATE2 salt by the registry, so a call that
    ///      first deploys the pair's wrapper must hand the salt through unchanged.
    function test_oracleSalt_reachesTheRegistry() public {
        creator.createNewPool(_params());
        bytes32 key =
            registry.wrapperKey(address(collateral), address(referenceToken), IMarketRegistry.OracleMode.PRICE);
        assertEq(wrapperFactory.lastWrapperSalt(), keccak256(abi.encode(key, ORACLE_SALT)), "salt forwarded");
    }

    // ─────────────────────────────── Step 4: what the recipe is told ─────────

    function test_verify_isToldWhetherThisCallCreates() public {
        vm.expectCall(address(recipe), _verifyCall(true), 1);
        creator.createNewPool(_params());

        vm.expectCall(address(recipe), _verifyCall(false), 1);
        creator.createNewPool(_params());
    }

    // ─────────────────────────────── Bounds and rejections ───────────────────

    function test_reverts_whenTheCollateralAssetIsNotApproved() public {
        MockERC20 rogue = new MockERC20("ROGUE", 18, false);
        ICorkMarketCreator.MarketParams memory params = _params();
        params.collateralAsset = address(rogue);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        creator.createNewPool(params);
    }

    function test_reverts_whenTheReferenceAssetIsNotApproved() public {
        MockERC20 rogue = new MockERC20("ROGUE", 18, false);
        ICorkMarketCreator.MarketParams memory params = _params();
        params.referenceAsset = address(rogue);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        creator.createNewPool(params);
    }

    /// @dev The FIXED path never hands the pair to the registry, so the creator's own gate is the
    ///      only thing standing between a delisted asset and a canonical pool.
    function test_reverts_whenAFixedRecipePairIsNotApproved() public {
        ICorkMarketCreator.MarketParams memory params = _fixedParams();
        vm.prank(owner);
        registry.removeAssets(one(address(referenceToken)));

        vm.expectCall(address(registry), abi.encodeCall(IMarketRegistry.deployFixedRateOracle, (FIXED_RATE)), 0);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        creator.createNewPool(params);
        assertEq(controller.createCalls(), 0, "a delisted asset must not gain new fixed-rate markets");
    }

    function test_reverts_whenTheRecipeIsNotRegistered() public {
        LiquidityPriceRecipe rogue = new LiquidityPriceRecipe();
        rogue.initialize(IMarketRegistry(address(registry)));
        ICorkMarketCreator.MarketParams memory params = _params();
        params.recipe = address(rogue);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.RecipeNotRegistered.selector, address(rogue)));
        creator.createNewPool(params);
    }

    function test_reverts_whenANonFixedRecipeCarriesARateOverride() public {
        ICorkMarketCreator.MarketParams memory params = _params();
        params.rateOverride = FIXED_RATE;
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.UnexpectedRateOverride.selector, address(recipe)));
        creator.createNewPool(params);
    }

    function test_reverts_whenTheRecipeRejectsTheConstraint() public {
        ICorkMarketCreator.MarketParams memory params = _params();
        params.constraint.rateMax = params.constraint.rateMax + 1;
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.RecipeRejectedConstraint.selector, address(recipe)));
        creator.createNewPool(params);
    }

    function test_reverts_whenTheExpiryOutlivesTheBound() public {
        ICorkMarketCreator.MarketParams memory params = _params();
        params.expiryTimestamp = expiry + 1;
        vm.expectRevert(abi.encodeWithSelector(ICorkMarketCreator.ExpiryOutOfRange.selector, expiry + 1, expiry));
        creator.createNewPool(params);
    }

    function test_expiryCheckedOnlyAtCreation_existingPoolSurvivesATightening() public {
        creator.createNewPool(_params());

        vm.prank(owner);
        registry.setMaxExpiryDuration(1 days);

        (MarketId poolId,,) = creator.createNewPool(_params());
        assertEq(MarketId.unwrap(poolId), MarketId.unwrap(_expectedPoolId()), "existing pool still served");
        assertEq(controller.createCalls(), 1, "and not re-created");
    }

    // -- Fees follow phoenix's rule; this contract adds none of its own ---------------------------

    /// @dev THE FEE RULE IS PHOENIX'S. A fee of 100% or more is refused by the controller with
    ///      phoenix's own `InvalidFees`, four frames down; the creator neither restates the rule nor
    ///      renames the error. The mock controller enforces exactly phoenix's `PoolLib.initialize`
    ///      check so the selector here is the real one.
    function test_swapFeeAtOneHundredPercent_revertsWithPhoenixInvalidFees() public {
        ICorkMarketCreator.MarketParams memory params = _params();
        params.swapFeePercentage = 100e18;
        vm.expectRevert(IErrors.InvalidFees.selector);
        creator.createNewPool(params);
        assertEq(controller.createCalls(), 0, "nothing created");
    }

    function test_unwindSwapFeeAtOneHundredPercent_revertsWithPhoenixInvalidFees() public {
        ICorkMarketCreator.MarketParams memory params = _params();
        params.unwindSwapFeePercentage = 100e18;
        vm.expectRevert(IErrors.InvalidFees.selector);
        creator.createNewPool(params);
        assertEq(controller.createCalls(), 0, "nothing created");
    }

    /// @dev And anything below 100% is creatable: there is no five-percent cap of this repository's
    ///      own any more. Fifty percent, well past the old cap and well under phoenix's bound.
    function test_feeAboveTheOldFivePercentCap_createsTheMarket() public {
        ICorkMarketCreator.MarketParams memory params = _params();
        params.swapFeePercentage = 50e18;
        params.unwindSwapFeePercentage = 100e18 - 1;
        (MarketId poolId,,) = creator.createNewPool(params);
        assertEq(controller.createCalls(), 1, "a fee phoenix accepts is creatable here");
        assertEq(poolManager.market(poolId).swapFeePercentage, 50e18, "the pool took the swap fee");
        assertEq(poolManager.market(poolId).unwindSwapFeePercentage, 100e18 - 1, "and the unwind fee");
    }

    function test_reverts_whenTheRateIsZeroAtCreation() public {
        // The permissive recipe accepts everything, so the creator's OWN zero-rate guard is what
        // fires — same reachability trick the adapter suite uses.
        ICorkMarketCreator.MarketParams memory params = _params();
        params.recipe = address(permissiveRecipe);
        rateOracle.setRate(0);
        vm.expectRevert(ICorkMarketCreator.RateUnavailable.selector);
        creator.createNewPool(params);
    }

    // ─────────────────────────────── Parity with the adapter ─────────────────

    /// @dev THE POINT OF THE CONTRACT. A smart account creates the pool ahead of the fill; the fill
    ///      must then find that pool rather than derive another one: no second creation, the same
    ///      pool id, the same share addresses the caller approved, and the mint lands in it.
    ///      Regression guard now that the fill goes through this contract — see the suite comment.
    function test_parity_createThenFill_theAdapterFindsThePool() public {
        vm.prank(SMART_ACCOUNT);
        (MarketId poolId, address cst, address cpt) = creator.createNewPool(_params());
        assertEq(controller.createCalls(), 1, "the creator created the pool");

        uint256 cstShares = 5_000e18;
        vm.recordLogs();
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, _adapterExtraData());

        assertEq(controller.createCalls(), 1, "the fill must not create a second pool");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertFalse(_sawMarketCreated(vm.getRecordedLogs()), "the fill was a lookup and emitted no creation");
        assertEq(MarketId.unwrap(poolId), MarketId.unwrap(_expectedPoolId()), "same pool id on both paths");
        (address hookCpt, address hookCst) = poolManager.shares(poolId);
        assertEq(cst, hookCst, "the cST the caller approved is the cST the fill moved");
        assertEq(cpt, hookCpt, "same cPT");
        assertEq(poolManager.cst().balanceOf(BOND), cstShares, "the fill minted into the creator's pool");
    }

    /// @dev The reverse direction: a fill created the pool, so a later `createNewPool` is a lookup
    ///      that returns the fill's pool and its shares without creating or emitting anything. The
    ///      fill's creation is this contract's too, so it is the creator's `MarketCreated` that the
    ///      fill emits, with the adapter as the caller — what an indexer keys on.
    function test_parity_fillThenCreate_theCreatorIsALookup() public {
        uint256 cstShares = 5_000e18;
        vm.expectEmit(true, true, true, true, address(creator));
        emit ICorkMarketCreator.MarketCreated(
            _expectedPoolId(),
            address(rateOracle),
            address(collateral),
            address(referenceToken),
            expiry,
            address(recipe),
            SWAP_FEE,
            UNWIND_FEE,
            address(hook)
        );
        lop.callPreInteraction(hook, _askOrder(cstShares), cstShares, 0, _adapterExtraData());
        assertEq(controller.createCalls(), 1, "the fill created the pool");

        vm.recordLogs();
        vm.prank(SMART_ACCOUNT);
        (MarketId poolId, address cst, address cpt) = creator.createNewPool(_params());

        assertEq(controller.createCalls(), 1, "the creator must not create a second pool");
        assertEq(poolManager.marketCount(), 1, "one market registered");
        assertFalse(_sawMarketCreated(vm.getRecordedLogs()), "a lookup emits nothing");
        assertEq(MarketId.unwrap(poolId), MarketId.unwrap(_expectedPoolId()), "the fill's pool id");
        (address hookCpt, address hookCst) = poolManager.shares(poolId);
        assertEq(cst, hookCst, "the fill's cST");
        assertEq(cpt, hookCpt, "the fill's cPT");
    }

    // ─────────────────────────────── Setup ───────────────────────────────────

    function test_initialize_rejectsZeroAddresses() public {
        IPoolManager pm = IPoolManager(address(poolManager));
        IDefaultCorkController ctrl = IDefaultCorkController(address(controller));
        IMarketRegistry reg = IMarketRegistry(address(registry));

        CorkMarketCreator fresh = new CorkMarketCreator();
        vm.expectRevert(ICorkMarketCreator.ZeroAddress.selector);
        fresh.initialize(IPoolManager(address(0)), ctrl, reg);
        vm.expectRevert(ICorkMarketCreator.ZeroAddress.selector);
        fresh.initialize(pm, IDefaultCorkController(address(0)), reg);
        vm.expectRevert(ICorkMarketCreator.ZeroAddress.selector);
        fresh.initialize(pm, ctrl, IMarketRegistry(address(0)));
    }

    function test_initialize_runsOnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        creator.initialize(
            IPoolManager(address(poolManager)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(registry))
        );
    }

    function test_version() public view {
        assertEq(creator.version(), "0.1.0");
    }

    // ─────────────────────────────── Log helpers ──────────────────────────────

    function _sawMarketCreated(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICorkMarketCreator.MarketCreated.selector) return true;
        }
        return false;
    }
}
