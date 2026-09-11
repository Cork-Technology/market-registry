// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMarketRecipe, RecipeSource} from "../interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../interfaces/IRateOracle.sol";
import {IVersion} from "../interfaces/IVersion.sol";
import {MarketRegistryLib} from "../MarketRegistryLib.sol";

/// @title ApySpreadImpairmentRecipe
/// @notice The impairment recipe: a market's rate may drift only as far as a bounded annual yield
///         difference would carry it over the market's life. The window is the anchor rate plus or
///         minus `apySpreadPercentage * durationSeconds / 365 days`, daily movement is one day of
///         that spread, and the accumulated capacity is seven of those days.
/// @dev `extraData` is produced by {encodeExtraData} and read back by {decodeExtraData}.
///
///      Both dials that size the window come from the order, so both are bounded here. The spread is
///      capped at {MAX_APY_SPREAD_PERCENTAGE} and the derived band at {MAX_BAND_PERCENTAGE}. The
///      declared life is bound to the market's own remaining life on the fill that creates the pool,
///      and only then: the remaining life shrinks every block while the signed duration is fixed, so
///      re-checking on later fills would strand every resting order after one block. The adapter
///      applies its own expiry bound the same way, once, at creation.
contract ApySpreadImpairmentRecipe is IMarketRecipe, Initializable, IVersion {
    /// @notice The ways the numbers an order carries can fail this recipe, one variant per rule.
    enum CheckFailure {
        None,
        ZeroAnchor,
        ZeroDuration,
        DurationTooLong,
        SpreadTooHigh,
        BandTooWide,
        WindowCollapsed
    }

    /// @notice Thrown at initialization when the registry address is zero.
    error ZeroRegistry();

    /// @notice Thrown by `resolve` and `decodeExtraData` when `extraData` is not the layout
    ///         {encodeExtraData} produces.
    error MalformedExtraData(uint256 length);

    /// @notice Thrown by `resolve` when the anchor rate it settled on is zero.
    error ZeroAnchorRate();

    /// @notice Thrown by `resolve` when the market has no life at all.
    error ZeroDuration();

    /// @notice Thrown by `resolve` when the market outlives the registry's creation bound. `verify`
    ///         never applies this bound: it is a creation-time rule, and re-checking it on every fill
    ///         would strand every resting order the moment governance tightened it. On the creating
    ///         fill `verify` instead holds the declared life to the market's own remaining life.
    error DurationTooLong(uint256 durationSeconds, uint256 maxDuration);

    /// @notice Thrown by `resolve` when the annual spread passes {MAX_APY_SPREAD_PERCENTAGE}.
    error SpreadTooHigh(uint256 apySpreadPercentage, uint256 maxSpreadPercentage);

    /// @notice Thrown by `resolve` when the derived band passes {MAX_BAND_PERCENTAGE}.
    error BandTooWide(uint256 bandPercentage, uint256 maxBandPercentage);

    /// @notice Thrown by `verify` when the caller supplied no rate oracle.
    error RateOracleNotDeployed(address ca, address ref);

    /// @notice Thrown by `resolve` when the derived window is not one a pool could be created with.
    error WindowCollapsed(uint256 rateMin, uint256 rateMax);

    /// @notice The registry this instance is deployed against.
    IMarketRegistry public REGISTRY;

    /// @notice The year the annual spread is quoted against, in seconds.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice How many days of movement the accumulated allowance is worth.
    uint256 public constant CAPACITY_DAYS = 7;

    /// @notice The only `extraData` length this recipe accepts: the three words {encodeExtraData} writes.
    uint256 public constant EXTRA_DATA_LENGTH = 96;

    /// @notice The widest annual spread an order may declare, percentage scale: 100% a year.
    /// @dev Policy. Without it the spread is a second free dial on the window width: a short declared
    ///      life with a huge spread produces the same band as a long life with a modest one.
    uint256 public constant MAX_APY_SPREAD_PERCENTAGE = 100e18;

    /// @notice The widest band the spread and the life may combine into, percentage scale: 50%.
    /// @dev Policy. Keeps the floor at no less than half the anchor, well away from the zero floor
    ///      that a 100% band would produce.
    uint256 public constant MAX_BAND_PERCENTAGE = 50e18;

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    /// @param registry The `MarketRegistry` whose `maxExpiryDuration` bounds the markets this recipe resolves for.
    function initialize(IMarketRegistry registry) external initializer {
        if (address(registry) == address(0)) revert ZeroRegistry();
        REGISTRY = registry;
    }

    /// @inheritdoc IMarketRecipe
    function source() external view override returns (RecipeSource) {
        return RecipeSource.NAV;
    }

    /// @inheritdoc IMarketRecipe
    function description() external view override returns (string memory) {
        return "Impairment: the rate window is the anchor plus or minus apySpreadPercentage * "
            "durationSeconds / 365 days of it, rateChangePerDayMax is one day of that annual spread and "
            "rateChangeCapacityMax is seven of those. extraData is built by encodeExtraData(anchorRate, "
            "durationSeconds, apySpreadPercentage) and read back by decodeExtraData, where anchorRate is on the "
            "rate scale (1e18 = 1.0) and used only when no oracle is supplied, durationSeconds is in "
            "seconds, and apySpreadPercentage is on the percentage scale (1e18 = 1%, so 10% a year is "
            "10e18). The four returned fields are on the rate scale. apySpreadPercentage is at most "
            "100e18 (100% a year) and the derived band at most 50e18 (50%). On the fill that creates "
            "the pool, durationSeconds must not exceed the market's remaining life; later fills do not "
            "re-check it. verify recovers the anchor from the window midpoint and requires the live rate "
            "strictly inside it.";
    }

    /// @inheritdoc IMarketRecipe
    /// @dev `resolve` never sees the market's expiry. For the order that creates the pool, pass a
    ///      `durationSeconds` of at most `expiryTimestamp - block.timestamp` at fill time, or `verify`
    ///      refuses the constraint on-chain and the order never fills.
    function resolve(
        address, /* ca */
        address, /* ref */
        address rateOracle,
        bytes calldata extraData
    )
        external
        view
        override
        returns (IMarketRegistry.ResolvedConstraint memory constraint)
    {
        (uint256 carriedAnchor, uint256 durationSeconds, uint256 apySpreadPercentage) = _decodeExtraData(extraData);

        // The carried anchor covers only the first order on a pair, signed before the oracle exists.
        uint256 anchorRate = rateOracle == address(0) ? carriedAnchor : IRateOracle(rateOracle).rate();

        // The registry bound is applied here, on the order-building path, where a loud rejection is
        // wanted. It is NOT applied in `verify`: the adapter enforces it once, when the pool is
        // created, and a later tightening must not stop the orders already resting against a market.
        uint256 maxDuration = REGISTRY.maxExpiryDuration();

        CheckFailure failure;
        uint256 bandPercentage;
        (failure, bandPercentage, constraint) = _check(anchorRate, durationSeconds, apySpreadPercentage, maxDuration);

        if (failure == CheckFailure.None) return constraint;

        if (failure == CheckFailure.ZeroAnchor) revert ZeroAnchorRate();
        if (failure == CheckFailure.ZeroDuration) revert ZeroDuration();
        if (failure == CheckFailure.DurationTooLong) revert DurationTooLong(durationSeconds, maxDuration);
        if (failure == CheckFailure.SpreadTooHigh) {
            revert SpreadTooHigh(apySpreadPercentage, MAX_APY_SPREAD_PERCENTAGE);
        }
        if (failure == CheckFailure.BandTooWide) revert BandTooWide(bandPercentage, MAX_BAND_PERCENTAGE);
        revert WindowCollapsed(constraint.rateMin, constraint.rateMax);
    }

    /// @inheritdoc IMarketRecipe
    function verify(
        address ca,
        address ref,
        address rateOracle,
        uint256 expiryTimestamp,
        bool creating,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata extraData
    ) external view override returns (bool) {
        // A payload this recipe cannot read is a verdict, not a failure to answer: the adapter owns
        // the revert selector, so the answer is `false`. Checked before the oracle so a caller who
        // gets both wrong is told about the payload.
        (bool wellFormed,, uint256 durationSeconds, uint256 apySpreadPercentage) = _tryDecodeExtraData(extraData);
        if (!wellFormed) return false;

        if (rateOracle == address(0)) revert RateOracleNotDeployed(ca, ref);

        // The carried anchor is not trusted; the window is symmetric, so its midpoint is the anchor.
        uint256 anchorRate = (constraint.rateMin + constraint.rateMax) / 2;

        // The declared life may not outlive the market, checked once, on the fill that creates the
        // pool. The adapter has already held the expiry to the registry bound by then, so the declared
        // life is transitively under that bound too, with no registry read here. Later fills skip it:
        // the constraint is part of the pool id and cannot have changed, while the remaining life
        // shrinks every block and would otherwise strand every resting order.
        uint256 maxDuration = type(uint256).max;
        if (creating) maxDuration = expiryTimestamp > block.timestamp ? expiryTimestamp - block.timestamp : 0;

        (CheckFailure failure,, IMarketRegistry.ResolvedConstraint memory expected) =
            _check(anchorRate, durationSeconds, apySpreadPercentage, maxDuration);
        if (failure != CheckFailure.None) return false;

        if (
            constraint.rateMin != expected.rateMin || constraint.rateMax != expected.rateMax
                || constraint.rateChangePerDayMax != expected.rateChangePerDayMax
                || constraint.rateChangeCapacityMax != expected.rateChangeCapacityMax
        ) return false;

        // Left last because it is the only check that costs an external call.
        uint256 rate = IRateOracle(rateOracle).rate();
        return rate > constraint.rateMin && rate < constraint.rateMax;
    }

    /// @notice Every rule this recipe has, and the constraint it stands behind, in one place.
    /// @param anchorRate The initialization rate, 18-decimal fixed point (`1e18` = 1.0).
    /// @param durationSeconds The market's life in seconds.
    /// @param apySpreadPercentage The annual yield difference, percentage scale (`1e18` = 1%).
    /// @param maxDuration The longest life the caller allows; `type(uint256).max` applies no bound.
    /// @return failure The first rule the numbers broke, or `None`.
    /// @return bandPercentage The derived band, zero when the numbers failed before it was reached.
    /// @return constraint The constraint for this market, meaningful only when `failure` is `None`.
    function _check(uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage, uint256 maxDuration)
        private
        pure
        returns (CheckFailure failure, uint256 bandPercentage, IMarketRegistry.ResolvedConstraint memory constraint)
    {
        if (anchorRate == 0) return (CheckFailure.ZeroAnchor, 0, constraint);

        if (durationSeconds == 0) return (CheckFailure.ZeroDuration, 0, constraint);

        if (durationSeconds > maxDuration) return (CheckFailure.DurationTooLong, 0, constraint);

        // No spread above zero fits the band cap past this life, and a zero spread collapses the
        // window, so nothing is lost by refusing it. This keeps a garbage duration from overflowing
        // the band product on the fills that apply no life bound.
        if (durationSeconds > MAX_BAND_PERCENTAGE * SECONDS_PER_YEAR) {
            return (CheckFailure.DurationTooLong, 0, constraint);
        }

        // The spread is bounded on its own, not only through the band: otherwise a short declared life
        // with a huge spread reproduces the band of a long life with a modest one.
        if (apySpreadPercentage > MAX_APY_SPREAD_PERCENTAGE) return (CheckFailure.SpreadTooHigh, 0, constraint);

        bandPercentage = (apySpreadPercentage * durationSeconds) / SECONDS_PER_YEAR;
        if (bandPercentage > MAX_BAND_PERCENTAGE) return (CheckFailure.BandTooWide, bandPercentage, constraint);

        uint256 perDayPercentage = (apySpreadPercentage * 1 days) / SECONDS_PER_YEAR;
        constraint = MarketRegistryLib.applyBands(
            anchorRate, bandPercentage, bandPercentage, perDayPercentage, CAPACITY_DAYS * perDayPercentage
        );

        // The two rules `CorkPoolManager.createNewPool` imposes, checked here so a rejection is named.
        if (constraint.rateMin == 0 || constraint.rateMin >= constraint.rateMax) {
            return (CheckFailure.WindowCollapsed, bandPercentage, constraint);
        }

        return (CheckFailure.None, bandPercentage, constraint);
    }

    /// @notice Build the `extraData` an order against this recipe carries.
    /// @param anchorRate The initialization rate, 18-decimal fixed point (`1e18` = 1.0). Read only
    ///        when `resolve` is given no oracle; `verify` never reads it.
    /// @param durationSeconds The market's life in seconds.
    /// @param apySpreadPercentage The annual yield difference, percentage scale (`1e18` = 1%).
    /// @return The bytes to place in the order's `extraData`.
    function encodeExtraData(uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(anchorRate, durationSeconds, apySpreadPercentage);
    }

    /// @notice Read back the three values {encodeExtraData} wrote, the same way `resolve` does.
    /// @dev The deployed recipe is the layout oracle: off-chain callers compare the result with
    ///      what they encoded before signing. Reverts `MalformedExtraData` on any other layout.
    /// @param extraData The order-carried bytes.
    /// @return anchorRate The initialization rate, 18-decimal fixed point (`1e18` = 1.0).
    /// @return durationSeconds The market's life in seconds.
    /// @return apySpreadPercentage The annual yield difference, percentage scale (`1e18` = 1%).
    function decodeExtraData(bytes calldata extraData)
        external
        pure
        returns (uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)
    {
        return _decodeExtraData(extraData);
    }

    /// @notice The decoder for the paths that want a loud rejection: `resolve` and `decodeExtraData`.
    /// @param extraData The order-carried bytes.
    function _decodeExtraData(bytes calldata extraData)
        private
        pure
        returns (uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)
    {
        bool wellFormed;
        (wellFormed, anchorRate, durationSeconds, apySpreadPercentage) = _tryDecodeExtraData(extraData);
        if (!wellFormed) revert MalformedExtraData(extraData.length);
    }

    /// @notice The one place the layout is read. `verify` uses it directly because a bad payload is a
    ///         `false` verdict there, not a revert.
    /// @param extraData The order-carried bytes.
    /// @return wellFormed Whether the bytes are the layout {encodeExtraData} produces.
    function _tryDecodeExtraData(bytes calldata extraData)
        private
        pure
        returns (bool wellFormed, uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)
    {
        if (extraData.length != EXTRA_DATA_LENGTH) return (false, 0, 0, 0);
        (anchorRate, durationSeconds, apySpreadPercentage) = abi.decode(extraData, (uint256, uint256, uint256));
        wellFormed = true;
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
