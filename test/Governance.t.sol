// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";
import {mkAsset, mkFeed, mkPriceSource, noSource} from "./fixtures/TenAssetSet.sol";
import {MockERC20} from "./mocks/HostileAssets.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title Governance.t.sol — governance + access-control suite
/// @notice Covers the constructor (including BOTH factory zero-address guards), `transferOwnership` /
///         `acceptOwnership` (two-step), the disabled `renounceOwnership`, the owner-gating sweep
///         across every mutating function, and the two DELIBERATELY UNGATED entrypoints —
///         `deploy` and the fixed-rate oracle pair `deployFixedRateOracle` / `predictFixedRateOracle`.
/// @dev Scope: the governance surface and cross-cutting owner gating ONLY. Store semantics, the
///      denomination walk, the hop graph and `deploy` all live in their own suites. Every
///      `vm.expectRevert` carries an explicit error selector.
///
///      THE SWEEP IS THE POINT. Eight functions mutate registry state and every one of them must be
///      owner-only; the sweep is what catches a new mutation shipped without a gate. It also pins the
///      one deliberate exception to "gate first": `addAssets` range-checks its enum ordinals BEFORE
///      `_checkOwner`, so a MALFORMED call fails as a malformed call whoever sent it. That ordering is
///      asserted in `AssetStore.t.sol`; here the sweep uses well-formed arguments so the authority
///      error is what surfaces.
contract GovernanceTest is Test {
    MarketRegistry internal reg;
    IMarketRegistry internal iReg;

    address internal owner = makeAddr("owner");
    address internal pending = makeAddr("pending");
    address internal other = makeAddr("other");
    address internal stranger = makeAddr("stranger");

    // Selectors reused across cases (explicit — never a bare expectRevert). Not `constant`: an error's
    // `.selector` is not a compile-time constant initializer.
    bytes4 internal UNAUTHORIZED = Ownable.OwnableUnauthorizedAccount.selector;
    bytes4 internal INVALID_OWNER = Ownable.OwnableInvalidOwner.selector;
    bytes4 internal RENOUNCE_DISABLED = IMarketRegistry.RenounceDisabled.selector;
    bytes4 internal ZERO_ADDRESS = IMarketRegistry.ZeroAddress.selector;
    bytes4 internal EMPTY_NAME = IMarketRegistry.EmptyName.selector;
    bytes4 internal ZERO_BOUND = IMarketRegistry.ZeroBound.selector;

    MockWrapperFactory internal wrapperFactory;

    /// @dev The REAL {FixedRateOracleFactory}, not a mock. Its `computeAddress` is the one fact the
    ///      registry's idempotency check depends on being true, so a mock could only lie about it.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    function setUp() public {
        wrapperFactory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        reg = new MarketRegistry();
        reg.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
        iReg = IMarketRegistry(address(reg));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    /// @dev Prank `caller` and arm an expectRevert for `OwnableUnauthorizedAccount(caller)`; the
    ///      immediately-following external call is the subject of both cheatcodes.
    function _expectUnauthorized(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED, caller));
    }

    /// @dev A structurally-shaped `Asset` — the arguments only need to type-check and to carry in-range
    ///      enum ordinals, because the call is rejected at the authority gate before any field is used.
    function _minimalAsset() internal returns (IMarketRegistry.Asset memory) {
        return mkAsset(
            makeAddr("asset"),
            "TEST",
            IMarketRegistry.AssetKind.ERC20,
            mkPriceSource(makeAddr("source"), "USD"),
            noSource()
        );
    }

    function _minimalFeed() internal returns (IMarketRegistry.ConversionFeed memory f) {
        f = IMarketRegistry.ConversionFeed({
            base: makeAddr("base"), quote: makeAddr("quote"), aggregatorAddress: makeAddr("aggregator"), feedDecimals: 8
        });
    }

    // ── constructor ─────────────────────────────────────────────────────────────

    /// @notice A zero initial owner is rejected by the registry's own zero-check at initialization.
    function test_constructor_zeroInitialOwner_reverts() public {
        MarketRegistry fresh = new MarketRegistry();
        vm.expectRevert(ZERO_ADDRESS);
        fresh.initialize(address(0), address(wrapperFactory), address(fixedRateOracleFactory));
    }

    /// @notice A zero wrapper factory is rejected by the registry constructor.
    /// @dev The factory is immutable and pinned for the life of the contract: a registry that could
    ///      change factories could hand a market a wrapper from a factory nobody reviewed.
    function test_constructor_zeroWrapperFactory_reverts() public {
        MarketRegistry fresh = new MarketRegistry();
        vm.expectRevert(ZERO_ADDRESS);
        fresh.initialize(owner, address(0), address(fixedRateOracleFactory));
    }

    /// @notice A zero FIXED-RATE ORACLE factory is rejected too — the symmetric third case.
    /// @dev The registry constructor now takes two factories and zero-checks BOTH, and the argument for
    ///      the second guard is the same as for the first: the address is `immutable`, so a registry
    ///      built with a zero here would look perfectly constructed and then fail on its first
    ///      `deployFixedRateOracle` with a call into nothing — which returns empty data and decodes as
    ///      an opaque revert. Failing at construction is the only place this is legible.
    function test_constructor_zeroFixedRateOracleFactory_reverts() public {
        MarketRegistry fresh = new MarketRegistry();
        vm.expectRevert(ZERO_ADDRESS);
        fresh.initialize(owner, address(wrapperFactory), address(0));
    }

    /// @notice A non-zero initial owner is accepted and recorded; no pending owner is set, and BOTH
    ///         factories are pinned on their public getters.
    function test_constructor_nonZeroInitialOwner_setsOwner() public view {
        assertEq(reg.owner(), owner, "owner not initialized");
        assertEq(reg.pendingOwner(), address(0), "pendingOwner should be unset at deploy");
        assertEq(reg.WRAPPER_FACTORY(), address(wrapperFactory), "wrapper factory not pinned");
        assertEq(
            reg.FIXED_RATE_ORACLE_FACTORY(),
            address(fixedRateOracleFactory),
            "fixed-rate oracle factory not pinned to the address passed in"
        );
    }

    /// @notice The constructor SEEDS `"USD"` and `"ETH"` into the denomination registry, so a fresh
    ///         deployment is never in the state where nothing resolves.
    /// @dev Without the seed the owner's first action would be forced boilerplate, and forgetting it
    ///      would look like a broken registry rather than an unconfigured one: every `addAssets` would
    ///      revert `UnregisteredDenomination`. Asserted through BEHAVIOUR rather than through
    ///      `lookupDenomination`: that a "USD"-quoted source is writable on a brand-new registry is the
    ///      claim that actually matters, and the getter agreeing would not prove it.
    function test_constructor_seedsUsdAndEthDenominations() public {
        // "ETH" needs its dollar bridge before an ETH-quoted source is writable; "USD" needs nothing.
        vm.prank(owner);
        iReg.addConversionFeeds(
            one(
                IMarketRegistry.ConversionFeed({
                    base: MarketRegistryLib.ETH_DENOMINATION,
                    quote: MarketRegistryLib.USD_DENOMINATION,
                    aggregatorAddress: makeAddr("ethUsd"),
                    feedDecimals: 8
                })
            )
        );

        vm.prank(owner);
        iReg.addDenominations(one("SEEDPROBE"), one(makeAddr("probeUnit"))); // proves the owner path works too

        assertTrue(_quoteUnitAccepted("USD"), "\"USD\" must be seeded at construction");
        assertTrue(_quoteUnitAccepted("ETH"), "\"ETH\" must be seeded at construction");
        assertFalse(_quoteUnitAccepted("usd"), "registration is case-sensitive: \"usd\" is not \"USD\"");
    }

    // ── owner-gating sweep across every mutating function ───────────────────────

    /// @notice Every state-changing function is owner-only: a non-owner caller reverts
    ///         `OwnableUnauthorizedAccount(caller)`.
    /// @dev EIGHT mutations — two verbs per store, and that is the whole mutating surface. It was ten
    ///      before the API converged: `addAsset` / `seedAssets` collapsed into `addAssets` and their
    ///      feed twins into `addConversionFeeds`, `updateSource` was deleted outright (an edit is a
    ///      remove plus an add, and both halves are already in this sweep), and `removeDenominations`
    ///      is new. The former factory-allowlist and wrapper-removal functions are still gone — the
    ///      factory is an immutable constructor argument, and wrappers have no removal path.
    ///
    ///      Keep this sweep exhaustive. A new owner-only function that is not listed here is a function
    ///      whose owner gate nothing checks. The market-bound setter is the one deliberate omission: it
    ///      is not a membership verb and its gating is asserted in the market-bound section below, where
    ///      the rest of its behaviour lives.
    function test_mutations_ownerOnly_all() public {
        IMarketRegistry.Asset memory asset = _minimalAsset();
        IMarketRegistry.ConversionFeed memory feed = _minimalFeed();

        // 1/8 addAssets
        _expectUnauthorized(stranger);
        iReg.addAssets(one(asset));

        // 2/8 removeAssets
        _expectUnauthorized(stranger);
        iReg.removeAssets(one(asset.addr));

        // 3/8 addConversionFeeds
        _expectUnauthorized(stranger);
        iReg.addConversionFeeds(one(feed));

        // 4/8 removeConversionFeeds
        _expectUnauthorized(stranger);
        iReg.removeConversionFeeds(one(feed.base), one(feed.quote));

        // 5/8 addDenominations
        _expectUnauthorized(stranger);
        iReg.addDenominations(one("USDC"), one(makeAddr("usdc")));

        // 6/8 removeDenominations
        _expectUnauthorized(stranger);
        iReg.removeDenominations(one("USD"));

        // 7/8 addRecipes
        _expectUnauthorized(stranger);
        iReg.addRecipes(one(address(wrapperFactory)));

        // 8/8 removeRecipes
        _expectUnauthorized(stranger);
        iReg.removeRecipes(one(address(wrapperFactory)));
    }

    /// @notice `deploy` is the one permissionless mutation, and that is deliberate: it builds a wrapper
    ///         through the pinned factory and records it, and anybody may do that for approved assets.
    /// @dev Asserted by the error it gives a stranger: `EntryNotFound` for an unregistered asset, NOT
    ///      `OwnableUnauthorizedAccount`. If a gate were ever added, this flips.
    function test_deploy_isPermissionless() public {
        vm.prank(stranger);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        iReg.deploy(makeAddr("ca"), makeAddr("ref"), IMarketRegistry.OracleMode.PRICE);
    }

    // ── the fixed-rate oracle entrypoint (permissionless, stateless, idempotent) ──
    //
    // `deployFixedRateOracle` / `predictFixedRateOracle` are a curated passthrough onto the second
    // immutable factory. They live in the GOVERNANCE suite for one reason: the interesting property is
    // the deliberate ABSENCE of an owner gate, which is a governance fact and is pinned below rather
    // than left to be inferred from the lack of an `onlyOwner`.

    /// @dev A rate used across the cases below. Any non-zero value works; the addresses are keyed by it.
    uint256 internal constant RATE = 0.8e18;

    /// @notice `predictFixedRateOracle(rate)` is exactly where a real deployment lands, and it is the
    ///         factory's own arithmetic rather than a second copy of it.
    /// @dev Both halves matter. If the registry re-derived the `CREATE2` address itself the two could
    ///      silently disagree, and the disagreement would only show up as the idempotency check failing
    ///      to notice an existing oracle — which surfaces as an opaque, data-free `CREATE2` collision.
    function test_predictFixedRateOracle_matchesRealDeployment() public {
        address predicted = iReg.predictFixedRateOracle(RATE);
        assertEq(predicted, fixedRateOracleFactory.computeAddress(RATE), "predict must forward to the factory verbatim");
        assertEq(predicted.code.length, 0, "nothing should be deployed there yet");

        vm.prank(stranger);
        address oracle = iReg.deployFixedRateOracle(RATE);

        assertEq(oracle, predicted, "the deployment must land at the predicted address");
        assertGt(oracle.code.length, 0, "the predicted address must hold code after deployment");
    }

    /// @notice `deployFixedRateOracle(rate)` deploys an oracle that reports back the rate it was given.
    function test_deployFixedRateOracle_deploysWithTheGivenRate() public {
        vm.prank(stranger);
        address oracle = iReg.deployFixedRateOracle(RATE);

        assertEq(IRateOracle(oracle).rate(), RATE, "the deployed oracle must report the rate it was built with");
    }

    /// @notice A REPEAT call for the same rate returns the same address and does NOT revert.
    /// @dev This is the whole reason the entrypoint exists rather than callers using the factory
    ///      directly. The factory `CREATE2`s to a rate-derived address, so a second `deploy` for one rate
    ///      lands on an address that already holds code — and that fails with NO RETURN DATA AT ALL: no
    ///      selector, no reason string, nothing a caller or a simulation can decode. The registry checks
    ///      `code.length` on the predicted address first and hands the existing oracle back instead.
    function test_deployFixedRateOracle_repeatSameRate_idempotentSameAddress() public {
        vm.prank(stranger);
        address first = iReg.deployFixedRateOracle(RATE);

        // A different caller, the same rate. Must succeed, not collide.
        vm.prank(other);
        address second = iReg.deployFixedRateOracle(RATE);

        assertEq(second, first, "a repeat call must return the SAME oracle address");
        assertEq(IRateOracle(second).rate(), RATE, "the returned oracle must still be the one for this rate");
    }

    /// @notice The event fires on the FIRST call and on no later one.
    /// @dev A repeat is a complete no-op: the factory is never reached, so neither the registry's
    ///      `FixedRateOracleDeployed` nor the factory's own `OracleDeployed` can appear. The assertion is
    ///      therefore "no logs at all", which is stricter than filtering for one selector.
    function test_deployFixedRateOracle_repeatSameRate_emitsOnlyOnce() public {
        address predicted = iReg.predictFixedRateOracle(RATE);

        // `rate` and `oracle` are both indexed; `caller` is not.
        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.FixedRateOracleDeployed(RATE, predicted, stranger);
        vm.prank(stranger);
        iReg.deployFixedRateOracle(RATE);

        vm.recordLogs();
        vm.prank(other);
        iReg.deployFixedRateOracle(RATE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "a repeat deployFixedRateOracle must emit nothing at all");
    }

    /// @notice A zero rate reverts with the real, decodable `IRateOracle.InvalidRate()` selector.
    /// @dev The failure comes from the ORACLE's constructor, bubbling factory → registry → caller. The
    ///      idempotency check cannot swallow it: `computeAddress(0)` returns a well-formed address that
    ///      can never hold code (the only account that could deploy there is the factory, whose
    ///      construction for rate 0 reverts), so the code-length check always falls through to the
    ///      factory. There is deliberately no second zero-check in the registry.
    function test_deployFixedRateOracle_zeroRate_revertsInvalidRate() public {
        // Prediction itself never reverts, not even for zero.
        address predicted = iReg.predictFixedRateOracle(0);
        assertEq(predicted.code.length, 0, "the zero-rate address can never hold code");

        vm.prank(stranger);
        vm.expectRevert(IRateOracle.InvalidRate.selector);
        iReg.deployFixedRateOracle(0);
    }

    /// @notice Two different rates are two different oracles at two different addresses.
    function test_deployFixedRateOracle_distinctRates_distinctAddresses() public {
        vm.prank(stranger);
        address a = iReg.deployFixedRateOracle(RATE);
        vm.prank(stranger);
        address b = iReg.deployFixedRateOracle(RATE + 1);

        assertTrue(a != b, "distinct rates must land at distinct addresses");
        assertEq(IRateOracle(a).rate(), RATE, "first oracle's rate");
        assertEq(IRateOracle(b).rate(), RATE + 1, "second oracle's rate");
    }

    /// @notice There is deliberately NO owner gate: a stranger deploys a fixed-rate oracle successfully.
    /// @dev Pinned by a test so the absence of access control reads as a decision rather than an
    ///      oversight. A `FixedRateOracle` has one constructor argument, one `view` function, no owner,
    ///      no setter and no privilege, so deploying one for an arbitrary rate cannot affect anything
    ///      that has not chosen to read it. The decision that matters is whether a market ADOPTS a given
    ///      oracle, and that lives with the market and its recipe. If a gate is ever added, this test
    ///      flips — which is the point of asserting it.
    function test_deployFixedRateOracle_isPermissionless() public {
        assertTrue(stranger != reg.owner(), "setup: the caller must not be the owner");

        vm.prank(stranger);
        address oracle = iReg.deployFixedRateOracle(RATE);

        assertGt(oracle.code.length, 0, "a non-owner must be able to deploy a fixed-rate oracle");
        assertEq(IRateOracle(oracle).rate(), RATE, "the stranger's oracle must carry the requested rate");
    }

    // ── market bound (owner-set) ────────────────────────────────────────────────
    //
    // One scalar — the longest life a market may be created with — and it is the only setting in this
    // contract that is UPDATED in place rather than added and removed. It exists because a market is
    // permanent: one mistyped payload mints a market that expires in the year 58527, and nobody can
    // take it back. The cases below pin the three facts a curator depends on: the bound is never
    // absent, only the owner moves it, and every move is in the log.

    /// @notice A fresh registry already has the bound set, at the constant the contract publishes.
    /// @dev There is no window in which the bound is unset. A registry deployed and handed to the
    ///      periphery before the owner has done anything at all still refuses an absurd expiry, so the
    ///      safe configuration is the one you get by doing nothing.
    function test_constructor_seedsTheMarketBound() public view {
        assertEq(reg.maxExpiryDuration(), reg.DEFAULT_MAX_EXPIRY_DURATION(), "expiry bound not seeded");

        // The published constant itself, so a change to it is a change a reader has to make here
        // deliberately rather than one that slips through against a self-referential assertion.
        assertEq(reg.DEFAULT_MAX_EXPIRY_DURATION(), 30 days, "the starting market life is one month");
    }

    /// @notice The CONSTRUCTOR emits the starting value, previous bound zero.
    /// @dev The reason the constructor sets the bound through the same internal setter the owner uses
    ///      instead of writing the slot directly. The registry promises that an indexer can rebuild its
    ///      entire state from logs alone, with no `eth_call` anywhere — a starting value written
    ///      silently would break that promise, because a replayer reading only events would see the
    ///      first `MaxExpiryDurationUpdated` of the contract's life and have no idea what the bound was
    ///      before it. Emitting from the constructor makes the zero the honest answer to "where did this
    ///      bound begin".
    function test_constructor_emitsTheMarketBound() public {
        MarketRegistry fresh = new MarketRegistry();

        // No indexed fields on the event, so only the data is checked.
        vm.expectEmit(false, false, false, true, address(fresh));
        emit IMarketRegistry.MaxExpiryDurationUpdated(0, 30 days);

        fresh.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
    }

    /// @notice The owner moves the expiry bound; the view reports the new value and the update is
    ///         logged with both the old and the new number.
    function test_setMaxExpiryDuration_ownerSets_viewAndEvent() public {
        uint256 previous = reg.maxExpiryDuration();
        uint256 next = 90 days;

        vm.expectEmit(false, false, false, true, address(reg));
        emit IMarketRegistry.MaxExpiryDurationUpdated(previous, next);
        vm.prank(owner);
        iReg.setMaxExpiryDuration(next);

        assertEq(reg.maxExpiryDuration(), next, "the view must report the new expiry bound");
    }

    /// @notice The setter is not reachable by a non-owner: it reverts
    ///         `OwnableUnauthorizedAccount(caller)`.
    /// @dev This is as privileged as any membership verb. Loosening it is what lets an absurd market
    ///      through, and tightening it is what stops honest ones being created, so both directions
    ///      belong to the curator Safe and nobody else.
    function test_setMaxExpiryDuration_nonOwner_revertsUnauthorized() public {
        _expectUnauthorized(stranger);
        iReg.setMaxExpiryDuration(90 days);

        assertEq(reg.maxExpiryDuration(), reg.DEFAULT_MAX_EXPIRY_DURATION(), "expiry bound moved on a failed call");
    }

    /// @notice Zero is refused, with `ZeroBound`.
    /// @dev Zero is not the tightest possible bound, it is a market-creation kill switch wearing a
    ///      bound's clothes: every expiry is past `block.timestamp + 0`, so a zero here stops market
    ///      creation entirely — and stops it SILENTLY, with nothing in the log that says "creation is
    ///      off" and no way for a caller to tell a paused registry from a broken one. Pausing belongs to
    ///      the controller, which has a real pause built for the job and an event that announces it.
    ///      Refusing zero keeps the two decisions apart.
    function test_setMaxExpiryDuration_zero_revertsZeroBound() public {
        vm.prank(owner);
        vm.expectRevert(ZERO_BOUND);
        iReg.setMaxExpiryDuration(0);

        assertEq(reg.maxExpiryDuration(), reg.DEFAULT_MAX_EXPIRY_DURATION(), "expiry bound cleared by a zero call");
    }

    /// @notice Setting the bound to the value it already holds still emits, with the two numbers equal.
    /// @dev The setter is unconditional — no "did it change" check — and that is the behaviour worth
    ///      keeping. A curator Safe that re-affirms the bound has taken a real governance action, and
    ///      the log is where that action is visible; suppressing the event would make a deliberate
    ///      re-affirmation indistinguishable from a transaction that never happened.
    function test_setMaxExpiryDuration_sameValue_stillEmits() public {
        uint256 expiry = reg.maxExpiryDuration();

        vm.expectEmit(false, false, false, true, address(reg));
        emit IMarketRegistry.MaxExpiryDurationUpdated(expiry, expiry);
        vm.prank(owner);
        iReg.setMaxExpiryDuration(expiry);

        assertEq(reg.maxExpiryDuration(), expiry, "a no-op set must leave the expiry bound where it was");
    }

    // ── registerDenomination structural checks ──────────────────────────────────

    /// @notice An empty label is refused, and so is a zero unit — the two structural checks on the one
    ///         write path the constructor's seed also uses.
    function test_addDenominations_structuralChecks() public {
        vm.prank(owner);
        vm.expectRevert(EMPTY_NAME);
        iReg.addDenominations(one(""), one(makeAddr("unit")));

        vm.prank(owner);
        vm.expectRevert(ZERO_ADDRESS);
        iReg.addDenominations(one("USDC"), one(address(0)));
    }

    /// @notice Re-registering an EXISTING label is REFUSED. Registration is add-only; correcting a
    ///         label's unit is a removal followed by an add.
    /// @dev This is the behaviour that flipped when the API converged. The old path was
    ///      create-or-overwrite, which was defensible only while there was no removal path to pair a
    ///      duplicate-rejection with. There is one now, so an overwrite would be a second, silent way
    ///      to change a label — and silent is the problem: a re-point that leaves no removal in the log
    ///      is indistinguishable from a first registration to anyone reading events.
    function test_addDenominations_existingLabel_reverts() public {
        vm.prank(owner);
        iReg.addDenominations(one("GBPX"), one(makeAddr("gbpxUnit")));

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        iReg.addDenominations(one("GBPX"), one(makeAddr("gbpxOtherUnit")));
    }

    /// @notice Re-pointing a label is remove-then-add, and it takes effect on the very next read.
    /// @dev Observed two ways: through `lookupDenomination`, which is the direct answer, and through the
    ///      GRAPH, which is the one that matters — the label starts out pointing at a unit WITH a dollar
    ///      edge (so a source quoting it is writable) and ends up pointing at one WITHOUT (so the same
    ///      source stops being writable). Re-pointing does NOT retroactively revalidate assets that
    ///      already stored the label; they keep their stored string and start failing at `deploy`.
    function test_denomination_rePointIsRemoveThenAdd() public {
        address unitWithPath = makeAddr("gbpxUnitWithPath");
        address unitWithoutPath = makeAddr("gbpxUnitWithoutPath");

        vm.prank(owner);
        iReg.addDenominations(one("GBPX"), one(unitWithPath));
        vm.prank(owner);
        iReg.addConversionFeeds(one(mkFeed(unitWithPath, MarketRegistryLib.USD_DENOMINATION, makeAddr("gbpxUsd"), 8)));
        assertTrue(_quoteUnitAccepted("GBPX"), "setup: the first registration should be usable");

        // The re-point, as a curator Safe would bundle it. Both halves land in the log: the removal
        // names the label it dropped, the add carries the label alongside the unit it now points at.
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryRemoved(
            IMarketRegistry.Namespace.Denomination, keccak256(bytes("GBPX")), abi.encode(string("GBPX"))
        );
        iReg.removeDenominations(one("GBPX"));

        vm.expectEmit(true, true, false, true, address(reg));
        emit IMarketRegistry.EntryAdded(
            IMarketRegistry.Namespace.Denomination,
            keccak256(bytes("GBPX")),
            abi.encode(string("GBPX"), unitWithoutPath)
        );
        iReg.addDenominations(one("GBPX"), one(unitWithoutPath));
        vm.stopPrank();

        (bool found, address unit) = iReg.lookupDenomination("GBPX");
        assertTrue(found, "the label must still be registered after the re-point");
        assertEq(unit, unitWithoutPath, "lookup must report the NEW unit");

        assertFalse(
            _quoteUnitAccepted("GBPX"), "a re-pointed label must resolve through the NEW unit, which has no path"
        );
    }

    /// @notice Removing a label makes it stop resolving, and a source quoting it stops being writable.
    /// @dev The teeth. There is no cascade: an asset that already stored the label keeps its entry and
    ///      starts failing, which is the same shape `removeConversionFeeds` has.
    function test_removeDenominations_labelStopsResolving() public {
        vm.prank(owner);
        iReg.addDenominations(one("GBPY"), one(makeAddr("gbpyUnit")));
        (bool foundBefore,) = iReg.lookupDenomination("GBPY");
        assertTrue(foundBefore, "setup: the label should resolve after the add");

        vm.prank(owner);
        iReg.removeDenominations(one("GBPY"));

        (bool foundAfter, address unit) = iReg.lookupDenomination("GBPY");
        assertFalse(foundAfter, "a removed label must stop resolving");
        assertEq(unit, address(0), "a removed label must report the zero unit");
        assertFalse(_quoteUnitAccepted("GBPY"), "a source quoting a removed label must stop being writable");
    }

    /// @notice Removing a label that was never registered reverts `EntryNotFound`.
    function test_removeDenominations_missing_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        iReg.removeDenominations(one("NEVERREGISTERED"));
    }

    /// @notice Even the constructor's seeds are removable — nothing is privileged.
    /// @dev Removing `"USD"` is close to bricking the registry, since almost nothing resolves a path
    ///      afterwards. It is still allowed: this is a governance decision, and the constructor does not
    ///      get to veto it.
    function test_removeDenominations_seededLabelIsRemovable() public {
        vm.prank(owner);
        iReg.removeDenominations(one("USD"));

        (bool found,) = iReg.lookupDenomination("USD");
        assertFalse(found, "the seeded USD label must be removable like any other");
        assertFalse(_quoteUnitAccepted("USD"), "nothing quoting USD should be writable once it is gone");
    }

    /// @notice `addDenominations` refuses mismatched array lengths rather than silently truncating.
    function test_addDenominations_lengthMismatch_reverts() public {
        string[] memory labels = new string[](2);
        labels[0] = "AAA";
        labels[1] = "BBB";

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.ArrayLengthMismatch.selector);
        iReg.addDenominations(labels, one(makeAddr("onlyOneUnit")));
    }

    // ── transferOwnership (two-step) ────────────────────────────────────────────

    /// @notice `transferOwnership` sets the pending owner only; authority does not move.
    function test_transferOwnership_pendingOnly_noAuthorityMove() public {
        vm.expectEmit(true, true, false, false, address(reg));
        emit Ownable2Step.OwnershipTransferStarted(owner, pending);

        vm.prank(owner);
        reg.transferOwnership(pending);

        assertEq(reg.owner(), owner, "authority moved on transferOwnership");
        assertEq(reg.pendingOwner(), pending, "pendingOwner not set");
    }

    /// @notice A mis-directed transfer is recoverable: the owner re-points the pending owner with a
    ///         second call, and the stale pending owner can no longer accept.
    function test_transferOwnership_misExecution_recoverable() public {
        // First (mistaken) transfer.
        vm.prank(owner);
        reg.transferOwnership(other);
        assertEq(reg.pendingOwner(), other, "first pending not set");

        // Re-point to the intended pending owner — authority still has not moved.
        vm.prank(owner);
        reg.transferOwnership(pending);
        assertEq(reg.pendingOwner(), pending, "pending not re-pointed");
        assertEq(reg.owner(), owner, "authority moved during re-point");

        // The stale (originally-targeted) pending owner can no longer accept.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED, other));
        reg.acceptOwnership();

        // The re-pointed pending owner accepts and gains authority.
        vm.prank(pending);
        reg.acceptOwnership();
        assertEq(reg.owner(), pending, "re-pointed owner did not gain authority");
        assertEq(reg.pendingOwner(), address(0), "pending not cleared on accept");
    }

    // ── acceptOwnership ─────────────────────────────────────────────────────────

    /// @notice Only the pending owner may accept; any other caller reverts
    ///         `OwnableUnauthorizedAccount(caller)`.
    function test_acceptOwnership_nonPending_reverts() public {
        vm.prank(owner);
        reg.transferOwnership(pending);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED, stranger));
        reg.acceptOwnership();

        // State unchanged.
        assertEq(reg.owner(), owner, "authority moved on failed accept");
        assertEq(reg.pendingOwner(), pending, "pending changed on failed accept");
    }

    // ── renounceOwnership is disabled ───────────────────────────────────────────

    /// @notice The owner calling `renounceOwnership` reverts `RenounceDisabled` — the registry can
    ///         never become ownerless.
    /// @dev Every mutation here is owner-only, so an ownerless registry is a frozen one: no new asset,
    ///      no feed, no recipe, no denomination, and no way back.
    function test_renounceOwnership_ownerCaller_revertsRenounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(RENOUNCE_DISABLED);
        reg.renounceOwnership();

        // Sanity: authority is retained regardless.
        assertEq(reg.owner(), owner, "owner was renounced");
    }

    /// @notice A non-owner calling `renounceOwnership` reverts `OwnableUnauthorizedAccount` — the
    ///         authority check wins over `RenounceDisabled`.
    /// @dev Asserting the authority selector (not `RenounceDisabled`) is load-bearing: the `onlyOwner`
    ///      gate must fire FIRST for a non-owner. Asserting `RenounceDisabled` here would hide a broken
    ///      check order — a stranger would be told the function is disabled (leaking that ordering)
    ///      instead of being rejected for lack of authority, and a future re-order that let
    ///      `RenounceDisabled` fire first for everyone would pass undetected.
    function test_renounceOwnership_nonOwnerCaller_revertsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED, stranger));
        reg.renounceOwnership();

        assertEq(reg.owner(), owner, "owner changed on unauthorized renounce");
    }

    // ── internal probes ─────────────────────────────────────────────────────────

    /// @dev Is `label` a registered denomination with a dollar path? Probed by attempting an add whose
    ///      only source quotes it. Deliberately NOT `lookupDenomination`, which answers only the first
    ///      half of the question — behaviour is the honest oracle for both halves at once. Each probe uses a FRESH asset address and name so a success cannot
    ///      collide with a previous one.
    function _quoteUnitAccepted(string memory label) internal returns (bool) {
        // A DEPLOYED token, not a label: the walk probes the asset address, and a call to a codeless
        // address makes the probe's ABI decode revert uncatchably, which would make every probe
        // answer "not accepted" for the wrong reason.
        address token = address(new MockERC20("Probe", "PRB", 18));
        IMarketRegistry.Asset memory e = mkAsset(
            token,
            string.concat("PROBE:", label),
            IMarketRegistry.AssetKind.ERC20,
            mkPriceSource(makeAddr("probeSource"), label),
            noSource()
        );
        vm.prank(owner);
        (bool ok,) = address(reg).call(abi.encodeWithSelector(IMarketRegistry.addAssets.selector, one(e)));
        return ok;
    }
}
