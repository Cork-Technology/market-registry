// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMarketRecipe, RecipeSource} from "../interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IRateOracle} from "../interfaces/IRateOracle.sol";
import {IVersion} from "../interfaces/IVersion.sol";

/// @title FixedRateRecipe
/// @notice The `IMarketRecipe` for a market whose rate never moves: the rate lives in an immutable
///         `FixedRateOracle`, and this recipe's job is to prove the market really adopted one of
///         those and that its constraint permits no drift.
/// @dev ## WHERE THE RATE LIVES, AND WHY THIS FILE NO LONGER HOLDS IT
///
///      The predecessor took the rate as a constructor `immutable`, so one deployed instance meant
///      one rate and approving the address approved that number. THE RATE HAS MOVED OUT OF THIS
///      CONTRACT AND INTO THE ORACLE, and the reason is worth stating rather than discovering.
///
///      The old shape did not work. A genuinely fixed constraint has `rateMin == rateMax`, and
///      phoenix's `CorkPoolManager.createNewPool` requires `rateMin < rateMax` STRICTLY; a `FIXED`
///      recipe also deployed no oracle at all, and the same function refuses a zero `rateOracle`.
///      Every market the old recipe could describe was therefore uncreatable, twice over.
///
///      Both blockages come from the same missing piece — an oracle — so both are closed by supplying
///      one. `CorkLimitOrderAdapter.JITMarketParams` now carries a `rateOverride`, and step 3 of the
///      adapter's sequence hands it to `MarketRegistry.deployFixedRateOracle`. That returns a
///      `FixedRateOracle`: one constructor argument, one `view` function, no owner, no setter, so its
///      rate is as immovable as a constructor `immutable` in this file ever was. The market gets a
///      real non-zero oracle, and the constraint is free to be a window rather than a point.
///
///      ## What approving this address means now
///
///      IT NO LONGER PINS ONE RATE. One deployment serves every fixed rate, because the rate arrives
///      in the order. This is a deliberate loosening and it should be read with open eyes: whoever
///      writes the order picks the number.
///
///      What the approval still guarantees is the SHAPE of the market, which is what {verify}
///      enforces:
///
///      1. The market's oracle is a genuine `FixedRateOracle` from the registry's own factory — not
///         a feed wrapper, not a contract someone controls. Its rate can never change after
///         deployment, so nobody can move the market's rate afterwards.
///      2. The pool's constraint grants NO movement: both allowances are zero, so the rate cannot
///         drift within the window either.
///
///      Together those say: this market's rate was chosen once, at signing time, and is frozen. That
///      is the policy. Which number was chosen is the order author's call and is visible in the
///      oracle address, which is `CREATE2`-derived from the rate and therefore reads back as the rate
///      — see {verify} for the provenance check that turns that derivation into a proof.
///
///      ## The one check this recipe deliberately does NOT make
///
///      It does not require the oracle's rate to sit inside `[rateMin, rateMax]`. Nothing here stops
///      an order from deploying an oracle at one rate and carrying a window somewhere else, in which
///      case the pool's constraint adapter would clamp the oracle's reading to the window's edge and
///      the effective rate would be the window's, not the oracle's. Phoenix rejects exactly that at
///      creation — `ConstraintRateAdapter.bootstrap` requires the live rate to be inside the window —
///      so such a market cannot come into existence. The check is left where it already exists rather
///      than duplicated here.
///
///      ## Why there is a registry reference, and why it is fixed at deployment
///
///      {verify} must decide whether an oracle address is one the registry's fixed-rate factory
///      produced, and only the registry can answer that. `IMarketRecipe` allows a registry reference
///      in exactly one shape — pinned at deployment, never a call argument — because a registry
///      arriving as an argument would let a caller redirect every lookup the recipe makes. The oracle
///      address is fine as an argument; the authority that vouches for it is not. It is written once
///      by `initialize`, in the deployment transaction, and has no setter.
///
///      ## `resolve` and `verify` are `view`, on purpose, warning and all
///
///      `source()` and `description()` return literals, so solc emits "state mutability can be
///      restricted to `pure`" for both. Leave them `view`. `IMarketRecipe` states that all four of
///      its functions being `view` IS the security boundary — it is what makes the caller reach them
///      by `staticcall` — and this contract's signatures should match the interface exactly.
contract FixedRateRecipe is IMarketRecipe, Initializable, IVersion {
    // ─────────────────────────────── Errors ────────────────────────────────

    /// @notice Thrown at initialization when the registry address is zero.
    /// @dev A hard requirement: {verify}'s whole provenance check runs through {REGISTRY}, so an
    ///      instance without one could never accept anything.
    error ZeroRegistry();

    /// @notice Thrown by `resolve` when `additionalData` is not empty.
    /// @dev `resolve` reverts where `verify` returns false, and the asymmetry is deliberate: `resolve`
    ///      is called off-chain by the agent BUILDING the order, so a loud failure there is a bug
    ///      report delivered at the moment the mistake is made. `verify` is called on-chain by
    ///      `CorkLimitOrderAdapter`, which owns the revert and its selector — see `IMarketRecipe.verify`.
    /// @param length The `additionalData` length that was supplied.
    error UnexpectedAdditionalData(uint256 length);

    /// @notice Thrown when the caller supplied no rate oracle (`rateOracle` is zero).
    /// @dev A revert, not a `false`, and that is the interface's own rule: `false` means the constraint
    ///      is unacceptable, a revert is reserved for a recipe that genuinely CANNOT answer. Without an
    ///      oracle there is no rate to check the provenance of, so there is no verdict to give.
    ///
    ///      Unreachable on the adapter's path: step 3 deploys the `FixedRateOracle` for the order's
    ///      `rateOverride` before `verify` runs, and `deployFixedRateOracle` either returns a live
    ///      address or reverts. It is reachable by anything calling directly, and this selector
    ///      propagates unchanged — a different selector from `RecipeRejectedConstraint`, so "your
    ///      oracle is missing" never reads as "your constraint is wrong".
    /// @param ca The collateral asset.
    /// @param ref The reference asset.
    error RateOracleNotDeployed(address ca, address ref);

    // ─────────────────────────────── Storage ────────────────────────────────

    /// @notice The registry whose fixed-rate oracle factory this instance vouches for.
    /// @dev Written once by `initialize` and never repointed — there is no setter. It is the whole
    ///      policy surface of a deployed instance: approving this recipe approves "markets whose
    ///      oracle came from THIS registry's fixed-rate factory", and the getter is how a reviewer
    ///      checks which registry that is. It moved out of the constructor so the creation code
    ///      carries no arguments and the recipe lands on the same CREATE2 address on every chain;
    ///      the `AtomicDeployer` initializes it in the deployment transaction.
    IMarketRegistry public REGISTRY;

    /// @notice How far above the floor {resolve} places the ceiling, in rate-scale wei.
    /// @dev One wei is the narrowest window phoenix's STRICT `rateMin < rateMax` permits, and a
    ///      one-wei window around an oracle that never moves is as close to a single pinned point as
    ///      a creatable market can get. See {resolve}.
    uint256 public constant WINDOW_WIDTH = 1;

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    /// @param registry The `MarketRegistry` whose `predictFixedRateOracle` decides which oracles this
    ///        instance accepts. Must be non-zero.
    function initialize(IMarketRegistry registry) external initializer {
        if (address(registry) == address(0)) revert ZeroRegistry();
        REGISTRY = registry;
    }

    // ─────────────────────────────── IMarketRecipe ──────────────────────────

    /// @inheritdoc IMarketRecipe
    /// @dev A literal, as the interface requires. `FIXED` is the one `RecipeSource` with no
    ///      `IMarketRegistry.OracleMode` counterpart: it tells `CorkLimitOrderAdapter` to take the
    ///      market's rate from the order's `rateOverride` and deploy a `FixedRateOracle` for it,
    ///      rather than to look up a feed wrapper for the pair.
    function source() external view override returns (RecipeSource) {
        return RecipeSource.FIXED;
    }

    /// @inheritdoc IMarketRecipe
    /// @dev A fixed string. It says outright that the rate comes from the ORDER and not from this
    ///      contract, because that is the one thing a reader of an approved recipe list would
    ///      otherwise get wrong.
    function description() external view override returns (string memory) {
        return "Fixed rate: the market's rate is whatever immutable FixedRateOracle the order names, "
            "and it can never move. Requires that oracle to come from this registry's fixed-rate "
            "factory and that both rate-change allowances are zero. Takes no additionalData.";
    }

    /// @inheritdoc IMarketRecipe
    /// @dev Reads the rate from `rateOracle` and returns the narrowest creatable window around it:
    ///      floor at the rate, ceiling one wei above, both movement allowances zero. The one wei is
    ///      not a tolerance — phoenix's `rateMin < rateMax` is strict, so a literal single point is
    ///      uncreatable, and one wei is the smallest window that is not one. See {WINDOW_WIDTH}.
    ///
    ///      UNLIKE MOST RECIPES, THIS ONE NEEDS THE ORACLE TO EXIST AT SIGNING TIME.
    ///      `IMarketRecipe.resolve` warns that a feed wrapper usually does not exist yet when an order
    ///      is signed, and a recipe should not depend on one. A `FixedRateOracle` is different: its
    ///      address is `CREATE2`-derived from the rate, and `MarketRegistry.deployFixedRateOracle` is
    ///      permissionless and idempotent, so the agent building the order can simply deploy it (or
    ///      simulate that call) before asking for a constraint. Reading the deployed oracle rather
    ///      than taking the rate as a parameter keeps `resolve` and {verify} pointed at the same
    ///      single source of truth.
    ///
    ///      `ca` and `ref` are unused: a fixed rate is a number, not a relationship between two assets.
    function resolve(address ca, address ref, address rateOracle, bytes calldata additionalData)
        external
        view
        override
        returns (IMarketRegistry.ResolvedConstraint memory constraint)
    {
        if (additionalData.length != 0) revert UnexpectedAdditionalData(additionalData.length);
        if (rateOracle == address(0)) revert RateOracleNotDeployed(ca, ref);

        uint256 rate = IRateOracle(rateOracle).rate();
        constraint = IMarketRegistry.ResolvedConstraint({
            rateMin: rate, rateMax: rate + WINDOW_WIDTH, rateChangePerDayMax: 0, rateChangeCapacityMax: 0
        });
    }

    /// @inheritdoc IMarketRecipe
    /// @dev Returns false rather than reverting for every rejection, as the interface requires: the
    ///      adapter owns the revert and its selector. The one exception is a missing oracle, which is
    ///      "cannot answer" rather than "no" — see {RateOracleNotDeployed}.
    ///
    ///      ## The provenance check, which is the substantive half of the job
    ///
    ///      `FixedRateOracleFactory` deploys with `CREATE2` using the RATE ITSELF as the salt, so for
    ///      any given rate there is exactly one address the factory could ever put an oracle at, and
    ///      only the factory can deploy there. Asking the registry for that address and comparing it
    ///      to the oracle the market actually adopted therefore proves three things at once: the
    ///      oracle came from this registry's factory, its code is `FixedRateOracle` (that is the only
    ///      thing the factory deploys), and the rate it reports is the rate it was deployed with.
    ///
    ///      An impostor cannot pass. It can report any rate it likes, but the address it would have to
    ///      occupy to match is determined by that rate and is reachable only through the factory.
    ///
    ///      ## The shape check, which is the other half
    ///
    ///      Both movement allowances must be zero — a window the rate may drift inside is not a fixed
    ///      market, and this is the requirement that makes the immutable oracle mean something. Then
    ///      the two rules `CorkPoolManager.createNewPool` imposes on the constraint fields:
    ///
    ///          require(poolParams.rateMin > 0, InvalidParams());
    ///          require(poolParams.rateMin < poolParams.rateMax, InvalidParams());
    ///
    ///      They are enforced here so a rejection is diagnosed at the step that owns it instead of
    ///      several frames inside the controller. The window's WIDTH is not otherwise constrained:
    ///      with an oracle that cannot move and no drift allowance, a wider window changes nothing
    ///      about the rate the market runs at.
    function verify(
        address ca,
        address ref,
        address rateOracle,
        IMarketRegistry.ResolvedConstraint calldata constraint,
        bytes calldata additionalData
    ) external view override returns (bool) {
        // This recipe reads no `additionalData`, so carrying any is a mismatch, not a courtesy.
        if (additionalData.length != 0) return false;

        if (rateOracle == address(0)) revert RateOracleNotDeployed(ca, ref);

        // Provenance: only the registry's own factory could have put an oracle at the address its
        // rate derives to.
        uint256 rate = IRateOracle(rateOracle).rate();
        if (REGISTRY.predictFixedRateOracle(rate) != rateOracle) return false;

        // Fixedness: no daily movement, no accumulated capacity.
        if (constraint.rateChangePerDayMax != 0) return false;
        if (constraint.rateChangeCapacityMax != 0) return false;

        // The pool manager's own two rules.
        if (constraint.rateMin == 0) return false;
        return constraint.rateMin < constraint.rateMax;
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
