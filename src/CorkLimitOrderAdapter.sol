// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IPoolManager, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {
    Address,
    AddressLib,
    IOrderMixin,
    IPreInteraction,
    ITakerInteraction
} from "./interfaces/I1inchLimitOrderProtocol.sol";
import {ICorkMarketCreator} from "./interfaces/ICorkMarketCreator.sol";
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
///         JIT MARKET CREATION IS THE UNCONDITIONAL PART, AND IT IS NOT DONE HERE. Both hooks always
///         hand the market instruction carried in `extraData` to `CorkMarketCreator.createNewPool`,
///         which derives the pool, creates it if it does not exist yet, and returns the pool id and
///         the share addresses. A fill into a pool that already exists pays for the derivation and
///         moves on. This adapter holds no creation logic of its own: every check a creating fill
///         runs — approved assets, registered recipe, the carried constraint, the expiry bound, the
///         fee caps, the live rate — lives in the creator, and the creator's revert reaches the fill
///         unchanged. That is what makes the creator THE creation path rather than a copy of one:
///         the pool a fill derives is, by construction, the pool anyone can create ahead of the
///         fill by calling the creator directly. A pool created that way emits the creator's
///         `MarketCreated` with the direct caller; a pool created inside a fill emits the same
///         event with this adapter as the caller.
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
///         Hook `extraData` is produced by {encodeExtraData} and read back by {decodeExtraData}.
///         `JITMarketParams` wraps the creator's own `MarketParams` next to the fill-only mint
///         flag, so the order's market description reaches the creator exactly as the maker
///         signed it. The market is ASSEMBLED inside the fill from parts the ORDER carries, not
///         referenced by id: the rate constraint is derived OFF-CHAIN at signing time and carried
///         in the order, which is what keeps the pool id — and with it the `CREATE2`-predicted
///         share addresses every resting order is signed against — fixed however far the rate
///         moves after signing. See {ICorkMarketCreator.MarketParams} for every field and the
///         reason each exists.
///
///         `OrderNotForPool` is the order/market identity guard. The creator returns the cST of the
///         pool the payload derives to, and the order must name that token on one of its sides; an
///         order that does not is a fill into a market it was never signed for, and a revert here
///         rolls back the whole fill, including any pool created earlier in the same transaction.
/// @dev No role anywhere. Pools are created by the creator, which holds POOL_CREATOR_ROLE on the
///      controller; this adapter needs nothing granted to it. No owner, no admin functions, no
///      upgradeability, no token custody beyond the duration of the fill transaction, and no
///      storage that moves after setup — the three protocol addresses are written once by
///      `initialize` (in the deployment transaction, via `AtomicDeployer`) and have no setter, and
///      the reentrancy guard uses TRANSIENT storage (EIP-1153), so nothing here changes after
///      deployment. An adapter with an owner is an adapter whose owner can retarget the minting
///      path, which is why there is none.
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

    /// @notice The market instruction carried in hook `extraData`: the creator's market description,
    ///         passed through to `createNewPool` untouched, plus the flag that gates the maker-side
    ///         mint.
    /// @dev The market is NESTED rather than copied field by field on purpose. The creator's
    ///      `MarketParams` is the one statement of what a market is made of; carrying it whole means
    ///      a field added to the creator reaches the fill without this contract learning about it,
    ///      and a fill can never hand the creator a market that differs from the one the maker
    ///      signed. The price is one extra ABI nesting level in the order payload.
    struct JITMarketParams {
        ICorkMarketCreator.MarketParams market; // the pool to derive and, if missing, create
        bool enableJitMint; // gate the maker-side mint in `preInteraction`; IGNORED by `takerInteraction`
    }

    /// @notice ERC-2612 permit carried in `extraData` next to the market instruction and executed
    ///         by this adapter right after the JIT mint. `extraData` carries an ARRAY of these
    ///         — any number of permits over any tokens. A carried permit is executed unless the
    ///         allowance it would grant is already in place (see {_applyPermits}: for the token
    ///         the LOP pulls, "in place" means enough for THIS fill, so one finite permit carries
    ///         an order through every partial fill); one that fails to execute reverts the whole
    ///         fill. An empty array carries none.
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

    /// @notice Thrown when an `initialize` address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when a callback caller is not the 1inch LOP.
    error OnlyLimitOrderProtocol();
    /// @notice Thrown when neither order side is the cST of the pool the payload derives to — the
    ///         order and the market it carries do not describe the same thing.
    error OrderNotForPool();
    /// @notice Thrown when the pool cannot mint (paused or expired: `previewMint` returned 0).
    error MintUnavailable();
    /// @notice Thrown when `mint` spent a different collateral amount than `previewMint` quoted
    ///         within the same transaction (should be unreachable; guards the exact-allowance
    ///         and no-custody invariants).
    error MintAmountDrift();

    // ─────────────────────────────── Events ────────────────────────────────

    /// @notice Emitted after a successful just-in-time mint inside a fill.
    /// @param poolId The Cork pool the shares were minted in.
    /// @param recipient The party served (order maker or fill taker) — receives cST AND cPT.
    /// @param cstShares Shares minted of each leg (18 decimals) — equals the cST the LOP pulls.
    /// @param collateralIn Collateral pulled from `recipient` (CA native decimals).
    event JITMinted(MarketId indexed poolId, address indexed recipient, uint256 cstShares, uint256 collateralIn);

    // ─────────────────────────────── Storage ────────────────────────────────

    /// @notice The 1inch Limit Order Protocol (Aggregation Router v6) — sole authorized caller
    ///         of the interaction callbacks.
    /// @dev Set once through `initialize` rather than a constructor, so the creation code carries no
    ///      arguments and the adapter lands on the same CREATE2 address on every chain. Deployed
    ///      through `AtomicDeployer`, which initializes in the deployment transaction. The same goes
    ///      for the two addresses below.
    address public LIMIT_ORDER_PROTOCOL;
    /// @notice The Cork pool manager mints are executed against.
    IPoolManager public POOL_MANAGER;
    /// @notice The Cork market creator every fill derives — and, when needed, creates — its pool
    ///         through. It holds the controller's POOL_CREATOR_ROLE so this adapter does not have to.
    ICorkMarketCreator public MARKET_CREATOR;

    /// @notice One-time setup, called in the deployment transaction by the `AtomicDeployer`.
    function initialize(address limitOrderProtocol, IPoolManager poolManager, ICorkMarketCreator marketCreator)
        external
        initializer
    {
        if (
            limitOrderProtocol == address(0) || address(poolManager) == address(0)
                || address(marketCreator) == address(0)
        ) {
            revert ZeroAddress();
        }
        LIMIT_ORDER_PROTOCOL = limitOrderProtocol;
        POOL_MANAGER = poolManager;
        MARKET_CREATOR = marketCreator;
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
        _makerFill(order, makingAmount, takingAmount, extraData);
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
        _takerFill(order, taker, makingAmount, takingAmount, extraData);
    }

    /// @dev The maker-side fill body. Lives outside the eight-parameter hook frame so the permit pass
    ///      can be told what the LOP is about to pull: `makingAmount` of `makerAsset` from the maker.
    function _makerFill(
        IOrderMixin.Order calldata order,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes calldata extraData
    ) internal {
        address maker = order.maker.get();

        (JITMarketParams memory params, PermitParams[] memory permits) = _decodeExtraData(extraData);

        (MarketId poolId, address cst,) = MARKET_CREATOR.createNewPool(params.market);
        uint256 cstShares = _resolveCstShares(order, cst, makingAmount, takingAmount);

        if (params.enableJitMint) _jitMint(poolId, params.market.collateralAsset, maker, cstShares);

        _applyPermits(maker, permits, order.makerAsset.get(), makingAmount);
    }

    /// @dev The taker-side fill body. The LOP pulls `takingAmount` of `takerAsset` from the taker once
    ///      this returns, and that is the pull the permit pass is keyed to.
    function _takerFill(
        IOrderMixin.Order calldata order,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes calldata extraData
    ) internal {
        (JITMarketParams memory params, PermitParams[] memory permits) = _decodeExtraData(extraData);

        (MarketId poolId, address cst,) = MARKET_CREATOR.createNewPool(params.market);
        uint256 cstShares = _resolveCstShares(order, cst, makingAmount, takingAmount);

        _jitMint(poolId, params.market.collateralAsset, taker, cstShares);

        _applyPermits(taker, permits, order.takerAsset.get(), takingAmount);
    }

    // ─────────────────────────────── Payload layout ─────────────────────────

    /// @notice Encode a hook `extraData` payload from its parts.
    function encodeExtraData(JITMarketParams calldata market, PermitParams[] calldata permits)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(market, permits);
    }

    /// @notice Decode a hook `extraData` payload exactly the way the hooks do.
    /// @dev WHY IT EXISTS: off-chain callers compare `decodeExtraData(encoded)` field by field
    ///      against what they meant to sign, BEFORE signing. A payload this function reads back
    ///      correctly is a payload the fill reads the same way, because both go through
    ///      {_decodeExtraData}. Reverts on bytes that do not decode.
    function decodeExtraData(bytes calldata extraData)
        external
        pure
        returns (JITMarketParams memory market, PermitParams[] memory permits)
    {
        return _decodeExtraData(extraData);
    }

    /// @dev The ONE decode both hooks and {decodeExtraData} share. Keep it the only place the
    ///      layout is stated, or the public helper stops describing what the hooks accept.
    function _decodeExtraData(bytes calldata extraData)
        internal
        pure
        returns (JITMarketParams memory market, PermitParams[] memory permits)
    {
        (market, permits) = abi.decode(extraData, (JITMarketParams, PermitParams[]));
    }

    // ─────────────────────────────── JIT minting ────────────────────────────

    /// @dev Resolve which side of the order is the derived pool's cST, and return that side's
    ///      amount. Runs on every fill, including one whose mint is gated off: it is what ties
    ///      the signed order to the market the payload derived, and it is the guard that fires
    ///      `OrderNotForPool` when the two disagree.
    /// @param cst The swap token of the pool the creator derived from the payload.
    function _resolveCstShares(
        IOrderMixin.Order calldata order,
        address cst,
        uint256 makingAmount,
        uint256 takingAmount
    ) internal pure returns (uint256) {
        if (order.makerAsset.get() == cst) return makingAmount;
        if (order.takerAsset.get() == cst) return takingAmount;
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

    /// @dev Execute the carried permits, skipping any whose allowance is already in place. For the
    ///      token the LOP is about to pull, "in place" means the allowance covers THIS fill's pull,
    ///      not the value the permit was signed for. A permit is single-use: the first partial fill
    ///      consumes its nonce and the pull drops the allowance below the signed value, so measuring
    ///      against the signed value would replay a dead signature on every later fill and strand the
    ///      maker's remaining liquidity. Any other carried token keeps the signed-value rule.
    ///
    ///      No try/catch on purpose: a permit that fails when the allowance is short is a fill that
    ///      cannot settle, and its revert data is more useful than a generic one.
    /// @param pulledToken The token the LOP pulls from `owner` right after this hook returns.
    /// @param pulledAmount How much of it this fill pulls.
    function _applyPermits(address owner, PermitParams[] memory permits, address pulledToken, uint256 pulledAmount)
        internal
    {
        for (uint256 i = 0; i < permits.length; i++) {
            PermitParams memory p = permits[i];
            uint256 needed = p.token == pulledToken ? pulledAmount : p.value;
            if (IERC20(p.token).allowance(owner, LIMIT_ORDER_PROTOCOL) >= needed) continue;
            IERC20Permit(p.token).permit(owner, LIMIT_ORDER_PROTOCOL, p.value, p.deadline, p.v, p.r, p.s);
        }
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.4.0";
    }
}
