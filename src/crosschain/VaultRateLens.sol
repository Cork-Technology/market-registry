// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IVersion} from "../interfaces/IVersion.sol";

/// @title VaultRateLens
/// @notice Stateless view lens for reading an ERC-4626 vault's share-to-assets
///         conversion in a single call. Exists because a LayerZero Read request
///         cannot chain `decimals()` into `convertToAssets()`; the lens does the
///         chaining on the vault's own chain and returns raw, self-describing facts.
/// @dev Deliberately unopinionated: no normalization, no zero-rate policy.
///      Interpretation and rejection rules belong to the consumer (RemoteNavFeed).
contract VaultRateLens is IVersion {
    /// @notice Read the vault's raw conversion facts at the current block.
    /// @param vault The ERC-4626 vault to read.
    /// @return sample The share amount used as input: 10 ** vault.decimals().
    /// @return assets vault.convertToAssets(sample), in the underlying's decimals.
    /// @return assetDecimals Decimals of the vault's underlying asset.
    /// @return blockNumber Source-chain block number of this reading.
    /// @return timestamp Source-chain timestamp of this reading.
    function read(IERC4626 vault)
        external
        view
        returns (uint256 sample, uint256 assets, uint8 assetDecimals, uint256 blockNumber, uint256 timestamp)
    {
        sample = 10 ** IERC20Metadata(address(vault)).decimals();
        assets = vault.convertToAssets(sample);
        assetDecimals = IERC20Metadata(vault.asset()).decimals();
        blockNumber = block.number;
        timestamp = block.timestamp;
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
