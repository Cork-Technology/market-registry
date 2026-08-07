// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IWrapper
/// @notice Minimal view of a wrapping token's underlying asset.
/// @dev Read by the MarketRegistry denomination-walk probe (`_probeAsset`). The registry calls
///      `asset()` through this interface with try/catch: a clean non-zero return means the token
///      wraps another and the walk hops to it; a revert, a missing `asset()`, or no code at the
///      address is caught and treated as a leaf.
interface IWrapper {
    /// @notice The underlying asset this token wraps.
    /// @return underlying The wrapped token's address.
    function asset() external view returns (address underlying);
}
