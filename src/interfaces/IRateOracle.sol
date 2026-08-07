// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IRateOracle
/// @notice The one shape every rate oracle in this repository presents: `rate()`, plus the shared
///         `InvalidRate()` selector. Implemented by `WrapperRateConsumer` (a wrapper over Chainlink-style
///         feeds and ERC-4626 vaults) and by `FixedRateOracle` (one constant, set at construction).
/// @dev The registry's relationship to this interface is DEPLOY-AND-RECORD, never READ. It builds
///      wrappers through `WrapperRateConsumerFactory` and records their addresses, and it deploys
///      `FixedRateOracle` instances through `FixedRateOracleFactory` (`deployFixedRateOracle`) without
///      recording anything at all. In neither case does the registry call `rate()` — markets do, at fill
///      time. So this stays a conformance reference from the registry's point of view: it fixes the
///      surface an oracle must present and the selector a bad rate must fail with, and the registry
///      never depends on the value behind it.
interface IRateOracle {
    /// @notice Thrown when a rate is zero. Declared here (rather than on any one implementation) so
    ///         every rate oracle in this repository reverts with the same selector, and so that
    ///         selector matches the `InvalidRate()` phoenix declares on its own `IRateOracle`.
    error InvalidRate();

    /// @notice 1 REF quoted in CA (one reference-asset unit quoted in the collateral asset),
    ///         scaled to 1e18.
    /// @return The rate, fixed-point with 18 decimals.
    function rate() external view returns (uint256);
}
