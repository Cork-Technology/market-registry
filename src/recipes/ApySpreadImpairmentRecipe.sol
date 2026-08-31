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
/// @dev `additionalData = abi.encode(uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)`.
contract ApySpreadImpairmentRecipe is IMarketRecipe, Initializable, IVersion {
    /// @notice The ways the numbers an order carries can fail this recipe, one variant per rule.
    enum CheckFailure {
        None,
        ZeroAnchor,
        ZeroDuration,
        DurationTooLong,
        BandTooWide,
        WindowCollapsed
    }

    /// @notice Thrown at initialization when the registry address is zero.
    error ZeroRegistry();

    /// @notice Thrown by `resolve` when `additionalData` is not exactly three ABI words.
    error MalformedAdditionalData(uint256 length);

    /// @notice Thrown by `resolve` when the anchor rate it settled on is zero.
    error ZeroAnchorRate();

    /// @notice Thrown by `resolve` when the market has no life at all.
    error ZeroDuration();

    /// @notice Thrown by `resolve` when the market outlives the registry's creation bound.
    error DurationTooLong(uint256 durationSeconds, uint256 maxDuration);

    /// @notice Thrown by `resolve` when the derived band reaches or passes 100%.
    error BandTooWide(uint256 bandPercentage);

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
            "rateChangeCapacityMax is seven of those. additionalData is abi.encode(uint256 anchorRate, "
            "uint256 durationSeconds, uint256 apySpreadPercentage), 96 bytes, where anchorRate is on the "
            "rate scale (1e18 = 1.0) and used only when no oracle is supplied, durationSeconds is in "
            "seconds, and apySpreadPercentage is on the percentage scale (1e18 = 1%, so 10% a year is "
            "10e18). The four returned fields are on the rate scale. The spread is the order author's "
            "choice and is not bounded here; verify recovers the anchor from the window midpoint and "
            "requires the live rate strictly inside it.";
    }

    /// @inheritdoc IMarketRecipe
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
        (uint256 carriedAnchor, uint256 durationSeconds, uint256 apySpreadPercentage) = _decode(additionalData);

        // The carried anchor covers only the first order on a pair, signed before the oracle exists.
        uint256 anchorRate = rateOracle == address(0) ? carriedAnchor : IRateOracle(rateOracle).rate();

        CheckFailure failure;
        uint256 bandPercentage;
        (failure, bandPercentage, constraint) = _check(anchorRate, durationSeconds, apySpreadPercentage);

        if (failure == CheckFailure.None) return constraint;

        if (failure == CheckFailure.ZeroAnchor) revert ZeroAnchorRate();
        if (failure == CheckFailure.ZeroDuration) revert ZeroDuration();
        if (failure == CheckFailure.DurationTooLong) {
            revert DurationTooLong(durationSeconds, REGISTRY.maxExpiryDuration());
        }
        if (failure == CheckFailure.BandTooWide) revert BandTooWide(bandPercentage);
        revert WindowCollapsed(constraint.rateMin, constraint.rateMax);
    }

    /// @inheritdoc IMarketRecipe
    function verify(
        address ca,
        address ref,
        address rateOracle,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata additionalData
    ) external view override returns (bool) {
        if (additionalData.length != 96) return false;

        if (rateOracle == address(0)) revert RateOracleNotDeployed(ca, ref);

        (, uint256 durationSeconds, uint256 apySpreadPercentage) =
            abi.decode(additionalData, (uint256, uint256, uint256));

        // The carried anchor is not trusted; the window is symmetric, so its midpoint is the anchor.
        uint256 anchorRate = (constraint.rateMin + constraint.rateMax) / 2;

        (CheckFailure failure,, IMarketRegistry.ResolvedConstraint memory expected) =
            _check(anchorRate, durationSeconds, apySpreadPercentage);
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
    /// @return failure The first rule the numbers broke, or `None`.
    /// @return bandPercentage The derived band, zero when the numbers failed before it was reached.
    /// @return constraint The constraint for this market, meaningful only when `failure` is `None`.
    function _check(uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)
        private
        view
        returns (CheckFailure failure, uint256 bandPercentage, IMarketRegistry.ResolvedConstraint memory constraint)
    {
        if (anchorRate == 0) return (CheckFailure.ZeroAnchor, 0, constraint);

        if (durationSeconds == 0) return (CheckFailure.ZeroDuration, 0, constraint);

        if (durationSeconds > REGISTRY.maxExpiryDuration()) return (CheckFailure.DurationTooLong, 0, constraint);

        // At 100% the floor lands on zero and beyond it there is no creatable market.
        bandPercentage = (apySpreadPercentage * durationSeconds) / SECONDS_PER_YEAR;
        if (bandPercentage >= MarketRegistryLib.PERCENTAGE_DENOMINATOR) {
            return (CheckFailure.BandTooWide, bandPercentage, constraint);
        }

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

    /// @notice Decode the order-carried `additionalData`, rejecting anything that is not three words.
    /// @param additionalData The order-carried bytes.
    function _decode(bytes calldata additionalData)
        private
        pure
        returns (uint256 anchorRate, uint256 durationSeconds, uint256 apySpreadPercentage)
    {
        if (additionalData.length != 96) revert MalformedAdditionalData(additionalData.length);
        return abi.decode(additionalData, (uint256, uint256, uint256));
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
