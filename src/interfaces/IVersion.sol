// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Lets tooling and operators identify which build of a contract is live at an address.
interface IVersion {
    /// @notice Semantic version of this contract, for example "0.3.1".
    function version() external pure returns (string memory);
}
