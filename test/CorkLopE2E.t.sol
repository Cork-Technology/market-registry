// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// End-to-end test: real 1inch Limit Order Protocol v4 (lib/limit-order-protocol @ 4.3.2)
// driving CorkLimitOrderAdapter's JIT hooks against the REAL phoenix stack — the full
// BaseTest deployment (proxied CorkPoolManager, DefaultCorkController, SharesFactory,
// ConstraintRateAdapter, WhitelistManager) — with the REAL CorkMarketCreator in between: the
// adapter creates every pool through it, and it is the creator, not the adapter, that holds
// the controller's POOL_CREATOR_ROLE. Only the MarketRegistry's wrapper factory is mocked (it
// returns phoenix's RateOracleMock as the pair's rate-oracle wrapper).
//
// THREE REAL-WORLD PROBLEMS THIS FILE EXERCISES END TO END:
//
// 1. THE cST ADDRESS MUST BE KNOWN BEFORE IT EXISTS. The order names the cST as an order
//    side, but the token is only deployed inside the fill (JIT market creation). Phoenix's
//    SharesFactory deploys both share tokens with CREATE2 salted by the pool id, so the
//    address is a pure function of the market params. The test predicts it by SIMULATING:
//    snapshot state -> create the pool exactly as the adapter will -> record the share
//    addresses and the cST's EIP-712 domain separator -> revert state. The fill must then
//    re-create the token at the recorded address.
//
// 2. THE LOP NEEDS A cST ALLOWANCE THAT CANNOT PRE-EXIST. Allowances live in the token's
//    own storage; a not-yet-deployed token cannot have been approved. The party delivering
//    cST therefore signs an ERC-2612 permit against the PREDICTED address (nonce 0, the
//    domain separator recorded during the simulation), carried in the hook's `extraData`
//    (PermitParams[]) and executed by the adapter right after the JIT mint — one call before
//    the LOP's transferFrom needs it.
//
// 3. THE MARKET'S RATE CONSTRAINT IS SIGNED, NOT DERIVED, AND THAT IS THE CHANGE THIS FILE
//    ABSORBED. The payload used to carry a mode STRING, and the adapter derived the four rate
//    limits inside the fill from the oracle's live rate — which made the pool id, and therefore
//    the CREATE2-predicted share addresses of problem 1, move every time the rate moved. The
//    payload now carries a recipe CONTRACT ADDRESS plus the four limits as a `ResolvedConstraint`,
//    derived off-chain at signing time. On-chain the adapter only re-CHECKS them, by
//    `staticcall`ing `IMarketRecipe.verify` at step 4 of its four-step sequence. So this suite
//    deploys and approves a real {LiquidityPriceRecipe} and builds the constraint an honest order would
//    carry. That recipe's four limits are compile-time constants, so {_constraint} restates them
//    rather than re-deriving them — see that helper.
//
//    That makes problem 1's prediction ceremony STRONGER rather than merely different: its
//    soundness no longer depends on the rate holding still between setUp and the fill. And
//    since the adapter creates through the creator, the ceremony simply CALLS the creator with
//    the order's market and records what it returns — the same call the fill will make.
//
// The real OrderMixin is stack-too-deep under legacy codegen, so this file is skipped by
// [profile.default] and runs under [profile.lop] (via_ir = true):
//   FOUNDRY_PROFILE=lop forge test --match-contract CorkLopE2ETest

import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IErrors} from "contracts/interfaces/IErrors.sol";
import {IPoolManager, Market, MarketId} from "contracts/interfaces/IPoolManager.sol";
import {PoolShare} from "contracts/core/assets/PoolShare.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {BaseTest} from "@phoenix-test/forge/BaseTest.sol";
import {DummyWETH} from "@phoenix-test/forge/mocks/DummyWETH.sol";
import {CorkLimitOrderAdapter} from "../src/CorkLimitOrderAdapter.sol";
import {CorkMarketCreator} from "../src/CorkMarketCreator.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {ICorkMarketCreator} from "../src/interfaces/ICorkMarketCreator.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {LiquidityPriceRecipe} from "../src/recipes/LiquidityPriceRecipe.sol";
import {mkPriceOnlyAsset} from "./helpers/RegistryFixture.sol";
import {MockERC20} from "./mocks/JITMocks.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";

// Real 1inch LOP v4 + its value types (aliased to avoid clashing with the vendored ones).
import {LimitOrderProtocol} from "limit-order-protocol/LimitOrderProtocol.sol";
import {IOrderMixin as ILopOrderMixin} from "limit-order-protocol/interfaces/IOrderMixin.sol";
import {MakerTraits} from "limit-order-protocol/libraries/MakerTraitsLib.sol";
import {TakerTraits} from "limit-order-protocol/libraries/TakerTraitsLib.sol";
import {Address as LopAddress} from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {one} from "./helpers/ArrayHelpers.sol";

contract CorkLopE2ETest is BaseTest {
    // 1inch MakerTraits flag bits (MakerTraitsLib).
    uint256 internal constant _ALLOW_MULTIPLE_FILLS_FLAG = 1 << 254;
    uint256 internal constant _PRE_INTERACTION_CALL_FLAG = 1 << 252;
    uint256 internal constant _HAS_EXTENSION_FLAG = 1 << 249;
    // 1inch TakerTraits bits (TakerTraitsLib).
    uint256 internal constant _MAKER_AMOUNT_FLAG = 1 << 255;
    uint256 internal constant _ARGS_EXTENSION_LENGTH_OFFSET = 224;
    uint256 internal constant _ARGS_INTERACTION_LENGTH_OFFSET = 200;

    /// @dev The rate the constraint is derived from at signing time, carried in `extraData` and
    ///      re-derived from by `verify`. The oracle is set to the same value so the live rate sits
    ///      inside the derived window — `verify` no longer requires that, but
    ///      `ConstraintRateAdapter.bootstrap` still does at creation.
    uint256 internal constant ANCHOR_RATE = 1e18;

    uint256 internal constant SWAP_FEE = 3e18; // 3%, 1e18 = 1%
    uint256 internal constant UNWIND_FEE = 4e18; // 4%
    uint256 internal constant BOND_FUNDING = 50_000e6;

    // Cork coverage seller: maker in the ASK test, taker in the BID test. Signs orders AND
    // cST permits, so it needs a known private key.
    address internal bond;
    uint256 internal bondPk;
    // Counterparty maker for the BID test (signs the premium-for-cST order).
    address internal bidder;
    uint256 internal bidderPk;
    // Plain takers lifting the ASK — never sign anything. The second one exists for the
    // partial-fill test, so two different parties fill one order.
    address internal lifter;
    address internal secondLifter;
    address internal registryOwner;

    // Plain mock ERC20s (JITMocks). NOT phoenix's DummyERC20: that mock MINTS in its payable
    // fallback, so the registry's try/catch `asset()` wrapper probe (a staticcall) hits a
    // state-change-during-staticcall error, which burns ALL forwarded gas and starves setUp.
    // Real tokens don't mint on fallback; these behave like real tokens.
    MockERC20 internal usdc; // 6-decimals collateral asset (CA)
    MockERC20 internal wstEth; // 18-decimals reference asset (REF)
    MockERC20 internal premium; // 18-decimals token coverage is paid with
    MockWrapperFactory internal wrapperFactory;
    MarketRegistry internal registry;
    LiquidityPriceRecipe internal recipe;
    LimitOrderProtocol internal lop;
    CorkMarketCreator internal creator;
    CorkLimitOrderAdapter internal hook;
    uint256 internal jitExpiry;

    // Prediction ceremony output (simulate-then-revert in setUp): the pool id the fill will
    // derive and the CREATE2-deterministic share token addresses it will deploy.
    MarketId internal jitPoolId;
    address internal predictedCpt;
    address internal predictedCst;
    bytes32 internal cstDomainSeparator;

    function setUp() public override {
        super.setUp(); // full phoenix deployment + its default 18/18 market
        vm.stopPrank(); // BaseTest.setUp leaves a startPrank active

        (bond, bondPk) = makeAddrAndKey("bond");
        (bidder, bidderPk) = makeAddrAndKey("bidder");
        lifter = makeAddr("lifter");
        secondLifter = makeAddr("secondLifter");
        registryOwner = makeAddr("registryOwner");

        usdc = new MockERC20("USDC", 6, false);
        wstEth = new MockERC20("wstETH", 18, false);
        premium = new MockERC20("PRM", 18, false);

        // Registry: both pool assets registered, one real recipe CONTRACT approved, and the wrapper
        // factory fixed to phoenix's RateOracleMock — so `registry.deploy(ca, ref, mode)` records a
        // wrapper whose `rate()` the real ConstraintRateAdapter can consume. ({LiquidityPriceRecipe.verify}
        // reads the same oracle, to check the live rate is still inside the carried window.)
        //
        // The registry constructor takes THREE arguments now; the third is the fixed-rate oracle
        // factory, which it zero-checks. Nothing in this suite deploys a fixed-rate oracle — a real
        // factory is supplied because a zero one is refused.
        wrapperFactory = new MockWrapperFactory();
        wrapperFactory.setFixedWrapper(address(testOracle));
        registry = new MarketRegistry();
        registry.initialize(registryOwner, address(wrapperFactory), address(new FixedRateOracleFactory()));
        recipe = new LiquidityPriceRecipe();
        recipe.initialize(IMarketRegistry(address(registry)));
        vm.startPrank(registryOwner);
        // The US Dollar sentinel is seeded as a denomination by `initialize` and IS the walk's
        // terminus, so each source resolves in ZERO bridge hops and no conversion feed has to be
        // added before these two writes.
        address usd = MarketRegistryLib.USD_DENOMINATION;
        registry.addAssets(one(mkPriceOnlyAsset(address(usdc), "USDC", address(0xFEED01), usd)));
        registry.addAssets(one(mkPriceOnlyAsset(address(wstEth), "wstETH", address(0xFEED02), usd)));
        registry.addRecipes(one(address(recipe)));
        vm.stopPrank();

        // Real LOP v4. The WETH is never exercised by these fills (no WETH order sides,
        // msg.value == 0) but the constructor requires a live address.
        lop = new LimitOrderProtocol(IWETH(address(new DummyWETH())));
        creator = new CorkMarketCreator();
        creator.initialize(
            IPoolManager(address(corkPoolManager)),
            IDefaultCorkController(address(defaultCorkController)),
            IMarketRegistry(address(registry))
        );
        hook = new CorkLimitOrderAdapter();
        hook.initialize(address(lop), IPoolManager(address(corkPoolManager)), ICorkMarketCreator(address(creator)));
        // Pools are created through the real controller by the CREATOR, so the creator role goes
        // to it and to nothing else: the adapter must be able to fill without holding any role.
        // (Role id cached first — the getter staticcall would consume a single-call prank.)
        bytes32 poolCreatorRole = defaultCorkController.POOL_CREATOR_ROLE();
        vm.prank(bravo);
        defaultCorkController.grantRole(poolCreatorRole, address(creator));
        assertFalse(defaultCorkController.hasRole(poolCreatorRole, address(hook)), "the adapter holds no role");

        testOracle.setRate(ANCHOR_RATE); // the live REF/CA rate `verify` checks the window against
        jitExpiry = block.timestamp + 30 days;

        // Funding + PRE-EXISTING-TOKEN approvals only. Deliberately absent: any cST approval —
        // the token does not exist yet; that is what the carried permit is for.
        //  - bond: collateral -> adapter (the adapter pulls CA inside the JIT mint).
        usdc.mint(bond, BOND_FUNDING);
        vm.prank(bond);
        usdc.approve(address(hook), type(uint256).max);
        //  - lifter (ASK taker): premium -> LOP (pulled after takerInteraction).
        premium.mint(lifter, 1_000_000e18);
        vm.prank(lifter);
        premium.approve(address(lop), type(uint256).max);
        premium.mint(secondLifter, 1_000_000e18);
        vm.prank(secondLifter);
        premium.approve(address(lop), type(uint256).max);
        //  - bidder (BID maker): premium -> LOP.
        premium.mint(bidder, 1_000_000e18);
        vm.prank(bidder);
        premium.approve(address(lop), type(uint256).max);

        _predictJitPool();
    }

    // ── Prediction ceremony: simulate the pool creation, record, revert ─────

    /// @dev The constraint an honest order carries, written out as literals. Its predecessor called
    ///      `MarketRegistryLib.applyBands` with the four percentages this file supplied to the
    ///      recipe's constructor. Those percentages are {LiquidityPriceRecipe}'s own constants now, so a
    ///      re-derivation would silently follow any change to them; restating them independently
    ///      fails instead, which is what a test is for.
    function _constraint() internal pure returns (IMarketRegistry.ResolvedConstraint memory c) {
        c.rateMin = 1; // one wei, flat, at every anchor
        c.rateMax = 2 * ANCHOR_RATE; // 100% above the anchor
        c.rateChangePerDayMax = ANCHOR_RATE; // 100% of the anchor per day
        c.rateChangeCapacityMax = 3 * ANCHOR_RATE; // 300% accumulated
    }

    /// @dev The market the adapter will assemble inside the fill: the constraint STRAIGHT OUT OF THE
    ///      PAYLOAD (no longer derived from the live rate), oracle = the fixed wrapper the registry
    ///      deploys/records, and the two fees the order carries, because phoenix hashes them into the
    ///      pool id. Because nothing here reads the rate, the pool id this ceremony predicts is stable
    ///      however far the rate moves between now and the fill. The fees MUST match the payload's:
    ///      a ceremony that predicted with other fees would predict another pool, and the share
    ///      addresses the permits are signed against would be wrong.
    function _derivedMarket() internal view returns (Market memory m) {
        IMarketRegistry.ResolvedConstraint memory c = _constraint();
        m = Market({
            collateralAsset: address(usdc),
            referenceAsset: address(wstEth),
            expiryTimestamp: jitExpiry,
            rateMin: c.rateMin,
            rateMax: c.rateMax,
            rateChangePerDayMax: c.rateChangePerDayMax,
            rateChangeCapacityMax: c.rateChangeCapacityMax,
            rateOracle: address(testOracle),
            swapFeePercentage: SWAP_FEE,
            unwindSwapFeePercentage: UNWIND_FEE
        });
    }

    /// @dev Deploy-first-then-reset: run the EXACT pool creation the adapter will perform
    ///      inside the fill — a `createNewPool` on the creator with the order's market — record
    ///      what the order/permit signatures must commit to, then roll the state back. Sound
    ///      because SharesFactory deploys the share tokens with CREATE2 (salt = pool id,
    ///      constructor args derived from the market params), so the replayed creation inside
    ///      the real fill lands on the same addresses regardless of any nonce drift between now
    ///      and then. The pool id the creator returns is checked against {_derivedMarket}, an
    ///      independent restatement of the market, so the ceremony cannot quietly follow a
    ///      creator that derived the wrong pool.
    function _predictJitPool() internal {
        jitPoolId = corkPoolManager.getId(_derivedMarket());

        uint256 snapshot = vm.snapshotState();
        (MarketId createdId, address cst, address cpt) = creator.createNewPool(_marketParams());
        assertEq(MarketId.unwrap(createdId), MarketId.unwrap(jitPoolId), "the creator derives the restated market");
        bytes32 domainSeparator = PoolShare(cst).DOMAIN_SEPARATOR();
        vm.revertToState(snapshot);

        // Recorded in LOCALS above and only persisted here: revertToState rolls back the
        // test contract's own storage too, so anything stored before it would be wiped.
        predictedCpt = cpt;
        predictedCst = cst;
        cstDomainSeparator = domainSeparator;

        // The rollback un-deployed the tokens: every test starts with a bare address.
        assertTrue(predictedCst != address(0), "prediction recorded");
        assertEq(predictedCst.code.length, 0, "cST must not exist before the fill");
        assertEq(predictedCpt.code.length, 0, "cPT must not exist before the fill");
    }

    // ── Hook payload helpers ────────────────────────────────────────────────

    /// @dev A single carried permit: ERC-2612 permit over the PREDICTED cST, owner -> LOP for
    ///      `value`, signed with the domain separator recorded during the simulation and
    ///      nonce 0 (the token will be freshly deployed when the adapter executes it).
    function _cstPermit(uint256 pk, address owner, uint256 value)
        internal
        view
        returns (CorkLimitOrderAdapter.PermitParams[] memory permits)
    {
        permits = new CorkLimitOrderAdapter.PermitParams[](1);
        permits[0].token = predictedCst;
        permits[0].value = value;
        permits[0].deadline = jitExpiry;
        bytes32 digest = getTypedDataHash(
            Permit({owner: owner, spender: address(lop), value: value, nonce: 0, deadline: permits[0].deadline}),
            cstDomainSeparator
        );
        (permits[0].v, permits[0].r, permits[0].s) = vm.sign(pk, digest);
    }

    /// @dev The market every order in this suite carries, as the creator's own params: what the
    ///      ceremony creates with, and what the fill nests inside `JITMarketParams`.
    function _marketParams() internal view returns (ICorkMarketCreator.MarketParams memory) {
        return ICorkMarketCreator.MarketParams({
            collateralAsset: address(usdc),
            referenceAsset: address(wstEth),
            expiryTimestamp: jitExpiry,
            recipe: address(recipe),
            rateOverride: 0, // a PRICE recipe takes its rate from the pair's wrapper, never from the order
            constraint: _constraint(),
            extraData: abi.encode(ANCHOR_RATE),
            oracleSalt: bytes32(0),
            swapFeePercentage: SWAP_FEE,
            unwindSwapFeePercentage: UNWIND_FEE
        });
    }

    function _extraData(CorkLimitOrderAdapter.PermitParams[] memory p) internal view returns (bytes memory) {
        return _extraData(p, true);
    }

    /// @dev `enableJitMint` gates the mint on the maker path only; the taker path mints
    ///      regardless, which is why the taker E2E below passes `false` and still expects shares.
    function _extraData(CorkLimitOrderAdapter.PermitParams[] memory p, bool enableJitMint)
        internal
        view
        returns (bytes memory)
    {
        return _extraData(p, enableJitMint, SWAP_FEE);
    }

    /// @dev Same payload with the swap fee chosen by the caller, for the fee-rule case below.
    function _extraData(CorkLimitOrderAdapter.PermitParams[] memory p, bool enableJitMint, uint256 swapFee)
        internal
        view
        returns (bytes memory)
    {
        ICorkMarketCreator.MarketParams memory market = _marketParams();
        market.swapFeePercentage = swapFee;
        return abi.encode(CorkLimitOrderAdapter.JITMarketParams({market: market, enableJitMint: enableJitMint}), p);
    }

    // ── 1inch v4 encoding helpers ───────────────────────────────────────────

    /// @dev Build an extension whose ONLY populated dynamic field is PreInteractionData
    ///      (field index 6 of 8): first 32 bytes are the packed uint32 END offsets of each
    ///      field inside the concatenated tail; PreInteractionData = 20-byte target ++ data.
    function _buildExtensionWithPreInteraction(address target, bytes memory data)
        internal
        pure
        returns (bytes memory extension)
    {
        bytes memory preInteractionData = abi.encodePacked(target, data);
        uint256 len = preInteractionData.length;
        // Fields 0..5 empty (end = 0), field 6 ends at len, field 7 (PostInteraction) also len.
        uint256 offsets = (len << (32 * 6)) | (len << (32 * 7));
        extension = abi.encodePacked(bytes32(offsets), preInteractionData);
    }

    /// @dev v4 salt rule: with HAS_EXTENSION, the low 160 bits of the salt MUST equal the low
    ///      160 bits of keccak256(extension). Upper 96 bits are free (kept zero here).
    function _saltFor(bytes memory extension) internal pure returns (uint256) {
        return uint256(keccak256(extension)) & type(uint160).max;
    }

    /// @dev EIP-2098 compact signature: fillOrderArgs takes (r, vs).
    function _signOrder(uint256 pk, ILopOrderMixin.Order memory order) internal view returns (bytes32 r, bytes32 vs) {
        bytes32 orderHash = lop.hashOrder(order);
        (uint8 v, bytes32 r_, bytes32 s) = vm.sign(pk, orderHash);
        r = r_;
        vs = bytes32((uint256(v - 27) << 255) | uint256(s));
    }

    function _addr(address a) internal pure returns (LopAddress) {
        return LopAddress.wrap(uint256(uint160(a)));
    }

    // ── Maker-side JIT: preInteraction via signed extension ─────────────────

    /// @dev ASK: bond (EOA) signs an order selling 20_000 cST for 1_000 PREMIUM, naming the
    ///      PREDICTED cST address as maker asset, with the adapter committed as preInteraction
    ///      target and the cST permit riding in the signed extension. When the order is filled,
    ///      NEITHER the pool NOR the cST exists — the fill creates the pool through the real
    ///      controller, mints through the real pool manager, executes the permit, and only then
    ///      does the LOP pull the fresh cST.
    function test_e2e_preInteraction_realPhoenix() public {
        uint256 cstShares = 20_000e18;
        uint256 premiumAmount = 1_000e18;

        bytes memory extension =
            _buildExtensionWithPreInteraction(address(hook), _extraData(_cstPermit(bondPk, bond, cstShares)));

        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: _saltFor(extension),
            maker: _addr(bond),
            receiver: _addr(address(0)),
            makerAsset: _addr(predictedCst),
            takerAsset: _addr(address(premium)),
            makingAmount: cstShares,
            takingAmount: premiumAmount,
            makerTraits: MakerTraits.wrap(_PRE_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG)
        });

        (bytes32 r, bytes32 vs) = _signOrder(bondPk, order);

        // Taker traits: amount is the MAKING amount; extension carried in args.
        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (extension.length << _ARGS_EXTENSION_LENGTH_OFFSET));

        assertEq(predictedCst.code.length, 0, "cST does not exist at fill time");

        vm.prank(lifter);
        (uint256 made, uint256 took,) = lop.fillOrderArgs(order, r, vs, cstShares, takerTraits, extension);

        assertEq(made, cstShares, "full making amount filled");
        assertEq(took, premiumAmount, "full taking amount paid");

        // The fill deployed the shares at the predicted addresses and registered the market
        // in the real singleton.
        assertGt(predictedCst.code.length, 0, "cST deployed inside the fill");
        Market memory created = corkPoolManager.market(jitPoolId);
        assertEq(created.collateralAsset, address(usdc), "market registered in the pool manager");
        assertEq(created.rateOracle, address(testOracle), "pool adopted the registry wrapper");

        // JIT-minted, permitted, then swept by the LOP: taker holds the cST, maker keeps the
        // cPT leg, premium and collateral moved, permit fully consumed.
        PoolShare cst = PoolShare(predictedCst);
        assertEq(cst.balanceOf(lifter), cstShares, "taker received the JIT-minted cST");
        assertEq(cst.balanceOf(bond), 0, "maker's cST fully swept by the fill");
        assertEq(PoolShare(predictedCpt).balanceOf(bond), cstShares, "maker keeps the cPT leg");
        assertEq(premium.balanceOf(bond), premiumAmount, "maker received the premium");
        assertEq(usdc.balanceOf(bond), BOND_FUNDING - 20_000e6, "maker paid the collateral");
        assertEq(cst.allowance(bond, address(lop)), 0, "permit allowance exactly consumed");
        assertEq(cst.nonces(bond), 1, "the carried permit was executed");
        _assertNoCustody();
    }

    /// @dev THE FEE RULE IS PHOENIX'S, END TO END. The same ask as above, but the order names a
    ///      100% swap fee. The adapter carries no fee rule of its own, so the fill reaches the REAL
    ///      controller, which refuses the pool with phoenix's `InvalidFees`; the revert surfaces
    ///      through the real 1inch fill unchanged, before any transfer.
    function test_e2e_feeAtOneHundredPercent_revertsWithPhoenixInvalidFees() public {
        uint256 cstShares = 20_000e18;
        uint256 premiumAmount = 1_000e18;

        bytes memory extension = _buildExtensionWithPreInteraction(
            address(hook), _extraData(new CorkLimitOrderAdapter.PermitParams[](0), true, 100e18)
        );

        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: _saltFor(extension),
            maker: _addr(bond),
            receiver: _addr(address(0)),
            makerAsset: _addr(predictedCst),
            takerAsset: _addr(address(premium)),
            makingAmount: cstShares,
            takingAmount: premiumAmount,
            makerTraits: MakerTraits.wrap(_PRE_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG)
        });

        (bytes32 r, bytes32 vs) = _signOrder(bondPk, order);
        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (extension.length << _ARGS_EXTENSION_LENGTH_OFFSET));

        vm.prank(lifter);
        vm.expectRevert(IErrors.InvalidFees.selector);
        lop.fillOrderArgs(order, r, vs, cstShares, takerTraits, extension);

        // The cST never came to exist, so the custody helper (which reads it) cannot run here;
        // the collateral leg is checked by hand instead.
        assertEq(predictedCst.code.length, 0, "no pool and no cST were created");
        assertEq(usdc.balanceOf(bond), BOND_FUNDING, "no collateral moved");
        assertEq(usdc.balanceOf(address(hook)), 0, "the adapter holds nothing");
    }

    // ── Taker-side JIT: takerInteraction via TakerTraits args ───────────────

    /// @dev BID: bidder (EOA) signs a plain no-extension order buying 7_500 cST for PREMIUM —
    ///      the taker asset is the PREDICTED cST. bond lifts it as taker, passing the adapter
    ///      + its cST permit as the taker interaction in args (no maker cooperation needed).
    ///      The adapter mints bond's delivery and executes the permit between the two
    ///      transfers.
    ///
    ///      Carries `enableJitMint: false` on purpose: the gate is maker-side only, and the
    ///      taker path must mint regardless. The cST does not exist at fill time, so if the
    ///      gate ever leaked into this path the fill could not settle at all.
    function test_e2e_takerInteraction_realPhoenix() public {
        uint256 cstShares = 7_500e18;
        uint256 premiumAmount = 400e18;

        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: 1, // no extension: salt is unconstrained
            maker: _addr(bidder),
            receiver: _addr(address(0)),
            makerAsset: _addr(address(premium)),
            takerAsset: _addr(predictedCst),
            makingAmount: premiumAmount,
            takingAmount: cstShares,
            makerTraits: MakerTraits.wrap(0)
        });

        (bytes32 r, bytes32 vs) = _signOrder(bidderPk, order);

        bytes memory interaction =
            abi.encodePacked(address(hook), _extraData(_cstPermit(bondPk, bond, cstShares), false));
        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (interaction.length << _ARGS_INTERACTION_LENGTH_OFFSET));

        assertEq(predictedCst.code.length, 0, "cST does not exist at fill time");

        vm.prank(bond);
        (uint256 made, uint256 took,) = lop.fillOrderArgs(order, r, vs, premiumAmount, takerTraits, interaction);

        assertEq(made, premiumAmount, "full premium side filled");
        assertEq(took, cstShares, "full cST side delivered");

        PoolShare cst = PoolShare(predictedCst);
        assertEq(cst.balanceOf(bidder), cstShares, "bid maker received the JIT-minted cST");
        assertEq(cst.balanceOf(bond), 0, "taker's cST fully swept by the fill");
        assertEq(PoolShare(predictedCpt).balanceOf(bond), cstShares, "taker keeps the cPT leg");
        assertEq(premium.balanceOf(bond), premiumAmount, "taker received the premium");
        assertEq(usdc.balanceOf(bond), BOND_FUNDING - 7_500e6, "taker paid the collateral");
        assertEq(cst.allowance(bond, address(lop)), 0, "permit allowance exactly consumed");
        assertEq(cst.nonces(bond), 1, "the carried permit was executed");
        _assertNoCustody();
    }

    // ── Permit griefing: a public permit signature must not brick the order ─

    /// @dev THE FRONT-RUN. A resting order's permit signature is public, so anyone can call
    ///      `cst.permit` with it directly and consume the nonce before the fill lands. The cST
    ///      must already exist for that attack to be possible at all, so this test creates the
    ///      pool first, exactly as an earlier fill would have. The griefed fill must still
    ///      complete: the front-runner granted the LOP the exact allowance the maker intended,
    ///      and the adapter skips a permit whose allowance is already in place instead of
    ///      re-executing it into a revert.
    function test_e2e_frontRunPermit_fillStillCompletes() public {
        uint256 cstShares = 20_000e18;
        uint256 premiumAmount = 1_000e18;

        // The pool (and with it the cST) exists before the fill, as after an earlier fill or a
        // direct call on the creator by anyone.
        creator.createNewPool(_marketParams());
        assertGt(predictedCst.code.length, 0, "cST exists before the fill");

        CorkLimitOrderAdapter.PermitParams[] memory permits = _cstPermit(bondPk, bond, cstShares);
        bytes memory extension = _buildExtensionWithPreInteraction(address(hook), _extraData(permits));

        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: _saltFor(extension),
            maker: _addr(bond),
            receiver: _addr(address(0)),
            makerAsset: _addr(predictedCst),
            takerAsset: _addr(address(premium)),
            makingAmount: cstShares,
            takingAmount: premiumAmount,
            makerTraits: MakerTraits.wrap(_PRE_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG)
        });
        (bytes32 r, bytes32 vs) = _signOrder(bondPk, order);

        // The attacker executes the maker's own permit signature, consuming nonce 0.
        PoolShare cst = PoolShare(predictedCst);
        vm.prank(makeAddr("attacker"));
        cst.permit(bond, address(lop), cstShares, permits[0].deadline, permits[0].v, permits[0].r, permits[0].s);
        assertEq(cst.nonces(bond), 1, "the attacker consumed the permit nonce");
        assertEq(cst.allowance(bond, address(lop)), cstShares, "and granted the intended allowance");

        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (extension.length << _ARGS_EXTENSION_LENGTH_OFFSET));
        vm.prank(lifter);
        (uint256 made, uint256 took,) = lop.fillOrderArgs(order, r, vs, cstShares, takerTraits, extension);

        assertEq(made, cstShares, "the griefed order still fills in full");
        assertEq(took, premiumAmount, "and the premium was paid");
        assertEq(cst.balanceOf(lifter), cstShares, "taker received the cST");
        assertEq(cst.allowance(bond, address(lop)), 0, "the front-run allowance was exactly consumed");
        assertEq(cst.nonces(bond), 1, "the adapter skipped the already-granted permit");
        _assertNoCustody();
    }

    /// @dev THE OTHER HALF of the defensive execution: a wrongly-signed carried permit aborts
    ///      the fill in `preInteraction`. The adapter no longer swallows permit failures — the
    ///      permit here is signed by the WRONG key, so `permit` recovers a different owner and
    ///      its revert bubbles up through the adapter, reverting the whole fill.
    function test_e2e_uselessPermit_revertsTheFill() public {
        uint256 cstShares = 20_000e18;
        uint256 premiumAmount = 1_000e18;

        CorkLimitOrderAdapter.PermitParams[] memory permits = _cstPermit(bidderPk, bond, cstShares);
        bytes memory extension = _buildExtensionWithPreInteraction(address(hook), _extraData(permits));

        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: _saltFor(extension),
            maker: _addr(bond),
            receiver: _addr(address(0)),
            makerAsset: _addr(predictedCst),
            takerAsset: _addr(address(premium)),
            makingAmount: cstShares,
            takingAmount: premiumAmount,
            makerTraits: MakerTraits.wrap(_PRE_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG)
        });
        (bytes32 r, bytes32 vs) = _signOrder(bondPk, order);

        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (extension.length << _ARGS_EXTENSION_LENGTH_OFFSET));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        vm.prank(lifter);
        lop.fillOrderArgs(order, r, vs, cstShares, takerTraits, extension);
    }

    // ── Partial fills: one finite permit must carry the order to the end ────

    /// @dev THE PARTIAL-FILL REPLAY. A maker signs ONE finite permit for the whole order and allows
    ///      multiple fills. The first, partial fill executes the permit (nonce 0 -> 1) and the LOP's
    ///      pull drops the allowance to half. The second fill must NOT replay the consumed signature:
    ///      the allowance left over covers what this fill pulls, so the adapter skips the permit and the
    ///      remaining liquidity fills without a fresh maker transaction. Before the skip was keyed to
    ///      the pull, the second fill replayed the dead permit and died with `ERC2612InvalidSigner`.
    function test_e2e_partialFills_oneFinitePermitCarriesBothFills() public {
        uint256 cstShares = 20_000e18;
        uint256 premiumAmount = 1_000e18;
        uint256 half = cstShares / 2;

        bytes memory extension =
            _buildExtensionWithPreInteraction(address(hook), _extraData(_cstPermit(bondPk, bond, cstShares)));
        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: _saltFor(extension),
            maker: _addr(bond),
            receiver: _addr(address(0)),
            makerAsset: _addr(predictedCst),
            takerAsset: _addr(address(premium)),
            makingAmount: cstShares,
            takingAmount: premiumAmount,
            makerTraits: MakerTraits.wrap(_ALLOW_MULTIPLE_FILLS_FLAG | _PRE_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG)
        });
        (bytes32 r, bytes32 vs) = _signOrder(bondPk, order);
        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (extension.length << _ARGS_EXTENSION_LENGTH_OFFSET));

        // First fill: half. The permit is executed and the pull consumes half of it.
        vm.prank(lifter);
        (uint256 made1,,) = lop.fillOrderArgs(order, r, vs, half, takerTraits, extension);
        assertEq(made1, half, "first fill took half");
        PoolShare cst = PoolShare(predictedCst);
        assertEq(cst.nonces(bond), 1, "the first fill executed the permit");
        assertEq(cst.allowance(bond, address(lop)), half, "half the permit's allowance is left");

        // Second fill, by a different taker: the rest. The dead signature must not be replayed.
        vm.prank(secondLifter);
        (uint256 made2,,) = lop.fillOrderArgs(order, r, vs, half, takerTraits, extension);
        assertEq(made2, half, "second fill took the rest");
        assertEq(cst.nonces(bond), 1, "the second fill did NOT replay the permit");
        assertEq(cst.allowance(bond, address(lop)), 0, "the one permit was exactly consumed across both fills");

        assertEq(cst.balanceOf(lifter), half, "first taker holds its half");
        assertEq(cst.balanceOf(secondLifter), half, "second taker holds the other half");
        assertEq(cst.balanceOf(bond), 0, "maker's cST fully swept");
        assertEq(premium.balanceOf(bond), premiumAmount, "maker was paid in full across both fills");
        assertEq(usdc.balanceOf(bond), BOND_FUNDING - 20_000e6, "maker paid the collateral for both mints");
        _assertNoCustody();
    }

    /// @dev THE GUARD on the skip. Keying it to the pull must not loosen it: an allowance that covers a
    ///      quarter does not cover a half-fill, so the carried permit is still executed — and this one
    ///      is signed by the wrong key, so the fill still reverts `ERC2612InvalidSigner`. A skip that
    ///      fired on any non-zero allowance would let this fill reach the LOP's pull and fail there
    ///      with a less useful error, or worse.
    function test_e2e_partialAllowanceWithWrongSignerPermit_stillReverts() public {
        uint256 cstShares = 20_000e18;
        uint256 premiumAmount = 1_000e18;

        // The cST must exist for a direct approval to be possible at all.
        creator.createNewPool(_marketParams());
        vm.prank(bond);
        PoolShare(predictedCst).approve(address(lop), cstShares / 4);

        CorkLimitOrderAdapter.PermitParams[] memory permits = _cstPermit(bidderPk, bond, cstShares);
        bytes memory extension = _buildExtensionWithPreInteraction(address(hook), _extraData(permits));
        ILopOrderMixin.Order memory order = ILopOrderMixin.Order({
            salt: _saltFor(extension),
            maker: _addr(bond),
            receiver: _addr(address(0)),
            makerAsset: _addr(predictedCst),
            takerAsset: _addr(address(premium)),
            makingAmount: cstShares,
            takingAmount: premiumAmount,
            makerTraits: MakerTraits.wrap(_ALLOW_MULTIPLE_FILLS_FLAG | _PRE_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG)
        });
        (bytes32 r, bytes32 vs) = _signOrder(bondPk, order);
        TakerTraits takerTraits =
            TakerTraits.wrap(_MAKER_AMOUNT_FLAG | (extension.length << _ARGS_EXTENSION_LENGTH_OFFSET));

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        vm.prank(lifter);
        lop.fillOrderArgs(order, r, vs, cstShares / 2, takerTraits, extension);
    }

    // ── Negative control: wrong caller cannot trigger the hook ─────────────

    function test_e2e_hookRejectsDirectCall() public {
        ILopOrderMixin.Order memory order; // zeroed
        bytes memory extraData = _extraData(_cstPermit(bondPk, bond, 1e18));
        vm.expectRevert(CorkLimitOrderAdapter.OnlyLimitOrderProtocol.selector);
        // Direct call with the REAL LOP configured: only the LOP address may call.
        (bool ok,) = address(hook)
            .call(
                abi.encodeWithSignature(
                    "preInteraction((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes,bytes32,address,uint256,uint256,uint256,bytes)",
                    order,
                    bytes(""),
                    bytes32(0),
                    address(0),
                    uint256(1e18),
                    uint256(0),
                    uint256(0),
                    extraData
                )
            );
        ok; // silence
    }

    function _assertNoCustody() internal view {
        assertEq(usdc.balanceOf(address(hook)), 0, "hook must hold no CA");
        assertEq(PoolShare(predictedCst).balanceOf(address(hook)), 0, "hook must hold no cST");
        assertEq(PoolShare(predictedCpt).balanceOf(address(hook)), 0, "hook must hold no cPT");
        assertEq(usdc.allowance(address(hook), address(corkPoolManager)), 0, "no dangling allowance");
    }
}
