// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

/// @title IAggregatorV2V3AdapterFactory
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Deterministic (CREATE2) factory for `AggregatorV2V3Adapter` instances. The salt is supplied
///         by the caller, so one source can back any number of adapters — a source may legitimately need
///         more than one (different answer decimals, a corrected description, a second adapter kept live
///         while consumers migrate off the first).
interface IAggregatorV2V3AdapterFactory {
    /// @notice Emitted once per adapter deployed by this factory.
    event CreateAdapter(address caller, address adapter, address source);

    /// @notice Thrown when the source address is zero.
    error ZeroAddress();

    /// @notice Thrown when an adapter for this exact combination of `source`, `decimals`, `description`
    ///         and `salt` has already been deployed by this factory. The address is fully determined by
    ///         those four values, so a repeat lands on an occupied address; pass a different salt to get
    ///         a second adapter for the same source.
    error AdapterExists(address adapter);

    /// @notice True for every adapter this factory has deployed.
    function isAdapter(address adapter) external view returns (bool created);

    /// @notice Deploy an adapter for `source` at a deterministic address.
    /// @param source The V2 feed exposing `latestAnswer()`.
    /// @param decimals Decimals of the source's ANSWER — NOT the source token's ERC20 decimals. The V2
    ///        surface does not expose this, and a wrapped token's own `decimals()` is the share decimals,
    ///        not the price decimals, so it must be supplied explicitly (e.g. 8 for an Aave USD price).
    /// @param description Human-readable feed description, e.g. "waArbUSDC / USD".
    /// @param salt The CREATE2 salt. Caller-chosen and unconstrained: it is the only knob that lets two
    ///        adapters share a source, and it is trailing so that it reads as the placement argument
    ///        rather than part of what the adapter is.
    /// @return adapter The deployed adapter address.
    function createAdapter(address source, uint8 decimals, string calldata description, bytes32 salt)
        external
        returns (address adapter);

    /// @notice Compute the address `createAdapter` would deploy to for the given arguments. Also the way
    ///         to ask whether that adapter already exists: check `.code.length` on the result.
    function predictAdapter(address source, uint8 decimals, string calldata description, bytes32 salt)
        external
        view
        returns (address adapter);
}
