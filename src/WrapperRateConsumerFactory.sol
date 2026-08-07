// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@morpho-oracle/interfaces/IERC4626.sol";
// The Morpho `IERC4626` above only exposes `convertToAssets`, so the OpenZeppelin ERC-4626 / ERC-20-metadata
// interfaces are aliased in to read `asset()` and the SHARE `decimals()` without colliding with it.
import {IERC4626 as IERC4626Metadata} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMorphoChainlinkOracleV2} from "@morpho-oracle/interfaces/IMorphoChainlinkOracleV2.sol";
import {IMorphoChainlinkOracleV2Factory} from "@phoenix/interfaces/IMorphoChainlinkOracleV2Factory.sol";
import {WrapperRateConsumer} from "@phoenix/periphery/WrapperRateConsumer.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IVersion} from "./interfaces/IVersion.sol";
import {IWrapperRateConsumerFactory} from "./interfaces/IWrapperRateConsumerFactory.sol";

//             CCCCCCCCC  C
//          CCCCCCCCCCC   C
//       CCCCCCCCCCCCCC   C
//     CCCCCCCCCCCCCCCC   C        CCCCCC                    CCCCCCCCCCCCCCC             CCCCCCCCCCCCCCC     CCCCCCCCCCCCCCCCCCCC     CCCCCCCCCCC     CCCCCCCCCC
//    CCCCCCCCCCCCCCCCC CC       CCCCCC  C               CCCCCCCCCCCCCCCCCC  CCC     CCCCCCCCCCCCCCCCCC  CC  CCCCCCCCCCCCCCCCCCCC  CC CCCCCCC   C    CCCCCCCC  CC
//   CCCCCCCCCCCCCCCC CC       CCCCCCCCC  C            CCCCCCCCCCCCCCCCCCCCC    CC CCCCCCCCCCCCCCCCCCCCCC   CCCCCCCCCCCCCCCCCCCCCCC  CCCCCCCC   C    CCCCCCCC  CC
//  CCCCCCCCCCCCCCC CC        CCCCCCCCCCC  C          CCCCCCCCCCCCCCCCCCCCCCCC    CCCCCCCCCCCCCCCCCCCCCCCC   CCCCCCCCCCCCCCCCCCCCCCC  CCCCCCC   C  CCCCCCCCCC  CC
// CCCCCCCCCCCCCC CC        CCCCCCCCCCCCC  CC        CCCCCCCCC    CC  CCCCCCCCC  CCCCCCCCC   CC   CCCCCCCCC  CCCCCCC    C   CCCCCCCC  CCCCCCC   CCCCCCCCCCC  CC
// CCCCCCCCCCCC  C         CCCCCCCCCCCCCCC  C        CCCCCCCC    CC     CCCCCCCCCCCCCCCC    CC     CCCCCCCC  CCCCCCC    C    CCCCCCC  CCCCCCC  CCCCCCCCCC  CC
// CCCCCCCCCCCC  C         CCCCCCCCCCCCCCC  C       CCCCCCCC    CC              CCCCCCCC   CC       CCCCCCCC CCCCCCC    C   CCCCCCCC  CCCCCCC  CCCCCCCC   C
// CCCCCCCCCCCC  C         CCCCCCCCCCCCCCC   C      CCCCCCCC    C               CCCCCCCC   C        CCCCCCCC CCCCCCCCCCCCCCCCCCCCCCC  CCCCCCC  CCCCCCCC   C
// CCCCCCCCCCCC  C         CCCCCCCCCCCCCCC  C       CCCCCCCC    CC              CCCCCCCC   CC       CCCCCCCC CCCCCCCCCCCCCCCCCCCCC   CCCCCCCC  CCCCCCCC   CC
// CCCCCCCCCCCC  C         CCCCCCCCCCCCCCC  C        CCCCCCCC    CC     CCCCCCCCCCCCCCCC    CC     CCCCCCCC  CCCCCCCCCCCCCCCCCCC   CC CCCCCCC  CCCCCCCCCC   C
// CCCCCCCCCCCCCC CC        CCCCCCCCCCCCC  CC        CCCCCCCCC    CCC CCCCCCCCC  CCCCCCCCC   CCC  CCCCCCCCC  CCCCCCCCCCCCCCCCCCCCC   CCCCCCCC   CCCCCCCCCCC  CC
//  CCCCCCCCCCCCCCC CC        CCCCCCCCCCC  C          CCCCCCCCCCCCCCCCCCCCCCCC   CCCCCCCCCCCCCCCCCCCCCCCCC   CCCCCCC    C CCCCCCCCCC  CCCCCCC   C  CCCCCCCCCC  CC
//   CCCCCCCCCCCCCCCC CC        CCCCCCCC  C            CCCCCCCCCCCCCCCCCCCCC    CC CCCCCCCCCCCCCCCCCCCCCC  CCCCCCCCC    C   CCCCCCCC  CCCCCCC   C    CCCCCCCC  CC
//    CCCCCCCCCCCCCCCC  CC        CCCCC CC                CCCCCCCCCCCCCCCC   CC      CCCCCCCCCCCCCCCCC  CCC  CCCCCCC    C   CCCCCCCC  CCCCCCC   C    CCCCCCCC  CC
//     CCCCCCCCCCCCCCCC   C        CCCCCC                    CCCCCCCCCCCCCCC             CCCCCCCCCCCCCC      CCCCCCCCCCCC    CCCCCCCCCCCCCCCCCCCC     CCCCCCCCCC
//       CCCCCCCCCCCCCC   C
//          CCCCCCCCCCC   C
//              CCCCCCCCCCC

/// @title WrapperRateConsumerFactory
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Atomically creates a `MorphoChainlinkOracleV2` through the configured Morpho factory and deploys a
///         `WrapperRateConsumer` wrapping that freshly-created oracle, in a single call.
/// @dev Decimals correctness now lives in THIS factory (the single source of truth), not in a factory guard nor in a
///      wrapper-side vault read: for each side the factory derives the UNDERLYING `asset().decimals()` and the SHARE
///      `vault.decimals()` from the vault, hands the UNDERLYING value to the Morpho oracle (whose `SCALE_FACTOR` is
///      built from underlying decimals) and the SHARE value to the `WrapperRateConsumer` (whose normalization undoes
///      Morpho's SHARE-decimal price scale). So a vault whose ERC-4626 *share* decimals differ from its
///      underlying-asset decimals (e.g. an 18-decimal MetaMorpho share over a 6-decimal USDC/USDT/AUSD underlying)
///      is normalized correctly.
contract WrapperRateConsumerFactory is IWrapperRateConsumerFactory, Initializable, IVersion {
    /// @inheritdoc IWrapperRateConsumerFactory
    /// @dev Set once through `initialize` rather than a constructor, so the creation code carries no arguments and
    ///      the factory lands on the same CREATE2 address on every chain. Deployed through `AtomicDeployer`, which
    ///      initializes in the deployment transaction.
    IMorphoChainlinkOracleV2Factory public MORPHO_FACTORY;

    /// @inheritdoc IWrapperRateConsumerFactory
    /// @dev Mirrors Morpho's `isMorphoChainlinkOracleV2` indexing pattern: only instances created through
    ///      `createWrapperRateConsumer` are recorded, so this is the registry of factory-created wrappers.
    mapping(address wrapperRateConsumer => bool created) public isWrapperRateConsumer;

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    /// @param morphoFactory Address of the `MorphoChainlinkOracleV2Factory` used to create the wrapped oracles.
    function initialize(address morphoFactory) external initializer {
        require(morphoFactory != address(0), ZeroAddress());
        MORPHO_FACTORY = IMorphoChainlinkOracleV2Factory(morphoFactory);
    }

    /// @inheritdoc IWrapperRateConsumerFactory
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
    ) external returns (address wrapper, address oracle) {
        return _createWrapperRateConsumer(
            baseVault,
            baseVaultConversionSample,
            baseFeed1,
            baseFeed2,
            baseTokenDecimals,
            quoteVault,
            quoteVaultConversionSample,
            quoteFeed1,
            quoteFeed2,
            quoteTokenDecimals,
            morphoSalt,
            wrapperSalt
        );
    }

    function _createWrapperRateConsumer(
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
    ) internal returns (address wrapper, address oracle) {
        // POC FIX (ChainSecurity): the per-side share-equals-underlying decimals guard is gone. Offset vaults
        // (share decimals != underlying decimals) now price correctly because this factory routes the right decimals
        // to each consumer below — there is nothing left to reject here.

        // POC FIX (see guides/oracle-decimals.md): derive BOTH decimals per side from the vault and feed each consumer
        // the one it needs — UNDERLYING `asset().decimals()` to the Morpho oracle, SHARE `vault.decimals()` to the
        // wrapper.

        // Step 1: create the underlying Morpho oracle through the configured factory — UNDERLYING decimals.
        oracle = _createMorphoOracle(
            baseVault,
            baseVaultConversionSample,
            baseFeed1,
            baseFeed2,
            baseTokenDecimals,
            quoteVault,
            quoteVaultConversionSample,
            quoteFeed1,
            quoteFeed2,
            quoteTokenDecimals,
            morphoSalt
        );

        // Step 2: deploy the wrapper around the freshly-created oracle — SHARE decimals.
        wrapper = _deployWrapper(oracle, wrapperSalt, baseTokenDecimals, quoteTokenDecimals);

        isWrapperRateConsumer[wrapper] = true;

        emit CreateWrapperRateConsumer(msg.sender, wrapper, oracle);
    }

    /// @notice Creates the underlying `MorphoChainlinkOracleV2` with each side's UNDERLYING decimals.
    /// @dev Split out of `_createWrapperRateConsumer` so the per-side `_underlyingDecimals` reads run in a smaller
    ///      stack frame than the 12-argument shared path would allow without via-IR.
    function _createMorphoOracle(
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
        bytes32 morphoSalt
    ) private returns (address) {
        uint256 underlyingBaseDecimals = _underlyingDecimals(baseVault, baseTokenDecimals);
        uint256 underlyingQuoteDecimals = _underlyingDecimals(quoteVault, quoteTokenDecimals);

        return MORPHO_FACTORY.createMorphoChainlinkOracleV2(
            baseVault,
            baseVaultConversionSample,
            baseFeed1,
            baseFeed2,
            underlyingBaseDecimals,
            quoteVault,
            quoteVaultConversionSample,
            quoteFeed1,
            quoteFeed2,
            underlyingQuoteDecimals,
            morphoSalt
        );
    }

    /// @notice Deploys the `WrapperRateConsumer` around `oracle` with each side's SHARE decimals.
    /// @dev Split out so the per-side `_shareDecimals` reads run in a smaller stack frame than the 12-argument shared
    ///      path would allow without via-IR. The vaults are read back from the freshly-created `oracle`
    ///      (`BASE_VAULT()` / `QUOTE_VAULT()`) rather than re-passing `baseVault`/`quoteVault` from the shared frame:
    ///      the oracle was just constructed from those exact vaults, so the values are identical, and avoiding the
    ///      re-pass keeps this within the stack limit. The factory remains the single source of truth — it (not the
    ///      wrapper) performs the SHARE-decimals read and hands the wrapper a value it trusts as-is. A no-vault side's
    ///      `BASE_VAULT()`/`QUOTE_VAULT()` is `address(0)`, so `_shareDecimals` falls back to the caller's token
    ///      decimals.
    function _deployWrapper(address oracle, bytes32 wrapperSalt, uint256 baseTokenDecimals, uint256 quoteTokenDecimals)
        private
        returns (address)
    {
        IMorphoChainlinkOracleV2 morphoOracle = IMorphoChainlinkOracleV2(oracle);
        uint256 shareBaseDecimals = _shareDecimals(morphoOracle.BASE_VAULT(), baseTokenDecimals);
        uint256 shareQuoteDecimals = _shareDecimals(morphoOracle.QUOTE_VAULT(), quoteTokenDecimals);

        return address(new WrapperRateConsumer{salt: wrapperSalt}(oracle, shareBaseDecimals, shareQuoteDecimals));
    }

    /// @notice The side's UNDERLYING-asset decimals — what the Morpho oracle's `SCALE_FACTOR` is built from.
    /// @dev For a vault side, read `vault.asset().decimals()` (DERIVED — the caller's value is ignored so it cannot
    ///      misconfigure the oracle). For a no-vault side, fall back to the caller-supplied token decimals.
    function _underlyingDecimals(IERC4626 vault, uint256 tokenDecimals) private view returns (uint256) {
        if (address(vault) == address(0)) return tokenDecimals;
        return IERC20Metadata(IERC4626Metadata(address(vault)).asset()).decimals();
    }

    /// @notice The side's SHARE decimals — what the `WrapperRateConsumer` normalizes against (Morpho's `price()`
    ///         carries the SHARE-decimal scale; see guides/oracle-decimals.md §2).
    /// @dev For a vault side, read `vault.decimals()` (the ERC-4626 share decimals). For a no-vault side, fall back
    ///      to the caller-supplied token decimals (no share/underlying split exists there).
    function _shareDecimals(IERC4626 vault, uint256 tokenDecimals) private view returns (uint256) {
        if (address(vault) == address(0)) return tokenDecimals;
        return IERC4626Metadata(address(vault)).decimals();
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.2.0";
    }
}
