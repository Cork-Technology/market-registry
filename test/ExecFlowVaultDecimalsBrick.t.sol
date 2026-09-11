// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@morpho-oracle/interfaces/IERC4626.sol";

import {WrapperRateConsumerFactory} from "../src/WrapperRateConsumerFactory.sol";
import {IWrapperRateConsumerFactory} from "../src/interfaces/IWrapperRateConsumerFactory.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {MockMorphoFactoryCreate2, MockMorphoOracle} from "./mocks/MockMorphoFactoryCreate2.sol";
import {MockERC20} from "./mocks/HostileAssets.sol";

/// @notice ERC-4626-shaped vault with the two reads the factory and wrapper perform: the underlying
///         `asset()` and the SHARE `decimals()`.
contract MockVault {
    address public immutable asset;
    uint8 public immutable decimals;

    constructor(address asset_, uint8 shareDecimals) {
        asset = asset_;
        decimals = shareDecimals;
    }
}

/// @title ExecFlowVaultDecimalsBrickTest
/// @notice Regression suite: for a vault-backed leg the factory ignores the caller's
///         token decimals and reads the vault, so before the fix two calls that differed only in that
///         ignored value built the SAME oracle and wrapper under DIFFERENT idempotency keys. An
///         attacker used the wrong value first; the honest call then missed the cache, replayed the
///         spent CREATE2 salt at the Morpho factory, and reverted with empty returndata — burning all
///         forwarded gas — forever.
///
///         The fix under test: the idempotency key hashes the DERIVED vault-side decimals, so the key
///         is exactly as fine as the identity it protects.
contract ExecFlowVaultDecimalsBrickTest is Test {
    address internal attacker = makeAddr("attacker");
    address internal honest = makeAddr("honest");

    MockMorphoFactoryCreate2 internal morphoFactory;
    WrapperRateConsumerFactory internal factory;

    address internal feed = makeAddr("feed");
    bytes32 internal constant SALT = keccak256("pair salt");

    uint8 internal constant TRUE_UNDERLYING = 6;
    uint8 internal constant SHARE = 18;
    uint256 internal constant WRONG = 7;

    function setUp() public {
        morphoFactory = new MockMorphoFactoryCreate2();
        factory = new WrapperRateConsumerFactory();
        factory.initialize(address(morphoFactory));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _newVault(uint8 underlyingDecimals, uint8 shareDecimals) internal returns (IERC4626) {
        address underlying = address(new MockERC20("U", "U", underlyingDecimals));
        return IERC4626(address(new MockVault(underlying, shareDecimals)));
    }

    function _call(IERC4626 baseVault, uint256 baseDecimals, IERC4626 quoteVault, uint256 quoteDecimals)
        internal
        returns (address wrapper, address oracle)
    {
        return factory.createWrapperRateConsumer(
            baseVault,
            address(baseVault) == address(0) ? 1 : 10 ** uint256(SHARE),
            AggregatorV3Interface(feed),
            AggregatorV3Interface(address(0)),
            baseDecimals,
            quoteVault,
            address(quoteVault) == address(0) ? 1 : 10 ** uint256(SHARE),
            AggregatorV3Interface(feed),
            AggregatorV3Interface(address(0)),
            quoteDecimals,
            SALT,
            SALT
        );
    }

    /// @dev The address the Morpho factory assigns for the arguments `_call` passes with EXACTLY these decimals,
    ///      computed here from first principles so it does not depend on the factory's own view.
    function _canonicalOracle(IERC4626 baseVault, uint256 baseDecimals, IERC4626 quoteVault, uint256 quoteDecimals)
        internal
        view
        returns (address)
    {
        bytes memory args = abi.encode(
            baseVault,
            address(baseVault) == address(0) ? 1 : 10 ** uint256(SHARE),
            AggregatorV3Interface(feed),
            AggregatorV3Interface(address(0)),
            baseDecimals,
            quoteVault,
            address(quoteVault) == address(0) ? 1 : 10 ** uint256(SHARE),
            AggregatorV3Interface(feed),
            AggregatorV3Interface(address(0)),
            quoteDecimals
        );
        return Create2.computeAddress(
            SALT, keccak256(abi.encodePacked(type(MockMorphoOracle).creationCode, args)), address(morphoFactory)
        );
    }

    /// @dev The factory's idempotency key for the arguments `_call` passes, with the decimals given here.
    function _paramsHash(IERC4626 baseVault, uint256 baseDecimals, IERC4626 quoteVault, uint256 quoteDecimals)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                baseVault,
                address(baseVault) == address(0) ? 1 : 10 ** uint256(SHARE),
                AggregatorV3Interface(feed),
                AggregatorV3Interface(address(0)),
                baseDecimals,
                quoteVault,
                address(quoteVault) == address(0) ? 1 : 10 ** uint256(SHARE),
                AggregatorV3Interface(feed),
                AggregatorV3Interface(address(0)),
                quoteDecimals,
                SALT,
                SALT
            )
        );
    }

    function _assertRecordedUnderDerivedKey(
        IERC4626 baseVault,
        uint256 derivedBaseDecimals,
        uint256 quoteDecimals,
        address wrapper,
        string memory label
    ) internal view {
        assertEq(
            factory.wrapperByParams(_paramsHash(baseVault, derivedBaseDecimals, IERC4626(address(0)), quoteDecimals)),
            wrapper,
            label
        );
    }

    function _sawCreateWrapper(Vm.Log[] memory logs) internal view returns (bool saw) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory)) continue;
            if (logs[i].topics[0] == IWrapperRateConsumerFactory.CreateWrapperRateConsumer.selector) saw = true;
        }
    }

    /// @dev The attack and the recovery for one leg layout. `baseIsVault` / `quoteIsVault` select
    ///      which legs are vault-backed; the attacker corrupts the ignored decimals of every vault leg.
    function _attackThenHonest(bool baseIsVault, bool quoteIsVault) internal {
        IERC4626 baseVault = baseIsVault ? _newVault(TRUE_UNDERLYING, SHARE) : IERC4626(address(0));
        IERC4626 quoteVault = quoteIsVault ? _newVault(TRUE_UNDERLYING, SHARE) : IERC4626(address(0));
        uint256 attackerBase = baseIsVault ? WRONG : TRUE_UNDERLYING;
        uint256 attackerQuote = quoteIsVault ? WRONG : TRUE_UNDERLYING;

        vm.prank(attacker);
        (address attackerWrapper, address attackerOracle) = _call(baseVault, attackerBase, quoteVault, attackerQuote);

        // Before the fix: reverts here with empty returndata (CREATE2 collision at the Morpho factory).
        vm.recordLogs();
        vm.prank(honest);
        (address wrapper, address oracle) = _call(baseVault, TRUE_UNDERLYING, quoteVault, TRUE_UNDERLYING);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wrapper, attackerWrapper, "the honest call must get the already-built wrapper");
        assertEq(oracle, attackerOracle, "the honest call must get the already-built oracle");
        assertFalse(_sawCreateWrapper(logs), "the honest call is a cache hit, so it emits no creation event");

        bytes32 derivedHash = _paramsHash(baseVault, TRUE_UNDERLYING, quoteVault, TRUE_UNDERLYING);
        bytes32 wrongHash = _paramsHash(baseVault, attackerBase, quoteVault, attackerQuote);
        assertEq(factory.wrapperByParams(derivedHash), wrapper, "the record lives under the derived-decimals hash");
        assertEq(factory.wrapperByParams(wrongHash), address(0), "nothing is recorded under the wrong-decimals hash");
    }

    // ── the attack, per leg layout ──────────────────────────────────────────────

    /// @notice Vault base leg, plain quote leg. Fails at `main` with an empty revert.
    function test_wrongIgnoredBaseDecimals_thenHonestCallAdoptsWithoutEvent() public {
        _attackThenHonest(true, false);
    }

    /// @notice Plain base leg, vault quote leg. Fails at `main` with an empty revert.
    function test_wrongIgnoredQuoteDecimals_thenHonestCallAdoptsWithoutEvent() public {
        _attackThenHonest(false, true);
    }

    /// @notice Both legs vault-backed, both ignored values corrupted. Fails at `main` with an empty revert.
    function test_wrongIgnoredDecimalsBothLegs_thenHonestCallAdoptsWithoutEvent() public {
        _attackThenHonest(true, true);
    }

    // ── canonical address: the wrong value never names the oracle ───────────────

    /// @notice A caller who passes a wrong value on a vault leg still lands on the canonical oracle:
    ///         the address the Morpho factory assigns for the DERIVED underlying decimals. The address the
    ///         wrong value would name, if the factory used it, stays empty.
    function test_wrongIgnoredBaseDecimals_oracleLandsOnCanonicalAddress() public {
        IERC4626 baseVault = _newVault(TRUE_UNDERLYING, SHARE);
        address canonical = _canonicalOracle(baseVault, TRUE_UNDERLYING, IERC4626(address(0)), TRUE_UNDERLYING);
        address ifWrongWereUsed = _canonicalOracle(baseVault, WRONG, IERC4626(address(0)), TRUE_UNDERLYING);
        assertNotEq(canonical, ifWrongWereUsed, "the wrong value names a different oracle, so the test can tell");

        vm.prank(attacker);
        (, address oracle) = _call(baseVault, WRONG, IERC4626(address(0)), TRUE_UNDERLYING);

        assertEq(oracle, canonical, "the factory builds the oracle for the derived decimals");
        assertEq(ifWrongWereUsed.code.length, 0, "and nothing is built where the wrong value would point");
    }

    // ── every spelling of a vault-side decimals value lands on one pair ──────────

    /// @notice For a pair with a vault on both legs, the caller's vault-side decimals never matter:
    ///         share decimals (what the registry passes), the true underlying value, or garbage all
    ///         return the SAME oracle and wrapper, the oracle sits at the first-principles canonical
    ///         address for the derived decimals, and only the first call builds anything.
    function test_vaultPair_anyIgnoredDecimals_returnSameOracleAndWrapper() public {
        uint8 quoteUnderlying = 8;
        IERC4626 baseVault = _newVault(TRUE_UNDERLYING, SHARE);
        IERC4626 quoteVault = _newVault(quoteUnderlying, SHARE);
        address canonical = _canonicalOracle(baseVault, TRUE_UNDERLYING, quoteVault, quoteUnderlying);
        assertEq(canonical.code.length, 0, "nothing there before the build");

        (address wShare, address oShare) = _call(baseVault, SHARE, quoteVault, SHARE);
        assertEq(oShare, canonical, "share decimals (what the registry passes) build the canonical oracle");

        vm.recordLogs();
        (address wTrue, address oTrue) = _call(baseVault, TRUE_UNDERLYING, quoteVault, quoteUnderlying);
        (address wGarbage, address oGarbage) = _call(baseVault, WRONG, quoteVault, type(uint256).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(oTrue, oShare, "the true underlying value returns the same oracle");
        assertEq(wTrue, wShare, "and the same wrapper");
        assertEq(oGarbage, oShare, "garbage vault-side decimals return the same oracle");
        assertEq(wGarbage, wShare, "and the same wrapper");
        assertFalse(_sawCreateWrapper(logs), "the repeats are cache hits, so they emit no creation event");
    }

    // ── control: a genuinely different argument still builds a different pair ────

    /// @notice A no-vault side's decimals are NOT ignored, so changing them must still yield a
    ///         distinct oracle and wrapper (different CREATE2 identity, different key), not a cache hit.
    function test_control_differentNoVaultDecimals_buildDistinctPairs() public {
        IERC4626 baseVault = _newVault(TRUE_UNDERLYING, SHARE);
        (address w1, address o1) = _call(baseVault, WRONG, IERC4626(address(0)), 6);
        (address w2, address o2) = _call(baseVault, TRUE_UNDERLYING, IERC4626(address(0)), 8);
        assertNotEq(o1, o2, "different quote decimals build different oracles");
        assertNotEq(w1, w2, "and therefore different wrappers");
    }

    // ── fuzz: the key is exactly as fine as the identity ───────────────────────

    /// @notice Two calls share the (wrapper, oracle) pair exactly when their DERIVED Morpho arguments
    ///         are equal: the vault-side caller decimals never matter, the no-vault decimals always do.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_pairSharedIffDerivedArgsEqual(
        uint8 underlyingDecimals,
        uint8 shareDecimals,
        uint256 callerBaseA,
        uint256 callerBaseB,
        uint8 quoteA,
        uint8 quoteB
    ) public {
        underlyingDecimals = uint8(bound(underlyingDecimals, 0, 36));
        quoteA = uint8(bound(quoteA, 0, 36));
        quoteB = uint8(bound(quoteB, 0, 36));
        // The mock oracle prices at a constant 1e36, and the wrapper refuses a zero rate, so the quote
        // side may exceed the base SHARE decimals by at most 18. A mock limit, not a factory one.
        uint8 maxQuote = quoteA > quoteB ? quoteA : quoteB;
        shareDecimals = uint8(bound(shareDecimals, maxQuote > 18 ? maxQuote - 18 : 0, 36));
        IERC4626 baseVault = _newVault(underlyingDecimals, shareDecimals);

        (address wA, address oA) = _call(baseVault, callerBaseA, IERC4626(address(0)), quoteA);
        (address wB, address oB) = _call(baseVault, callerBaseB, IERC4626(address(0)), quoteB);

        bool sameDerivedArgs = quoteA == quoteB;
        assertEq(oA == oB, sameDerivedArgs, "oracles shared iff derived args equal");
        assertEq(wA == wB, sameDerivedArgs, "wrappers shared iff derived args equal");

        _assertRecordedUnderDerivedKey(baseVault, underlyingDecimals, quoteA, wA, "call A recorded under derived key");
        _assertRecordedUnderDerivedKey(baseVault, underlyingDecimals, quoteB, wB, "call B recorded under derived key");
    }
}
