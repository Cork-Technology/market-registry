// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RecipeSource} from "../interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IVersion} from "../interfaces/IVersion.sol";
import {BaseLiquidityRecipe} from "./BaseLiquidityRecipe.sol";

/// @title LiquidityNavRecipe
/// @notice {BaseLiquidityRecipe}'s maximally permissive rate window, applied to markets quoted from a
///         vault's net asset value. The policy — all four limits, both entrypoints — lives in the base
///         contract and is not restated or altered here; the only thing this deployment adds is the
///         rate kind.
/// @dev Approving this address means approving the base contract's policy AND the choice of net asset
///         value as the market's rate source. The price-feed twin is {LiquidityPriceRecipe}, and the
///         two are otherwise byte-for-byte the same policy.
contract LiquidityNavRecipe is BaseLiquidityRecipe, IVersion {
    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    /// @param registry The `MarketRegistry` this recipe is deployed against. Must be non-zero.
    function initialize(IMarketRegistry registry) external initializer {
        __BaseLiquidityRecipe_init(registry);
    }

    /// @inheritdoc BaseLiquidityRecipe
    /// @dev `NAV` sends the adapter's step 3 to `registry.deploy(ca, ref, OracleMode.NAV)`, which
    ///      requires at least one leg of the pair to carry a NAV source. The oracle it returns is the
    ///      one the base contract's `resolve` and `verify` read.
    function _source() internal pure override returns (RecipeSource) {
        return RecipeSource.NAV;
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
