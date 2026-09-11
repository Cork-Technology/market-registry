// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IPoolManager, Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {ICorkMarketCreator} from "./interfaces/ICorkMarketCreator.sol";
import {IMarketRecipe, RecipeSource} from "./interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {IRateOracle} from "./interfaces/IRateOracle.sol";
import {IVersion} from "./interfaces/IVersion.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title CorkMarketCreator
/// @notice Direct, permissionless market creation: the same pool a `CorkLimitOrderAdapter` fill
///         derives and creates just in time, creatable AHEAD of the fill by anyone willing to pay
///         for it. A smart contract account that cannot sign an ERC-2612 permit creates the pool
///         here first, approves the resulting cST to the limit order protocol, and then fills with
///         no permit at all.
///
///         THIS IS THE SINGLE CREATION PATH. `CorkLimitOrderAdapter` calls {createNewPool} with the
///         market instruction an order carries and takes the pool id and the share addresses back.
///         The creation logic lives here and nowhere else, so a fill can never derive a pool this
///         contract would not.
///
///         THE TWO POOL FEES ARE MARKET IDENTITY. Phoenix fixes the swap fee and the unwind fee at
///         pool creation and hashes them into the pool id, so the same pair, expiry, constraint,
///         and oracle with different fees is a different pool. Both fee fields therefore enter the
///         derivation on every call, not only on the creating one.
///
///         THE FEE RULE IS PHOENIX'S, NOT THIS CONTRACT'S. Phoenix refuses a fee of 100% or more at
///         pool creation (`InvalidFees`) and accepts anything below. This contract adds no bound of
///         its own, so what a pool may charge is decided in exactly one place.
/// @dev This contract must hold POOL_CREATOR_ROLE on the controller. No owner, no admin
///      functions, no upgradeability, no token custody, and no storage that moves after setup —
///      the three protocol addresses are written once by `initialize` (in the deployment
///      transaction, via `AtomicDeployer`) and have no setter. The reentrancy guard uses
///      TRANSIENT storage (EIP-1153).
///
///      The maximum market life is read from `MarketRegistry` at call time, for the same reason
///      the adapter reads it there: the registry already has an accountable owner, so the number
///      has a home and this contract does not need an owner of its own.
contract CorkMarketCreator is ICorkMarketCreator, ReentrancyGuardTransient, Initializable, IVersion {
    // ─────────────────────────────── Storage ────────────────────────────────

    /// @notice The Cork pool manager markets are derived and looked up against.
    /// @dev Set once through `initialize` rather than a constructor, so the creation code carries no
    ///      arguments and the creator lands on the same CREATE2 address on every chain. The same goes
    ///      for the two addresses below.
    IPoolManager public POOL_MANAGER;
    /// @notice The Cork controller pools are created through (this contract must hold its
    ///         POOL_CREATOR_ROLE).
    IDefaultCorkController public CONTROLLER;
    /// @notice The Cork market registry: deploys/records rate oracles, holds the approved-asset
    ///         and approved-recipe sets, and owns the expiry bound.
    IMarketRegistry public MARKET_REGISTRY;

    /// @inheritdoc ICorkMarketCreator
    function initialize(IPoolManager poolManager, IDefaultCorkController controller, IMarketRegistry marketRegistry)
        external
        initializer
    {
        if (
            address(poolManager) == address(0) || address(controller) == address(0)
                || address(marketRegistry) == address(0)
        ) {
            revert ZeroAddress();
        }
        POOL_MANAGER = poolManager;
        CONTROLLER = controller;
        MARKET_REGISTRY = marketRegistry;
    }

    // ─────────────────────────────── Entry point ─────────────────────────────

    /// @inheritdoc ICorkMarketCreator
    function createNewPool(MarketParams calldata params)
        external
        nonReentrant
        returns (MarketId poolId, address cst, address cpt)
    {
        poolId = _ensureMarket(params);
        (cpt, cst) = POOL_MANAGER.shares(poolId);
    }

    // ─────────────────────────────── Market creation ─────────────────────────

    function _ensureMarket(MarketParams memory params) internal returns (MarketId poolId) {
        // Both assets must be registry-approved on EVERY recipe path. The price and net-asset-value
        // paths get this from `MarketRegistry.deploy`, but the FIXED path never hands the pair to
        // the registry, so without this line anyone could create a canonical pool over two tokens
        // nobody approved. Checked before the recipe lookup so the answer does not depend on which
        // branch `_resolveOracle` takes.
        if (!MARKET_REGISTRY.isAsset(params.collateralAsset) || !MARKET_REGISTRY.isAsset(params.referenceAsset)) {
            revert IMarketRegistry.EntryNotFound();
        }

        address oracle = _resolveOracle(params);

        // Field order is load-bearing for the id hash. The fees are the last two fields, and they
        // are part of the id: a different fee is a different pool.
        Market memory market = Market({
            collateralAsset: params.collateralAsset,
            referenceAsset: params.referenceAsset,
            expiryTimestamp: params.expiryTimestamp,
            rateMin: params.constraint.rateMin,
            rateMax: params.constraint.rateMax,
            rateChangePerDayMax: params.constraint.rateChangePerDayMax,
            rateChangeCapacityMax: params.constraint.rateChangeCapacityMax,
            rateOracle: oracle,
            swapFeePercentage: params.swapFeePercentage,
            unwindSwapFeePercentage: params.unwindSwapFeePercentage
        });
        poolId = POOL_MANAGER.getId(market);

        // Step 4 — the recipe stands behind the carried constraint. Runs on every call, for the
        // live-rate check; the flag lets the recipe apply its creation-only rules once, the same
        // way the expiry bound below is applied once.
        bool creating = !_poolExists(poolId);
        _verifyConstraint(params.recipe, oracle, params, creating);

        if (creating) {
            // The bound is INCLUSIVE, matching the adapter: the longest permitted market must
            // stay creatable.
            uint256 maxExpiry = block.timestamp + MARKET_REGISTRY.maxExpiryDuration();
            if (params.expiryTimestamp > maxExpiry) revert ExpiryOutOfRange(params.expiryTimestamp, maxExpiry);

            uint256 rate = IRateOracle(oracle).rate();
            if (rate == 0) revert RateUnavailable();

            // The fees travel inside `market`; the creation params carry nothing else but the
            // whitelist flag, which stays off so the adapter can mint into the pool.
            CONTROLLER.createNewPool(
                IDefaultCorkController.PoolCreationParams({pool: market, isWhitelistEnabled: false})
            );
            emit MarketCreated(
                poolId,
                oracle,
                params.collateralAsset,
                params.referenceAsset,
                params.expiryTimestamp,
                params.recipe,
                params.swapFeePercentage,
                params.unwindSwapFeePercentage,
                msg.sender
            );
        }
    }

    // ─────────────────────────────── The four-step recipe sequence ──────────────
    /// @dev Steps 1 to 3. Step 4, `verify`, lives in {_ensureMarket} because it needs to know
    ///      whether the pool exists, and that takes the pool id.
    function _resolveOracle(MarketParams memory params) internal returns (address oracle) {
        address recipe = params.recipe;

        // Step 1 — membership. FIRST, before `source()` is read: there is no unverified path.
        if (!MARKET_REGISTRY.isRecipe(recipe)) revert IMarketRegistry.RecipeNotRegistered(recipe);

        // Step 2 — which kind of rate this recipe works against.
        RecipeSource src = IMarketRecipe(recipe).source();

        // Step 3 — produce the oracle. Every path yields a real, non-zero one. A FIXED recipe has
        // no feed to wrap, so the caller names the rate and the registry deploys the oracle for
        // it; neither asset reaches the registry on that branch, which is why the pair is gated
        // up front in `_ensureMarket` rather than here.
        if (src == RecipeSource.FIXED) {
            oracle = MARKET_REGISTRY.deployFixedRateOracle(params.rateOverride);
        } else {
            if (params.rateOverride != 0) revert UnexpectedRateOverride(recipe);
            oracle = MARKET_REGISTRY.deploy(
                params.collateralAsset,
                params.referenceAsset,
                src == RecipeSource.NAV ? IMarketRegistry.OracleMode.NAV : IMarketRegistry.OracleMode.PRICE,
                params.oracleSalt
            );
        }
    }

    /// @param creating True when this call is about to create the pool.
    function _verifyConstraint(address recipe, address rateOracle, MarketParams memory params, bool creating)
        internal
        view
    {
        bool accepted = IMarketRecipe(recipe)
            .verify(
                params.collateralAsset,
                params.referenceAsset,
                rateOracle,
                params.expiryTimestamp,
                creating,
                params.constraint,
                params.extraData
            );
        if (!accepted) revert RecipeRejectedConstraint(recipe);
    }

    /// @dev Phoenix's `market(poolId)` reverts for an uninitialized market; some doubles return
    ///      a zeroed struct instead. Treat both as "does not exist".
    function _poolExists(MarketId poolId) internal view returns (bool) {
        try POOL_MANAGER.market(poolId) returns (Market memory existing) {
            return existing.collateralAsset != address(0);
        } catch {
            return false;
        }
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
