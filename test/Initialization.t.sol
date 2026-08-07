// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IDefaultCorkController} from "contracts/interfaces/IDefaultCorkController.sol";
import {IPoolManager} from "contracts/interfaces/IPoolManager.sol";

import {CorkLimitOrderAdapter} from "../src/CorkLimitOrderAdapter.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {WrapperRateConsumerFactory} from "../src/WrapperRateConsumerFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {FixedRateRecipe} from "../src/recipes/FixedRateRecipe.sol";
import {LiquidityNavRecipe} from "../src/recipes/LiquidityNavRecipe.sol";
import {LiquidityPriceRecipe} from "../src/recipes/LiquidityPriceRecipe.sol";
import {MockJITController, MockJITPoolManager, MockLimitOrderProtocol} from "./mocks/JITMocks.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";

/// @title Initialization suite
/// @notice Every contract that moved from constructor configuration to `initialize` gets the same two
///         assertions here: the first call lands its arguments on the public getters, and a second call
///         is refused outright. The deployment story depends on both — `AtomicDeployer` initializes in
///         the deployment transaction, and nothing may ever re-point one of these afterwards.
/// @dev The registry additionally pins the ownership handoff: the constructor's placeholder owner is
///      whoever deployed it, and `initialize` must hand ownership to the `initialOwner` ARGUMENT — the
///      deployer keeps nothing.
contract InitializationTest is Test {
    address internal owner = makeAddr("owner");

    bytes4 internal ALREADY_INITIALIZED = Initializable.InvalidInitialization.selector;

    MockWrapperFactory internal wrapperFactory;
    FixedRateOracleFactory internal fixedRateOracleFactory;

    function setUp() public {
        wrapperFactory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
    }

    function _initializedRegistry() internal returns (MarketRegistry reg) {
        reg = new MarketRegistry();
        reg.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
    }

    // ── MarketRegistry ──────────────────────────────────────────────────────────

    function test_marketRegistry_initialize_setsValues() public {
        MarketRegistry reg = _initializedRegistry();
        assertEq(reg.WRAPPER_FACTORY(), address(wrapperFactory), "wrapper factory not pinned");
        assertEq(
            reg.FIXED_RATE_ORACLE_FACTORY(), address(fixedRateOracleFactory), "fixed-rate oracle factory not pinned"
        );
    }

    function test_marketRegistry_initialize_handsOwnershipToInitialOwner() public {
        MarketRegistry reg = new MarketRegistry();
        assertEq(reg.owner(), address(this), "deployer should be the placeholder owner before initialize");
        reg.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
        assertEq(reg.owner(), owner, "initialize must hand ownership to the initialOwner argument");
    }

    function test_marketRegistry_secondInitialize_reverts() public {
        MarketRegistry reg = _initializedRegistry();
        vm.expectRevert(ALREADY_INITIALIZED);
        reg.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
    }

    // ── WrapperRateConsumerFactory ──────────────────────────────────────────────

    function test_wrapperRateConsumerFactory_initialize_setsValues() public {
        address morphoFactory = makeAddr("morphoFactory");
        WrapperRateConsumerFactory factory = new WrapperRateConsumerFactory();
        factory.initialize(morphoFactory);
        assertEq(address(factory.MORPHO_FACTORY()), morphoFactory, "morpho factory not pinned");
    }

    function test_wrapperRateConsumerFactory_secondInitialize_reverts() public {
        WrapperRateConsumerFactory factory = new WrapperRateConsumerFactory();
        factory.initialize(makeAddr("morphoFactory"));
        vm.expectRevert(ALREADY_INITIALIZED);
        factory.initialize(makeAddr("morphoFactory"));
    }

    // ── CorkLimitOrderAdapter ───────────────────────────────────────────────────

    function test_corkLimitOrderAdapter_initialize_setsValues() public {
        MarketRegistry reg = _initializedRegistry();
        MockJITPoolManager poolManager = new MockJITPoolManager();
        MockJITController controller = new MockJITController(poolManager);
        MockLimitOrderProtocol lop = new MockLimitOrderProtocol();

        CorkLimitOrderAdapter hook = new CorkLimitOrderAdapter();
        hook.initialize(
            address(lop),
            IPoolManager(address(poolManager)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(reg))
        );

        assertEq(hook.LIMIT_ORDER_PROTOCOL(), address(lop), "limit order protocol not pinned");
        assertEq(address(hook.POOL_MANAGER()), address(poolManager), "pool manager not pinned");
        assertEq(address(hook.CONTROLLER()), address(controller), "controller not pinned");
        assertEq(address(hook.MARKET_REGISTRY()), address(reg), "market registry not pinned");
    }

    function test_corkLimitOrderAdapter_secondInitialize_reverts() public {
        MarketRegistry reg = _initializedRegistry();
        MockJITPoolManager poolManager = new MockJITPoolManager();
        MockJITController controller = new MockJITController(poolManager);
        MockLimitOrderProtocol lop = new MockLimitOrderProtocol();

        CorkLimitOrderAdapter hook = new CorkLimitOrderAdapter();
        hook.initialize(
            address(lop),
            IPoolManager(address(poolManager)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(reg))
        );

        vm.expectRevert(ALREADY_INITIALIZED);
        hook.initialize(
            address(lop),
            IPoolManager(address(poolManager)),
            IDefaultCorkController(address(controller)),
            IMarketRegistry(address(reg))
        );
    }

    // ── LiquidityPriceRecipe ────────────────────────────────────────────────────

    function test_liquidityPriceRecipe_initialize_setsValues() public {
        MarketRegistry reg = _initializedRegistry();
        LiquidityPriceRecipe recipe = new LiquidityPriceRecipe();
        recipe.initialize(IMarketRegistry(address(reg)));
        assertEq(address(recipe.REGISTRY()), address(reg), "registry not pinned");
    }

    function test_liquidityPriceRecipe_secondInitialize_reverts() public {
        MarketRegistry reg = _initializedRegistry();
        LiquidityPriceRecipe recipe = new LiquidityPriceRecipe();
        recipe.initialize(IMarketRegistry(address(reg)));
        vm.expectRevert(ALREADY_INITIALIZED);
        recipe.initialize(IMarketRegistry(address(reg)));
    }

    // ── LiquidityNavRecipe ──────────────────────────────────────────────────────

    function test_liquidityNavRecipe_initialize_setsValues() public {
        MarketRegistry reg = _initializedRegistry();
        LiquidityNavRecipe recipe = new LiquidityNavRecipe();
        recipe.initialize(IMarketRegistry(address(reg)));
        assertEq(address(recipe.REGISTRY()), address(reg), "registry not pinned");
    }

    function test_liquidityNavRecipe_secondInitialize_reverts() public {
        MarketRegistry reg = _initializedRegistry();
        LiquidityNavRecipe recipe = new LiquidityNavRecipe();
        recipe.initialize(IMarketRegistry(address(reg)));
        vm.expectRevert(ALREADY_INITIALIZED);
        recipe.initialize(IMarketRegistry(address(reg)));
    }

    // ── FixedRateRecipe ─────────────────────────────────────────────────────────

    function test_fixedRateRecipe_initialize_setsValues() public {
        MarketRegistry reg = _initializedRegistry();
        FixedRateRecipe recipe = new FixedRateRecipe();
        recipe.initialize(IMarketRegistry(address(reg)));
        assertEq(address(recipe.REGISTRY()), address(reg), "registry not pinned");
    }

    function test_fixedRateRecipe_secondInitialize_reverts() public {
        MarketRegistry reg = _initializedRegistry();
        FixedRateRecipe recipe = new FixedRateRecipe();
        recipe.initialize(IMarketRegistry(address(reg)));
        vm.expectRevert(ALREADY_INITIALIZED);
        recipe.initialize(IMarketRegistry(address(reg)));
    }
}
