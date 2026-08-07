// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {FixedRateOracle} from "../src/FixedRateOracle.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";

/// @title FixedRateOracleFactory.t.sol — the deterministic rate-keyed factory
/// @notice Covers `deploy`, `computeAddress`, the `OracleDeployed` event, the zero-rate rejection that
///         bubbles out of the oracle's constructor, and the DATA-FREE revert a repeat deployment for one
///         rate produces.
/// @dev Ported from the `cork-lop-market-creator-hackathon` repository, file
///      `test/FixedRateOracleFactory.t.sol`. The five original cases are carried over; the import paths
///      were repointed at this repository's own `IRateOracle` (that repository carried a vendored copy),
///      the event assertion was split out of `test_deploy_repeatRate_reverts` into its own case to keep
///      one fact per test the way the rest of this directory does, and the boundary-rate,
///      purity-of-`computeAddress`, per-factory-keying and agrees-with-direct-construction cases below
///      are new.
///
///      This suite does NOT extend `RegistryFixture`. The local convention is that a suite takes the
///      fixture only when it needs a live registry — `AssetEnumOffset`, `Deploy`, `HopGraph` and `Recipe`
///      do; `ConversionFeed`, `AggregatorV2V3Adapter` and `ERC4626ShareAdapter` extend `Test` directly.
///      This factory takes no constructor arguments and touches no registry state, so the fixture would
///      contribute nothing but unused setup. The registry-level wrapper over this factory
///      (`deployFixedRateOracle` / `predictFixedRateOracle`, which is idempotent precisely to hide the
///      data-free collision asserted below) is covered in `Governance.t.sol` and is not repeated here.
///
///      NO TEST BELOW ASSERTS A HARD-CODED ADDRESS, on purpose. `computeAddress` hashes
///      `type(FixedRateOracle).creationCode`, so every address it predicts depends on the compiler
///      version, the optimizer settings and the metadata hash. The predictions are self-consistent inside
///      this repository, but they do NOT match the ones the hackathon repository produced, because that
///      repository compiled against a different Ethereum Virtual Machine target. Every assertion here is
///      therefore a comparison between two values computed in the same build — a prediction against a
///      real deployment, or a prediction against another prediction — never against a literal.
///
///      Every `vm.expectRevert` carries an explicit error selector, including the empty-`bytes` form used
///      for the collision case; see `test_deploy_repeatRate_reverts`.
contract FixedRateOracleFactoryTest is Test {
    FixedRateOracleFactory internal factory;

    function setUp() public {
        factory = new FixedRateOracleFactory();
    }

    // ── prediction matches reality ──────────────────────────────────────────────

    /// @notice `computeAddress(rate)` names the address `deploy(rate)` actually lands on, and the contract
    ///         that ends up there is a working oracle for that rate.
    function test_computeAddress_matchesDeployedAddress() public {
        uint256 rate = 1.5e18;

        address predicted = factory.computeAddress(rate);
        assertEq(predicted.code.length, 0, "nothing should be deployed there yet");

        address deployed = factory.deploy(rate);

        assertEq(deployed, predicted, "computeAddress parity");
        assertGt(deployed.code.length, 0, "no code at deployed address");
        assertEq(FixedRateOracle(deployed).rate(), rate, "oracle rate mismatch");
    }

    /// @notice The parity holds for every non-zero rate, not just the tidy one above.
    function testFuzz_computeAddress_matchesDeployedAddress(uint256 rate) public {
        rate = bound(rate, 1, type(uint256).max);

        address predicted = factory.computeAddress(rate);
        address deployed = factory.deploy(rate);

        assertEq(deployed, predicted, "computeAddress parity");
        assertEq(FixedRateOracle(deployed).rate(), rate, "oracle rate mismatch");
    }

    /// @notice The parity holds at both ends of the `uint256` range.
    /// @dev The salt IS the rate (`bytes32(rate)`), so one wei and the maximum `uint256` are the two
    ///      extreme salts — an all-zeros-but-one salt and an all-ones salt. Both are also fed to the
    ///      oracle's constructor as its argument, so this doubles as the boundary case for the encoding of
    ///      the constructor argument inside the init-code hash.
    function test_computeAddress_boundaryRates_matchDeployedAddresses() public {
        uint256[2] memory rates = [uint256(1), type(uint256).max];

        for (uint256 i = 0; i < rates.length; ++i) {
            uint256 rate = rates[i];
            address predicted = factory.computeAddress(rate);
            address deployed = factory.deploy(rate);
            assertEq(deployed, predicted, "boundary rate: computeAddress parity");
            assertEq(FixedRateOracle(deployed).rate(), rate, "boundary rate: oracle rate mismatch");
        }
    }

    /// @notice `computeAddress` is a pure function of the rate: nothing else it could read moves it.
    /// @dev The four things varied here are the four things a reader might reasonably fear leak into the
    ///      address: repetition, whether the oracle already exists, the clock and block height, and the
    ///      caller. None may. The prediction surviving the deployment is the load-bearing one — the
    ///      registry's idempotency check calls `computeAddress` on an address that may ALREADY hold code
    ///      and has to get the same answer, so if the prediction moved after deployment that check would
    ///      look at the wrong slot and fall through into the data-free collision.
    function test_computeAddress_isAPureFunctionOfTheRate() public {
        uint256 rate = 3e18;

        address first = factory.computeAddress(rate);
        assertEq(factory.computeAddress(rate), first, "two reads in the same state must agree");

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);
        assertEq(factory.computeAddress(rate), first, "the clock and block height must not move it");

        vm.prank(makeAddr("stranger"));
        assertEq(factory.computeAddress(rate), first, "the caller must not move it");

        factory.deploy(rate);
        assertEq(factory.computeAddress(rate), first, "an existing deployment must not move the prediction");
    }

    /// @notice Two different rates predict two different addresses BEFORE anything is deployed.
    /// @dev The separation is a property of the prediction arithmetic, not something a deployment
    ///      establishes, so it is asserted on a cold factory.
    function test_computeAddress_distinctRates_distinctPredictions() public view {
        address a = factory.computeAddress(1e18);
        address b = factory.computeAddress(2e18);
        assertTrue(a != b, "distinct rates must predict distinct addresses");
        assertEq(a.code.length, 0, "prediction alone deploys nothing");
        assertEq(b.code.length, 0, "prediction alone deploys nothing");
    }

    /// @notice The keying is per FACTORY INSTANCE, not global: two factories predict two different
    ///         addresses for one rate, and both can deploy their own oracle for it.
    /// @dev `address(this)` is part of the `CREATE2` preimage, so "each rate exactly once" is scoped to a
    ///      factory. This matters for the registry, which holds ONE factory address as a constructor
    ///      immutable: a second factory deployment would give a second, unrelated set of addresses for the
    ///      same rates, and the registry's stored immutable is the only thing that says which set is the
    ///      real one.
    function test_computeAddress_isScopedToTheFactoryInstance() public {
        uint256 rate = 4e18;
        FixedRateOracleFactory other = new FixedRateOracleFactory();

        address mine = factory.computeAddress(rate);
        address theirs = other.computeAddress(rate);
        assertTrue(mine != theirs, "two factories must not predict the same address for one rate");

        assertEq(factory.deploy(rate), mine, "each factory deploys to its own prediction");
        assertEq(other.deploy(rate), theirs, "each factory deploys to its own prediction");
        assertEq(FixedRateOracle(mine).rate(), rate, "first factory's oracle rate");
        assertEq(FixedRateOracle(theirs).rate(), rate, "second factory's oracle rate");
    }

    // ── the event ───────────────────────────────────────────────────────────────

    /// @notice A genuine deployment emits `OracleDeployed(rate, oracle)` with both fields correct.
    /// @dev Split out of the hackathon's `test_deploy_repeatRate_reverts`, which asserted the event and
    ///      the collision in one case. Both parameters are indexed and the event carries no unindexed
    ///      data, hence `(true, true, false, true)`.
    function test_deploy_emitsOracleDeployed() public {
        uint256 rate = 2e18;
        address predicted = factory.computeAddress(rate);

        vm.expectEmit(true, true, false, true, address(factory));
        emit FixedRateOracleFactory.OracleDeployed(rate, predicted);
        address deployed = factory.deploy(rate);

        assertEq(deployed, predicted, "the emitted address must be the one deployed");
        assertGt(deployed.code.length, 0, "no code at deployed address");
    }

    // ── failure modes ───────────────────────────────────────────────────────────

    /// @notice A second `deploy` for a rate already deployed reverts, and reverts with NO ERROR DATA.
    /// @dev The failure is a `CREATE2` collision inside the `new FixedRateOracle{salt: ...}` expression:
    ///      the target address already holds code, so the creation returns the zero address and Solidity's
    ///      own check reverts — with nothing. No selector, no reason string, no data of any kind. A caller
    ///      or an off-chain simulation gets an undecodable failure.
    ///
    ///      `vm.expectRevert(bytes(""))` is the exact assertion for that, and it is exact rather than a
    ///      wildcard on this Foundry version: an empty expectation matches an empty revert and REJECTS a
    ///      revert that carries data (verified by probe, see the report for this change), and it fails
    ///      outright if the call does not revert at all. The empty-`bytes` form already has precedent in
    ///      this directory at `CorkLimitOrderAdapter.t.sol` for the same "call into a function that is not
    ///      there" shape. `test_deploy_repeatRate_revertCarriesNoData` below re-asserts the same fact
    ///      through a low-level call, which is where the emptiness is checked as data rather than trusted
    ///      to the cheatcode.
    ///
    ///      This opacity is the entire reason `MarketRegistry.deployFixedRateOracle` is idempotent instead
    ///      of forwarding blindly; see `Governance.t.sol`.
    function test_deploy_repeatRate_reverts() public {
        uint256 rate = 2e18;

        address first = factory.deploy(rate);
        assertGt(first.code.length, 0, "no code at deployed address");

        vm.expectRevert(bytes(""));
        factory.deploy(rate);
    }

    /// @notice The repeat-deployment revert carries a zero-length payload, asserted as data.
    /// @dev The cheatcode-free version of the case above, and the one that can state the emptiness
    ///      positively: a low-level call hands back the raw return data, so `ret.length == 0` IS the
    ///      assertion rather than a claim about how `vm.expectRevert` compares payloads.
    ///
    ///      The hazard with a low-level call is that `ok == false` also happens if the calldata is
    ///      malformed — a mistyped selector hits a contract with no fallback and produces an identical
    ///      empty revert, so the test would pass while proving nothing. That is why the FIRST deployment
    ///      here goes through the very same `abi.encodeCall(factory.deploy, ...)` expression and is
    ///      asserted to SUCCEED and to return the predicted address. One encoding, used twice: it works,
    ///      then the same encoding for the same rate fails. If a repeat deployment ever started
    ///      succeeding, `assertFalse(second, ...)` fails; if it started failing with a real error, the
    ///      `ret.length` assertion fails.
    function test_deploy_repeatRate_revertCarriesNoData() public {
        uint256 rate = 5e18;
        address predicted = factory.computeAddress(rate);
        bytes memory call = abi.encodeCall(factory.deploy, (rate));

        (bool firstOk, bytes memory firstRet) = address(factory).call(call);
        assertTrue(firstOk, "control: the first deploy with this exact encoding must succeed");
        assertEq(abi.decode(firstRet, (address)), predicted, "control: it must return the predicted address");

        (bool secondOk, bytes memory secondRet) = address(factory).call(call);
        assertFalse(secondOk, "repeat deploy must revert");
        assertEq(secondRet.length, 0, "the collision must carry no error data at all");
    }

    /// @notice A zero rate reverts with the real, decodable `IRateOracle.InvalidRate()` selector.
    /// @dev It bubbles up from the `FixedRateOracle` constructor; the factory has no zero-check of its
    ///      own and deliberately does not need one. Note the contrast with the case above: this failure IS
    ///      decodable, so the two failure modes of `deploy` are not interchangeable.
    function test_deploy_zeroRate_reverts() public {
        // Prediction never reverts, not even for a rate that can never be deployed.
        assertEq(factory.computeAddress(0).code.length, 0, "the zero-rate address can never hold code");

        vm.expectRevert(IRateOracle.InvalidRate.selector);
        factory.deploy(0);
    }

    // ── distinct rates, and agreement with direct construction ──────────────────

    /// @notice Two rates deployed through one factory are two separate oracles, each with its own rate.
    function test_deploy_distinctRates_distinctAddresses() public {
        address a = factory.deploy(1e18);
        address b = factory.deploy(2e18);

        assertTrue(a != b, "distinct rates must map to distinct oracles");
        assertEq(FixedRateOracle(a).rate(), 1e18, "oracle a rate");
        assertEq(FixedRateOracle(b).rate(), 2e18, "oracle b rate");
    }

    /// @notice An oracle built by the factory and one built with `new` agree on `rate()`.
    /// @dev They are two different contracts at two different addresses — the factory adds a `CREATE2`
    ///      address and an event and nothing else. This pins that the factory does not transform, scale or
    ///      reinterpret the rate on its way into the constructor, which is the only thing it could quietly
    ///      get wrong while still producing a working oracle.
    function test_factoryDeployedAndDirectlyConstructedOraclesAgreeOnRate() public {
        uint256 rate = 1.25e18;

        address viaFactory = factory.deploy(rate);
        FixedRateOracle direct = new FixedRateOracle(rate);

        assertTrue(viaFactory != address(direct), "they must be two distinct contracts");
        assertEq(FixedRateOracle(viaFactory).rate(), direct.rate(), "both routes must report the same rate");
        assertEq(direct.rate(), rate, "and it must be the rate that was asked for");
    }
}
