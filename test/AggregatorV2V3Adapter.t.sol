// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AggregatorV2V3Adapter} from "../src/adapters/AggregatorV2V3Adapter.sol";
import {AggregatorV2V3AdapterFactory} from "../src/adapters/AggregatorV2V3AdapterFactory.sol";
import {IAggregatorV2V3AdapterFactory} from "../src/interfaces/IAggregatorV2V3AdapterFactory.sol";
import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";

/// @dev Minimal V2 source: a settable `latestAnswer()`, like a wrapped-aToken exposing its price.
contract MockLatestAnswerFeed {
    int256 public latestAnswer;

    constructor(int256 initial_) {
        latestAnswer = initial_;
    }

    function set(int256 value) external {
        latestAnswer = value;
    }
}

contract AggregatorV2V3AdapterTest is Test {
    AggregatorV2V3AdapterFactory internal factory;
    MockLatestAnswerFeed internal source;

    uint8 internal constant DECIMALS = 8;
    string internal constant DESCRIPTION = "waArbUSDC / USD";
    int256 internal constant INITIAL = 1_0023_0000; // 1.00230000 at 8 decimals

    /// @dev The salt is a CALLER-supplied argument now, not derived from the source, which is what lets
    ///      one source back several adapters. Every call below names one explicitly.
    bytes32 internal constant SALT = keccak256("adapter-salt-a");
    bytes32 internal constant SALT_B = keccak256("adapter-salt-b");

    function setUp() public {
        factory = new AggregatorV2V3AdapterFactory();
        source = new MockLatestAnswerFeed(INITIAL);
    }

    function _create() internal returns (AggregatorV2V3Adapter) {
        return _create(SALT);
    }

    function _create(bytes32 salt) internal returns (AggregatorV2V3Adapter) {
        return AggregatorV2V3Adapter(factory.createAdapter(address(source), DECIMALS, DESCRIPTION, salt));
    }

    function testMetadata() public {
        AggregatorV2V3Adapter adapter = _create();
        assertEq(adapter.decimals(), DECIMALS);
        assertEq(adapter.description(), DESCRIPTION);
        assertEq(adapter.version(), 4);
        assertEq(adapter.source(), address(source));
    }

    function testLatestRoundDataPassesThroughAnswer() public {
        AggregatorV2V3Adapter adapter = _create();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();
        assertEq(roundId, 0);
        assertEq(answer, INITIAL);
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);
        assertEq(answeredInRound, 0);
        assertEq(adapter.latestAnswer(), INITIAL);
    }

    function testTracksSourceUpdates() public {
        AggregatorV2V3Adapter adapter = _create();
        int256 next = 1_0100_0000; // 1.01 at 8 decimals
        source.set(next);
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, next);
        assertEq(adapter.latestAnswer(), next);
    }

    /// @notice The adapter carries no heartbeat from the source, so it must never invent one: a
    ///         fabricated `block.timestamp` would turn every downstream staleness check into a no-op.
    function testTimestampsAreAlwaysZero() public {
        AggregatorV2V3Adapter adapter = _create();
        vm.warp(1_234_567);
        (,, uint256 startedAt, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);

        (,, startedAt, updatedAt,) = adapter.getRoundData(42);
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);
    }

    function testGetRoundDataReturnsCurrentAnswer() public {
        AggregatorV2V3Adapter adapter = _create();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.getRoundData(42);
        assertEq(roundId, 42);
        assertEq(answer, INITIAL);
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);
        assertEq(answeredInRound, 42);
    }

    function testRevertOnZeroAnswer() public {
        AggregatorV2V3Adapter adapter = _create();
        source.set(0);

        vm.expectRevert(abi.encodeWithSelector(AggregatorV2V3Adapter.NonPositiveAnswer.selector, int256(0)));
        adapter.latestRoundData();

        vm.expectRevert(abi.encodeWithSelector(AggregatorV2V3Adapter.NonPositiveAnswer.selector, int256(0)));
        adapter.getRoundData(1);

        vm.expectRevert(abi.encodeWithSelector(AggregatorV2V3Adapter.NonPositiveAnswer.selector, int256(0)));
        adapter.latestAnswer();
    }

    function testRevertOnNegativeAnswer() public {
        AggregatorV2V3Adapter adapter = _create();
        source.set(-1);

        vm.expectRevert(abi.encodeWithSelector(AggregatorV2V3Adapter.NonPositiveAnswer.selector, int256(-1)));
        adapter.latestRoundData();

        vm.expectRevert(abi.encodeWithSelector(AggregatorV2V3Adapter.NonPositiveAnswer.selector, int256(-1)));
        adapter.getRoundData(1);

        vm.expectRevert(abi.encodeWithSelector(AggregatorV2V3Adapter.NonPositiveAnswer.selector, int256(-1)));
        adapter.latestAnswer();
    }

    function testFactoryPredictAndTrack() public {
        address predicted = factory.predictAdapter(address(source), DECIMALS, DESCRIPTION, SALT);
        AggregatorV2V3Adapter adapter = _create();
        assertEq(address(adapter), predicted);
        assertTrue(factory.isAdapter(address(adapter)));
        assertFalse(factory.isAdapter(address(0xBEEF)));
    }

    function testAddressIsAPureFunctionOfTheArguments() public {
        // Address must be a pure function of (factory, source, decimals, description, salt) — deploying
        // from a cold factory lands on exactly the address predicted for the same five values.
        address predicted = factory.predictAdapter(address(source), DECIMALS, DESCRIPTION, SALT);
        assertEq(address(_create()), predicted);
    }

    /// @notice Replaces the removed `adapterOf` lookup, which keyed on the source alone. The surviving
    ///         question is the same one: does the factory report anything at that address before it is
    ///         created? `predictAdapter` names the address, and it holds no code and is not an adapter
    ///         until `createAdapter` runs.
    function testPredictedAddressIsEmptyUntilCreated() public {
        address predicted = factory.predictAdapter(address(source), DECIMALS, DESCRIPTION, SALT);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isAdapter(predicted));

        assertEq(address(_create()), predicted);
        assertGt(predicted.code.length, 0);
        assertTrue(factory.isAdapter(predicted));
    }

    /// @notice The salt is new, and this is what it buys: the SAME source, decimals and description at
    ///         two different salts land on two different addresses, so one source can back several
    ///         adapters. That is precisely the restriction the removal of the `adapterOf[source]` guard
    ///         lifted.
    function testDifferentSaltsYieldDifferentAddresses() public {
        address predictedA = factory.predictAdapter(address(source), DECIMALS, DESCRIPTION, SALT);
        address predictedB = factory.predictAdapter(address(source), DECIMALS, DESCRIPTION, SALT_B);
        assertTrue(predictedA != predictedB, "the salt must separate the addresses");

        address a = address(_create(SALT));
        address b = address(_create(SALT_B));
        assertEq(a, predictedA);
        assertEq(b, predictedB);
        assertTrue(factory.isAdapter(a));
        assertTrue(factory.isAdapter(b));
        assertEq(AggregatorV2V3Adapter(a).source(), address(source), "both back the same source");
        assertEq(AggregatorV2V3Adapter(b).source(), address(source), "both back the same source");
    }

    /// @notice `decimals` and `description` stay in the init-code hash and deliberately OUT of the salt,
    ///         so the address separates on them too — the salt is not the only thing that moves it.
    function testDifferentConstructorArgsYieldDifferentAddressesAtTheSameSalt() public view {
        address base = factory.predictAdapter(address(source), DECIMALS, DESCRIPTION, SALT);
        assertTrue(base != factory.predictAdapter(address(source), DECIMALS + 1, DESCRIPTION, SALT), "decimals");
        assertTrue(base != factory.predictAdapter(address(source), DECIMALS, "other / USD", SALT), "description");
    }

    function testRevertCreateOnZeroSource() public {
        vm.expectRevert(IAggregatorV2V3AdapterFactory.ZeroAddress.selector);
        factory.createAdapter(address(0), DECIMALS, DESCRIPTION, SALT);
    }

    /// @notice Duplicate protection is now derived from the PREDICTED ADDRESS holding code, not from a
    ///         per-source mapping. So the duplicate case is "these exact five values again", and it
    ///         names the occupied address in the error.
    function testRevertCreateDuplicateArguments() public {
        address adapter = address(_create());
        vm.expectRevert(abi.encodeWithSelector(IAggregatorV2V3AdapterFactory.AdapterExists.selector, adapter));
        factory.createAdapter(address(source), DECIMALS, DESCRIPTION, SALT);
    }

    function testAdapterSatisfiesAggregatorV3() public {
        AggregatorV2V3Adapter adapter = _create();
        // Must present as the exact interface the Morpho oracle + Cork admission consume.
        AggregatorV3Interface v3 = AggregatorV3Interface(address(adapter));
        (, int256 answer,,,) = v3.latestRoundData();
        assertEq(answer, INITIAL);
        assertEq(v3.decimals(), DECIMALS);
    }
}
