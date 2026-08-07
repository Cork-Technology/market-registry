// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {MarketRegistryLib} from "./MarketRegistryLib.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";

/// @title MarketRegistryRecipe
/// @notice The recipe store: the set of recipe CONTRACT ADDRESSES governance has approved.
abstract contract MarketRegistryRecipe is IMarketRegistry, Ownable2Step, MarketRegistryStorage {
    // ── membership mutation (owner-only) ───────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    function addRecipes(address[] calldata recipes) external override onlyOwner {
        uint256 len = recipes.length;
        for (uint256 i = 0; i < len; ++i) {
            _addRecipe(recipes[i]);
        }
    }

    /// @inheritdoc IMarketRegistry
    function removeRecipes(address[] calldata recipes) external override onlyOwner {
        uint256 len = recipes.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeRecipe(recipes[i]);
        }
    }

    // ── reads (unrestricted views) ─────────────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    /// @dev The only point read this store needs. There is no `lookupRecipe`, because an approved
    ///      recipe is nothing but its address — a lookup would have no record to return beyond the
    ///      yes-or-no this already answers, and a position in `_recipeKeys` is not a stable name for
    ///      anything (swap-on-remove moves it, and a remove-then-add cycle moves it again).
    function isRecipe(address recipe) external view override returns (bool) {
        return _recipeIndex[recipe] != 0;
    }

    // ── enumeration (paginated) ────────────────────────────────────────────────

    /// @inheritdoc IMarketRegistry
    function getRecipes(uint256 offset, uint256 limit)
        external
        view
        override
        returns (address[] memory page, uint256 total)
    {
        total = _recipeKeys.length;
        (uint256 start, uint256 count) = MarketRegistryLib.pageBounds(total, offset, limit);
        page = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            page[i] = _recipeKeys[start + i];
        }
    }

    // ── internals ───────────────────────────────────────────────────────────────

    function _addRecipe(address recipe) private {
        if (recipe == address(0)) revert ZeroAddress();
        if (recipe.code.length == 0) revert RecipeNotContract(recipe);
        if (_recipeIndex[recipe] != 0) revert EntryAlreadyExists();

        MarketRegistryLib.insertAddress(_recipeKeys, _recipeIndex, recipe);

        // The keyHash keeps the topic layout uniform across namespaces; the address it hashes is what
        // the store is actually keyed by, so the payload carries it back unhashed.
        emit EntryAdded(Namespace.Recipe, MarketRegistryLib.recipeKeyHash(recipe), abi.encode(recipe));
    }

    function _removeRecipe(address recipe) private {
        if (_recipeIndex[recipe] == 0) revert EntryNotFound();
        MarketRegistryLib.removeAddress(_recipeKeys, _recipeIndex, recipe);
        emit EntryRemoved(Namespace.Recipe, MarketRegistryLib.recipeKeyHash(recipe), abi.encode(recipe));
    }
}
