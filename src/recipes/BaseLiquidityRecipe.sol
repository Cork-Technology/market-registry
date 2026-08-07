// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMarketRecipe, RecipeSource} from "../interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../interfaces/IRateOracle.sol";
import {MarketRegistryLib} from "../MarketRegistryLib.sol";

/// @title BaseLiquidityRecipe
/// @notice The recipe for markets that should trade freely: the rate window is opened as wide as
///         `CorkPoolManager` will accept, and both movement allowances are set high enough that they
///         never bind in practice. Nothing is configurable — the four limits are compile-time
///         constants, so every deployment of this contract stands for the same, maximally permissive
///         policy.
/// @dev ## WHY THIS CONTRACT IS ABSTRACT
///
///      The policy above says nothing about WHICH KIND OF RATE it is applied to. A market quoted from
///      a price feed and a market quoted from a vault's net asset value want the same maximally
///      permissive window; they differ only in where `CorkLimitOrderAdapter`'s step 3 goes to fetch
///      the oracle, which is what `source()` announces. That single answer is the only thing left
///      open here — see {_source} — so the two live recipes are one-line subclasses and the policy
///      itself exists exactly once.
///
///      ## WHERE THE ANCHOR RATE COMES FROM
///
///      Every one of the four limits is a multiple of a single number, the ANCHOR RATE. The two
///      entrypoints get that number from different places, and the asymmetry is the whole design:
///
///      - `resolve` runs OFF-CHAIN at signing time, when the pair's oracle may not exist yet. It
///        prefers the live oracle and falls back to the anchor carried in `additionalData` when no
///        oracle address is supplied.
///      - `verify` runs ON-CHAIN at fill time, after the adapter's step 3 has produced the oracle.
///        It reads ONLY the oracle and ignores `additionalData` entirely — at that point a live rate
///        is guaranteed, so the order's own account of the rate is not worth trusting.
abstract contract BaseLiquidityRecipe is IMarketRecipe, Initializable {
    // ─────────────────────────────── Errors ────────────────────────────────

    /// @notice Thrown at initialization when the registry address is zero.
    error ZeroRegistry();

    /// @notice Thrown by `resolve` when no oracle was supplied and `additionalData` is not exactly one
    ///         ABI word.
    /// @param length The `additionalData` length that was supplied.
    error MalformedAdditionalData(uint256 length);

    /// @notice Thrown by `resolve` when the anchor rate it settled on is zero.
    error ZeroAnchorRate();

    /// @notice Thrown by `verify` when the caller supplied no rate oracle (`rateOracle` is zero).
    /// @dev A revert, not a `false`, per `IMarketRecipe.verify`: `false` means the constraint is
    ///      unacceptable, a revert is reserved for a recipe that genuinely CANNOT answer. `verify`
    ///      reads the rate from nowhere else, so without an oracle there is no verdict to give.
    ///
    ///      Unreachable on the adapter's path, where step 3 produces the oracle before `verify` runs.
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    error RateOracleNotDeployed(address ca, address ref);

    /// @notice Thrown by `resolve` when the derived window is not strictly widening.
    /// @param rateMin The derived floor.
    /// @param rateMax The derived ceiling.
    error WindowCollapsed(uint256 rateMin, uint256 rateMax);

    // ─────────────────────────────── Storage ────────────────────────────────

    /// @notice The registry this instance is deployed against.
    /// @dev Set once through the subclass's `initialize` rather than a constructor, so the creation
    ///      code carries no arguments and each recipe lands on the same CREATE2 address on every
    ///      chain. Deployed through `AtomicDeployer`, which initializes in the deployment
    ///      transaction.
    IMarketRegistry public REGISTRY;

    /// @notice The floor every constraint this recipe produces carries: one wei, regardless of rate.
    /// @dev The smallest value `CorkPoolManager.sol:110` accepts, and therefore the closest this
    ///      recipe can get to having no floor at all. See {_constraintFor} for why it is a literal
    ///      rather than a band.
    uint256 public constant RATE_MIN = 1;

    /// @notice The floor band handed to `applyBands`: 100%, the whole rate below the anchor.
    /// @dev On the percentage scale (`1e18` = 1%), so `100e18`. Its output is always zero and is
    ///      always discarded in favour of {RATE_MIN}; it is named here so the "fully open floor"
    ///      intent is visible on-chain rather than buried in the helper.
    uint256 public constant RATE_MIN_PERCENTAGE = 100e18;

    /// @notice How far above the anchor the ceiling sits: 100%, putting `rateMax` at twice the anchor.
    /// @dev On the percentage scale (`1e18` = 1%), so `100e18`.
    uint256 public constant RATE_MAX_PERCENTAGE = 100e18;

    /// @notice Rate movement allowed per day: 100% of the anchor rate.
    /// @dev Granting a whole day's allowance equal to the entire rate is deliberate — this recipe
    ///      exists so the allowance never binds. `MarketRegistryLib` does not bound this band.
    ///
    ///      Being exactly 100% is also what lets `verify` read the anchor back out of a constraint
    ///      instead of being handed it: at 100% the field IS the anchor. Change this and `verify`
    ///      stops accepting anything — it would recover the wrong anchor and the shape check would
    ///      fail — so recover the anchor differently if this ever moves.
    uint256 public constant RATE_CHANGE_PER_DAY_MAX_PERCENTAGE = 100e18;

    /// @notice Ceiling on accumulated movement allowance: 300% of the anchor rate.
    /// @dev Three days of the per-day allowance, for the same reason.
    uint256 public constant RATE_CHANGE_CAPACITY_MAX_PERCENTAGE = 300e18;

    /// @dev One-time setup shared by the two subclasses; only callable from inside their `initialize`.
    /// @param registry The `MarketRegistry` this recipe is deployed against. Must be non-zero.
    function __BaseLiquidityRecipe_init(IMarketRegistry registry) internal onlyInitializing {
        if (address(registry) == address(0)) revert ZeroRegistry();
        REGISTRY = registry;
    }

    // ─────────────────────────────── IMarketRecipe ──────────────────────────

    /// @inheritdoc IMarketRecipe
    /// @dev The subclass's literal, handed straight back. Every other line in this file is identical
    ///      across the two liquidity recipes; this is the one answer they disagree on, and it is what
    ///      tells the adapter's step 3 which `IMarketRegistry.OracleMode` to deploy the pair's oracle
    ///      in. See {_source}.
    function source() external view override returns (RecipeSource) {
        return _source();
    }

    /// @inheritdoc IMarketRecipe
    /// @dev A fixed string. It quotes the actual limits, which a parameterised recipe could not do,
    ///      and it says where each entrypoint takes its anchor from — this string plus the public
    ///      getters are the whole on-chain account of what approving this address meant.
    ///
    ///      Shared by both subclasses, and it does not name the rate kind: the policy really is the
    ///      same either way, and `source()` is where a reader looks to find out which oracle a given
    ///      approved address is for.
    function description() external view virtual override returns (string memory) {
        return "Liquidity: the widest rate window CorkPoolManager will accept. rateMin is 1 wei "
            "always, rateMax is twice the anchor rate, rateChangePerDayMax is the whole anchor rate "
            "and rateChangeCapacityMax is three times it. Nothing is configurable - all four limits "
            "are compile-time constants. resolve takes the anchor from the rate oracle when one is "
            "supplied, and otherwise from additionalData = abi.encode(uint256 anchorRate). verify "
            "ignores additionalData and requires an oracle: it checks that all four limits are "
            "consistent with a single anchor and that the LIVE oracle rate sits strictly inside "
            "[rateMin, rateMax], so a window that no longer contains reality stops filling.";
    }

    /// @inheritdoc IMarketRecipe
    /// @dev The live oracle is the preferred anchor, and `additionalData` is the fallback for the one
    ///      case the oracle cannot cover: the FIRST order ever written against a pair, signed before
    ///      the adapter's step 3 has deployed the oracle. `IMarketRecipe.resolve` warns that
    ///      `rateOracle` may well be `address(0)` at signing time for an oracle-backed recipe, so
    ///      insisting on one would make this recipe unusable for exactly the order that creates the
    ///      market.
    ///
    ///      A zero `rateOracle` is therefore the only thing that selects the fallback. Once an address
    ///      is supplied it is authoritative and `additionalData` is not read at all — an agent that
    ///      passes both is telling us the oracle is live, and the oracle wins.
    ///
    ///      Reverts loudly on every bad input rather than returning a degenerate constraint, because
    ///      this is called off-chain by the agent building the order: the mistake is reported at the
    ///      moment it is made.
    ///
    ///      `ca` and `ref` are accepted to satisfy the interface and are genuinely unused: this recipe
    ///      has no per-pair policy.
    function resolve(
        address, /* ca */
        address, /* ref */
        address rateOracle,
        bytes calldata additionalData
    )
        external
        view
        override
        returns (IMarketRegistry.ResolvedConstraint memory constraint)
    {
        uint256 anchorRate =
            rateOracle == address(0) ? _decodeAnchorRate(additionalData) : IRateOracle(rateOracle).rate();
        if (anchorRate == 0) revert ZeroAnchorRate();

        constraint = _constraintFor(anchorRate);

        // `CorkPoolManager.sol:111` is strict, so a window that did not widen is uncreatable. The
        // floor is a non-zero constant, so this one comparison covers both of the pool manager's
        // constraint requirements. See {WindowCollapsed} for why it is kept though it cannot fire.
        if (constraint.rateMin >= constraint.rateMax) {
            revert WindowCollapsed(constraint.rateMin, constraint.rateMax);
        }
    }

    /// @inheritdoc IMarketRecipe
    /// @dev Returns false rather than reverting for every rejection, as the interface requires: the
    ///      adapter owns the revert and its selector. The one exception is a missing oracle, which is
    ///      "cannot answer" rather than "no" — see {RateOracleNotDeployed}.
    ///
    ///      THE ORACLE IS THE ONLY RATE THIS FUNCTION TRUSTS. `additionalData` is ignored outright,
    ///      whatever it contains, because by the time this runs the adapter's step 3 has produced a
    ///      live oracle and the order's own account of the rate adds nothing but a way to lie.
    ///
    ///      ## Two checks: the shape, then reality
    ///
    ///      The constraint was derived at SIGNING time and this runs at FILL time, so the rate has
    ///      moved. Re-deriving all four limits from the live rate and demanding equality would break
    ///      every resting order on the first tick — a pool's identifier includes its constraint, so
    ///      limits that track the live rate would invalidate the share addresses the order was signed
    ///      against. The live rate is therefore used as a BOUND, not as the anchor.
    ///
    ///      1. SHAPE. All four limits are multiples of one anchor, and `rateChangePerDayMax` IS that
    ///         anchor — {RATE_CHANGE_PER_DAY_MAX_PERCENTAGE} is 100%, so the field reads the anchor
    ///         back exactly. Feeding it to {_constraintFor} — the same helper `resolve` uses, so this
    ///         compares against the real answer rather than a second implementation that could drift —
    ///         and comparing field for field says: these four numbers are internally consistent, and
    ///         they are numbers this recipe would have produced. Nothing else needs to be carried.
    ///      2. REALITY. The live rate must sit STRICTLY inside `[rateMin, rateMax]`. This is what the
    ///         anchor is held to: a window derived from an anchor nowhere near the market cannot
    ///         contain the live rate, so it stops filling. Strict at both ends because a rate sitting
    ///         exactly on an edge is a rate the pool's constraint adapter would clamp, and a market
    ///         running at its own boundary is not a market trading freely.
    ///
    ///      THE BOUND IS ONE-SIDED, and that is the honest limit of what this recipe enforces. The
    ///      ceiling is twice the anchor, so an anchor at or below half the live rate is caught. The
    ///      floor is a flat 1 wei at every anchor, so an anchor ABOVE the live rate is not caught at
    ///      all — an arbitrarily wide window still contains the market. Approving this address means
    ///      accepting that a market may be created far wider than it needs to be, which is in keeping
    ///      with a recipe whose whole purpose is to be maximally permissive.
    ///
    ///      ## The `createNewPool` guarantees, enforced here on purpose
    ///
    ///      So a rejection is diagnosed at the step that owns it instead of several frames inside the
    ///      controller. `CorkPoolManager.createNewPool` imposes exactly two requirements on the four
    ///      constraint fields:
    ///
    ///          require(poolParams.rateMin > 0, InvalidParams());                   // :110
    ///          require(poolParams.rateMin < poolParams.rateMax, InvalidParams());  // :111
    ///
    ///      Both are checked first, so a structurally impossible constraint is rejected by the
    ///      cheapest test rather than by the one that costs an external call.
    function verify(
        address ca,
        address ref,
        address rateOracle,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata /* additionalData */
    ) external view override returns (bool) {
        if (rateOracle == address(0)) revert RateOracleNotDeployed(ca, ref);

        // The pool manager's two requirements, `CorkPoolManager.sol:110-111`. First, because a
        // constraint that fails them can never be created anyway.
        if (constraint.rateMin == 0) return false;
        if (constraint.rateMin >= constraint.rateMax) return false;

        // The anchor, read back out of the constraint itself.
        uint256 anchorRate = constraint.rateChangePerDayMax;
        if (anchorRate == 0) return false;

        // The shape. Exact, field for field, against `resolve`'s own helper.
        IMarketRegistry.ResolvedConstraint memory expected = _constraintFor(anchorRate);
        if (
            constraint.rateMin != expected.rateMin || constraint.rateMax != expected.rateMax
                || constraint.rateChangePerDayMax != expected.rateChangePerDayMax
                || constraint.rateChangeCapacityMax != expected.rateChangeCapacityMax
        ) return false;

        // Reality. Left last because it is the only check that costs an external call.
        uint256 rate = IRateOracle(rateOracle).rate();
        return rate > constraint.rateMin && rate < constraint.rateMax;
    }

    // ─────────────────────────────── Internal ───────────────────────────────

    /// @dev The one decision this contract leaves to a subclass: which kind of rate the shared policy
    ///      above is applied to. A subclass returns a literal and nothing else, so that approving one
    ///      of its instances approves this file's policy and a choice of oracle, and nothing more.
    /// @return The subclass's rate kind, surfaced verbatim by {source}.
    function _source() internal pure virtual returns (RecipeSource);

    /// @dev The constraint this recipe stands behind at a given anchor rate. Both `resolve` and
    ///      `verify` go through here, which is what makes "would this recipe have produced it" a
    ///      comparison against the real answer rather than against a re-derivation that could drift.
    ///
    ///      `applyBands` is the one place the PERCENTAGE scale (`1e18` = 1%) meets the RATE scale
    ///      (`1e18` = 1.0), and it stays the only arithmetic here — nothing in this file divides by
    ///      `100e18`. Two copies of that conversion is a 100x error waiting for whichever copy drifts.
    ///
    ///      The floor is then overwritten, and that is the whole reason this helper has a second
    ///      statement. A fully open floor band resolves to zero, which `CorkPoolManager.sol:110`
    ///      refuses, and no percentage produces 1 wei — the band is a fraction OF THE RATE, so the
    ///      only way to a rate-independent floor is to assign it. See {RATE_MIN}.
    /// @param rate The anchor rate, 18-decimal fixed point (`1e18` = 1.0).
    function _constraintFor(uint256 rate) private pure returns (IMarketRegistry.ResolvedConstraint memory r) {
        r = MarketRegistryLib.applyBands(
            rate,
            RATE_MIN_PERCENTAGE,
            RATE_MAX_PERCENTAGE,
            RATE_CHANGE_PER_DAY_MAX_PERCENTAGE,
            RATE_CHANGE_CAPACITY_MAX_PERCENTAGE
        );
        r.rateMin = RATE_MIN;
    }

    /// @dev Decode `additionalData` as `abi.encode(uint256 anchorRate)`, rejecting anything that is
    ///      not exactly one word with a named error. Reached only on `resolve`'s fallback path, when no
    ///      oracle was supplied; `verify` never reads these bytes at all.
    /// @param additionalData The order-carried bytes.
    function _decodeAnchorRate(bytes calldata additionalData) private pure returns (uint256) {
        if (additionalData.length != 32) revert MalformedAdditionalData(additionalData.length);
        return abi.decode(additionalData, (uint256));
    }
}
