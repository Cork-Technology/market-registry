// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, Vm} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@morpho-oracle/interfaces/IERC4626.sol";
import {WrapperRateConsumer} from "@phoenix/periphery/WrapperRateConsumer.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {WrapperRateConsumerFactory} from "../src/WrapperRateConsumerFactory.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IWrapperRateConsumerFactory} from "../src/interfaces/IWrapperRateConsumerFactory.sol";
import {MockMorphoFactoryCreate2, MockMorphoOracle} from "./mocks/MockMorphoFactoryCreate2.sol";
import {RegistryFixture, mkPriceOnlyAsset} from "./helpers/RegistryFixture.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title WrapperFactoryFrontrunTest
/// @notice Regression suite: a CREATE2 front-run must not
///         brick `MarketRegistry.deploy` for a pair, ever.
///
///         The attack: `createWrapperRateConsumer` is public and both of its deployments are CREATE2,
///         so anyone who mirrors the arguments the registry would pass can spend the pair's salts
///         FIRST — either through this factory (byte-identical pair) or straight at the Morpho
///         factory (just the oracle). Before the fixes, the registry's later `deploy` replayed the
///         spent salt and reverted on the CREATE2 collision, permanently.
///
///         Two fixes under test:
///           - the factory is idempotent for canonical arguments, so a pair pre-built THROUGH the
///             factory is handed back instead of colliding (tests A and B);
///           - the registry mixes a caller-chosen `oracleSalt` into the CREATE2 salt, so a salt
///             pre-spent DIRECTLY at the Morpho factory costs the caller one failed call and a new
///             salt, never the pair (tests C to F). The cache key does not include the salt: one
///             wrapper per pair, and the salt only matters on the call that first builds it.
///
///         Unlike the rest of the deploy suite, this one wires the REAL `WrapperRateConsumerFactory`
///         into a real `MarketRegistry` — the collision only exists with real CREATE2 underneath —
///         with a mock Morpho factory that preserves genuine CREATE2 semantics.
contract WrapperFactoryFrontrunTest is RegistryFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant SALT_A = keccak256("maker salt A");
    bytes32 internal constant SALT_B = keccak256("maker salt B");

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
        iReg.addAssets(one(mkPriceOnlyAsset(ca, "CA", ca, USD_UNIT)));
        iReg.addAssets(one(mkPriceOnlyAsset(ref, "REF", ref, USD_UNIT)));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    /// @dev The wrapper key the registry derives for the setUp pair in PRICE mode, read off the
    ///      registry so the mirror below stays byte-identical to the real call whatever the key folds
    ///      in. The salt is NOT part of it.
    function _registryKey() internal view returns (bytes32) {
        return iReg.wrapperKey(ca, ref, IMarketRegistry.OracleMode.PRICE);
    }

    /// @dev The CREATE2 salt the registry hands the factory for the setUp pair and a caller's
    ///      `oracleSalt`. Everything in it is public, so an attacker can compute it too.
    function _factorySalt(bytes32 oracleSalt) internal view returns (bytes32) {
        return keccak256(abi.encode(_registryKey(), oracleSalt));
    }

    /// @dev The ten Morpho constructor arguments the registry passes for the setUp pair: REF is the
    ///      base leg, CA the quote leg.
    function _oracleArgs() internal view returns (bytes memory) {
        return abi.encode(
            IERC4626(address(0)),
            uint256(1),
            AggregatorV3Interface(ref),
            AggregatorV3Interface(address(0)),
            uint256(18),
            IERC4626(address(0)),
            uint256(1),
            AggregatorV3Interface(ca),
            AggregatorV3Interface(address(0)),
            uint256(6)
        );
    }

    /// @dev Where the Morpho factory puts the setUp pair's oracle for a caller's `oracleSalt`.
    function _oracleFor(bytes32 oracleSalt) internal view returns (address) {
        return Create2.computeAddress(
            _factorySalt(oracleSalt),
            keccak256(abi.encodePacked(type(MockMorphoOracle).creationCode, _oracleArgs())),
            address(morphoFactory)
        );
    }

    /// @dev Spend the setUp pair's oracle salt for `oracleSalt` DIRECTLY at the Morpho factory, outside
    ///      this factory — a direct Morpho oracle pre-deployment, which must not block the registry's
    ///      wrapper. The Morpho factory uses the raw salt without mixing
    ///      in `msg.sender`, so anybody can spend anybody's salt there.
    function _spendAtMorpho(bytes32 oracleSalt) internal returns (address oracle) {
        oracle = morphoFactory.createMorphoChainlinkOracleV2(
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
            _factorySalt(oracleSalt)
        );
    }

    /// @dev Mirror the exact factory call the registry would make for the setUp pair with a zero
    ///      `oracleSalt`: REF is the base leg, CA the quote leg, both salts equal to the registry's
    ///      factory salt. This is precisely the attacker's front-run payload from the finding.
    function _mirrorRegistryCall() internal returns (address wrapper, address oracle) {
        bytes32 salt = _factorySalt(bytes32(0));
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

    function _deploy(address caller, bytes32 oracleSalt) internal returns (address) {
        vm.prank(caller);
        return iReg.deploy(ca, ref, IMarketRegistry.OracleMode.PRICE, oracleSalt);
    }

    function _sawCreateWrapper(Vm.Log[] memory logs) internal view returns (bool saw) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(realFactory)) continue;
            if (logs[i].topics[0] == IWrapperRateConsumerFactory.CreateWrapperRateConsumer.selector) saw = true;
        }
    }

    function _sawDeployed(Vm.Log[] memory logs) internal view returns (bool saw) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reg)) continue;
            if (logs[i].topics[0] == IMarketRegistry.MarketOracleDeployed.selector) saw = true;
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
        address w = _deploy(alice, bytes32(0));

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

    // ── Test C: a salt pre-spent directly at the Morpho factory fails THAT call only ──

    /// @notice Direct pre-deployment, the attack half. The attacker spends the oracle salt for `SALT_A`
    ///         straight at
    ///         the Morpho factory. A `deploy` carrying `SALT_A` collides there and reverts. The revert
    ///         is the Morpho factory's own CREATE2 failure, which carries no data: the factory does not
    ///         predict or adopt at the Morpho level, so this is the documented shape of the failure.
    ///         The registry writes nothing, so the pair is not stuck — see test D.
    function test_preSpentSalt_deployWithThatSaltReverts() public {
        vm.prank(attacker);
        address squatted = _spendAtMorpho(SALT_A);
        assertEq(squatted, _oracleFor(SALT_A), "the attacker sits exactly where SALT_A would land");

        vm.expectRevert(bytes(""));
        _deploy(alice, SALT_A);

        assertEq(
            iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE),
            address(0),
            "a failed deploy records nothing, so the pair stays deployable"
        );
    }

    // ── Test D: the same maker re-signs with a fresh salt and the pair deploys ───

    /// @notice Direct pre-deployment, the recovery half. After the `SALT_A` squat, the same maker
    ///         re-signs with
    ///         `SALT_B`. That `deploy` builds the oracle where `SALT_B` lands, deploys the wrapper
    ///         around it, records it and announces it. The attacker spent gas on an oracle nobody
    ///         uses.
    function test_preSpentSalt_freshSaltDeploysAndRecords() public {
        vm.prank(attacker);
        _spendAtMorpho(SALT_A);
        vm.expectRevert(bytes(""));
        _deploy(alice, SALT_A);

        address expectedOracle = _oracleFor(SALT_B);
        assertEq(expectedOracle.code.length, 0, "SALT_B's slot is untouched by the squat");

        vm.recordLogs();
        address w = _deploy(alice, SALT_B);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_sawDeployed(logs), "the fresh salt is a real deploy and announces itself");
        assertEq(iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), w, "the wrapper is recorded");
        assertEq(address(WrapperRateConsumer(w).MORPHO_ORACLE()), expectedOracle, "the wrapper wraps the SALT_B oracle");
        assertTrue(realFactory.isWrapperRateConsumer(w), "the factory built the wrapper itself");
    }

    // ── Test E: once recorded, every salt — the squatted one included — hits the cache ──

    /// @notice The cache key does not include the salt. After the pair is recorded under `SALT_B`,
    ///         a `deploy` with `SALT_A` (still squatted at the Morpho factory), with `SALT_B` again, or
    ///         with a salt nobody has used returns the recorded wrapper, touches no factory and emits
    ///         nothing. One wrapper per pair; the salt matters only on the first build.
    function test_recordedPair_anySaltHitsCache() public {
        vm.prank(attacker);
        _spendAtMorpho(SALT_A);
        address w = _deploy(alice, SALT_B);

        bytes32[3] memory salts = [SALT_A, SALT_B, keccak256("never used")];
        for (uint256 i; i < salts.length; ++i) {
            vm.recordLogs();
            address again = _deploy(bob, salts[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(again, w, "a recorded pair returns the same wrapper whatever the salt");
            assertFalse(_sawDeployed(logs), "a cache hit announces nothing");
            assertFalse(_sawCreateWrapper(logs), "a cache hit builds nothing");
        }
        assertEq(_oracleFor(salts[2]).code.length, 0, "the unused salt's slot stays empty: nothing was built");
    }

    // ── Test F: two makers race with different salts on an empty key ─────────────

    /// @notice Alice and Bob both carry a fresh pair with different salts. Whoever lands first fixes
    ///         the wrapper; the other gets the cached one and nothing is built at their salt.
    function test_race_twoMakersDifferentSalts_firstLandsSecondGetsCached() public {
        address first = _deploy(alice, SALT_A);
        assertEq(address(WrapperRateConsumer(first).MORPHO_ORACLE()), _oracleFor(SALT_A), "alice's salt placed it");

        vm.recordLogs();
        address second = _deploy(bob, SALT_B);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(second, first, "bob gets alice's wrapper");
        assertFalse(_sawDeployed(logs), "bob's call is a cache hit and announces nothing");
        assertEq(_oracleFor(SALT_B).code.length, 0, "nothing was built where bob's salt would have landed");
        assertEq(iReg.lookupWrapper(ca, ref, IMarketRegistry.OracleMode.PRICE), first, "one wrapper per pair");
    }

    // ── Test G: a different salt lands on a different address ────────────────────

    /// @notice Control for tests C to F: the salt really changes where the pair lands, so a squat at
    ///         one salt says nothing about another. Two registries' worth of proof is in Deploy.t.sol;
    ///         here it is one registry and two salts.
    function test_control_differentSalts_differentOracleAddresses() public view {
        assertNotEq(_oracleFor(SALT_A), _oracleFor(SALT_B), "different salts, different CREATE2 addresses");
        assertNotEq(_oracleFor(bytes32(0)), _oracleFor(SALT_A), "the zero salt is just another salt");
    }
}
