// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IMarketRegistry} from "./IMarketRegistry.sol";

/// @notice Which kind of rate a recipe works against.
/// @dev Declared at file scope, not inside the interface, so the limit-order adapter and the registry
///      can both name it without importing an interface they otherwise do not use.
///
///      `NAV` and `PRICE` map one-for-one onto `IMarketRegistry.OracleMode`. `FIXED` deliberately
///      does NOT — see the interface documentation below for what a caller does with it.
enum RecipeSource {
    NAV,
    PRICE,
    FIXED
}

/// @title IMarketRecipe
/// @notice A rate-constraint recipe: the pluggable policy that turns a market's rate into the four
///         concrete limits a pool is created with, and later re-checks that a submitted constraint
///         is one it would have produced.
interface IMarketRecipe {
    /// @notice Which kind of rate this recipe works against.
    /// @return The recipe's rate kind.
    function source() external view returns (RecipeSource);

    /// @notice What this recipe does, in words — and the formula, if it has a non-obvious one.
    /// @return A short description of the policy this recipe implements.
    function description() external view returns (string memory);

    /// @notice Derive the rate constraint this recipe would impose on a (collateral, reference) pair.
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    /// @param rateOracle The rate oracle for this market — an `IRateOracle`.
    /// @param additionalData Recipe-specific input, opaque to the registry and to the adapter. Passed
    ///        through from the order payload verbatim so that `verify` can be handed the same bytes
    ///        `resolve` saw.
    /// @return constraint The four concrete rate limits, on the RATE scale (`1e18` = 1.0). If the
    ///         recipe holds percentage bands internally, `MarketRegistryLib.applyBands` is the one
    ///         place that conversion is allowed to happen — the percentage scale (`1e18` = 1%) and
    ///         the rate scale differ by a factor of 100.
    function resolve(address ca, address ref, address rateOracle, bytes calldata additionalData)
        external
        view
        returns (IMarketRegistry.ResolvedConstraint memory constraint);

    /// @notice Check that a submitted constraint is one this recipe stands behind, right now.
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    /// @param rateOracle The rate oracle step 3 produced for this market — an `IRateOracle`, never
    ///        zero on the adapter's path whatever the recipe's `source()`. This is the LIVE rate
    ///        source: unlike in `resolve`, the caller guarantees it is already deployed, so a recipe
    ///        that checks the constraint against the current rate reads it from here. Cast to
    ///        `IRateOracle` to do so. A recipe that needs the rate and is handed `address(0)` cannot
    ///        answer and should REVERT rather than return `false` — see above on why those two are
    ///        different.
    /// @param constraint The constraint the order carries, on the rate scale (`1e18` = 1.0).
    /// @param additionalData The same recipe-specific bytes `resolve` was given, carried in the order.
    /// @return True if the recipe accepts the constraint for this pair at this moment.
    function verify(
        address ca,
        address ref,
        address rateOracle,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata additionalData
    ) external view returns (bool);
}
