// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FixedRateOracle} from "./FixedRateOracle.sol";
import {IVersion} from "./interfaces/IVersion.sol";

// Ported from the `cork-lop-market-creator-hackathon` repository, file `src/FixedRateOracleFactory.sol`.
// The deployment scheme, salt derivation, zero-rate check and event are carried over unchanged.
//
// Caveat carried over deliberately: `computeAddress` hashes `type(FixedRateOracle).creationCode`, so
// the address it predicts depends on the compiler version, the optimizer settings and the metadata
// hash. It is self-consistent inside this repository, but the addresses will NOT match the ones the
// hackathon repository predicted, because that repository compiled against a different Ethereum
// Virtual Machine target. This is expected and is not something to reconcile.

/// @title FixedRateOracleFactory
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Deterministic (CREATE2) factory for `FixedRateOracle` instances, keyed by rate.
///         Each rate can be deployed exactly once per factory.
/// @dev No admin surface. `computeAddress` lets agents precompute the oracle address off-chain
///      before any transaction is sent.
contract FixedRateOracleFactory is IVersion {
    /// @notice Emitted when an oracle is deployed.
    /// @param rate The fixed rate the oracle was deployed with.
    /// @param oracle The deployed oracle address.
    event OracleDeployed(uint256 indexed rate, address indexed oracle);

    /// @notice Deploys the oracle for `rate`.
    /// @dev Reverts with NO error data (CREATE2 salt collision) if the oracle for `rate` already exists.
    ///      A zero rate reverts `IRateOracle.InvalidRate()` from the `FixedRateOracle` constructor.
    /// @param rate The fixed rate (1 REF quoted in CA, 1e18-scaled). Must be nonzero.
    /// @return oracle The deployed oracle address.
    function deploy(uint256 rate) external returns (address oracle) {
        oracle = address(new FixedRateOracle{salt: bytes32(rate)}(rate));
        emit OracleDeployed(rate, oracle);
    }

    /// @notice Computes the deterministic CREATE2 address of the oracle for `rate`.
    /// @dev salt = bytes32(rate); init-code hash = keccak256(creationCode ++ abi.encode(rate)).
    /// @param rate The fixed rate the oracle is keyed by.
    /// @return The deterministic oracle address (which may not be deployed yet).
    function computeAddress(uint256 rate) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(FixedRateOracle).creationCode, abi.encode(rate)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(rate), initCodeHash))))
        );
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
