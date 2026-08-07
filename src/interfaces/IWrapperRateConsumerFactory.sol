// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@morpho-oracle/interfaces/IERC4626.sol";
import {IMorphoChainlinkOracleV2Factory} from "@phoenix/interfaces/IMorphoChainlinkOracleV2Factory.sol";

/// @title IWrapperRateConsumerFactory
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Interface for the factory that atomically creates a `MorphoChainlinkOracleV2` through the configured
///         Morpho factory and deploys a `WrapperRateConsumer` wrapping that freshly-created oracle.
interface IWrapperRateConsumerFactory {
    /// @notice Emitted when a new `WrapperRateConsumer` (and its underlying Morpho oracle) is created.
    /// @param caller The caller of `createWrapperRateConsumer`.
    /// @param wrapperRateConsumer The address of the newly created `WrapperRateConsumer`.
    /// @param morphoOracle The address of the underlying `MorphoChainlinkOracleV2` created in the same call.
    event CreateWrapperRateConsumer(address caller, address wrapperRateConsumer, address morphoOracle);

    /// @notice Thrown when the configured Morpho factory address is zero.
    error ZeroAddress();

    /// @notice The Morpho oracle factory used to create the wrapped `MorphoChainlinkOracleV2` instances.
    function MORPHO_FACTORY() external view returns (IMorphoChainlinkOracleV2Factory);

    /// @notice Whether a `WrapperRateConsumer` was created by this factory.
    /// @param wrapperRateConsumer The address to query.
    /// @return created True if the address was created through `createWrapperRateConsumer`.
    function isWrapperRateConsumer(address wrapperRateConsumer) external view returns (bool created);

    /// @notice Creates a `MorphoChainlinkOracleV2` through the configured Morpho factory, then deploys a
    ///         `WrapperRateConsumer` wrapping it, atomically in one transaction.
    /// @dev The base asset should be the collateral token and the quote asset the loan token, matching Morpho's
    ///      orientation. Decimals correctness is handled inside the ported `WrapperRateConsumer`, which derives each
    ///      side's decimals from the underlying `asset()` — so vaults whose ERC-4626 share decimals differ from their
    ///      underlying-asset decimals price correctly and are accepted (the former per-side guard is removed).
    ///      Both deployments are CREATE2: the oracle address is deterministic in `morphoSalt`, and the
    ///      wrapper address is deterministic in `wrapperSalt` AND the oracle address (which the wrapper takes as a
    ///      constructor argument), so the wrapper address can only be pre-computed once `morphoSalt` is fixed.
    /// @param baseVault Base vault. Pass address zero to omit (price = 1 on the base side).
    /// @param baseVaultConversionSample Sample amount of base vault shares used to convert to underlying. Pass 1 if
    ///        the base asset is not a vault.
    /// @param baseFeed1 First base feed. Pass address zero if the price = 1.
    /// @param baseFeed2 Second base feed. Pass address zero if the price = 1.
    /// @param baseTokenDecimals Base (underlying) token decimals, forwarded to the Morpho oracle's scale factor.
    /// @param quoteVault Quote vault. Pass address zero to omit (price = 1 on the quote side).
    /// @param quoteVaultConversionSample Sample amount of quote vault shares used to convert to underlying. Pass 1 if
    ///        the quote asset is not a vault.
    /// @param quoteFeed1 First quote feed. Pass address zero if the price = 1.
    /// @param quoteFeed2 Second quote feed. Pass address zero if the price = 1.
    /// @param quoteTokenDecimals Quote (underlying) token decimals, forwarded to the Morpho oracle's scale factor.
    /// @param morphoSalt The CREATE2 salt forwarded to the Morpho factory for the oracle deployment.
    /// @param wrapperSalt The CREATE2 salt used for the `WrapperRateConsumer` deployment.
    /// @return wrapper The address of the newly created `WrapperRateConsumer`.
    /// @return oracle The address of the newly created `MorphoChainlinkOracleV2`.
    function createWrapperRateConsumer(
        IERC4626 baseVault,
        uint256 baseVaultConversionSample,
        AggregatorV3Interface baseFeed1,
        AggregatorV3Interface baseFeed2,
        uint256 baseTokenDecimals,
        IERC4626 quoteVault,
        uint256 quoteVaultConversionSample,
        AggregatorV3Interface quoteFeed1,
        AggregatorV3Interface quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 morphoSalt,
        bytes32 wrapperSalt
    ) external returns (address wrapper, address oracle);
}
