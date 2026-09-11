// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IPoolManager, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";

/// @title ICorkMarketCreator
/// @notice Direct, permissionless market creation: the same pool a `CorkLimitOrderAdapter` fill
///         derives and creates just in time, creatable AHEAD of the fill by anyone willing to pay
///         for it. Integrators build against this interface — a smart contract account batches
///         `createNewPool` → `cst.approve(limitOrderProtocol)` → the fill with an empty permit
///         array, and never needs the ERC-2612 permit it cannot sign.
///
///         This is the single creation path. The adapter hands its market instruction to
///         {createNewPool} and gets the pool id and the share addresses back, so the creation logic
///         lives in ONE place and a fill can never derive a pool this contract would not.
interface ICorkMarketCreator {
    // ─────────────────────────────── Types ─────────────────────────────────

    /// @notice Everything {createNewPool} needs to assemble (and, if missing, create) a pool —
    ///         the adapter's `JITMarketParams` without the fill-only mint flag. The ten shared
    ///         fields keep the same names, types, and order, so an adapter can pass its own
    ///         payload through unchanged.
    struct MarketParams {
        address collateralAsset; // CA — the pool collateral asset
        address referenceAsset; // REF — the pool reference asset
        uint256 expiryTimestamp; // pool expiry, unix seconds; at creation, no later than now plus the registry's `maxExpiryDuration`
        address recipe; // the approved `IMarketRecipe` contract — required, never zero
        uint256 rateOverride; // FIXED recipes only: the rate to deploy a `FixedRateOracle` at; else 0
        IMarketRegistry.ResolvedConstraint constraint; // the four limits, derived OFF-CHAIN at signing time
        bytes extraData; // recipe-specific bytes `verify` needs
        bytes32 oracleSalt; // caller-chosen entropy for the wrapper's CREATE2 salt; matters only on the first deploy of the pair; zero is fine
        uint256 swapFeePercentage; // swap/exercise fee, 1e18 = 1%; Phoenix refuses 100e18 or more at creation (`InvalidFees`); part of the pool id
        uint256 unwindSwapFeePercentage; // unwindSwap/unwindExercise fee, same scale, same Phoenix rule; part of the pool id
    }

    // ─────────────────────────────── Errors ────────────────────────────────

    /// @notice Thrown when an `initialize` address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when the pair's rate oracle reports a zero rate at the moment this call
    ///         would CREATE the pool. A pool is permanent; creating one around an oracle that is
    ///         currently reporting nothing bakes in a dead rate source.
    error RateUnavailable();
    /// @notice Thrown when the params carry a non-zero `rateOverride` for a recipe that does not
    ///         read one — anything whose `source()` is not `FIXED`.
    /// @param recipe The recipe whose `source()` takes no rate override.
    error UnexpectedRateOverride(address recipe);
    /// @notice Thrown when the recipe returned `false` for the carried constraint — the
    ///         constraint is stale, or was never one this recipe would have produced.
    /// @param recipe The recipe address that rejected the constraint.
    error RecipeRejectedConstraint(address recipe);
    /// @notice Thrown when the call would CREATE a market that outlives the registry's maximum
    ///         market life. Only a call that CREATES the market can raise this.
    /// @param expiryTimestamp The expiry the params carried.
    /// @param maxExpiryTimestamp The latest expiry this call could have created.
    error ExpiryOutOfRange(uint256 expiryTimestamp, uint256 maxExpiryTimestamp);

    // ─────────────────────────────── Events ────────────────────────────────

    /// @notice Emitted when a call created the pool it derived. Not emitted for a call that
    ///         found the pool already existing.
    /// @param poolId The Cork pool id derived and created by this call.
    /// @param rateOracle The registry-deployed oracle the pool adopted.
    /// @param collateralAsset The pool collateral asset.
    /// @param referenceAsset The pool reference asset.
    /// @param expiryTimestamp The pool expiry in unix seconds.
    /// @param recipe The approved `IMarketRecipe` that verified the carried constraint.
    /// @param swapFeePercentage The pool's swap/exercise fee, 1e18 = 1%. Part of the pool id, so
    ///        an indexer can rebuild the `Market` struct and the id from this event alone.
    /// @param unwindSwapFeePercentage The pool's unwindSwap/unwindExercise fee, same scale, same
    ///        reason.
    /// @param caller The account that paid for the creation.
    event MarketCreated(
        MarketId indexed poolId,
        address indexed rateOracle,
        address collateralAsset,
        address referenceAsset,
        uint256 expiryTimestamp,
        address recipe,
        uint256 swapFeePercentage,
        uint256 unwindSwapFeePercentage,
        address indexed caller
    );

    // ─────────────────────────────── Functions ─────────────────────────────

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    function initialize(IPoolManager poolManager, IDefaultCorkController controller, IMarketRegistry marketRegistry)
        external;

    /// @notice Assemble the market described by `params` and create its pool if it does not
    ///         exist yet — the same derivation and the same checks every adapter fill runs,
    ///         minus the fill.
    /// @dev The returned share addresses are what a smart-account caller batches its approval
    ///      against: `cst` is the token the limit order protocol will pull. If the pool already
    ///      exists this is a lookup, and the expiry bound is NOT re-checked — the same rule as a
    ///      fill into an existing pool. The recipe's `verify` runs on EVERY call.
    /// @param params The market description, identical field-for-field to the ten market fields
    ///        an order carries in its `extraData`.
    /// @return poolId The Cork pool id derived from `params` (created by this call if needed).
    /// @return cst The pool's swap token — what a coverage order moves.
    /// @return cpt The pool's principal token.
    function createNewPool(MarketParams calldata params) external returns (MarketId poolId, address cst, address cpt);
}
