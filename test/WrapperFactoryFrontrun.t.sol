// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, Vm} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@morpho-oracle/interfaces/IERC4626.sol";
import {WrapperRateConsumer} from "@phoenix/periphery/WrapperRateConsumer.sol";

import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {WrapperRateConsumerFactory} from "../src/WrapperRateConsumerFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IWrapperRateConsumerFactory} from "../src/interfaces/IWrapperRateConsumerFactory.sol";
import {MockMorphoFactoryCreate2} from "./mocks/MockMorphoFactoryCreate2.sol";
import {RegistryFixture, mkPriceOnlyAsset} from "./helpers/RegistryFixture.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title WrapperFactoryFrontrunTest
/// @notice Regression suite for pre-audit finding 1: a CREATE2 front-run must not brick
///         `MarketRegistry.deploy` for a pair, ever.
///
///         The attack: `createWrapperRateConsumer` is public and both of its deployments are CREATE2,
///         so anyone who mirrors the arguments the registry would pass can spend the pair's salts
///         FIRST — either through this factory (byte-identical pair) or straight at the Morpho
///         factory (just the oracle). Before the fix, the registry's later `deploy` replayed the
///         spent salt and reverted on the CREATE2 collision, permanently.
///
///         The fix under test: the factory is idempotent for byte-identical arguments — it returns
///         the recorded pair instead of colliding.
///
///         Unlike the rest of the deploy suite, this one wires the REAL `WrapperRateConsumerFactory`
///         into a real `MarketRegistry` — the collision only exists with real CREATE2 underneath —
///         with a mock Morpho factory that preserves genuine CREATE2 semantics.
contract WrapperFactoryFrontrunTest is RegistryFixture {
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    MockMorphoFactoryCreate2 internal morphoFactory;
    WrapperRateConsumerFactory internal realFactory;

    address internal ca; // 6 decimals, "USD"
    address internal ref; // 18 decimals, "USD"

    function setUp() public {
        // The real factory over the CREATE2-faithful Morpho mock, wired into a real registry.
        morphoFactory = new MockMorphoFactoryCreate2();
        realFactory = new WrapperRateConsumerFactory();
        realFactory.initialize(address(morphoFactory));
        fixedRateOracleFactory = new FixedRateOracleFactory();
        reg = new MarketRegistry();
        reg.initialize(address(this), address(realFactory), address(fixedRateOracleFactory));
        iReg = IMarketRegistry(address(reg));

        // Two price-only "USD" assets, each its own price source — the same shape Deploy.t.sol uses,
        // so the registry wires each leg as (vault 0, sample 1, feed1 = source, feed2 = 0).
        ca = _newToken("CA", 6);
        ref = _newToken("REF", 18);
        iReg.addAssets(one(mkPriceOnlyAsset(ca, "CA", ca, "USD")));
        iReg.addAssets(one(mkPriceOnlyAsset(ref, "REF", ref, "USD")));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    /// @dev The salt the registry derives for the setUp pair in PRICE mode: both legs' resolved
    ///      sources are the tokens themselves.
    function _registrySalt() internal view returns (bytes32) {
        return keccak256(abi.encode(address(reg), ca, ref, ca, ref));
    }

    /// @dev Mirror the exact factory call the registry would make for the setUp pair: REF is the
    ///      base leg, CA the quote leg, both salts equal to the registry's key. This is precisely
    ///      the attacker's front-run payload from the finding.
    function _mirrorRegistryCall() internal returns (address wrapper, address oracle) {
        bytes32 salt = _registrySalt();
        return realFactory.createWrapperRateConsumer(
            IERC4626(address(0)),
            1,
            AggregatorV3Interface(ref),
            AggregatorV3Interface(address(0)),
            18,
            IERC4626(address(0)),
            1,
            AggregatorV3Interface(ca),
            AggregatorV3Interface(address(0)),
            6,
            salt,
            salt
        );
    }

    function _sawCreateWrapper(Vm.Log[] memory logs) internal view returns (bool saw) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(realFactory)) continue;
            if (logs[i].topics[0] == IWrapperRateConsumerFactory.CreateWrapperRateConsumer.selector) saw = true;
        }
    }

    // ── Test A: the finding's exact attack — byte-identical pair pre-deployed ────

    /// @notice The attacker mirrors the registry's arguments and calls the factory FIRST. The
    ///         registry's later `deploy` must adopt the pre-deployed wrapper instead of reverting.
    /// @dev On the unfixed factory this test reverts inside `deploy`: the attacker's call spent both
    ///      CREATE2 salts, so the registry's replay collided at the Morpho factory with empty return
    ///      data. Verified by running this test against the pre-fix factory (it fails there).
    function test_frontrunFullPair_deployAdoptsPreDeployedWrapper() public {
        vm.prank(attacker);
        (address attackerWrapper, address attackerOracle) = _mirrorRegistryCall();

        // The victim's deploy must now succeed, land on the attacker-pre-deployed wrapper, and
        // record + announce it like any fresh deploy.
        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.MarketOracleDeployed(
            ca, ref, attackerWrapper, IMarketRegistry.OracleMode.PRICE, ca, ref, alice
        );
        vm.prank(alice);
        address w = iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE);

        assertEq(w, attackerWrapper, "deploy must return the pre-deployed wrapper, not revert");
        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            attackerWrapper,
            "the adopted wrapper must be recorded for the pair"
        );
        assertEq(
            address(WrapperRateConsumer(w).MORPHO_ORACLE()),
            attackerOracle,
            "the adopted wrapper still wraps the canonical oracle"
        );
    }

    // ── Test B: factory idempotency for byte-identical arguments ─────────────────

    /// @notice A byte-identical repeat call returns the SAME (wrapper, oracle) pair, deploys
    ///         nothing, and emits nothing.
    function test_repeatIdenticalArgs_returnsSamePairNoEvent() public {
        (address wrapper1, address oracle1) = _mirrorRegistryCall();

        vm.recordLogs();
        (address wrapper2, address oracle2) = _mirrorRegistryCall();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wrapper2, wrapper1, "repeat must return the identical wrapper");
        assertEq(oracle2, oracle1, "repeat must return the identical oracle");
        assertFalse(_sawCreateWrapper(logs), "a repeat is a read, so it must emit no CreateWrapperRateConsumer");
    }
}
