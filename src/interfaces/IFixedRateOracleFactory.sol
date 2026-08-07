// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IFixedRateOracleFactory
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Registry-side view of `FixedRateOracleFactory` — the deterministic (`CREATE2`) factory for
///         `FixedRateOracle` instances, keyed by the rate itself.
/// @dev This interface exists so `MarketRegistry` depends on a SHAPE rather than on the concrete
///      factory contract, as it already does for the wrapper factory through `IWrapperFactory`.
///
///      The concrete reason: `FixedRateOracleFactory.computeAddress` reads
///      `type(FixedRateOracle).creationCode`, so the factory's own runtime code carries a full copy of
///      the oracle's creation code. Importing the concrete factory into the registry's compilation unit
///      pulls that contract in as a compilation dependency for no benefit; calling through this
///      interface keeps the registry's dependency surface to two function selectors.
///
///      It does NOT buy a smaller registry, so do not re-litigate the choice on size grounds: both
///      spellings were measured with `forge build --sizes` on the default profile and `MarketRegistry`
///      came out at exactly 16,344 bytes of runtime code either way. Solidity embeds a callee's creation
///      code only where the caller says `new` or reads `type(X).creationCode`, and the registry does
///      neither.
///
///      Same selector caveat as `IWrapperFactory`: nothing links this declaration to the deployed
///      factory except the selectors agreeing, so if `FixedRateOracleFactory`'s signatures change,
///      change them here in the same commit.
///
///      A repeat rate reverts with EMPTY data (a `CREATE2` onto an address that already holds code),
///      which is why `MarketRegistry.deployFixedRateOracle` checks `computeAddress(rate).code.length`
///      before it ever calls `deploy` instead of calling and interpreting a failure.
interface IFixedRateOracleFactory {
    /// @notice Emitted by the FACTORY when it deploys an oracle. Distinct from the registry's own
    ///         `IMarketRegistry.FixedRateOracleDeployed`, which records who asked for it.
    /// @param rate The fixed rate the oracle was deployed with.
    /// @param oracle The deployed oracle address.
    event OracleDeployed(uint256 indexed rate, address indexed oracle);

    /// @notice Deploy the `FixedRateOracle` for `rate` at its deterministic address.
    /// @dev Two failure modes, and only one of them is decodable:
    ///
    ///      - `rate == 0` reverts `IRateOracle.InvalidRate()` from the oracle's constructor, which
    ///        bubbles out of this call as a real four-byte selector.
    ///      - a rate that has ALREADY been deployed through this factory reverts with empty return
    ///        data, because the `CREATE2` lands on an address that already holds code.
    /// @param rate The fixed rate (one reference-asset unit quoted in the collateral asset, scaled to
    ///        1e18). Must be non-zero.
    /// @return oracle The deployed oracle address.
    function deploy(uint256 rate) external returns (address oracle);

    /// @notice The deterministic address the oracle for `rate` occupies, deployed or not.
    /// @dev Pure arithmetic over the factory's own address, `bytes32(rate)` as the salt, and the
    ///      init-code hash — no storage, no external call, and it does not revert for a zero rate. Ask
    ///      whether that oracle exists by checking `.code.length` on the answer.
    ///
    ///      The predicted address depends on the compiler version, the optimizer settings and the
    ///      metadata hash, because the init-code hash covers `FixedRateOracle`'s creation code. It is
    ///      self-consistent within one build of this repository and will NOT match a different build.
    /// @param rate The fixed rate the oracle is keyed by.
    /// @return The deterministic oracle address.
    function computeAddress(uint256 rate) external view returns (address);
}
