// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@morpho-oracle/interfaces/IERC4626.sol";

/// @title MockMorphoOracle
/// @notice Minimal stand-in for `MorphoChainlinkOracleV2`: exposes the three reads
///         `WrapperRateConsumer`'s constructor performs (`BASE_VAULT`, `QUOTE_VAULT`, `price`).
/// @dev All eleven creation arguments are constructor arguments, so — exactly like the real oracle —
///      the CREATE2 address commits to the full argument set, not just the salt.
contract MockMorphoOracle {
    IERC4626 public immutable BASE_VAULT;
    IERC4626 public immutable QUOTE_VAULT;

    constructor(
        IERC4626 baseVault,
        uint256, // baseVaultConversionSample
        AggregatorV3Interface, // baseFeed1
        AggregatorV3Interface, // baseFeed2
        uint256, // baseTokenDecimals
        IERC4626 quoteVault,
        uint256, // quoteVaultConversionSample
        AggregatorV3Interface, // quoteFeed1
        AggregatorV3Interface, // quoteFeed2
        uint256 // quoteTokenDecimals
    ) {
        BASE_VAULT = baseVault;
        QUOTE_VAULT = quoteVault;
    }

    /// @dev Non-zero so `WrapperRateConsumer`'s constructor rate check passes.
    function price() external pure returns (uint256) {
        return 1e36;
    }
}

/// @title MockMorphoFactoryCreate2
/// @notice A Morpho oracle factory stand-in with GENUINE CREATE2 semantics: a repeat call with the
///         same salt and arguments hits an address that already has code, and the CREATE2 opcode
///         fails with EMPTY return data — the exact failure shape the front-run finding is about.
/// @dev Matches the `IMorphoChainlinkOracleV2Factory.createMorphoChainlinkOracleV2` selector, so the
///      real `WrapperRateConsumerFactory` can be initialized against it.
contract MockMorphoFactoryCreate2 {
    mapping(address oracle => bool created) public isMorphoChainlinkOracleV2;

    function createMorphoChainlinkOracleV2(
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
        bytes32 salt
    ) external returns (address oracle) {
        oracle = address(
            new MockMorphoOracle{salt: salt}(
                baseVault,
                baseVaultConversionSample,
                baseFeed1,
                baseFeed2,
                baseTokenDecimals,
                quoteVault,
                quoteVaultConversionSample,
                quoteFeed1,
                quoteFeed2,
                quoteTokenDecimals
            )
        );
        isMorphoChainlinkOracleV2[oracle] = true;
    }
}
