// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IErrors} from "contracts/interfaces/IErrors.sol";
import {Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {CorkLimitOrderAdapter} from "../../src/CorkLimitOrderAdapter.sol";
import {Address, IOrderMixin, MakerTraits} from "../../src/interfaces/I1inchLimitOrderProtocol.sol";
import {IMarketRecipe, RecipeSource} from "../../src/interfaces/IMarketRecipe.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";

/// @dev Minimal ERC-20 for JIT tests. `noReturnData` mimics USDT-style tokens whose
///      `transferFrom`/`approve` return nothing, to exercise the hook's safe-ERC20 paths.
///      Also serves as a registerable registry asset: `MarketRegistry.deploy` re-reads live
///      `decimals()`, which this exposes.
contract MockERC20 {
    string public name;
    // Same string as `name`: phoenix's SharesFactory reads `symbol()` from both pool assets
    // when naming the share tokens, so a registry-registered asset must answer it.
    string public symbol;
    uint8 public decimals;
    bool public noReturnData;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, uint8 decimals_, bool noReturnData_) {
        name = name_;
        symbol = name_;
        decimals = decimals_;
        noReturnData = noReturnData_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @dev Test helper: set an allowance directly, bypassing `approve`'s return-data chopping
    ///      (a high-level `approve` call on a no-return token reverts at the caller's decode).
    function setAllowance(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        _handleReturn();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockERC20: balance");
        require(allowance[from][msg.sender] >= amount, "MockERC20: allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _handleReturn();
        return true;
    }

    /// @dev For `noReturnData` tokens, chop the return data like USDT does.
    function _handleReturn() internal view {
        if (noReturnData) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
    }
}

/// @dev Settable rate oracle standing in for a registry-deployed `WrapperRateConsumer`.
///      Wired in through `MockWrapperFactory.setFixedWrapper` so `MarketRegistry.deploy`
///      returns an address that actually answers `rate()`.
contract MockRateOracle {
    uint256 public rate;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }
}

/// @dev Multi-market pool manager mock for the JIT hook and the market creator, mirroring the
///      phoenix surface they touch: `getId` is the canonical struct hash over the whole ten-field
///      `Market` (fees included, so a different fee derives a different pool, like phoenix),
///      `market`/`shares`/`previewMint` REVERT for an uninitialized market (like the real
///      `CorkPoolManager`, unlike a zero-returning double), `previewMint` ceil-divides shares
///      (18 dec) into CA native decimals, and `mint` pulls the CA from `msg.sender` and mints both
///      share legs to `receiver`. Markets are registered by `createMarket` (called by
///      `MockJITController`).
///      One cPT/cST pair is deployed up front and shared by every market so tests can name the
///      cST address in orders BEFORE the market exists. `setPaused` makes `previewMint` return
///      0 (phoenix behavior when paused/expired); `setDriftBps` makes `mint` spend more than
///      `previewMint` quoted, to exercise the drift guard.
contract MockJITPoolManager {
    error MarketNotInitialized();

    MockERC20 public cpt;
    MockERC20 public cst;
    mapping(bytes32 => Market) internal _markets;
    uint256 public marketCount;

    bool public paused;
    uint256 public driftBps;

    constructor() {
        cpt = new MockERC20("cPT", 18, false);
        cst = new MockERC20("cST", 18, false);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setDriftBps(uint256 driftBps_) external {
        driftBps = driftBps_;
    }

    function createMarket(Market calldata marketParameters) external {
        _markets[keccak256(abi.encode(marketParameters))] = marketParameters;
        marketCount++;
    }

    function getId(Market calldata marketParameters) external pure returns (MarketId marketId) {
        marketId = MarketId.wrap(keccak256(abi.encode(marketParameters)));
    }

    function market(MarketId id) external view returns (Market memory parameters) {
        parameters = _markets[MarketId.unwrap(id)];
        if (parameters.collateralAsset == address(0)) revert MarketNotInitialized();
    }

    function shares(MarketId id) external view returns (address principalToken, address swapToken) {
        if (_markets[MarketId.unwrap(id)].collateralAsset == address(0)) revert MarketNotInitialized();
        principalToken = address(cpt);
        swapToken = address(cst);
    }

    function previewMint(MarketId id, uint256 cptAndCstSharesOut) public view returns (uint256 collateralAssetsIn) {
        address collateralAsset = _markets[MarketId.unwrap(id)].collateralAsset;
        if (collateralAsset == address(0)) revert MarketNotInitialized();
        if (paused) return 0;
        // fixedToTokenNativeDecimalsWithCeilDiv, like phoenix.
        uint256 scale = 10 ** MockERC20(collateralAsset).decimals();
        collateralAssetsIn = (cptAndCstSharesOut * scale + 1e18 - 1) / 1e18;
    }

    function mint(MarketId id, uint256 cptAndCstSharesOut, address receiver)
        external
        returns (uint256 collateralAssetsIn)
    {
        collateralAssetsIn = previewMint(id, cptAndCstSharesOut);
        collateralAssetsIn += (collateralAssetsIn * driftBps) / 10_000;
        address collateralAsset = _markets[MarketId.unwrap(id)].collateralAsset;
        // Low-level pull, like phoenix's SafeERC20: tolerates no-return-data collateral.
        (bool ok, bytes memory data) = collateralAsset.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", msg.sender, address(this), collateralAssetsIn
            )
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "MockJITPoolManager: pull failed");
        cpt.mint(receiver, cptAndCstSharesOut);
        cst.mint(receiver, cptAndCstSharesOut);
    }
}

/// @dev Stands in for `DefaultCorkController`: records what the creation call carried — the two
///      fees now travel INSIDE `pool`, and the suites pin that each lands in its own slot — and
///      forwards the market into the mock pool manager, like the real controller forwards into
///      the real pool manager. No role check: the real controller gates `createNewPool` behind
///      `POOL_CREATOR_ROLE`, which the creator holds; here any caller is accepted, and the suites
///      pin that the creator is the only one that calls.
contract MockJITController {
    MockJITPoolManager public poolManager;

    uint256 public createCalls;
    uint256 public lastUnwindSwapFeePercentage;
    uint256 public lastSwapFeePercentage;
    bool public lastIsWhitelistEnabled;

    constructor(MockJITPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @dev Enforces exactly phoenix's fee rule (`PoolLib.initialize`): either fee at 100% or more
    ///      is refused with the real `InvalidFees` selector, so a test that expects the revert is
    ///      checking the selector the real controller would return.
    function createNewPool(IDefaultCorkController.PoolCreationParams calldata params) external {
        require(params.pool.swapFeePercentage < 100e18, IErrors.InvalidFees());
        require(params.pool.unwindSwapFeePercentage < 100e18, IErrors.InvalidFees());
        createCalls++;
        lastUnwindSwapFeePercentage = params.pool.unwindSwapFeePercentage;
        lastSwapFeePercentage = params.pool.swapFeePercentage;
        lastIsWhitelistEnabled = params.isWhitelistEnabled;
        poolManager.createMarket(params.pool);
    }
}

/// @dev Stands in for the 1inch LOP: the only address allowed to invoke the hook callbacks.
///      Forwards constructed orders into either callback.
contract MockLimitOrderProtocol {
    function callPreInteraction(
        CorkLimitOrderAdapter hook,
        IOrderMixin.Order memory order,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes memory extraData
    ) external {
        hook.preInteraction(order, "", bytes32(0), address(0), makingAmount, takingAmount, 0, extraData);
    }

    function callTakerInteraction(
        CorkLimitOrderAdapter hook,
        IOrderMixin.Order memory order,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        bytes memory extraData
    ) external {
        hook.takerInteraction(order, "", bytes32(0), taker, makingAmount, takingAmount, 0, extraData);
    }
}

/// @dev A registered recipe that accepts every constraint, so a test can reach the creator's own
///      creation-time checks without a real recipe rejecting the payload at step 4 first. The
///      `RateUnavailable` test needs it: `LiquidityPriceRecipe.verify` reads the live rate and refuses a
///      zero one, so the creator's own guard is unreachable through a real recipe.
///      `PRICE` so the creator still deploys a wrapper at step 3.
contract PermissiveRecipe is IMarketRecipe {
    function source() external pure returns (RecipeSource) {
        return RecipeSource.PRICE;
    }

    function description() external pure returns (string memory) {
        return "accepts everything; tests only";
    }

    function resolve(address, address, address, bytes calldata)
        external
        pure
        returns (IMarketRegistry.ResolvedConstraint memory constraint)
    {
        return constraint;
    }

    function verify(
        address,
        address,
        address,
        uint256,
        bool,
        IMarketRegistry.ResolvedConstraint calldata,
        bytes calldata
    ) external pure returns (bool) {
        return true;
    }
}

/// @dev Order construction helpers shared by the JIT tests. An order names the cST address on one
///      side; the market it belongs to travels separately, nested as the creator's `MarketParams`
///      inside the hook's `JITMarketParams`.
library OrderBuilder {
    function build(address maker, address makerAsset, address takerAsset, uint256 makingAmount, uint256 takingAmount)
        internal
        pure
        returns (IOrderMixin.Order memory order)
    {
        order = IOrderMixin.Order({
            salt: 1,
            maker: Address.wrap(uint256(uint160(maker))),
            receiver: Address.wrap(0),
            makerAsset: Address.wrap(uint256(uint160(makerAsset))),
            takerAsset: Address.wrap(uint256(uint160(takerAsset))),
            makingAmount: makingAmount,
            takingAmount: takingAmount,
            makerTraits: MakerTraits.wrap(0)
        });
    }
}
