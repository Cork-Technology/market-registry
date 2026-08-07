// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IPoolManager, Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {
    Address,
    AddressLib,
    IOrderMixin,
    IPreInteraction,
    ITakerInteraction
} from "./interfaces/I1inchLimitOrderProtocol.sol";
import {IMarketRecipe, RecipeSource} from "./interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {IRateOracle} from "./interfaces/IRateOracle.sol";
import {IVersion} from "./interfaces/IVersion.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title CorkLimitOrderAdapter
/// @notice The single 1inch Limit Order Protocol (LOP) v4 adapter for Cork coverage orders:
///         just-in-time market creation AND just-in-time minting in one stateless,
///         custody-free contract.
///
///         JIT MARKET CREATION IS THE UNCONDITIONAL PART. Both hooks always derive the market
///         from `extraData` and create the pool if it does not exist yet. A fill into a pool
///         that already exists just pays for the derivation and moves on.
///
///         JIT MINTING IS THE GATED PART, and the two hooks gate it differently:
///         - `preInteraction` (maker-side, committed in the maker-signed extension): fires
///           BEFORE the LOP pulls the maker asset. Minting here is OPTIONAL and controlled by
///           `JITMarketParams.enableJitMint`. With the flag set, a maker selling cST it does
///           not hold yet gets it minted just in time. With the flag clear, the hook only
///           ensures the market exists and the maker is expected to already hold the cST the
///           LOP is about to pull. Either way the LOP needs a cST allowance from the maker for
///           that pull — granted either by a prior approval (existing pool) or by an ERC-2612
///           permit carried in `extraData` (see {PermitParams}: a just-created cST cannot have
///           a prior approval, the token did not exist to be approved).
///         - `takerInteraction` (taker-side, chosen freely per fill, no maker cooperation):
///           fires AFTER the maker asset arrived and BEFORE the LOP pulls the taker asset from
///           `msg.sender`, so a taker lifting a buy-cST bid mints its delivery just in time.
///           Minting here is UNCONDITIONAL — `enableJitMint` is ignored on this path. A taker
///           chooses this hook per fill precisely because it wants the mint; a taker that does
///           not want one simply does not attach the hook.
///         Both mint paths pull collateral ONLY from the party being served (`order.maker` /
///         `taker`), mint via `IPoolManager.mint` with that party as receiver, and hold
///         nothing across transactions. Abuse can only spend the abuser's own allowance.
///
///         Hook `extraData` = `abi.encode(JITMarketParams, PermitParams[])` — the market is
///         ASSEMBLED inside the fill from parts the ORDER carries, not referenced by id. The
///         four-step recipe sequence (see {_resolveOracle}) runs first and produces the rate
///         oracle; the constraint itself arrives in the order and is only CHECKED here. The
///         resulting `Market` struct yields the pool id; if that pool does not exist yet it is
///         created through `DefaultCorkController.createNewPool` with the whitelist DISABLED
///         (phoenix gates `mint` by `_onlyWhitelisted(poolId, msg.sender)`, and `msg.sender`
///         here is this adapter — a whitelisted pool could never be JIT-minted).
///
///         MARKET IDENTITY NO LONGER FOLLOWS THE RATE, and closing that was the point of the
///         payload change. The pool id hashes the whole `Market` struct including its four
///         rate-constraint fields, and those fields used to be DERIVED at fill time from the
///         oracle's live rate. So the pool id moved every time the rate moved, which moved the
///         `CREATE2`-predicted cST/cPT addresses, which invalidated the share addresses baked
///         into every resting order against that market. Chainlink's hourly heartbeat was the
///         only reason a market was predictable at all; against a continuously-updating vault
///         net asset value it may never have been. The constraint is now derived OFF-CHAIN at
///         signing time and carried in the order, so the pool id is fixed the moment the order
///         is signed and the predicted share addresses stay valid however far the rate moves.
///         `IMarketRecipe.verify` — a `staticcall`, step 4 — is what stops a stale or dishonest
///         constraint from being filled, and it replaces the accidental protection the moving
///         pool id used to provide. `OrderNotForPool` remains as the order/market identity
///         guard for every other kind of mismatch, and a revert still rolls back the whole
///         fill, including any pool created earlier in the same transaction.
/// @dev This contract must hold POOL_CREATOR_ROLE on the controller. No owner, no admin
///      functions, no upgradeability, no token custody beyond the duration of the fill
///      transaction, and no storage that moves after setup — the four protocol addresses are
///      written once by `initialize` (in the deployment transaction, via `AtomicDeployer`) and
///      have no setter, and the reentrancy guard uses TRANSIENT storage (EIP-1153), so nothing
///      here changes after deployment. See {preInteraction} for why the guard exists at all.
///
///      THE CREATION BOUND IS GOVERNANCE-SET, AND IT LIVES ON THE REGISTRY, NOT HERE. The
///      maximum market life (see {ExpiryOutOfRange}) is read from `MarketRegistry` at fill time.
///      That is the whole reason this contract can stay ownerless: the registry is already
///      `Ownable2Step` with the curator Safe behind it, so the number has a home where someone is
///      accountable for it and this contract does not need an owner of its own. An adapter with an
///      owner is an adapter whose owner can retarget the minting path.
contract CorkLimitOrderAdapter is
    IPreInteraction,
    ITakerInteraction,
    ReentrancyGuardTransient,
    Initializable,
    IVersion
{
    using AddressLib for Address;
    using SafeERC20 for IERC20;

    // ─────────────────────────────── Types ─────────────────────────────────

    /// @notice The market instruction carried in hook `extraData`: everything `_ensureMarket`
    ///         needs to assemble (and, if missing, create) the pool inside the fill, plus the flag
    ///         that gates the maker-side mint.
    /// @dev THE FOUR RATE-CONSTRAINT FIELDS ARE NOW CARRIED HERE, AND THE PREVIOUS COMMENT SAID
    ///      THE OPPOSITE. That reversal is the whole point of this shape, so it is worth stating
    ///      why rather than leaving the reader to wonder which version was right.
    ///
    ///      The predecessor carried a `string mode` — a registry recipe name — and DERIVED the
    ///      four constraint fields at fill time by reading the oracle's live `rate()` and running
    ///      it through the registry's stored percentage bands. The pool id is
    ///      `keccak256(abi.encode(Market))` and the `Market` struct contains those four fields, so
    ///      deriving them from the live rate made THE POOL IDENTIFIER MOVE WITH THE RATE. The
    ///      cST/cPT addresses are `CREATE2`-salted by the pool id, so every rate movement silently
    ///      invalidated the share addresses that every resting order had already been signed
    ///      against. A maker could not sign an order for a market that would still exist by the
    ///      time someone filled it.
    ///
    ///      So the derivation moved OFF-CHAIN, to order-signing time: an agent calls
    ///      `IMarketRecipe.resolve` off-chain, puts the resulting `ResolvedConstraint` in the order
    ///      next to the `recipe` address and the `additionalData` it was derived from, and the
    ///      pool identifier is fixed from that moment on. On-chain, `verify` re-checks the carried
    ///      constraint on every fill (step 4 of {_resolveOracle}). Nothing about the market is
    ///      derived from the live rate any more, so nothing about the market moves with it.
    ///
    ///      EVERY order must name a registered recipe. There is no unverified path: `address(0)` is
    ///      not a special case, it is simply an address the registry will never hold, so it fails
    ///      step 1 of {_resolveOracle} like any other unregistered address.
    ///
    ///      The fee fields are only consumed when the fill actually creates the pool; on an
    ///      existing pool they are ignored (fees are not part of market identity). They are still
    ///      BOUNDS-CHECKED on every fill — see {_checkFees}.
    ///
    ///      `rateOverride` IS THE ORDER NAMING ITS OWN RATE, and it is meaningful for exactly one
    ///      kind of recipe. A `FIXED` recipe has no feed to wrap: there is no pair lookup that would
    ///      ever find its rate, because the rate is not a fact about the two assets. So the order
    ///      carries the number, step 3 of {_resolveOracle} deploys the `FixedRateOracle` for it
    ///      through the registry, and the market gets a real, permanently immutable oracle instead of
    ///      the `address(0)` that used to make these markets uncreatable. For a `NAV` or `PRICE`
    ///      recipe the rate comes from the pair's feed wrapper and this field must be zero — a
    ///      non-zero one is REJECTED rather than ignored, so a payload can never carry a number that
    ///      looks like it chose the rate when nothing read it.
    struct JITMarketParams {
        address collateralAsset; // CA — the pool collateral asset, pulled from the party served
        address referenceAsset; // REF — the pool reference asset
        uint256 expiryTimestamp; // pool expiry, unix seconds; at creation, no later than now plus the registry's `maxExpiryDuration`
        address recipe; // the approved `IMarketRecipe` contract — required, never zero
        uint256 rateOverride; // FIXED recipes only: the rate to deploy a `FixedRateOracle` at; else 0
        IMarketRegistry.ResolvedConstraint constraint; // the four limits, derived OFF-CHAIN at signing time
        bytes additionalData; // recipe-specific bytes `verify` needs
        uint256 swapFeePercentage; // swap/exercise fee, 1e18 = 1%; capped at {MAX_FEE_PERCENTAGE}, checked on EVERY fill
        uint256 unwindSwapFeePercentage; // unwindSwap/unwindExercise fee, same scale, same cap, also checked on EVERY fill
        bool enableJitMint; // gate the maker-side mint in `preInteraction`; IGNORED by `takerInteraction`
    }

    /// @notice ERC-2612 permit carried in `extraData` next to the market recipe and executed
    ///         by this adapter right after the JIT mint. `extraData` carries an ARRAY of these
    ///         — any number of permits over any tokens; EVERY carried permit is executed, and
    ///         one that fails to execute reverts the whole fill. An empty array carries none.
    ///
    ///         WHY IT EXISTS: the LOP pulls tokens from the party served with a plain
    ///         `transferFrom` immediately after the interaction returns, which requires an
    ///         allowance to the LOP — but a just-created cST could not have been approved in
    ///         advance (the token did not exist; allowances live in ITS storage). The share
    ///         tokens ARE predictable before creation (phoenix's SharesFactory deploys them
    ///         with CREATE2, salted by the pool id), so the party signs a permit against the
    ///         predicted address and this adapter executes it the moment the token exists:
    ///         mint, then permit, then the LOP's pull finds the allowance in place.
    ///
    ///         The owner is always the party served (`order.maker` in `preInteraction`, the
    ///         taker in `takerInteraction`), the spender is always the LOP.
    struct PermitParams {
        address token; // the ERC-2612 token the permit is signed over
        uint256 value; // allowance granted to the LOP
        uint256 deadline; // permit deadline, unix seconds
        uint8 v; // signature v
        bytes32 r; // signature r
        bytes32 s; // signature s
    }

    // ─────────────────────────────── Errors ────────────────────────────────

    /// @notice Thrown when a constructor address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when a callback caller is not the 1inch LOP.
    error OnlyLimitOrderProtocol();
    /// @notice Thrown when neither order side is the derived pool's cST (order/market
    ///         mismatch — including a mismatch caused by the oracle rate having moved since
    ///         the order was signed).
    error OrderNotForPool();
    /// @notice Thrown when the pair's rate oracle reports a zero rate at the moment this fill
    ///         would CREATE the pool.
    /// @dev The reason changed even though the selector did not. It used to guard constraint
    ///      derivation: a zero rate resolved every band to zero and derived a degenerate market.
    ///      The constraint no longer comes from the rate, so that reason is gone. What remains is
    ///      narrower and only applies at creation: a pool is permanent, and creating one around an
    ///      oracle that is currently reporting nothing bakes in a dead rate source. Phoenix would
    ///      catch it too — `ConstraintRateAdapter.bootstrap` requires the live rate to sit inside
    ///      `[rateMin, rateMax]` and `createNewPool` requires `rateMin > 0`, so a zero rate fails
    ///      there — but it fails with phoenix's `InvalidRate`, several frames down and naming
    ///      nothing. This check is the same rejection with a name on it. See {_ensureMarket} for
    ///      why the rate is NOT read on the far more common fill-into-an-existing-pool path.
    error RateUnavailable();
    /// @notice Thrown when an order carries a non-zero `rateOverride` for a recipe that does not read
    ///         one — anything whose `source()` is not `FIXED`.
    /// @dev Rejected rather than ignored, for the same reason a recipe rejects `additionalData` it does
    ///      not read: a silently ignored number in a signed payload leaves a provenance trail claiming
    ///      the order chose the rate, when the rate actually came from the pair's feed wrapper. A
    ///      `NAV` or `PRICE` market's rate is a fact about the two assets and the order does not get a
    ///      vote on it.
    /// @param recipe The recipe whose `source()` takes no rate override.
    error UnexpectedRateOverride(address recipe);
    /// @notice Thrown when the recipe returned `false` for the constraint the order carries — the
    ///         constraint is stale, or was never one this recipe would have produced.
    /// @dev This is the on-chain enforcement of the whole policy. `IMarketRecipe.verify` returns a
    ///      boolean rather than reverting precisely so that "your constraint is wrong" is a distinct
    ///      failure from "this recipe cannot answer" — the latter is the recipe's OWN revert, which
    ///      propagates to the caller unchanged.
    /// @param recipe The recipe address that rejected the constraint.
    error RecipeRejectedConstraint(address recipe);
    /// @notice Thrown when a fill would CREATE a market that outlives the registry's maximum market
    ///         life.
    /// @dev The July 28 incident in one selector. Every layer of the stack accepted an unbounded
    ///      `uint256` here, and the composition was the outage: an expiry in MILLISECONDS is a
    ///      perfectly ordinary number ~1000x too large, it is comfortably in the future, so phoenix's
    ///      `expiryTimestamp > block.timestamp` waves it through and the result is a market that
    ///      expires in the year 58527. Nothing can retire it, and it costs about twenty cents to make.
    ///
    ///      Only a fill that CREATES the market can raise this. A market created while a looser bound
    ///      was in force keeps filling — see {_ensureMarket}.
    /// @param expiryTimestamp The expiry the order carried.
    /// @param maxExpiryTimestamp The latest expiry this fill could have created, `block.timestamp`
    ///        plus the registry's maximum market life.
    error ExpiryOutOfRange(uint256 expiryTimestamp, uint256 maxExpiryTimestamp);
    /// @notice Thrown when the order's swap/exercise fee exceeds {MAX_FEE_PERCENTAGE}.
    error SwapFeeOutOfRange(uint256 fee, uint256 maxFee);
    /// @notice Thrown when the order's unwindSwap/unwindExercise fee exceeds {MAX_FEE_PERCENTAGE}.
    error UnwindSwapFeeOutOfRange(uint256 fee, uint256 maxFee);
    /// @notice Thrown when the pool cannot mint (paused or expired: `previewMint` returned 0).
    error MintUnavailable();
    /// @notice Thrown when `mint` spent a different collateral amount than `previewMint` quoted
    ///         within the same transaction (should be unreachable; guards the exact-allowance
    ///         and no-custody invariants).
    error MintAmountDrift();

    // ─────────────────────────────── Events ────────────────────────────────

    /// @notice Emitted when a fill created the pool it was minting into.
    /// @param poolId The Cork pool id derived and created by this fill.
    /// @param rateOracle The registry-deployed wrapper the pool adopted as its rate oracle.
    /// @param collateralAsset The pool collateral asset.
    /// @param referenceAsset The pool reference asset.
    /// @param expiryTimestamp The pool expiry in unix seconds.
    /// @param recipe The approved `IMarketRecipe` that verified the carried constraint — always a
    ///        registered address, never zero. Replaces the mode STRING the predecessor emitted:
    ///        recipes are no longer named by a string at all.
    event JITMarketCreated(
        MarketId indexed poolId,
        address indexed rateOracle,
        address collateralAsset,
        address referenceAsset,
        uint256 expiryTimestamp,
        address recipe
    );

    /// @notice Emitted after a successful just-in-time mint inside a fill.
    /// @param poolId The Cork pool the shares were minted in.
    /// @param recipient The party served (order maker or fill taker) — receives cST AND cPT.
    /// @param cstShares Shares minted of each leg (18 decimals) — equals the cST the LOP pulls.
    /// @param collateralIn Collateral pulled from `recipient` (CA native decimals).
    event JITMinted(MarketId indexed poolId, address indexed recipient, uint256 cstShares, uint256 collateralIn);

    // ─────────────────────────────── Storage ────────────────────────────────

    /// @notice The highest either fee field may be, 1e18 = 1%. Five percent.
    uint256 public constant MAX_FEE_PERCENTAGE = 5e18;

    /// @notice The 1inch Limit Order Protocol (Aggregation Router v6) — sole authorized caller
    ///         of the interaction callbacks.
    /// @dev Set once through `initialize` rather than a constructor, so the creation code carries no
    ///      arguments and the adapter lands on the same CREATE2 address on every chain. Deployed
    ///      through `AtomicDeployer`, which initializes in the deployment transaction. The same goes
    ///      for the three addresses below.
    address public LIMIT_ORDER_PROTOCOL;
    /// @notice The Cork pool manager mints are executed against.
    IPoolManager public POOL_MANAGER;
    /// @notice The Cork controller pools are created through (this adapter must hold its
    ///         POOL_CREATOR_ROLE).
    IDefaultCorkController public CONTROLLER;
    /// @notice The Cork market registry: deploys/records the pair's rate-oracle wrapper, and holds
    ///         the approved-recipe membership set this adapter gates every order-supplied recipe
    ///         address against.
    /// @dev It no longer resolves constraints. `applyBands` is gone from the registry; the bands
    ///      arithmetic lives in `MarketRegistryLib` and the recipes call it off-chain.
    IMarketRegistry public MARKET_REGISTRY;

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    function initialize(
        address limitOrderProtocol,
        IPoolManager poolManager,
        IDefaultCorkController controller,
        IMarketRegistry marketRegistry
    ) external initializer {
        if (
            limitOrderProtocol == address(0) || address(poolManager) == address(0) || address(controller) == address(0)
                || address(marketRegistry) == address(0)
        ) revert ZeroAddress();
        LIMIT_ORDER_PROTOCOL = limitOrderProtocol;
        POOL_MANAGER = poolManager;
        CONTROLLER = controller;
        MARKET_REGISTRY = marketRegistry;
    }

    // ─────────────────────────────── Interactions ───────────────────────────

    /// @inheritdoc IPreInteraction
    function preInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata,
        bytes32,
        address,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256,
        bytes calldata extraData
    ) external nonReentrant {
        if (msg.sender != LIMIT_ORDER_PROTOCOL) revert OnlyLimitOrderProtocol();
        address maker = order.maker.get();

        (JITMarketParams memory params, PermitParams[] memory permits) =
            abi.decode(extraData, (JITMarketParams, PermitParams[]));

        MarketId poolId = _ensureMarket(params);
        uint256 cstShares = _resolveCstShares(order, poolId, makingAmount, takingAmount);

        if (params.enableJitMint) _jitMint(poolId, params.collateralAsset, maker, cstShares);

        _applyPermits(maker, permits);
    }

    /// @inheritdoc ITakerInteraction
    function takerInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata,
        bytes32,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256,
        bytes calldata extraData
    ) external nonReentrant {
        if (msg.sender != LIMIT_ORDER_PROTOCOL) revert OnlyLimitOrderProtocol();

        (JITMarketParams memory params, PermitParams[] memory permits) =
            abi.decode(extraData, (JITMarketParams, PermitParams[]));

        MarketId poolId = _ensureMarket(params);
        uint256 cstShares = _resolveCstShares(order, poolId, makingAmount, takingAmount);

        _jitMint(poolId, params.collateralAsset, taker, cstShares);

        _applyPermits(taker, permits);
    }

    // ─────────────────────────────── JIT minting ────────────────────────────

    /// @dev Resolve which side of the order is the derived pool's cST, and return that side's
    ///      amount. Runs on every fill, including one whose mint is gated off: it is what ties
    ///      the signed order to the market derived at fill time, and it is the guard that fires
    ///      `OrderNotForPool` when the oracle rate has moved the derived pool out from under a
    ///      signed order.
    function _resolveCstShares(
        IOrderMixin.Order calldata order,
        MarketId poolId,
        uint256 makingAmount,
        uint256 takingAmount
    ) internal view returns (uint256) {
        (, address swapToken) = POOL_MANAGER.shares(poolId);
        if (order.makerAsset.get() == swapToken) return makingAmount;
        if (order.takerAsset.get() == swapToken) return takingAmount;
        revert OrderNotForPool();
    }

    /// @dev Mint `cstShares` of each leg to `recipient`, funded by `recipient`'s own collateral:
    ///      quote the exact collateral via `previewMint` (phoenix does the ceil-division
    ///      decimals math), pull it from `recipient`, mint both legs back to `recipient`. The
    ///      LOP's own transferFrom then moves the fresh cST. `MintAmountDrift` enforces that
    ///      the approval granted to the pool manager is consumed exactly, leaving no dangling
    ///      allowance and no stranded CA.
    function _jitMint(MarketId poolId, address collateralAsset, address recipient, uint256 cstShares) internal {
        uint256 collateralIn = POOL_MANAGER.previewMint(poolId, cstShares);
        if (collateralIn == 0) revert MintUnavailable();

        IERC20(collateralAsset).safeTransferFrom(recipient, address(this), collateralIn);
        IERC20(collateralAsset).forceApprove(address(POOL_MANAGER), collateralIn);
        uint256 spent = POOL_MANAGER.mint(poolId, cstShares, recipient);
        if (spent != collateralIn) revert MintAmountDrift();

        emit JITMinted(poolId, recipient, cstShares, collateralIn);
    }

    /// @dev Execute every carried permit (see {PermitParams}) now that any JIT-created token
    ///      exists: `_ensureMarket` above deployed the share tokens if this fill created the
    ///      pool. Runs on every path, mint or no mint — a fill that only created the pool still
    ///      leaves the party served holding a cST the LOP has no allowance over, and the permit
    ///      is the only way to grant it. A permit that fails to execute reverts the whole fill.
    function _applyPermits(address owner, PermitParams[] memory permits) internal {
        for (uint256 i = 0; i < permits.length; i++) {
            PermitParams memory p = permits[i];
            IERC20Permit(p.token).permit(owner, LIMIT_ORDER_PROTOCOL, p.value, p.deadline, p.v, p.r, p.s);
        }
    }

    // ─────────────────────────────── JIT market creation ────────────────────

    function _ensureMarket(JITMarketParams memory params) internal returns (MarketId poolId) {
        _checkFees(params);

        address oracle = _resolveOracle(params);

        // Field order is load-bearing for the id hash.
        Market memory market = Market({
            collateralAsset: params.collateralAsset,
            referenceAsset: params.referenceAsset,
            expiryTimestamp: params.expiryTimestamp,
            rateMin: params.constraint.rateMin,
            rateMax: params.constraint.rateMax,
            rateChangePerDayMax: params.constraint.rateChangePerDayMax,
            rateChangeCapacityMax: params.constraint.rateChangeCapacityMax,
            rateOracle: oracle
        });
        poolId = POOL_MANAGER.getId(market);

        if (!_poolExists(poolId)) {
            // The bound is INCLUSIVE: an order that asks for exactly the maximum market life is
            // asking for something the curator allows, and rounding it down would make the
            // longest permitted market unsignable.
            uint256 maxExpiry = block.timestamp + MARKET_REGISTRY.maxExpiryDuration();
            if (params.expiryTimestamp > maxExpiry) revert ExpiryOutOfRange(params.expiryTimestamp, maxExpiry);

            uint256 rate = IRateOracle(oracle).rate();
            if (rate == 0) revert RateUnavailable();

            // NAMED fields: PoolCreationParams puts the unwind fee BEFORE the swap fee.
            CONTROLLER.createNewPool(
                IDefaultCorkController.PoolCreationParams({
                    pool: market,
                    unwindSwapFeePercentage: params.unwindSwapFeePercentage,
                    swapFeePercentage: params.swapFeePercentage,
                    isWhitelistEnabled: false
                })
            );
            emit JITMarketCreated(
                poolId, oracle, params.collateralAsset, params.referenceAsset, params.expiryTimestamp, params.recipe
            );
        }
    }

    function _checkFees(JITMarketParams memory params) private pure {
        if (params.swapFeePercentage > MAX_FEE_PERCENTAGE) {
            revert SwapFeeOutOfRange(params.swapFeePercentage, MAX_FEE_PERCENTAGE);
        }
        if (params.unwindSwapFeePercentage > MAX_FEE_PERCENTAGE) {
            revert UnwindSwapFeeOutOfRange(params.unwindSwapFeePercentage, MAX_FEE_PERCENTAGE);
        }
    }

    // ─────────────────────────────── The four-step recipe sequence ──────────────
    function _resolveOracle(JITMarketParams memory params) internal returns (address oracle) {
        address recipe = params.recipe;

        // Step 1 — membership. FIRST, before `source()` is read. `addRecipes` refuses `address(0)`, so
        // an order that names no recipe at all fails here too: there is no unverified path.
        if (!MARKET_REGISTRY.isRecipe(recipe)) revert IMarketRegistry.RecipeNotRegistered(recipe);

        // Step 2 — which kind of rate this recipe works against. Recipes are Cork-approved
        // contracts (step 1 just proved it), so a plain typed call is enough here.
        RecipeSource src = IMarketRecipe(recipe).source();

        // Step 3 — produce the oracle. Every path now yields a real, non-zero one.
        //
        // A FIXED recipe has no feed to wrap, so the order names the rate itself and the registry
        // deploys the `FixedRateOracle` for it. That call is idempotent — the oracle's address is
        // CREATE2-derived from the rate, so a repeat fill at the same rate pays a lookup — and a zero
        // `rateOverride` reverts `IRateOracle.InvalidRate` out of the oracle's constructor.
        if (src == RecipeSource.FIXED) {
            oracle = MARKET_REGISTRY.deployFixedRateOracle(params.rateOverride);
        } else {
            if (params.rateOverride != 0) revert UnexpectedRateOverride(recipe);
            oracle = MARKET_REGISTRY.deploy(
                params.collateralAsset,
                params.referenceAsset,
                src == RecipeSource.NAV ? IMarketRegistry.OracleMode.NAV : IMarketRegistry.OracleMode.PRICE
            );
        }

        _verifyConstraint(recipe, oracle, params);
    }

    /// @param recipe The order-supplied recipe address, already proven registered by step 1.
    /// @param rateOracle The rate oracle step 3 resolved for this market — the pair's feed wrapper, or
    ///        the `FixedRateOracle` for the order's `rateOverride`. Never zero on either path.
    /// @param params The decoded market instruction the order carries.
    function _verifyConstraint(address recipe, address rateOracle, JITMarketParams memory params) internal view {
        bool accepted = IMarketRecipe(recipe)
            .verify(params.collateralAsset, params.referenceAsset, rateOracle, params.constraint, params.additionalData);
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
        return "0.3.1";
    }
}
