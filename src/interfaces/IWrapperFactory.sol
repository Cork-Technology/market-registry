// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IWrapperFactory
/// @notice Minimal, registry-side view of `WrapperRateConsumerFactory.createWrapperRateConsumer`.
/// @dev This declares the same selector as `IWrapperRateConsumerFactory.createWrapperRateConsumer`
///      with the vault and feed arguments widened from `IERC4626` / `AggregatorV3Interface` to plain
///      `address`. The ABI encoding is identical — contract types encode as `address` — so a call
///      through this interface reaches the real factory unchanged.
///
///      ## There is NO Solidity version split, and there never is again
///
///      An earlier comment here claimed the registry was pinned to `0.8.26` while the factory was on
///      `0.8.30`, and that this widened interface existed because the registry therefore could not
///      import the real one. **That was stale.** Every `.sol` file in `src/` and `script/` declares
///      `pragma solidity ^0.8.30` and `foundry.toml` pins `solc_version = "0.8.30"`. Do not build an
///      argument on a version split and do not reintroduce the claim.
///
///      ## Why it is kept anyway
///
///      Because the command-line tool's PINNED contract artifact
///      (`packages/cli/contracts/artifacts/`, guarded by `pnpm ci:pin-parity`) references this shape.
///      Deleting the interface is churn with a downstream cost and no upside, so it stays. If the
///      factory's signature ever changes, change it here too — the selector has to match or the call
///      silently hits nothing.
///
///      Both shapes of call happen: a leg resolved to an `ERC4626` source passes a real vault and
///      `10 ** shareDecimals`, while a leg resolved to an aggregator passes `address(0)` and exactly
///      `1`, which the Morpho oracle REQUIRES on a vault-less leg. See `MarketRegistry._wireLeg`.
interface IWrapperFactory {
    /// @notice Create a `MorphoChainlinkOracleV2` and the `WrapperRateConsumer` wrapping it.
    /// @return wrapper The `WrapperRateConsumer` (the rate oracle a market reads).
    /// @return oracle The underlying `MorphoChainlinkOracleV2`.
    function createWrapperRateConsumer(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 morphoSalt,
        bytes32 wrapperSalt
    ) external returns (address wrapper, address oracle);
}
