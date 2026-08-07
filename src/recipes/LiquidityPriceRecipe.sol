// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RecipeSource} from "../interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IVersion} from "../interfaces/IVersion.sol";
import {BaseLiquidityRecipe} from "./BaseLiquidityRecipe.sol";

/// @title LiquidityPriceRecipe
/// @notice {BaseLiquidityRecipe}'s maximally permissive rate window, applied to markets priced from a
///         price feed. The policy — all four limits, both entrypoints — lives in the base contract and
///         is not restated or altered here; the only thing this deployment adds is the rate kind.
/// @dev Approving this address means approving the base contract's policy AND the choice of a price
///         feed as the market's rate source. The NAV twin is {LiquidityNavRecipe}, and the two are
///         otherwise byte-for-byte the same policy.
contract LiquidityPriceRecipe is BaseLiquidityRecipe, IVersion {
    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    /// @param registry The `MarketRegistry` this recipe is deployed against. Must be non-zero.
    function initialize(IMarketRegistry registry) external initializer {
        __BaseLiquidityRecipe_init(registry);
    }

    /// @inheritdoc BaseLiquidityRecipe
    /// @dev `PRICE` sends the adapter's step 3 to `registry.deploy(ca, ref, OracleMode.PRICE)` for the
    ///      pair's feed wrapper, which is the oracle the base contract's `resolve` and `verify` read.
    function _source() internal pure override returns (RecipeSource) {
        return RecipeSource.PRICE;
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
