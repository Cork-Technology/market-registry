// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMarketRecipe, RecipeSource} from "../src/interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";
import {BaseLiquidityRecipe} from "../src/recipes/BaseLiquidityRecipe.sol";
import {LiquidityPriceRecipe} from "../src/recipes/LiquidityPriceRecipe.sol";
import {LiquidityNavRecipe} from "../src/recipes/LiquidityNavRecipe.sol";
import {FixedRateRecipe} from "../src/recipes/FixedRateRecipe.sol";
import {RegistryFixture} from "./helpers/RegistryFixture.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @dev An oracle that looks exactly like the real thing and is not one: same `IRateOracle` surface,
///      same immutable rate, deployed with plain `CREATE` so it does NOT sit at the address
///      `FixedRateOracleFactory` would have put it at. `FixedRateRecipe.verify` must refuse it —
///      being at the factory's deterministic address is the whole proof, not reporting a plausible
///      number.
contract StandaloneFixedOracle is IRateOracle {
    uint256 private immutable _RATE;

    constructor(uint256 rate_) {
        _RATE = rate_;
    }

    function rate() external view returns (uint256) {
        return _RATE;
    }
}

/// @dev A contract whose `verify` WRITES STORAGE, used to prove the `view` guarantee is real.
/// @notice Deliberately does NOT inherit `IMarketRecipe`. It cannot: the interface declares `verify`
///         as `view`, so a contract implementing it could not compile with a body that writes. That is
///         exactly the point — the compiler stops an HONEST implementer, and this mock is what a
///         dishonest one deployed from hand-written assembly or a different source file would look
///         like. The four function SIGNATURES are byte-identical to the interface's, so the selectors
///         match and `abi.encodeCall(IMarketRecipe.verify, ...)` reaches this code.
contract StateWritingRecipe {
    /// @notice Counts how many times `verify` managed to write.
    uint256 public writeCount;

    function source() external view returns (RecipeSource) {
        return RecipeSource.PRICE;
    }

    function description() external view returns (string memory) {
        return "hostile: writes storage during verify";
    }

    function resolve(address, address, address, bytes calldata)
        external
        pure
        returns (IMarketRegistry.ResolvedConstraint memory constraint)
    {
        return constraint;
    }

    /// @dev NOT `view`. A single `SSTORE`, which is all it takes: `STATICCALL` makes any state write an
    ///      exceptional halt, so this whole function is unreachable through the adapter's call shape.
    function verify(
        address,
        address,
        address,
        uint256,
        bool,
        IMarketRegistry.ResolvedConstraint calldata,
        bytes calldata
    ) external returns (bool) {
        writeCount += 1;
        return true;
    }
}

/// @title Recipe suite — the registry's membership set plus the two concrete recipe contracts
/// @notice Three subjects, in this order:
///
///         1. `MarketRegistryRecipe` — the registry's ENTIRE involvement with recipes is a membership
///            set of contract addresses: `addRecipe`, `removeRecipe`, `isRecipe`, `getRecipe`,
///            `getRecipes`. It stores no bands, no formula and no metadata, and it never calls a
///            recipe.
///         2. `FixedRateRecipe` — a market whose rate is the immutable `FixedRateOracle` the order
///            names. The rate is NOT a constructor argument any more; see
///            {test_fixedRate_verify_rejectsAnOracleTheFactoryDidNotDeploy} for what pins it instead.
///         3. `LiquidityPriceRecipe` — the widest window the pool manager will accept, from compile-time
///            constants. The one that works end to end.
///
/// @dev This file was rewritten wholesale. Its predecessor tested a store that no longer exists: a
///      recipe used to be a `ConstraintBands` RECORD stored in the registry and keyed by a MODE
///      STRING, resolved by an external `reg.applyBands(mode, rate)`. All of that is gone. A recipe is
///      now a CONTRACT keyed by its own address, and the band arithmetic moved to
///      `MarketRegistryLib.applyBands`, a `pure` helper recipes import.
///
///      `LiquidityPriceRecipe` was itself once `BandsRecipe`, which took four percentages as constructor
///      arguments and required the live rate to sit inside the window on every fill. Both are gone:
///      the percentages are constants now, and the live-rate check was removed. Tests that pinned
///      either were rewritten to pin the CURRENT behaviour, including the tests that now assert the
///      live rate is ignored — see {test_liquidity_verify_ignoresTheLiveRateEntirely}, which is the
///      inverse of what its predecessor asserted, on purpose.
///
///      Two fixed-point scales are in play and they differ by 100x — that hazard survived the rewrite
///      unchanged and is still what these numbers guard. A PERCENTAGE is the Phoenix convention
///      (`PCT` below, `1e18` = 1%). A RATE is plain 18-decimal fixed point (`ONE` below, `1e18` = 1.0).
///      Percentages are the recipe's constants; rates come out of `resolve`.
///
///      Every `vm.expectRevert` carries an explicit selector, so a body-less revert (empty returndata)
///      is never mistaken for the specified one.
contract RecipeTest is RegistryFixture {
    // ─────────────────────────────── constants ───────────────────────────────

    /// @dev Taken from the interface rather than restated as an ordinal, so a change to the enum
    ///      reaches this suite instead of silently disagreeing with it.
    IMarketRegistry.Namespace internal constant NS_RECIPE = IMarketRegistry.Namespace.Recipe;

    /// @dev One percent, the percentage scale.
    uint256 internal constant PCT = 1e18;
    /// @dev 100%, the percentage denominator.
    uint256 internal constant HUNDRED_PCT = 100e18;
    /// @dev The rate 1.0, the rate scale. Equal in magnitude to `PCT` and meaning something completely
    ///      different — that collision is what several of these assertions exist to pin.
    uint256 internal constant ONE = 1e18;

    /// @dev 300%, the accumulated-capacity band.
    uint256 internal constant THREE_HUNDRED_PCT = 300e18;

    /// @dev The rate the fixed-rate markets in this suite run at. It is the ORDER's choice now, not
    ///      the recipe's, so it is carried by the oracle {_oracleAt} deploys rather than by
    ///      `fixedRecipe` itself.
    uint256 internal constant FIXED = 3 * ONE;

    // ─────────────────────────────── state ───────────────────────────────────

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    /// @dev A market pair. Neither recipe reads anything about these two addresses beyond naming them
    ///      in an error, so plain labels are honest here.
    address internal ca = makeAddr("collateralAsset");
    address internal ref = makeAddr("referenceAsset");

    LiquidityPriceRecipe internal liquidity;
    FixedRateRecipe internal fixedRecipe;

    function setUp() public {
        _deployRegistry(owner);
        liquidity = new LiquidityPriceRecipe();
        liquidity.initialize(iReg);
        fixedRecipe = new FixedRateRecipe();
        fixedRecipe.initialize(iReg);
    }

    // ─────────────────────────────── helpers ─────────────────────────────────

    function _recipeKeyHash(address recipe) internal pure returns (bytes32) {
        // Recomputed here, NOT imported, so it pins the normative EVENT hash. The STORE is keyed by
        // the raw address; this hash appears only in EntryAdded / EntryRemoved.
        return keccak256(abi.encode(recipe));
    }

    function _addRecipe(address recipe) internal {
        vm.prank(owner);
        iReg.addRecipes(one(recipe));
    }

    function _removeRecipe(address recipe) internal {
        vm.prank(owner);
        iReg.removeRecipes(one(recipe));
    }

    /// @dev A live `FixedRateOracle` reporting `rate`, through the registry's own permissionless
    ///      entrypoint. Real code and a real `IRateOracle.rate()`, which is what BOTH recipes need; a
    ///      `makeAddr` label would make the `rate()` call revert on an empty return. It stands in for
    ///      the pair's feed wrapper in the `LiquidityPriceRecipe` tests — that recipe only ever reads
    ///      `rate()`, so where the number comes from does not matter to it.
    /// @dev A market expiry a year out. Neither recipe under test reads it; the argument exists for
    ///      recipes whose policy is sized by the market's life.
    function _expiry() internal view returns (uint256) {
        return block.timestamp + 365 days;
    }

    function _oracleAt(uint256 rate) internal returns (address) {
        return reg.deployFixedRateOracle(rate);
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

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. The registry's membership surface
    // ═══════════════════════════════════════════════════════════════════════════

    function test_addRecipes_happyPath_storesAndIndexes() public {
        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryAdded(NS_RECIPE, _recipeKeyHash(address(liquidity)), abi.encode(address(liquidity)));
        _addRecipe(address(liquidity));

        assertTrue(iReg.isRecipe(address(liquidity)), "recipe not a member after add");

        (address[] memory page, uint256 total) = iReg.getRecipes(0, 10);
        assertEq(total, 1, "total should be 1");
        assertEq(page.length, 1, "page length mismatch");
        assertEq(page[0], address(liquidity), "page must name the member");
    }

    /// @notice The registry holds membership and NOTHING else — the only thing `getRecipes` can page is
    ///         addresses. There is no band, no mode string and no metadata to read back, so the recipe's
    ///         own `source()` / `description()` have to be asked of the recipe directly.
    function test_registry_holdsNoRecipeStateBeyondMembership() public {
        _addRecipe(address(liquidity));

        (address[] memory page,) = iReg.getRecipes(0, 10);
        assertEq(page[0], address(liquidity), "the address IS the whole record");

        // Read straight from the contract, which is the only place the policy lives.
        assertEq(uint8(IMarketRecipe(page[0]).source()), uint8(RecipeSource.PRICE), "source lives on the recipe");
        assertEq(LiquidityPriceRecipe(page[0]).RATE_MAX_PERCENTAGE(), HUNDRED_PCT, "bands live on the recipe");
    }

    function test_addRecipes_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        iReg.addRecipes(one(address(0)));
    }

    /// @notice Registration's one shape check: an address with no code can never answer `source()` or
    ///         `verify`, so approving it would record an entry guaranteed to fail at the first fill.
    function test_addRecipes_addressWithNoCode_reverts() public {
        address codeless = makeAddr("codeless");
        assertEq(codeless.code.length, 0, "fixture precondition: the label must hold no code");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.RecipeNotContract.selector, codeless));
        iReg.addRecipes(one(codeless));
    }

    /// @notice The code-length check is NOT an interface probe, and that is a locked decision rather
    ///         than an oversight: the registry deliberately never `staticcall`s `source()`, because a
    ///         proxy could answer correctly at registration and differently on the next block. So a
    ///         contract that is not a recipe at all registers fine. What protects a fill is the
    ///         four-step sequence, not this check.
    function test_addRecipes_acceptsAContractThatIsNotARecipe() public {
        address notARecipe = _newToken("TKN"); // a plain ERC-20; no source(), no verify()

        _addRecipe(notARecipe);
        assertTrue(iReg.isRecipe(notARecipe), "registration is a code-length check, not a shape probe");
    }

    function test_addRecipes_duplicate_reverts() public {
        _addRecipe(address(liquidity));

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        iReg.addRecipes(one(address(liquidity)));
    }

    function test_addRecipes_nonOwner_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        iReg.addRecipes(one(address(liquidity)));
    }

    function test_removeRecipes_happyPath_swapAndPop() public {
        _addRecipe(address(liquidity));
        _addRecipe(address(fixedRecipe));

        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryRemoved(NS_RECIPE, _recipeKeyHash(address(liquidity)), abi.encode(address(liquidity)));
        _removeRecipe(address(liquidity));

        assertFalse(iReg.isRecipe(address(liquidity)), "removed recipe still a member");

        // The survivor was swapped into the freed slot: it is still enumerable and still a member.
        (address[] memory page, uint256 total) = iReg.getRecipes(0, 10);
        assertEq(total, 1, "total should drop to 1");
        assertEq(page[0], address(fixedRecipe), "survivor must occupy the freed slot");
        assertTrue(iReg.isRecipe(address(fixedRecipe)), "survivor lost after swap-and-pop");
    }

    /// @notice Removal is the kill switch, so it takes effect immediately — no grace period.
    function test_removeRecipes_membershipStopsImmediately() public {
        _addRecipe(address(liquidity));
        assertTrue(iReg.isRecipe(address(liquidity)), "precondition");

        _removeRecipe(address(liquidity));
        assertFalse(iReg.isRecipe(address(liquidity)), "the gate must close on the very next call");
    }

    /// @notice Remove-then-add is the only way to replace a recipe, and the re-add must land cleanly.
    ///         Note what "replace" means now: a different POLICY is a different CONTRACT at a different
    ///         address, so the pair of calls names two addresses rather than editing one record. The
    ///         successor here is a `FixedRateRecipe`, because two `LiquidityPriceRecipe` instances would
    ///         carry the SAME policy — the limits are constants, so the only way to a different policy
    ///         is a different contract.
    function test_removeRecipes_thenAddASuccessor() public {
        _addRecipe(address(liquidity));
        _removeRecipe(address(liquidity));

        FixedRateRecipe successor = new FixedRateRecipe();
        successor.initialize(iReg);
        _addRecipe(address(successor));

        assertFalse(iReg.isRecipe(address(liquidity)), "predecessor must stay out");
        assertTrue(iReg.isRecipe(address(successor)), "successor must be in");
        assertEq(uint8(successor.source()), uint8(RecipeSource.FIXED), "successor carries its own policy");
    }

    /// @notice Re-adding the SAME address after removal is legal — removal frees the key.
    function test_removeRecipes_thenReAddSameAddress() public {
        _addRecipe(address(liquidity));
        _removeRecipe(address(liquidity));
        _addRecipe(address(liquidity));

        assertTrue(iReg.isRecipe(address(liquidity)), "re-add must land");
        (address[] memory page, uint256 total) = iReg.getRecipes(0, 10);
        assertEq(total, 1, "re-add must not double-count");
        assertEq(page[0], address(liquidity), "re-added address must be enumerable");
    }

    function test_removeRecipes_missing_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        iReg.removeRecipes(one(address(liquidity)));
    }

    function test_removeRecipes_nonOwner_reverts() public {
        _addRecipe(address(liquidity));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        iReg.removeRecipes(one(address(liquidity)));
    }

    function test_isRecipe_unregistered_false() public view {
        assertFalse(iReg.isRecipe(address(liquidity)), "nothing is a member before an add");
        assertFalse(iReg.isRecipe(address(0)), "the zero address is never a member");
    }

    function test_getRecipes_pagination() public {
        LiquidityPriceRecipe a = new LiquidityPriceRecipe();
        a.initialize(iReg);
        LiquidityPriceRecipe b = new LiquidityPriceRecipe();
        b.initialize(iReg);
        LiquidityPriceRecipe c = new LiquidityPriceRecipe();
        c.initialize(iReg);
        _addRecipe(address(a));
        _addRecipe(address(b));
        _addRecipe(address(c));

        (address[] memory first, uint256 total) = iReg.getRecipes(0, 2);
        assertEq(total, 3, "total should count every recipe");
        assertEq(first.length, 2, "limit should cap the page");
        assertEq(first[0], address(a), "insertion order within a page");
        assertEq(first[1], address(b), "insertion order within a page");

        (address[] memory tail,) = iReg.getRecipes(2, 10);
        assertEq(tail.length, 1, "limit should clamp to the remainder");
        assertEq(tail[0], address(c), "tail must hold the last member");

        (address[] memory past,) = iReg.getRecipes(99, 10);
        assertEq(past.length, 0, "offset past the end should yield an empty page");
    }

    function test_getRecipes_empty() public view {
        (address[] memory page, uint256 total) = iReg.getRecipes(0, 10);
        assertEq(total, 0, "empty set should report zero total");
        assertEq(page.length, 0, "empty set should return an empty page");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. FixedRateRecipe
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fixedRate_constructor_zeroRegistry_reverts() public {
        FixedRateRecipe fresh = new FixedRateRecipe();
        vm.expectRevert(FixedRateRecipe.ZeroRegistry.selector);
        fresh.initialize(IMarketRegistry(address(0)));
    }

    function test_fixedRate_source_isFixed() public view {
        assertEq(uint8(fixedRecipe.source()), uint8(RecipeSource.FIXED), "source() must be FIXED");
    }

    /// @notice `resolve` reads the rate from the oracle and returns the NARROWEST window phoenix will
    ///         accept: floor at the rate, ceiling one wei above it, no movement allowed either way. The
    ///         one wei is not a tolerance — `rateMin < rateMax` is strict, so a single point is
    ///         uncreatable — and with an oracle that cannot move, a one-wei window is a pinned rate.
    function test_fixedRate_resolve_derivesTheNarrowestCreatableWindow() public {
        IMarketRegistry.ResolvedConstraint memory c =
            fixedRecipe.resolve(ca, ref, _oracleAt(FIXED), fixedRecipe.encodeExtraData());

        assertEq(c.rateMin, FIXED, "floor is the oracle's rate");
        assertEq(c.rateMax, FIXED + fixedRecipe.WINDOW_WIDTH(), "ceiling is one wei above it");
        assertLt(c.rateMin, c.rateMax, "phoenix's STRICT rateMin < rateMax must hold");
        assertEq(c.rateChangePerDayMax, 0, "no daily movement allowance");
        assertEq(c.rateChangeCapacityMax, 0, "no accumulated capacity");
    }

    /// @notice THE RATE IS THE ORDER'S CHOICE NOW, and this is the test that pins it. The same recipe
    ///         instance answers for two different oracles with two different rates. Its predecessor
    ///         carried the rate as a constructor `immutable` and would have returned the identical
    ///         constraint for both.
    function test_fixedRate_resolve_followsTheOracleNotTheRecipe() public {
        IMarketRegistry.ResolvedConstraint memory low = fixedRecipe.resolve(ca, ref, _oracleAt(FIXED), "");
        IMarketRegistry.ResolvedConstraint memory high = fixedRecipe.resolve(ca, ref, _oracleAt(FIXED * 7), "");

        assertEq(low.rateMin, FIXED, "the first market runs at the first oracle's rate");
        assertEq(high.rateMin, FIXED * 7, "and the second at the second's, from the same recipe");
    }

    function test_fixedRate_resolve_nonEmptyExtraData_reverts() public {
        address oracle = _oracleAt(FIXED);
        bytes memory payload = abi.encode(ONE); // 32 bytes: looks plausible, means nothing here
        vm.expectRevert(abi.encodeWithSelector(FixedRateRecipe.UnexpectedExtraData.selector, payload.length));
        fixedRecipe.resolve(ca, ref, oracle, payload);
    }

    /// @notice No oracle means no rate to answer about, so both functions REVERT rather than return a
    ///         verdict. That is the interface's rule: `false` says "your constraint is wrong", a revert
    ///         says "I cannot answer" — see `IMarketRecipe.verify`.
    function test_fixedRate_zeroOracle_revertsRatherThanAnswering() public {
        vm.expectRevert(abi.encodeWithSelector(FixedRateRecipe.RateOracleNotDeployed.selector, ca, ref));
        fixedRecipe.resolve(ca, ref, address(0), "");

        vm.expectRevert(abi.encodeWithSelector(FixedRateRecipe.RateOracleNotDeployed.selector, ca, ref));
        fixedRecipe.verify(ca, ref, address(0), _expiry(), true, _constraint(FIXED, FIXED + 1, 0, 0), "");
    }

    function test_fixedRate_verify_acceptsItsOwnResolveOutput() public {
        address oracle = _oracleAt(FIXED);
        IMarketRegistry.ResolvedConstraint memory c = fixedRecipe.resolve(ca, ref, oracle, "");
        assertTrue(fixedRecipe.verify(ca, ref, oracle, _expiry(), true, c, ""), "resolve's own output must verify");
    }

    /// @notice THE PROVENANCE CHECK, which is what replaced the constructor `immutable` as the thing
    ///         that makes this recipe's rate immovable. A contract that merely presents an
    ///         `IRateOracle` surface is refused however honest its rate looks, because the factory's
    ///         `CREATE2` address for that rate is not where it lives. Only the factory can deploy at
    ///         that address, and the only thing it deploys is an oracle whose rate can never change.
    function test_fixedRate_verify_rejectsAnOracleTheFactoryDidNotDeploy() public {
        address impostor = address(new StandaloneFixedOracle(FIXED));
        assertEq(IRateOracle(impostor).rate(), FIXED, "fixture precondition: the impostor reports a real rate");
        assertTrue(reg.predictFixedRateOracle(FIXED) != impostor, "fixture precondition: at the wrong address");

        IMarketRegistry.ResolvedConstraint memory c = _constraint(FIXED, FIXED + 1, 0, 0);
        assertFalse(
            fixedRecipe.verify(ca, ref, impostor, _expiry(), true, c, ""), "an oracle not from the factory is refused"
        );
        assertTrue(
            fixedRecipe.verify(ca, ref, _oracleAt(FIXED), _expiry(), true, c, ""),
            "and the genuine one at the same rate is not"
        );
    }

    /// @notice "Fixed" is the two allowances at zero: a window the rate may drift inside is not a fixed
    ///         market, whatever the oracle says. Plus the two rules `createNewPool` imposes on the
    ///         constraint fields, enforced here so a rejection is diagnosed at the step that owns it.
    function test_fixedRate_verify_rejectsAnythingNotActuallyFixed() public {
        address oracle = _oracleAt(FIXED);

        assertFalse(
            fixedRecipe.verify(ca, ref, oracle, _expiry(), true, _constraint(FIXED, FIXED + 1, 1, 0), ""),
            "daily allowance"
        );
        assertFalse(
            fixedRecipe.verify(ca, ref, oracle, _expiry(), true, _constraint(FIXED, FIXED + 1, 0, 1), ""),
            "capacity allowance"
        );
        assertFalse(
            fixedRecipe.verify(ca, ref, oracle, _expiry(), true, _constraint(FIXED, FIXED, 0, 0), ""),
            "collapsed window"
        );
        assertFalse(
            fixedRecipe.verify(ca, ref, oracle, _expiry(), true, _constraint(FIXED + 1, FIXED, 0, 0), ""),
            "inverted window"
        );
        assertFalse(
            fixedRecipe.verify(ca, ref, oracle, _expiry(), true, _constraint(0, FIXED, 0, 0), ""), "zero rateMin"
        );
    }

    /// @notice The window's WIDTH is not the policy — the oracle is. With a rate that cannot move and
    ///         no drift allowance, a wide window changes nothing about the rate the market runs at, so
    ///         `verify` accepts one. This is the deliberate looseness noted on the contract.
    function test_fixedRate_verify_acceptsAWiderWindowThanResolveProduces() public {
        address oracle = _oracleAt(FIXED);
        assertTrue(
            fixedRecipe.verify(ca, ref, oracle, _expiry(), true, _constraint(FIXED / 2, FIXED * 2, 0, 0), ""),
            "width is free"
        );
    }

    /// @notice `verify` returns FALSE for a payload it cannot use, where `resolve` REVERTS. The
    ///         asymmetry is the interface's rule, not an inconsistency: `resolve` is called off-chain
    ///         by the agent building the order, so a loud failure is a bug report at the moment the
    ///         mistake is made; `verify` runs on-chain and the adapter owns the revert selector.
    function test_fixedRate_verify_nonEmptyExtraData_returnsFalseRatherThanReverting() public {
        IMarketRegistry.ResolvedConstraint memory c = _constraint(FIXED, FIXED + 1, 0, 0);
        assertFalse(
            fixedRecipe.verify(ca, ref, _oracleAt(FIXED), _expiry(), true, c, abi.encode(ONE)),
            "carried bytes are a mismatch"
        );
    }

    /// @notice The blockage the predecessor documented is GONE, and this asserts the fix rather than
    ///         trusting the comment. `createNewPool` needs a non-zero `rateOracle` and a strictly
    ///         widening window; a fixed-rate market now has both, because the order names a rate and
    ///         the registry deploys a real `FixedRateOracle` for it.
    function test_fixedRate_constraintIsNowCreatableByPhoenix() public {
        address oracle = _oracleAt(FIXED);
        IMarketRegistry.ResolvedConstraint memory c = fixedRecipe.resolve(ca, ref, oracle, "");

        assertTrue(oracle != address(0), "the market has a real rate oracle");
        assertGt(c.rateMin, 0, "phoenix's rateMin > 0");
        assertLt(c.rateMin, c.rateMax, "phoenix's STRICT rateMin < rateMax");
        assertGe(IRateOracle(oracle).rate(), c.rateMin, "and the live rate sits inside the window,");
        assertLe(IRateOracle(oracle).rate(), c.rateMax, "which is what bootstrap requires at creation");
    }

    // ─────────────────────── FixedRateRecipe: extraData helpers ───────────────────────

    /// @notice The recipe takes no `extraData`, and it says so through the same helper pair
    ///         every other recipe exposes, so off-chain tooling never needs a special case for it.
    function test_fixedRate_encodeExtraData_isEmpty() public view {
        assertEq(fixedRecipe.encodeExtraData().length, 0, "the expected payload is no payload");
    }

    function test_fixedRate_decodeExtraData_acceptsEmpty() public view {
        fixedRecipe.decodeExtraData("");
    }

    /// @notice The decoder rejects a payload with the same selector `resolve` uses, so a builder
    ///         who checks the payload up front sees the same error they would see at resolve time.
    function test_fixedRate_decodeExtraData_nonEmpty_reverts() public {
        bytes memory payload = abi.encode(ONE);
        vm.expectRevert(abi.encodeWithSelector(FixedRateRecipe.UnexpectedExtraData.selector, payload.length));
        fixedRecipe.decodeExtraData(payload);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. LiquidityPriceRecipe — constructor and constants
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The registry is the ONLY constructor argument left. Its predecessor took four
    ///         percentages and rejected several combinations of them at deployment; there is nothing
    ///         left to reject, because the percentages are constants.
    function test_liquidity_constructor_zeroRegistry_reverts() public {
        LiquidityPriceRecipe fresh = new LiquidityPriceRecipe();
        vm.expectRevert(BaseLiquidityRecipe.ZeroRegistry.selector);
        fresh.initialize(IMarketRegistry(address(0)));
    }

    /// @notice The registry reference is part of a deployed instance's PUBLIC POLICY SURFACE: "the
    ///         recipe address is the policy" only holds if the address commits to which registry
    ///         governs it. Nothing in the contract reads it, so the getter and the zero check are the
    ///         whole of that commitment.
    function test_liquidity_registryGetterNamesTheGoverningRegistry() public view {
        assertEq(address(liquidity.REGISTRY()), address(reg), "the instance must name its registry");
    }

    /// @notice The getters ARE the policy, and they are the same on every instance — which is the
    ///         point of making them constants. The floor is the odd one out: it is a rate (1 wei), not
    ///         a percentage, because no percentage of a rate produces a rate-independent floor.
    function test_liquidity_gettersAreTheWholePolicy() public view {
        assertEq(liquidity.RATE_MIN(), 1, "floor is one wei, flat");
        assertEq(liquidity.RATE_MIN_PERCENTAGE(), HUNDRED_PCT, "floor band is fully open");
        assertEq(liquidity.RATE_MAX_PERCENTAGE(), HUNDRED_PCT, "ceiling band is 100% above the anchor");
        assertEq(liquidity.RATE_CHANGE_PER_DAY_MAX_PERCENTAGE(), HUNDRED_PCT, "daily allowance band");
        assertEq(liquidity.RATE_CHANGE_CAPACITY_MAX_PERCENTAGE(), THREE_HUNDRED_PCT, "capacity band");
    }

    /// @notice Two instances carry the identical policy. Under its predecessor this was the one thing
    ///         that could differ between deployments, and the reason `CREATE2` review mattered; now the
    ///         policy is in the bytecode, so approving any instance approves the same numbers.
    function test_liquidity_everyInstanceCarriesTheSamePolicy() public {
        LiquidityPriceRecipe other = new LiquidityPriceRecipe();
        other.initialize(iReg);
        assertTrue(address(other) != address(liquidity), "precondition: two distinct deployments");

        IMarketRegistry.ResolvedConstraint memory a = liquidity.resolve(ca, ref, address(0), abi.encode(ONE));
        IMarketRegistry.ResolvedConstraint memory b = other.resolve(ca, ref, address(0), abi.encode(ONE));

        assertEq(a.rateMin, b.rateMin, "same floor");
        assertEq(a.rateMax, b.rateMax, "same ceiling");
        assertEq(a.rateChangePerDayMax, b.rateChangePerDayMax, "same daily allowance");
        assertEq(a.rateChangeCapacityMax, b.rateChangeCapacityMax, "same capacity");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. LiquidityPriceRecipe — source, description, resolve
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `PRICE` is what tells the adapter where this recipe's rate comes from: it maps to
    ///         `OracleMode.PRICE`, so step 3 deploys the pair's feed wrapper. A `FIXED` recipe takes
    ///         the same step to `deployFixedRateOracle` with the rate the order named instead.
    function test_liquidity_source_isPrice() public view {
        assertEq(uint8(liquidity.source()), uint8(RecipeSource.PRICE), "source() must be PRICE");
    }

    /// @notice The NAV twin differs from the price recipe in `source()` and in nothing else. Both halves
    ///         are asserted here, because the split only pays for itself if the shared half really is
    ///         shared: a subclass that quietly re-derived the window would be a second policy wearing
    ///         the same name.
    function test_liquidityNav_isTheSamePolicyOnADifferentSource() public {
        LiquidityNavRecipe nav = new LiquidityNavRecipe();
        nav.initialize(iReg);

        assertEq(uint8(nav.source()), uint8(RecipeSource.NAV), "source() must be NAV");

        IMarketRegistry.ResolvedConstraint memory n = nav.resolve(ca, ref, address(0), abi.encode(ONE));
        IMarketRegistry.ResolvedConstraint memory p = liquidity.resolve(ca, ref, address(0), abi.encode(ONE));
        assertEq(n.rateMin, p.rateMin, "same floor");
        assertEq(n.rateMax, p.rateMax, "same ceiling");
        assertEq(n.rateChangePerDayMax, p.rateChangePerDayMax, "same daily allowance");
        assertEq(n.rateChangeCapacityMax, p.rateChangeCapacityMax, "same capacity");
        assertEq(nav.description(), liquidity.description(), "one policy, one description");
    }

    /// @notice The registry stores nothing about a recipe except its address, so `description()` plus
    ///         the public getters are the entire on-chain account of what approving that address meant.
    ///         An empty string would leave no account at all.
    function test_bothRecipes_describeThemselves() public view {
        assertGt(bytes(liquidity.description()).length, 0, "LiquidityPriceRecipe must describe itself");
        assertGt(bytes(fixedRecipe.description()).length, 0, "FixedRateRecipe must describe itself");
    }

    /// @notice The four limits at an anchor of 1.0, spelled out: a 1 wei floor, a ceiling at twice the
    ///         anchor, a daily allowance equal to the whole anchor and a capacity of three times it.
    ///         These are the numbers the 100x percentage/rate scale error would break — a ceiling of
    ///         `1.01e18` rather than `2e18` is what a misplaced `100e18` looks like.
    function test_liquidity_resolve_derivesWindowFromTheAnchor() public view {
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), abi.encode(ONE));

        assertEq(c.rateMin, 1, "floor is one wei, not a fraction of the anchor");
        assertEq(c.rateMax, 2 * ONE, "ceiling sits 100% above the anchor");
        assertEq(c.rateChangePerDayMax, ONE, "100% of 1.0 is 1.0");
        assertEq(c.rateChangeCapacityMax, 3 * ONE, "300% of 1.0 is 3.0");
    }

    /// @notice Three of the four limits scale with the anchor and the floor does not — it is a flat
    ///         1 wei at every anchor. That asymmetry is the one thing about this recipe's arithmetic
    ///         worth pinning, because the floor is the only field `applyBands` does not decide.
    function test_liquidity_resolve_everythingButTheFloorScalesWithTheAnchor() public view {
        IMarketRegistry.ResolvedConstraint memory low = liquidity.resolve(ca, ref, address(0), abi.encode(0.5e18));
        assertEq(low.rateMin, 1, "floor does not track the anchor down");
        assertEq(low.rateMax, ONE, "ceiling tracks the anchor down");
        assertEq(low.rateChangePerDayMax, 0.5e18, "daily allowance tracks the anchor down");
        assertEq(low.rateChangeCapacityMax, 1.5e18, "capacity tracks the anchor down");

        IMarketRegistry.ResolvedConstraint memory high = liquidity.resolve(ca, ref, address(0), abi.encode(2e18));
        assertEq(high.rateMin, 1, "floor does not track the anchor up either");
        assertEq(high.rateMax, 4 * ONE, "ceiling tracks the anchor up");
        assertEq(high.rateChangePerDayMax, 2 * ONE, "daily allowance tracks the anchor up");
        assertEq(high.rateChangeCapacityMax, 6 * ONE, "capacity tracks the anchor up");
    }

    /// @notice The live oracle is the preferred anchor. When the agent building the order can name one,
    ///         the window is derived from the rate it reports and the anchor in `extraData` is not
    ///         read at all — so the two disagreeing here must resolve in the oracle's favour.
    function test_liquidity_resolve_prefersTheLiveOracleOverExtraData() public {
        address live = _oracleAt(5 * ONE); // five times the anchor the payload claims
        assertEq(IRateOracle(live).rate(), 5 * ONE, "fixture precondition: the oracle disagrees");

        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, live, abi.encode(ONE));

        assertEq(c.rateMin, 1, "the floor is one wei whatever the anchor");
        assertEq(c.rateMax, 10 * ONE, "the ceiling is twice the ORACLE's rate, not twice the payload's");
        assertEq(c.rateChangePerDayMax, 5 * ONE, "the daily allowance follows the oracle too");
        assertEq(c.rateChangeCapacityMax, 15 * ONE, "and so does the capacity");
    }

    /// @notice "Prefers" means the payload is not read, not that it is read and overridden. Every
    ///         payload that would be REJECTED on the fallback path below is simply ignored once an
    ///         oracle is supplied.
    function test_liquidity_resolve_withAnOracle_doesNotReadExtraDataAtAll() public {
        address live = _oracleAt(5 * ONE);
        uint256 expected = 10 * ONE;

        assertEq(liquidity.resolve(ca, ref, live, "").rateMax, expected, "empty payload");
        assertEq(liquidity.resolve(ca, ref, live, abi.encode(ONE, ONE)).rateMax, expected, "two words");
        assertEq(liquidity.resolve(ca, ref, live, abi.encode(uint256(0))).rateMax, expected, "a zero anchor");
        assertEq(liquidity.resolve(ca, ref, live, hex"c0ffee").rateMax, expected, "not a word at all");
    }

    /// @notice The fallback exists for one case: the FIRST order ever written against a pair, signed
    ///         before the adapter's step 3 has deployed the feed wrapper. There is no oracle to read
    ///         then, so the anchor travels in `extraData` instead — and a `resolve` that insisted
    ///         on an oracle would be unusable for exactly the order that creates the market.
    function test_liquidity_resolve_fallsBackToExtraDataWhenNoOracleIsSupplied() public view {
        IMarketRegistry.ResolvedConstraint memory c =
            liquidity.resolve(ca, ref, address(0), liquidity.encodeExtraData(2 * ONE));

        assertEq(c.rateMin, 1, "floor");
        assertEq(c.rateMax, 4 * ONE, "the window comes from the payload's anchor");
        assertEq(c.rateChangePerDayMax, 2 * ONE, "daily allowance");
        assertEq(c.rateChangeCapacityMax, 6 * ONE, "capacity");
    }

    /// @notice A ZERO address is the only thing that selects the fallback. An address that simply is not
    ///         a live oracle is a caller error, not an invitation to guess: the `rate()` call reverts and
    ///         the payload is never consulted. Asserted through a low-level call because the failure is
    ///         solc's own code-length check, which carries no selector to expect.
    function test_liquidity_resolve_addressWithNoCodeIsNotAFallback() public {
        address junk = makeAddr("junkOracle");
        assertEq(junk.code.length, 0, "fixture precondition: the label must hold no code");

        (bool ok,) =
            address(liquidity).staticcall(abi.encodeCall(IMarketRecipe.resolve, (ca, ref, junk, abi.encode(ONE))));
        assertFalse(ok, "a non-zero oracle is read, not second-guessed");
    }

    function test_liquidity_resolve_malformedExtraData_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BaseLiquidityRecipe.MalformedExtraData.selector, 0));
        liquidity.resolve(ca, ref, address(0), "");

        bytes memory twoWords = abi.encode(ONE, ONE);
        vm.expectRevert(abi.encodeWithSelector(BaseLiquidityRecipe.MalformedExtraData.selector, twoWords.length));
        liquidity.resolve(ca, ref, address(0), twoWords);
    }

    function test_liquidity_resolve_zeroAnchor_reverts() public {
        vm.expectRevert(BaseLiquidityRecipe.ZeroAnchorRate.selector);
        liquidity.resolve(ca, ref, address(0), abi.encode(uint256(0)));
    }

    /// @notice The dust anchor that killed its predecessor now resolves cleanly, and this is the test
    ///         that proves {BaseLiquidityRecipe.WindowCollapsed} cannot fire. A four-percentage recipe
    ///         rounded the floor UP and the ceiling DOWN, so at an anchor of 1 wei with a 1% ceiling
    ///         both landed on 1 and phoenix's STRICT `rateMin < rateMax` refused the result. Here the
    ///         floor is a flat 1 and the ceiling is twice the anchor, so the window widens at every
    ///         anchor the recipe accepts — including the smallest one there is.
    function test_liquidity_resolve_dustAnchorStillWidens() public view {
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), abi.encode(uint256(1)));

        assertEq(c.rateMin, 1, "floor at the smallest legal value");
        assertEq(c.rateMax, 2, "ceiling at twice a one-wei anchor");
        assertLt(c.rateMin, c.rateMax, "phoenix's STRICT rateMin < rateMax must still hold");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4b. Liquidity recipes — extraData helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `encodeExtraData` then `decodeExtraData` returns the anchor unchanged on both subclasses.
    function test_liquidity_extraData_roundTripsOnBothRecipes() public {
        LiquidityNavRecipe nav = new LiquidityNavRecipe();
        nav.initialize(iReg);

        uint256[4] memory anchors = [uint256(1), ONE, 2 * ONE, type(uint256).max];
        for (uint256 i = 0; i < anchors.length; i++) {
            assertEq(liquidity.decodeExtraData(liquidity.encodeExtraData(anchors[i])), anchors[i], "price round trip");
            assertEq(nav.decodeExtraData(nav.encodeExtraData(anchors[i])), anchors[i], "nav round trip");
        }
    }

    /// @notice The helper is a convenience, not a new layout: what it returns is exactly the one ABI
    ///         word `resolve` has always read, so payloads built either way stay interchangeable.
    function test_liquidity_encodeExtraData_isPlainAbiEncode() public view {
        assertEq(liquidity.encodeExtraData(ONE), abi.encode(ONE), "one");
        assertEq(liquidity.encodeExtraData(0), abi.encode(uint256(0)), "zero");
        assertEq(liquidity.encodeExtraData(type(uint256).max), abi.encode(type(uint256).max), "max");
        assertEq(liquidity.encodeExtraData(ONE).length, 32, "exactly one ABI word");
    }

    /// @notice The helper and `resolve` share one decoder, so a payload the helper rejects is rejected
    ///         with the same error, and the same length, that `resolve` would report.
    function test_liquidity_decodeExtraData_malformed_revertsLikeResolve() public {
        vm.expectRevert(abi.encodeWithSelector(BaseLiquidityRecipe.MalformedExtraData.selector, 0));
        liquidity.decodeExtraData("");

        bytes memory twoWords = abi.encode(ONE, ONE);
        vm.expectRevert(abi.encodeWithSelector(BaseLiquidityRecipe.MalformedExtraData.selector, twoWords.length));
        liquidity.decodeExtraData(twoWords);

        bytes memory short = hex"01";
        vm.expectRevert(abi.encodeWithSelector(BaseLiquidityRecipe.MalformedExtraData.selector, short.length));
        liquidity.decodeExtraData(short);
    }

    /// @notice A payload that decodes through the helper is a payload `resolve` accepts, and it lands on
    ///         the same anchor: the fallback window is derived from exactly what the helper read.
    function test_liquidity_decodeExtraData_agreesWithResolve() public view {
        bytes memory payload = liquidity.encodeExtraData(3 * ONE);
        uint256 anchor = liquidity.decodeExtraData(payload);
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), payload);

        assertEq(anchor, 3 * ONE, "decoded anchor");
        assertEq(c.rateChangePerDayMax, anchor, "resolve anchored on what the helper decoded");
        assertEq(c.rateMax, 2 * anchor, "and the window follows it");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. LiquidityPriceRecipe — verify
    // ═══════════════════════════════════════════════════════════════════════════

    function test_liquidity_verify_acceptsItsOwnResolveOutput() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, oracle, "");

        assertTrue(liquidity.verify(ca, ref, oracle, _expiry(), true, c, ""), "resolve's own output must verify");
    }

    /// @notice THE LIVE RATE IS A BOUND, NOT THE ANCHOR, and this test is the first half of what that
    ///         means. A constraint signed at one rate keeps verifying as the rate moves — it has to,
    ///         because the pool's identifier includes the constraint, so limits that tracked the live
    ///         rate would invalidate the share addresses every resting order was signed against.
    function test_liquidity_verify_acceptsAMovedRateThatIsStillInsideTheWindow() public {
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, _oracleAt(ONE), "");
        assertEq(c.rateMax, 2 * ONE, "precondition: the window is [1 wei, 2.0]");

        assertTrue(liquidity.verify(ca, ref, _oracleAt(1.5e18), _expiry(), true, c, ""), "50% up and still filling");
        assertTrue(liquidity.verify(ca, ref, _oracleAt(0.01e18), _expiry(), true, c, ""), "99% down and still filling");
        assertTrue(
            liquidity.verify(ca, ref, _oracleAt(2 * ONE - 1), _expiry(), true, c, ""), "one wei below the ceiling"
        );
    }

    /// @notice The second half: once the live rate leaves the window the order stops filling. This is
    ///         the check that makes the anchor mean anything at all — a window that no longer contains
    ///         the market's own rate describes a market that is not there.
    function test_liquidity_verify_rejectsALiveRateOutsideTheWindow() public {
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, _oracleAt(ONE), "");

        assertFalse(
            liquidity.verify(ca, ref, _oracleAt(2 * ONE), _expiry(), true, c, ""), "exactly on the ceiling: excluded"
        );
        assertFalse(
            liquidity.verify(ca, ref, _oracleAt(2 * ONE + 1), _expiry(), true, c, ""), "one wei above the ceiling"
        );
        assertFalse(liquidity.verify(ca, ref, _oracleAt(1000 * ONE), _expiry(), true, c, ""), "a thousand times over");
        assertFalse(liquidity.verify(ca, ref, _oracleAt(1), _expiry(), true, c, ""), "exactly on the floor: excluded");
    }

    /// @notice THE BOUND IS ONE-SIDED, asserted here rather than left to be discovered. Containment
    ///         catches an anchor that is too SMALL, because the ceiling is twice the anchor: an anchor
    ///         at or below half the live rate puts the market outside its own window. It does NOT catch
    ///         an anchor that is too LARGE, because the floor is a flat 1 wei at every anchor, so an
    ///         arbitrarily wide window still contains the live rate. Approving this recipe's address
    ///         means accepting that a market may be created far wider than it needs to be.
    function test_liquidity_verify_catchesATooSmallAnchorButNotATooLargeOne() public {
        address oracle = _oracleAt(ONE);

        IMarketRegistry.ResolvedConstraint memory tooSmall =
            liquidity.resolve(ca, ref, address(0), abi.encode(0.5e18 - 1));
        assertLt(tooSmall.rateMax, ONE, "precondition: the ceiling sits below the live rate");
        assertFalse(
            liquidity.verify(ca, ref, oracle, _expiry(), true, tooSmall, ""), "so the market is outside its own window"
        );

        IMarketRegistry.ResolvedConstraint memory tooLarge =
            liquidity.resolve(ca, ref, address(0), abi.encode(1000 * ONE));
        assertEq(tooLarge.rateMax, 2000 * ONE, "a window a thousand times wider than it needs to be");
        assertTrue(
            liquidity.verify(ca, ref, oracle, _expiry(), true, tooLarge, ""), "and the 1 wei floor lets it through"
        );
    }

    /// @notice `verify` is handed no anchor at all now, so it reads one back out of the constraint:
    ///         `rateChangePerDayMax` IS the anchor, because the daily allowance is 100% of it. It then
    ///         requires the other three fields to be exactly what this recipe produces at that anchor,
    ///         which is what stops a constraint from being assembled out of two different ones. Both
    ///         halves below are individually well-formed and the live rate sits inside both windows, so
    ///         only the cross-field comparison can catch the mixture.
    function test_liquidity_verify_rejectsAnInternallyInconsistentConstraint() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory a = liquidity.resolve(ca, ref, address(0), abi.encode(ONE));
        IMarketRegistry.ResolvedConstraint memory b = liquidity.resolve(ca, ref, address(0), abi.encode(1.5e18));

        IMarketRegistry.ResolvedConstraint memory mixed =
            _constraint(b.rateMin, b.rateMax, a.rateChangePerDayMax, a.rateChangeCapacityMax);

        assertTrue(liquidity.verify(ca, ref, oracle, _expiry(), true, a, ""), "A alone verifies");
        assertTrue(liquidity.verify(ca, ref, oracle, _expiry(), true, b, ""), "B alone verifies");
        assertFalse(
            liquidity.verify(ca, ref, oracle, _expiry(), true, mixed, ""), "B's window with A's allowances does not"
        );
    }

    /// @notice The shape is checked on all FOUR fields, not just the window. Tampering with either
    ///         movement allowance while leaving the window intact must still be rejected.
    function test_liquidity_verify_rejectsATamperedMovementAllowance() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, oracle, "");

        IMarketRegistry.ResolvedConstraint memory perDay =
            _constraint(c.rateMin, c.rateMax, c.rateChangePerDayMax + 1, c.rateChangeCapacityMax);
        IMarketRegistry.ResolvedConstraint memory capacity =
            _constraint(c.rateMin, c.rateMax, c.rateChangePerDayMax, c.rateChangeCapacityMax + 1);

        assertFalse(liquidity.verify(ca, ref, oracle, _expiry(), true, perDay, ""), "widened daily allowance");
        assertFalse(liquidity.verify(ca, ref, oracle, _expiry(), true, capacity, ""), "widened capacity");
    }

    /// @notice The interface's rule about reverting, and the one place this recipe uses it: `false`
    ///         means "this constraint is unacceptable", a revert means "I cannot answer". `verify` takes
    ///         the rate from nowhere but the oracle, so with no oracle there is no verdict to give. The
    ///         selector is its own, so "your oracle is missing" never reads as "your constraint is
    ///         wrong".
    ///
    ///         Unreachable through the adapter, which produces the oracle at step 3 before this runs.
    function test_liquidity_verify_zeroOracle_reverts() public {
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), abi.encode(ONE));

        vm.expectRevert(abi.encodeWithSelector(BaseLiquidityRecipe.RateOracleNotDeployed.selector, ca, ref));
        liquidity.verify(ca, ref, address(0), _expiry(), true, c, "");
    }

    /// @notice `verify` reads no `extraData` whatsoever. The oracle is live by the time this runs,
    ///         so the order's own account of the rate adds nothing but a way to lie — and an order signed
    ///         through `resolve`'s fallback path still carries its anchor, so rejecting a non-empty
    ///         payload would refuse exactly the orders that created their own markets.
    function test_liquidity_verify_ignoresExtraDataEntirely() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, oracle, "");

        assertTrue(liquidity.verify(ca, ref, oracle, _expiry(), true, c, ""), "empty");
        assertTrue(
            liquidity.verify(ca, ref, oracle, _expiry(), true, c, abi.encode(ONE)), "the anchor it was signed with"
        );
        assertTrue(
            liquidity.verify(ca, ref, oracle, _expiry(), true, c, abi.encode(1000 * ONE)), "an anchor it was not"
        );
        assertTrue(
            liquidity.verify(ca, ref, oracle, _expiry(), true, c, hex"c0ffee"), "bytes that are not a word at all"
        );
    }

    /// @notice Phoenix's two constraint requirements are checked here, so a structurally impossible
    ///         constraint is rejected at the step that owns the diagnosis rather than several frames
    ///         inside the controller. All three shapes below would also fail the shape comparison, so
    ///         what this pins is that they are refused at all.
    function test_liquidity_verify_rejectsAStructurallyImpossibleConstraint() public {
        address oracle = _oracleAt(ONE);

        assertFalse(liquidity.verify(ca, ref, oracle, _expiry(), true, _constraint(0, ONE, 0, 0), ""), "zero rateMin");
        assertFalse(
            liquidity.verify(ca, ref, oracle, _expiry(), true, _constraint(2 * ONE, ONE, 0, 0), ""), "inverted window"
        );
        assertFalse(
            liquidity.verify(ca, ref, oracle, _expiry(), true, _constraint(ONE, ONE, 0, 0), ""), "single-point window"
        );
    }

    /// @notice The property `verify` is built on, fuzzed: given a constraint this recipe produced, the
    ///         verdict is EXACTLY whether the live rate sits strictly inside the window. The anchor runs
    ///         from one wei — `resolve` accepts dust — to a rate large enough that trebling it still
    ///         cannot overflow.
    function testFuzz_liquidity_verifyIsWindowContainment(uint256 anchor, uint256 live) public {
        anchor = bound(anchor, 1, 1e30);
        live = bound(live, 1, 1e30); // 0 is not a deployable rate — FixedRateOracle refuses it

        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), abi.encode(anchor));
        assertEq(c.rateMin, 1, "the floor is one wei at every anchor");
        assertEq(c.rateMax, 2 * anchor, "the ceiling is twice the anchor at every anchor");

        assertEq(
            liquidity.verify(ca, ref, _oracleAt(live), _expiry(), true, c, ""),
            live > c.rateMin && live < c.rateMax,
            "the verdict IS window containment, at every anchor and every live rate"
        );
    }

    /// @notice The anchor recovery, fuzzed: whatever anchor a constraint was built at, `verify` reads
    ///         that same number back out of `rateChangePerDayMax`, which is why no anchor has to travel
    ///         with the order. Nudging that one field by a wei breaks the other three fields' agreement
    ///         with it, so the recovery cannot be passing by accident.
    function testFuzz_liquidity_verifyRecoversTheAnchorFromTheConstraint(uint256 anchor) public {
        anchor = bound(anchor, 2, 1e30); // above the 1 wei floor, so the anchor is inside its own window

        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), abi.encode(anchor));
        assertEq(c.rateChangePerDayMax, anchor, "the daily allowance IS the anchor");

        address oracle = _oracleAt(anchor);
        assertTrue(
            liquidity.verify(ca, ref, oracle, _expiry(), true, c, ""), "precondition: the untouched constraint verifies"
        );

        IMarketRegistry.ResolvedConstraint memory nudged =
            _constraint(c.rateMin, c.rateMax, c.rateChangePerDayMax + 1, c.rateChangeCapacityMax);
        assertFalse(
            liquidity.verify(ca, ref, oracle, _expiry(), true, nudged, ""), "a one wei nudge breaks the agreement"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. A recipe cannot write state during verify
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice `IMarketRecipe` states that every function being `view` IS the security boundary: the
    ///         caller reaches `verify` by `STATICCALL`, which cannot write state, cannot emit, cannot
    ///         move value and cannot reenter anything that would. So the worst a hostile recipe can do
    ///         is return a false answer.
    ///
    /// @dev Making this test PROVE the property rather than trivially pass takes three deliberate
    ///      choices.
    ///
    ///      1. **The mock must actually try to write.** A contract inheriting `IMarketRecipe` could not
    ///         compile with a writing `verify`, because the interface declares it `view`. So
    ///         {StateWritingRecipe} does not inherit the interface; it re-declares the four signatures
    ///         byte for byte, which keeps the selectors identical while letting `verify` be
    ///         non-`view`.
    ///      2. **The call must be a real low-level `staticcall`.** `IMarketRecipe(hostile).verify(...)`
    ///         would be compiled from the INTERFACE's `view` marking, so solc would emit the
    ///         `STATICCALL` for its own reasons and the test would be checking the compiler rather than
    ///         the guarantee. `CorkLimitOrderAdapter._verifyConstraint` makes a typed call inside a
    ///         `view` function, which solc compiles to `STATICCALL`; this test reproduces that shape
    ///         with an explicit `staticcall` over `abi.encodeCall(IMarketRecipe.verify, ...)`.
    ///      3. **There must be a positive control.** A failing `staticcall` on its own proves nothing —
    ///         a wrong selector, a mis-encoded argument or a missing function would fail identically
    ///         and the test would pass for the wrong reason. So the same calldata is first sent as an
    ///         ordinary `CALL`, which must SUCCEED, return `true`, and leave the write behind. Only
    ///         then is the `staticcall` attempted. The two differ in exactly one thing — the static
    ///         flag — so the failure can only be the state write.
    function test_verify_cannotWriteState_staticcallIsWhatStopsIt() public {
        StateWritingRecipe hostile = new StateWritingRecipe();

        // Registration is no defence and is not meant to be: the code-length check is all `addRecipe`
        // does, so an approved address can still hold a writing `verify`. The `staticcall` is the
        // guarantee, not the membership set.
        _addRecipe(address(hostile));
        assertTrue(iReg.isRecipe(address(hostile)), "the registry approves it on code length alone");

        bytes memory callData = abi.encodeCall(
            IMarketRecipe.verify, (ca, ref, address(0), _expiry(), true, _constraint(ONE, 2 * ONE, 0, 0), bytes(""))
        );

        // Positive control: as an ordinary CALL this calldata reaches the function, is accepted, and
        // the write lands. Without this, the negative result below would be indistinguishable from a
        // typo in the encoding.
        (bool okCall, bytes memory ret) = address(hostile).call(callData);
        assertTrue(okCall, "control: the plain call must succeed, or the calldata is wrong");
        assertEq(ret.length, 32, "control: verify must return one word");
        assertTrue(abi.decode(ret, (bool)), "control: the hostile recipe answers true");
        assertEq(hostile.writeCount(), 1, "control: the write really is a write");

        // The property: the identical calldata, sent the way the adapter sends it, cannot succeed.
        (bool okStatic,) = address(hostile).staticcall(callData);
        assertFalse(okStatic, "a verify that writes state must fail under STATICCALL");
        assertEq(hostile.writeCount(), 1, "and no second write may have landed");
    }

    /// @notice The honest counterpart, so the test above is not merely detecting a broken mock: both
    ///         real recipes answer the very same `staticcall` successfully. Whatever
    ///         {test_verify_cannotWriteState_staticcallIsWhatStopsIt} caught, it was not the call shape.
    function test_verify_realRecipesAnswerTheSameStaticcall() public {
        address oracle = _oracleAt(ONE);
        IMarketRegistry.ResolvedConstraint memory c = liquidity.resolve(ca, ref, address(0), abi.encode(ONE));

        (bool okLiquidity, bytes memory liquidityRet) = address(liquidity)
            .staticcall(abi.encodeCall(IMarketRecipe.verify, (ca, ref, oracle, _expiry(), true, c, abi.encode(ONE))));
        assertTrue(okLiquidity, "LiquidityPriceRecipe.verify must survive a staticcall");
        assertTrue(abi.decode(liquidityRet, (bool)), "and accept its own constraint");

        IMarketRegistry.ResolvedConstraint memory f = fixedRecipe.resolve(ca, ref, oracle, "");
        (bool okFixed, bytes memory fixedRet) = address(fixedRecipe)
            .staticcall(abi.encodeCall(IMarketRecipe.verify, (ca, ref, oracle, _expiry(), true, f, bytes(""))));
        assertTrue(okFixed, "FixedRateRecipe.verify must survive a staticcall");
        assertTrue(abi.decode(fixedRet, (bool)), "and accept its own constraint");
    }
}
