// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IMarketRecipe, RecipeSource} from "../src/interfaces/IMarketRecipe.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";
import {ApySpreadImpairmentRecipe} from "../src/recipes/ApySpreadImpairmentRecipe.sol";
import {RegistryFixture} from "./helpers/RegistryFixture.sol";

/// @dev An oracle reporting ZERO. The registry's `FixedRateOracleFactory` cannot produce one — a zero
///      rate reverts `IRateOracle.InvalidRate()` in the constructor — so the only way to hand `resolve`
///      a live rate of zero is a hand-written stand-in. That path is worth pinning because the anchor
///      then comes from the ORACLE, not from the carried bytes, and the recipe must still refuse it.
contract ZeroRateOracle is IRateOracle {
    function rate() external pure returns (uint256) {
        return 0;
    }
}

/// @title ApySpreadImpairmentRecipe suite — the impairment window and the checks around it
/// @notice One recipe, one formula. Given an anchor rate `a`, a market life `d` in seconds and an
///         annual yield spread `p`, the band is `p * d / 365 days` and the window is symmetric,
///         `a - a*band` to `a + a*band`. Daily movement is one day of the annual spread and the
///         accumulated capacity is seven of those days.
///
/// @dev Three things this file is built around.
///
///      1. **Two fixed-point scales, 100x apart.** A PERCENTAGE is the Phoenix convention (`PCT`
///         below, `1e18` = 1%). A RATE is plain 18-decimal fixed point (`ONE` below, `1e18` = 1.0).
///         The spread and the band are percentages; everything `resolve` returns is a rate.
///      2. **Every expectation is re-derived here, from the formula in the contract's own
///         documentation.** {_expected} does the arithmetic independently rather than calling the
///         recipe's `_check`, so a change to the recipe's arithmetic breaks these assertions instead
///         of being mirrored by them.
///      3. **The midpoint is EXACT, and that is why the round trip works.** The floor rounds up and
///         the ceiling rounds down by the same amount — `rateMin = a - floor(a*band/100%)` and
///         `rateMax = a + floor(a*band/100%)` — so the two sum to exactly `2a` and `verify` recovers
///         the anchor without loss. See {testFuzz_apySpread_verifyAcceptsResolveOutput}.
///
///      The registry's `maxExpiryDuration` starts at 30 days, which is shorter than most of the
///      durations this formula is interesting at, so {setUp} raises it to a year. The bound itself is
///      tested against that raised value.
///
///      Every `vm.expectRevert` carries an explicit selector, so a body-less revert (empty returndata)
///      is never mistaken for the specified one.
contract ApySpreadImpairmentRecipeTest is RegistryFixture {
    // ─────────────────────────────── constants ───────────────────────────────

    /// @dev One percent, the percentage scale.
    uint256 internal constant PCT = 1e18;
    /// @dev 100%, the percentage denominator.
    uint256 internal constant HUNDRED_PCT = 100e18;
    /// @dev The rate 1.0, the rate scale. Equal in magnitude to `PCT` and meaning something
    ///      completely different.
    uint256 internal constant ONE = 1e18;

    /// @dev The year the annual spread is quoted against.
    uint256 internal constant YEAR = 365 days;

    /// @dev The registry bound this suite runs under, raised from the 30-day default so a one-year
    ///      market is expressible at all.
    uint256 internal constant MAX_EXPIRY = 365 days;

    // ─────────────────────────────── state ───────────────────────────────────

    address internal owner = makeAddr("owner");

    /// @dev A market pair. The recipe reads nothing about these two beyond naming them in an error.
    address internal ca = makeAddr("collateralAsset");
    address internal ref = makeAddr("referenceAsset");

    ApySpreadImpairmentRecipe internal recipe;

    function setUp() public {
        _deployRegistry(owner);
        recipe = new ApySpreadImpairmentRecipe();
        recipe.initialize(iReg);

        vm.prank(owner);
        reg.setMaxExpiryDuration(MAX_EXPIRY);
    }

    // ─────────────────────────────── helpers ─────────────────────────────────

    /// @dev A live `FixedRateOracle` reporting `rate`, through the registry's permissionless
    ///      entrypoint. Idempotent on purpose: the factory keys an oracle by its rate and a second
    ///      deploy at the same rate is a `CREATE2` collision that reverts with no error data, which a
    ///      fuzz run that happens to pick a repeated rate would hit.
    function _oracleAt(uint256 rate) internal returns (address oracle) {
        oracle = reg.predictFixedRateOracle(rate);
        if (oracle.code.length == 0) oracle = reg.deployFixedRateOracle(rate);
    }

    /// @dev An expiry a full registry bound away, so every duration this suite declares fits inside
    ///      the market's life. Tests about the life rule itself build their own expiry.
    function _expiry() internal view returns (uint256) {
        return block.timestamp + MAX_EXPIRY;
    }

    /// @dev The recipe's `extraData`, built by hand so the tests below can pin that the recipe's
    ///      own `encodeExtraData` agrees with it (see {test_apySpread_encodeExtraData_isAbiEncode}).
    function _data(uint256 anchor, uint256 duration, uint256 spread) internal pure returns (bytes memory) {
        return abi.encode(anchor, duration, spread);
    }

    function _constraint(uint256 rateMin, uint256 rateMax, uint256 perDay, uint256 capacity)
        internal
        pure
        returns (IMarketRegistry.ResolvedConstraint memory c)
    {
        c.rateMin = rateMin;
        c.rateMax = rateMax;
        c.rateChangePerDayMax = perDay;
        c.rateChangeCapacityMax = capacity;
    }

    /// @dev The four limits, re-derived from the formula rather than from the recipe. The floor rounds
    ///      UP and the other three round DOWN — rounding always moves toward the tighter constraint.
    function _expected(uint256 anchor, uint256 duration, uint256 spread)
        internal
        pure
        returns (IMarketRegistry.ResolvedConstraint memory c)
    {
        uint256 band = (spread * duration) / YEAR;
        uint256 perDayPct = (spread * 1 days) / YEAR;

        uint256 floorNumerator = anchor * (HUNDRED_PCT - band);
        c.rateMin = floorNumerator / HUNDRED_PCT + (floorNumerator % HUNDRED_PCT == 0 ? 0 : 1);
        c.rateMax = (anchor * (HUNDRED_PCT + band)) / HUNDRED_PCT;
        c.rateChangePerDayMax = (anchor * perDayPct) / HUNDRED_PCT;
        c.rateChangeCapacityMax = (anchor * (7 * perDayPct)) / HUNDRED_PCT;
    }

    function _assertConstraintEq(
        IMarketRegistry.ResolvedConstraint memory got,
        IMarketRegistry.ResolvedConstraint memory want,
        string memory what
    ) internal pure {
        assertEq(got.rateMin, want.rateMin, string.concat(what, ": floor"));
        assertEq(got.rateMax, want.rateMax, string.concat(what, ": ceiling"));
        assertEq(got.rateChangePerDayMax, want.rateChangePerDayMax, string.concat(what, ": daily allowance"));
        assertEq(got.rateChangeCapacityMax, want.rateChangeCapacityMax, string.concat(what, ": capacity"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. Metadata and initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `NAV` is what tells the adapter where this recipe's rate comes from: it maps to
    ///         `IMarketRegistry.OracleMode.NAV`, so step 3 deploys the pair's net-asset-value wrapper.
    function test_apySpread_source_isNav() public view {
        assertEq(uint8(recipe.source()), uint8(RecipeSource.NAV), "source() must be NAV");
    }

    /// @notice The registry stores nothing about a recipe except its address, so `description()` is
    ///         the entire on-chain account of what approving that address meant.
    function test_apySpread_describesItself() public view {
        assertGt(bytes(recipe.description()).length, 0, "the recipe must describe itself");
    }

    function test_apySpread_version_isInitial() public view {
        assertEq(recipe.version(), "0.1.0", "version() must be the initial release");
    }

    /// @notice The registry reference is part of a deployed instance's public policy surface: "the
    ///         recipe address is the policy" only holds if the address commits to which registry
    ///         governs it — and here it is more than a commitment, because `maxExpiryDuration` is read
    ///         from it on every `resolve`.
    function test_apySpread_registryGetterNamesTheGoverningRegistry() public view {
        assertEq(address(recipe.REGISTRY()), address(reg), "the instance must name its registry");
    }

    function test_apySpread_initialize_zeroRegistry_reverts() public {
        ApySpreadImpairmentRecipe fresh = new ApySpreadImpairmentRecipe();
        vm.expectRevert(ApySpreadImpairmentRecipe.ZeroRegistry.selector);
        fresh.initialize(IMarketRegistry(address(0)));
    }

    /// @notice The registry is set once, in the deployment transaction, and can never be repointed.
    function test_apySpread_initialize_twice_reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        recipe.initialize(iReg);
    }

    /// @notice A reverted initialization leaves the contract uninitialized, so the zero-registry
    ///         rejection above does not brick the instance.
    function test_apySpread_initialize_afterAFailedAttempt_succeeds() public {
        ApySpreadImpairmentRecipe fresh = new ApySpreadImpairmentRecipe();

        vm.expectRevert(ApySpreadImpairmentRecipe.ZeroRegistry.selector);
        fresh.initialize(IMarketRegistry(address(0)));

        fresh.initialize(iReg);
        assertEq(address(fresh.REGISTRY()), address(reg), "the retry must land");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 1b. The payload helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `encodeExtraData` and `decodeExtraData` agree on every value.
    function testFuzz_apySpread_extraData_roundTrips(uint256 anchor, uint256 duration, uint256 spread) public view {
        bytes memory data = recipe.encodeExtraData(anchor, duration, spread);
        assertEq(data.length, recipe.EXTRA_DATA_LENGTH(), "three words");

        (uint256 gotAnchor, uint256 gotDuration, uint256 gotSpread) = recipe.decodeExtraData(data);
        assertEq(gotAnchor, anchor, "anchor");
        assertEq(gotDuration, duration, "duration");
        assertEq(gotSpread, spread, "spread");
    }

    /// @notice The helper is plain `abi.encode` of the three words, in that order, so a caller that
    ///         encodes by hand and one that asks the recipe produce byte-identical payloads.
    function test_apySpread_encodeExtraData_isAbiEncode() public view {
        assertEq(recipe.encodeExtraData(ONE, YEAR, 10 * PCT), abi.encode(ONE, YEAR, 10 * PCT), "typical values");
        assertEq(recipe.encodeExtraData(0, 0, 0), abi.encode(uint256(0), uint256(0), uint256(0)), "zeros");
        assertEq(
            recipe.encodeExtraData(type(uint256).max, 1, 2),
            abi.encode(type(uint256).max, uint256(1), uint256(2)),
            "extremes"
        );
        assertEq(recipe.encodeExtraData(ONE, YEAR, 10 * PCT), _data(ONE, YEAR, 10 * PCT), "the suite's own helper");
    }

    /// @notice `decodeExtraData` refuses what `resolve` refuses, with the same error, so a caller
    ///         checking a payload off-chain sees exactly the rejection `resolve` would give.
    function test_apySpread_decodeExtraData_malformed_revertsLikeResolve() public {
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 0));
        recipe.decodeExtraData("");

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 32));
        recipe.decodeExtraData(abi.encode(ONE));

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 64));
        recipe.decodeExtraData(abi.encode(ONE, YEAR));

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 128));
        recipe.decodeExtraData(abi.encode(ONE, YEAR, 10 * PCT, ONE));

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 3));
        recipe.decodeExtraData(hex"c0ffee");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. resolve — the happy paths
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The whole formula, spelled out at an anchor of 1.0 over a year at a 10% spread: a
    ///         window of [0.9, 1.1], a daily allowance of one 365th of the spread, and seven of those
    ///         as capacity. The literals are what the 100x percentage/rate scale error would break — a
    ///         ceiling of `1.001e18` rather than `1.1e18` is what a misplaced `100e18` looks like.
    function test_apySpread_resolve_derivesTheWindowFromTheOracleRate() public {
        uint256 spread = 10 * PCT;
        address oracle = _oracleAt(ONE);

        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, _data(0, YEAR, spread));

        assertEq(c.rateMin, 0.9e18, "floor is 10% below the anchor");
        assertEq(c.rateMax, 1.1e18, "ceiling is 10% above it");

        uint256 perDayPct = (spread * 1 days) / YEAR; // one day of the annual spread
        assertEq(c.rateChangePerDayMax, (ONE * perDayPct) / HUNDRED_PCT, "daily movement is one day of the spread");
        assertEq(c.rateChangeCapacityMax, 7 * c.rateChangePerDayMax, "capacity is seven of those days");

        _assertConstraintEq(c, _expected(ONE, YEAR, spread), "the independently derived constraint");
    }

    /// @notice The fallback exists for one case: the FIRST order ever written against a pair, signed
    ///         before the adapter's step 3 has deployed the feed wrapper. There is no oracle to read
    ///         then, so the anchor travels in `extraData` instead.
    function test_apySpread_resolve_fallsBackToTheCarriedAnchorWhenNoOracle() public view {
        uint256 anchor = 2 * ONE;
        uint256 spread = 10 * PCT;

        IMarketRegistry.ResolvedConstraint memory c =
            recipe.resolve(ca, ref, address(0), recipe.encodeExtraData(anchor, YEAR, spread));

        assertEq(c.rateMin, 1.8e18, "floor is 10% below the CARRIED anchor");
        assertEq(c.rateMax, 2.2e18, "ceiling is 10% above it");
        _assertConstraintEq(c, _expected(anchor, YEAR, spread), "the independently derived constraint");
    }

    /// @notice The live oracle is the preferred anchor, and the two disagree here on purpose: the
    ///         carried anchor claims 1.0 while the oracle reports 5.0. Every field must come from the
    ///         oracle, and the result must be identical to the one the carried anchor would have
    ///         produced had it said 5.0 in the first place.
    function test_apySpread_resolve_prefersTheOracleOverTheCarriedAnchor() public {
        uint256 carried = ONE;
        uint256 live = 5 * ONE;
        uint256 spread = 10 * PCT;

        address oracle = _oracleAt(live);
        assertEq(IRateOracle(oracle).rate(), live, "fixture precondition: the oracle disagrees with the payload");

        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, _data(carried, YEAR, spread));

        assertEq(c.rateMin, 4.5e18, "floor is 10% below the ORACLE's rate, not the payload's");
        assertEq(c.rateMax, 5.5e18, "and so is the ceiling");
        _assertConstraintEq(c, _expected(live, YEAR, spread), "the oracle's anchor decides every field");

        IMarketRegistry.ResolvedConstraint memory carriedOnly =
            recipe.resolve(ca, ref, address(0), _data(carried, YEAR, spread));
        assertTrue(carriedOnly.rateMax != c.rateMax, "and the carried anchor really would have said otherwise");
    }

    /// @notice The band is the spread PRORATED over the market's life: a full year is the whole
    ///         spread, half a year is half of it. This is the one piece of arithmetic that makes the
    ///         spread an ANNUAL number rather than a flat window width.
    function test_apySpread_resolve_bandIsTheSpreadProratedOverTheLife() public view {
        uint256 spread = 20 * PCT;

        IMarketRegistry.ResolvedConstraint memory year = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, spread));
        assertEq(year.rateMin, 0.8e18, "a one-year market gets the WHOLE 20% spread");
        assertEq(year.rateMax, 1.2e18, "on both sides of the anchor");

        IMarketRegistry.ResolvedConstraint memory half =
            recipe.resolve(ca, ref, address(0), _data(ONE, YEAR / 2, spread));
        assertEq(half.rateMin, 0.9e18, "a half-year market gets half of it");
        assertEq(half.rateMax, 1.1e18, "on both sides of the anchor");

        // The daily allowance is NOT prorated — it is one day of the annual spread either way.
        assertEq(half.rateChangePerDayMax, year.rateChangePerDayMax, "daily movement does not depend on the life");
        assertEq(half.rateChangeCapacityMax, year.rateChangeCapacityMax, "and neither does the capacity");
    }

    /// @notice THERE IS NO WHITELIST OF SPREADS, only a ceiling. An earlier draft restricted the
    ///         spread to a fixed set of buckets; that policy stays removed, so any spread up to and
    ///         including {ApySpreadImpairmentRecipe.MAX_APY_SPREAD_PERCENTAGE} resolves like any
    ///         other as long as the band it produces fits under
    ///         {ApySpreadImpairmentRecipe.MAX_BAND_PERCENTAGE}. Over half a year the band is half the
    ///         spread, so the whole permitted range fits. The predecessor of this test guarded the
    ///         absence of any ceiling; that decision is reversed on purpose, see
    ///         {test_apySpread_resolve_spreadTooHigh_revertsAndTheBoundaryHolds}.
    function test_apySpread_resolve_acceptsAnySpreadUnderTheCapWhenTheBandFits() public view {
        uint256 cap = recipe.MAX_APY_SPREAD_PERCENTAGE();
        assertEq(cap, 100 * PCT, "the ceiling is 100% a year");
        uint256[5] memory spreads = [uint256(1 * PCT), 10 * PCT, 60 * PCT, 99 * PCT, cap];

        for (uint256 i = 0; i < spreads.length; ++i) {
            IMarketRegistry.ResolvedConstraint memory c =
                recipe.resolve(ca, ref, address(0), _data(ONE, YEAR / 2, spreads[i]));
            _assertConstraintEq(c, _expected(ONE, YEAR / 2, spreads[i]), "no bucket policy stands in the way");
            assertGt(c.rateMin, 0, "phoenix's rateMin > 0");
            assertLt(c.rateMin, c.rateMax, "phoenix's STRICT rateMin < rateMax");
        }

        // The 60% case in full, because it is the one the removed bucket policy would have refused.
        IMarketRegistry.ResolvedConstraint memory sixty =
            recipe.resolve(ca, ref, address(0), _data(ONE, YEAR / 2, 60 * PCT));
        assertEq(sixty.rateMin, 0.7e18, "a 60% spread over half a year puts the floor at 0.7");
        assertEq(sixty.rateMax, 1.3e18, "and the ceiling at 1.3");
    }

    /// @notice The recipe holds no state about a market, so the same instance answers for any pair and
    ///         any numbers — the policy is the formula, not a stored record.
    function test_apySpread_resolve_isPurelyAFunctionOfItsArguments() public {
        IMarketRegistry.ResolvedConstraint memory a = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, 10 * PCT));
        IMarketRegistry.ResolvedConstraint memory b =
            recipe.resolve(makeAddr("otherCa"), makeAddr("otherRef"), address(0), _data(ONE, YEAR, 10 * PCT));
        _assertConstraintEq(a, b, "the pair addresses are not read");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. resolve — the rejections
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `extraData` is exactly three words. Anything else is an order built against a
    ///         different recipe, and guessing at it is how a market gets created with the wrong
    ///         numbers.
    function test_apySpread_resolve_malformedExtraData_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 0));
        recipe.resolve(ca, ref, address(0), "");

        bytes memory oneWord = abi.encode(ONE);
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 32));
        recipe.resolve(ca, ref, address(0), oneWord);

        bytes memory twoWords = abi.encode(ONE, YEAR);
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 64));
        recipe.resolve(ca, ref, address(0), twoWords);

        bytes memory fourWords = abi.encode(ONE, YEAR, 10 * PCT, ONE);
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 128));
        recipe.resolve(ca, ref, address(0), fourWords);
    }

    /// @notice The length check comes BEFORE the oracle is read, so a live oracle does not excuse a
    ///         malformed payload — unlike the liquidity recipes, this one needs the payload's other two
    ///         words whatever the anchor's provenance.
    function test_apySpread_resolve_malformedExtraData_revertsEvenWithALiveOracle() public {
        address oracle = _oracleAt(ONE);
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.MalformedExtraData.selector, 0));
        recipe.resolve(ca, ref, oracle, "");
    }

    /// @notice Both routes to a zero anchor, because they come from different places: the carried word
    ///         on the fallback path, and a live oracle reporting zero on the normal one.
    function test_apySpread_resolve_zeroAnchor_reverts() public {
        vm.expectRevert(ApySpreadImpairmentRecipe.ZeroAnchorRate.selector);
        recipe.resolve(ca, ref, address(0), _data(0, YEAR, 10 * PCT));

        address zeroOracle = address(new ZeroRateOracle());
        assertEq(IRateOracle(zeroOracle).rate(), 0, "fixture precondition: the oracle reports zero");

        // The carried anchor is healthy and is still not consulted — the oracle wins, then fails.
        vm.expectRevert(ApySpreadImpairmentRecipe.ZeroAnchorRate.selector);
        recipe.resolve(ca, ref, zeroOracle, _data(ONE, YEAR, 10 * PCT));
    }

    function test_apySpread_resolve_zeroDuration_reverts() public {
        vm.expectRevert(ApySpreadImpairmentRecipe.ZeroDuration.selector);
        recipe.resolve(ca, ref, address(0), _data(ONE, 0, 10 * PCT));
    }

    /// @notice The registry's creation bound is the recipe's bound too, and the boundary is inclusive:
    ///         a market lasting exactly `maxExpiryDuration` is creatable, one second more is not.
    function test_apySpread_resolve_durationTooLong_revertsAndTheBoundaryHolds() public {
        assertEq(iReg.maxExpiryDuration(), MAX_EXPIRY, "fixture precondition");

        vm.expectRevert(
            abi.encodeWithSelector(ApySpreadImpairmentRecipe.DurationTooLong.selector, MAX_EXPIRY + 1, MAX_EXPIRY)
        );
        recipe.resolve(ca, ref, address(0), _data(ONE, MAX_EXPIRY + 1, 10 * PCT));

        IMarketRegistry.ResolvedConstraint memory c =
            recipe.resolve(ca, ref, address(0), _data(ONE, MAX_EXPIRY, 10 * PCT));
        _assertConstraintEq(c, _expected(ONE, MAX_EXPIRY, 10 * PCT), "exactly at the bound is fine");
    }

    /// @notice The bound follows the registry rather than a copy of it: lowering `maxExpiryDuration`
    ///         retires the longer markets immediately, and the error names the CURRENT bound.
    function test_apySpread_resolve_durationBoundFollowsTheRegistry() public {
        uint256 duration = 60 days;
        recipe.resolve(ca, ref, address(0), _data(ONE, duration, 10 * PCT)); // fine at a year's bound

        vm.prank(owner);
        reg.setMaxExpiryDuration(30 days);

        vm.expectRevert(
            abi.encodeWithSelector(ApySpreadImpairmentRecipe.DurationTooLong.selector, duration, uint256(30 days))
        );
        recipe.resolve(ca, ref, address(0), _data(ONE, duration, 10 * PCT));
    }

    /// @notice The band is capped at 50%, which keeps the floor at no less than half the anchor. The
    ///         predecessor of this rule only refused a band at or past 100%, where the floor lands on
    ///         zero. Over a full year the band IS the spread, which makes the boundary exact: a 50%
    ///         spread is allowed and a 50%-plus-one-wei spread is refused, with the error naming both
    ///         the band and the cap.
    function test_apySpread_resolve_bandTooWide_revertsAndTheBoundaryHolds() public {
        uint256 cap = recipe.MAX_BAND_PERCENTAGE();
        assertEq(cap, 50 * PCT, "the band ceiling is 50%");

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.BandTooWide.selector, cap + 1, cap));
        recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, cap + 1));

        // The spread ceiling itself, over a full year: a band of 100%.
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.BandTooWide.selector, HUNDRED_PCT, cap));
        recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, HUNDRED_PCT));

        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, cap));
        _assertConstraintEq(c, _expected(ONE, YEAR, cap), "exactly at the cap still resolves");
        assertEq(c.rateMin, 0.5e18, "and the floor is half the anchor");
        assertEq(c.rateMax, 1.5e18, "with the ceiling mirrored above it");
    }

    /// @notice THE SPREAD IS BOUNDED ON ITS OWN, not only through the band. The band is the product
    ///         of the spread and the life, so with the spread free an author could trade a short life
    ///         for a huge spread and land on the same window. The ceiling is 100% a year, inclusive:
    ///         100% over half a year is a 50% band and resolves; one wei more is refused before the
    ///         band is even computed, so the error names the spread and the cap.
    function test_apySpread_resolve_spreadTooHigh_revertsAndTheBoundaryHolds() public {
        uint256 cap = recipe.MAX_APY_SPREAD_PERCENTAGE();

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.SpreadTooHigh.selector, cap + 1, cap));
        recipe.resolve(ca, ref, address(0), _data(ONE, YEAR / 2, cap + 1));

        // A short life does not rescue an oversized spread: the band would be tiny, and it is still refused.
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.SpreadTooHigh.selector, 500 * PCT, cap));
        recipe.resolve(ca, ref, address(0), _data(ONE, 1 days, 500 * PCT));

        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR / 2, cap));
        _assertConstraintEq(c, _expected(ONE, YEAR / 2, cap), "exactly at the cap still resolves");
        assertEq(c.rateMin, 0.5e18, "100% a year over half a year is a 50% band");
    }

    /// @notice The rules are checked in a fixed order and the spread ceiling comes before the band
    ///         ceiling, so an author who breaks both is told about the spread.
    function test_apySpread_resolve_spreadTooHigh_isReportedBeforeBandTooWide() public {
        uint256 cap = recipe.MAX_APY_SPREAD_PERCENTAGE();
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.SpreadTooHigh.selector, 2 * cap, cap));
        recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, 2 * cap));
    }

    /// @notice `WindowCollapsed` IS reachable, and this is the shape that reaches it: a dust anchor.
    ///         The floor rounds up and the ceiling rounds down, so at an anchor of 1 wei any band
    ///         smaller than the anchor itself collapses both onto the same value — and phoenix's
    ///         `rateMin < rateMax` is strict, so that market cannot be created. The recipe names the
    ///         rejection here rather than letting it surface several frames inside the pool manager.
    function test_apySpread_resolve_windowCollapsed_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.WindowCollapsed.selector, 1, 1));
        recipe.resolve(ca, ref, address(0), _data(1, 1 days, 1 * PCT));

        // The neighbouring case that does NOT collapse, so the test above pins the collapse and not
        // merely a small anchor: at a large enough anchor the same band separates the two bounds.
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, address(0), _data(1e18, 1 days, 1 * PCT));
        assertLt(c.rateMin, c.rateMax, "the same band widens at a real anchor");
    }

    /// @notice A zero address is the only thing that selects the fallback. An address that simply is
    ///         not a live oracle is a caller error: the `rate()` call reverts and the carried anchor is
    ///         never consulted. Asserted through a low-level call because the failure is solc's own
    ///         code-length check, which carries no selector to expect.
    function test_apySpread_resolve_addressWithNoCodeIsNotAFallback() public {
        address junk = makeAddr("junkOracle");
        assertEq(junk.code.length, 0, "fixture precondition: the label must hold no code");

        (bool ok,) = address(recipe)
            .staticcall(abi.encodeCall(IMarketRecipe.resolve, (ca, ref, junk, _data(ONE, YEAR, 10 * PCT))));
        assertFalse(ok, "a non-zero oracle is read, not second-guessed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. verify
    // ═══════════════════════════════════════════════════════════════════════════

    function test_apySpread_verify_acceptsItsOwnResolveOutput() public {
        bytes memory data = recipe.encodeExtraData(0, YEAR, 10 * PCT);
        address oracle = _oracleAt(ONE);

        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, data);
        assertTrue(recipe.verify(ca, ref, oracle, _expiry(), true, c, data), "resolve's own output must verify");
    }

    /// @notice `verify` returns FALSE for a payload it cannot use, where `resolve` REVERTS. The
    ///         asymmetry is the interface's rule, not an inconsistency: `resolve` is called off-chain
    ///         by the agent building the order, so a loud failure is a bug report at the moment the
    ///         mistake is made; `verify` runs on-chain and the adapter owns the revert selector.
    function test_apySpread_verify_malformedExtraData_returnsFalse() public {
        bytes memory data = _data(0, YEAR, 10 * PCT);
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, data);

        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), true, c, ""), "empty");
        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), true, c, abi.encode(ONE)), "one word");
        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), true, c, abi.encode(ONE, YEAR)), "two words");
        assertFalse(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, abi.encode(ONE, YEAR, 10 * PCT, ONE)), "four words"
        );
        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), true, c, hex"c0ffee"), "not a word at all");
    }

    /// @notice The shape is checked on all FOUR fields, so tampering with any one of them is refused
    ///         even when the other three and the live rate are impeccable. One wei is enough.
    function test_apySpread_verify_rejectsATamperedField() public {
        bytes memory data = _data(0, YEAR, 10 * PCT);
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, data);
        assertTrue(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, data), "precondition: the untouched constraint verifies"
        );

        // The window fields move the recovered midpoint too, so each is nudged by two wei on one side
        // only — enough to break the shape without any chance of the rounding absorbing it.
        assertFalse(
            recipe.verify(
                ca,
                ref,
                oracle,
                _expiry(),
                true,
                _constraint(c.rateMin - 2, c.rateMax, c.rateChangePerDayMax, c.rateChangeCapacityMax),
                data
            ),
            "widened floor"
        );
        assertFalse(
            recipe.verify(
                ca,
                ref,
                oracle,
                _expiry(),
                true,
                _constraint(c.rateMin, c.rateMax + 2, c.rateChangePerDayMax, c.rateChangeCapacityMax),
                data
            ),
            "widened ceiling"
        );
        assertFalse(
            recipe.verify(
                ca,
                ref,
                oracle,
                _expiry(),
                true,
                _constraint(c.rateMin, c.rateMax, c.rateChangePerDayMax + 1, c.rateChangeCapacityMax),
                data
            ),
            "widened daily allowance"
        );
        assertFalse(
            recipe.verify(
                ca,
                ref,
                oracle,
                _expiry(),
                true,
                _constraint(c.rateMin, c.rateMax, c.rateChangePerDayMax, c.rateChangeCapacityMax + 1),
                data
            ),
            "widened capacity"
        );
    }

    /// @notice The constraint and the payload have to describe the SAME market. `verify` rebuilds the
    ///         four limits from the payload's duration and spread, so an order that carries a
    ///         constraint built from different numbers is refused however well-formed both halves are.
    function test_apySpread_verify_rejectsAPayloadThatDoesNotMatchTheConstraint() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, _data(0, YEAR, 10 * PCT));

        assertFalse(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(0, YEAR / 2, 10 * PCT)), "a different duration"
        );
        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(0, YEAR, 20 * PCT)), "a different spread");
        assertTrue(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(0, YEAR, 10 * PCT)),
            "and the matching pair still passes"
        );
    }

    /// @notice The carried anchor is NOT trusted and NOT read: `verify` recovers the anchor from the
    ///         window's midpoint instead, so the first word of the payload can say anything at all.
    function test_apySpread_verify_ignoresTheCarriedAnchor() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, _data(0, YEAR, 10 * PCT));

        assertTrue(recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(0, YEAR, 10 * PCT)), "a zero anchor");
        assertTrue(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(ONE, YEAR, 10 * PCT)), "the anchor it was built at"
        );
        assertTrue(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(1000 * ONE, YEAR, 10 * PCT)), "one it was not"
        );
    }

    /// @notice THE MIDPOINT IS THE ANCHOR, and this is what that buys. Both halves below are
    ///         individually well-formed constraints this recipe really produced, and the live rate sits
    ///         inside the mixed window, so only the anchor recovery can catch the mixture: the midpoint
    ///         says the anchor is 2.0 while the allowances were built at 1.0.
    function test_apySpread_verify_rejectsAConstraintWhoseMidpointIsNotItsAnchor() public {
        bytes memory data = _data(0, YEAR, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory low = recipe.resolve(ca, ref, _oracleAt(ONE), data);
        IMarketRegistry.ResolvedConstraint memory high = recipe.resolve(ca, ref, _oracleAt(2 * ONE), data);

        assertTrue(
            recipe.verify(ca, ref, _oracleAt(ONE), _expiry(), true, low, data), "the 1.0 constraint alone verifies"
        );
        assertTrue(
            recipe.verify(ca, ref, _oracleAt(2 * ONE), _expiry(), true, high, data), "the 2.0 constraint alone verifies"
        );

        IMarketRegistry.ResolvedConstraint memory mixed =
            _constraint(high.rateMin, high.rateMax, low.rateChangePerDayMax, low.rateChangeCapacityMax);
        assertFalse(
            recipe.verify(ca, ref, _oracleAt(2 * ONE), _expiry(), true, mixed, data),
            "the 2.0 window with the 1.0 allowances does not"
        );
    }

    /// @notice Phoenix's two constraint requirements, plus the recipe's own, checked here so a
    ///         structurally impossible constraint is diagnosed at the step that owns it.
    function test_apySpread_verify_rejectsAStructurallyImpossibleConstraint() public {
        bytes memory data = _data(0, YEAR, 10 * PCT);
        address oracle = _oracleAt(ONE);

        assertFalse(
            recipe.verify(ca, ref, oracle, _expiry(), true, _constraint(2 * ONE, ONE, 0, 0), data), "inverted window"
        );
        assertFalse(
            recipe.verify(ca, ref, oracle, _expiry(), true, _constraint(0, 0, 0, 0), data), "a zero-anchor window"
        );
        assertFalse(
            recipe.verify(ca, ref, oracle, _expiry(), true, _constraint(ONE, ONE, 0, 0), data), "single-point window"
        );
    }

    /// @notice THE REGISTRY BOUND IS A CREATION-TIME RULE, AND `verify` DOES NOT APPLY IT. The adapter
    ///         checks `maxExpiryDuration` once, on the fill that creates the pool, and deliberately not
    ///         afterwards: a market is permanent, so re-checking would only strand the honest orders
    ///         already resting against it. The constraint is part of the pool id, so a stranded order
    ///         cannot even be re-signed under the new bound without pointing at a different market.
    ///         `verify` therefore reads nothing from the registry; `resolve`, the order-building path,
    ///         still rejects loudly (see {test_apySpread_resolve_durationBoundFollowsTheRegistry}).
    function test_apySpread_verify_ignoresTheRegistryBound() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, _data(0, YEAR, 10 * PCT));
        assertTrue(recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(0, YEAR, 10 * PCT)), "precondition");

        vm.prank(owner);
        reg.setMaxExpiryDuration(30 days);
        assertLt(iReg.maxExpiryDuration(), YEAR, "fixture precondition: the carried duration now exceeds the bound");

        assertTrue(
            recipe.verify(ca, ref, oracle, _expiry(), true, c, _data(0, YEAR, 10 * PCT)), "the same order keeps filling"
        );

        // Control: the order-building path is where the tightened bound bites.
        vm.expectRevert(
            abi.encodeWithSelector(ApySpreadImpairmentRecipe.DurationTooLong.selector, YEAR, uint256(30 days))
        );
        recipe.resolve(ca, ref, oracle, _data(0, YEAR, 10 * PCT));
    }

    /// @notice The interface's rule about reverting: `false` means "this constraint is unacceptable",
    ///         a revert means "I cannot answer". `verify` takes the rate from nowhere but the oracle,
    ///         so with no oracle there is no verdict to give — and the selector is its own, so "your
    ///         oracle is missing" never reads as "your constraint is wrong".
    ///
    ///         Unreachable through the adapter, which produces the oracle at step 3 before this runs.
    function test_apySpread_verify_zeroOracle_reverts() public {
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, 10 * PCT));

        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.RateOracleNotDeployed.selector, ca, ref));
        recipe.verify(ca, ref, address(0), _expiry(), true, c, _data(ONE, YEAR, 10 * PCT));
    }

    /// @notice The malformed-payload check runs BEFORE the missing-oracle revert, so a caller who gets
    ///         both wrong is told `false` rather than handed the oracle selector. Pinned because the
    ///         order of those two lines is the difference between a verdict and a revert.
    function test_apySpread_verify_malformedPayloadWinsOverTheMissingOracle() public view {
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, 10 * PCT));
        assertFalse(recipe.verify(ca, ref, address(0), _expiry(), true, c, ""), "length first, oracle second");
    }

    /// @notice THE LIVE RATE MUST SIT STRICTLY INSIDE THE WINDOW, at both ends. This is what makes the
    ///         impairment window mean something: an order stops filling the moment the market's own
    ///         rate reaches the edge of the band it was written against.
    function test_apySpread_verify_liveRateMustSitStrictlyInsideTheWindow() public {
        bytes memory data = _data(0, YEAR, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, _oracleAt(ONE), data);
        assertEq(c.rateMin, 0.9e18, "precondition: the window is [0.9, 1.1]");
        assertEq(c.rateMax, 1.1e18, "precondition: the window is [0.9, 1.1]");

        assertTrue(
            recipe.verify(ca, ref, _oracleAt(c.rateMin + 1), _expiry(), true, c, data), "one wei above the floor"
        );
        assertTrue(recipe.verify(ca, ref, _oracleAt(ONE), _expiry(), true, c, data), "at the anchor");
        assertTrue(
            recipe.verify(ca, ref, _oracleAt(c.rateMax - 1), _expiry(), true, c, data), "one wei below the ceiling"
        );

        assertFalse(
            recipe.verify(ca, ref, _oracleAt(c.rateMin), _expiry(), true, c, data), "exactly on the floor: excluded"
        );
        assertFalse(
            recipe.verify(ca, ref, _oracleAt(c.rateMax), _expiry(), true, c, data), "exactly on the ceiling: excluded"
        );
        assertFalse(
            recipe.verify(ca, ref, _oracleAt(c.rateMin - 1), _expiry(), true, c, data), "one wei below the floor"
        );
        assertFalse(
            recipe.verify(ca, ref, _oracleAt(c.rateMax + 1), _expiry(), true, c, data), "one wei above the ceiling"
        );
        assertFalse(recipe.verify(ca, ref, _oracleAt(1000 * ONE), _expiry(), true, c, data), "a thousand times over");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. verify — the market's life and the two dials
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice THE BAND IS SIZED BY THE MARKET'S OWN LIFE, and this is the attack it closes. The band
    ///         is linear in the declared `durationSeconds`, and before this rule nothing tied that
    ///         number to the market: a one-hour market could carry the band of a 30-day one, 720 times
    ///         wider than the policy allows. On the fill that creates the pool, `verify` is handed the
    ///         market's expiry and refuses a declared life longer than the life that remains.
    function test_apySpread_verify_creating_refusesADeclaredLifeLongerThanTheMarkets() public {
        address oracle = _oracleAt(ONE);
        bytes memory thirtyDays = _data(0, 30 days, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, thirtyDays);

        uint256 oneHourMarket = block.timestamp + 1 hours;
        assertFalse(
            recipe.verify(ca, ref, oracle, oneHourMarket, true, c, thirtyDays), "a 30-day band on a 1-hour market"
        );

        // Control: the honest payload for that market, declaring exactly the hour it lives.
        bytes memory oneHour = _data(0, 1 hours, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory honest = recipe.resolve(ca, ref, oracle, oneHour);
        assertTrue(recipe.verify(ca, ref, oracle, oneHourMarket, true, honest, oneHour), "the honest band is accepted");
        assertLt(honest.rateMax - honest.rateMin, c.rateMax - c.rateMin, "and it really is the narrower window");
    }

    /// @notice The life bound is INCLUSIVE and exact: a declared life equal to the market's remaining
    ///         life is accepted, one second more is refused.
    function test_apySpread_verify_creating_lifeBoundaryIsExact() public {
        address oracle = _oracleAt(ONE);
        uint256 life = 30 days;
        uint256 expiry = block.timestamp + life;

        bytes memory exact = _data(0, life, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, exact);
        assertTrue(recipe.verify(ca, ref, oracle, expiry, true, c, exact), "exactly the market's life");

        bytes memory oneMore = _data(0, life + 1, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory d = recipe.resolve(ca, ref, oracle, oneMore);
        assertFalse(recipe.verify(ca, ref, oracle, expiry, true, d, oneMore), "one second past it");
    }

    /// @notice An expired market has no life left, so no declared life fits: the creating fill is
    ///         refused whether the expiry is in the past or is this very second.
    function test_apySpread_verify_creating_refusesAnExpiredMarket() public {
        address oracle = _oracleAt(ONE);
        bytes memory data = _data(0, 1, 10 * PCT); // the shortest life there is
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, data);

        vm.warp(1_000_000);
        assertFalse(recipe.verify(ca, ref, oracle, block.timestamp, true, c, data), "expiring this second");
        assertFalse(recipe.verify(ca, ref, oracle, block.timestamp - 1, true, c, data), "already expired");
        assertTrue(recipe.verify(ca, ref, oracle, block.timestamp + 1, true, c, data), "control: one second of life");
    }

    /// @notice THE LIFE RULE IS CREATION-ONLY, and here is why it cannot be anything else. The
    ///         remaining life shrinks every block while the signed duration is fixed, so re-checking
    ///         on every fill would strand every resting order one block after creation. A tolerance
    ///         only moves that deadline. The constraint is part of the pool id, so nothing about the
    ///         declared life can change after creation anyway; the only party that knows creation
    ///         happened is the adapter, which is why it passes the flag.
    function test_apySpread_verify_laterFill_doesNotRecheckTheLife() public {
        address oracle = _oracleAt(ONE);
        bytes memory data = _data(0, 30 days, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, data);

        uint256 expiry = block.timestamp + 30 days;
        assertTrue(recipe.verify(ca, ref, oracle, expiry, true, c, data), "created with exactly its life");

        vm.warp(block.timestamp + 1);
        assertFalse(recipe.verify(ca, ref, oracle, expiry, true, c, data), "one block later a CREATING fill would fail");
        assertTrue(recipe.verify(ca, ref, oracle, expiry, false, c, data), "but a later fill into the pool does not");

        vm.warp(expiry - 1);
        assertTrue(recipe.verify(ca, ref, oracle, expiry, false, c, data), "right up to the market's last second");
    }

    /// @notice A later fill applies no life bound, so a garbage duration reaches the band arithmetic.
    ///         It must come back as a plain `false`, the same answer the creating fill gives, not as
    ///         an arithmetic panic: through the adapter that would surface as `Panic(0x11)` instead of
    ///         `RecipeRejectedConstraint`.
    function test_apySpread_verify_laterFill_garbageDurationReturnsFalse() public {
        address oracle = _oracleAt(ONE);
        bytes memory honest = _data(0, 30 days, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, honest);

        // Large enough that `spread * duration` does not fit in 256 bits. It is refused as a life no
        // spread could ever fit under the band cap, before the product is formed.
        bytes memory garbage = _data(0, type(uint256).max, 10 * PCT);
        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), false, c, garbage), "a later fill refuses it quietly");
        assertFalse(recipe.verify(ca, ref, oracle, _expiry(), true, c, garbage), "and the creating fill agrees");
    }

    /// @notice THE SECOND DIAL. `(30 days, 12%)` and `(1 day, 360%)` produce the same band, so
    ///         binding the life alone would only push an author toward the spread. The spread ceiling
    ///         is what stops that: the first pair is honest and verifies on a 30-day market, the second
    ///         is refused by `verify` and reverts `SpreadTooHigh` in `resolve`.
    function test_apySpread_sameBandFromTwoPairs_theHighSpreadOneIsRefused() public {
        address oracle = _oracleAt(ONE);
        uint256 band = (12 * PCT * 30 days) / YEAR;
        assertEq((360 * PCT * 1 days) / YEAR, band, "fixture precondition: the two pairs give the same band");

        bytes memory honest = _data(0, 30 days, 12 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, honest);
        assertTrue(recipe.verify(ca, ref, oracle, block.timestamp + 30 days, true, c, honest), "the honest pair");

        bytes memory inflated = _data(0, 1 days, 360 * PCT);
        vm.expectRevert(abi.encodeWithSelector(ApySpreadImpairmentRecipe.SpreadTooHigh.selector, 360 * PCT, 100 * PCT));
        recipe.resolve(ca, ref, oracle, inflated);

        // The constraint is the same bytes either way; only the payload differs, and verify refuses it
        // on a market long enough for the declared day, so the refusal is the spread and not the life.
        assertFalse(recipe.verify(ca, ref, oracle, block.timestamp + 30 days, true, c, inflated), "the inflated pair");
        assertFalse(recipe.verify(ca, ref, oracle, block.timestamp + 30 days, false, c, inflated), "on any fill");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. Fuzz
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice THE ROUND TRIP, and the single most valuable property in this file: whatever `resolve`
    ///         produces, `verify` accepts for the same inputs. It holds only because the two roundings
    ///         are symmetric — the floor loses exactly what the ceiling gains — so the midpoint
    ///         recovers the anchor with no loss at all. The oracle is parked at the anchor, which is
    ///         strictly inside the window at every set of numbers this fuzzes over.
    function testFuzz_apySpread_verifyAcceptsResolveOutput(uint256 anchor, uint256 duration, uint256 spread) public {
        anchor = bound(anchor, 1e12, 1e30); // large enough that the band is at least one wei wide
        duration = bound(duration, 1 days, MAX_EXPIRY);
        spread = bound(spread, 1 * PCT, 50 * PCT); // at most a year at 50%, so the band stays under 100%

        bytes memory data = _data(0, duration, spread);
        address oracle = _oracleAt(anchor);

        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, oracle, data);
        _assertConstraintEq(c, _expected(anchor, duration, spread), "resolve follows the formula");
        assertEq((c.rateMin + c.rateMax) / 2, anchor, "the midpoint IS the anchor, exactly");

        assertTrue(recipe.verify(ca, ref, oracle, _expiry(), true, c, data), "verify must accept what resolve produced");
    }

    /// @notice Phoenix's two rules, fuzzed: no constraint this recipe returns can have a zero floor or
    ///         a floor at or above the ceiling. The bounds keep the fuzzer inside the territory
    ///         `resolve` accepts — the collapse it rejects instead is pinned by
    ///         {test_apySpread_resolve_windowCollapsed_reverts}.
    function testFuzz_apySpread_resolveNeverReturnsACollapsedWindow(uint256 anchor, uint256 duration, uint256 spread)
        public
        view
    {
        anchor = bound(anchor, 1e6, 1e30);
        duration = bound(duration, 1 days, MAX_EXPIRY);
        spread = bound(spread, 1 * PCT, 50 * PCT);

        IMarketRegistry.ResolvedConstraint memory c =
            recipe.resolve(ca, ref, address(0), _data(anchor, duration, spread));

        assertGt(c.rateMin, 0, "phoenix's rateMin > 0");
        assertLt(c.rateMin, c.rateMax, "phoenix's STRICT rateMin < rateMax");
        assertLe(
            c.rateChangeCapacityMax, 7 * c.rateChangePerDayMax + 7, "capacity is seven days, give or take rounding"
        );
    }

    /// @notice The live-rate check, fuzzed against a constraint the recipe really produced: the verdict
    ///         is EXACTLY whether the current rate sits strictly inside the window, at every rate.
    function testFuzz_apySpread_verifyIsWindowContainment(uint256 live) public {
        live = bound(live, 1, 1e30); // 0 is not a deployable rate — FixedRateOracle refuses it

        bytes memory data = _data(0, YEAR, 10 * PCT);
        IMarketRegistry.ResolvedConstraint memory c = recipe.resolve(ca, ref, address(0), _data(ONE, YEAR, 10 * PCT));

        assertEq(
            recipe.verify(ca, ref, _oracleAt(live), _expiry(), true, c, data),
            live > c.rateMin && live < c.rateMax,
            "the verdict IS window containment, at every live rate"
        );
    }
}
