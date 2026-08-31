// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {FixedRateOracle} from "../src/FixedRateOracle.sol";
import {IRateOracle} from "../src/interfaces/IRateOracle.sol";

/// @title FixedRateOracle.t.sol — the fixed-rate oracle's whole surface
/// @notice Covers the constructor (including the zero-rate rejection), `rate()`, and the deliberate
///         ABSENCE of any way to change the rate after construction.
/// @dev Ported from the `cork-lop-market-creator-hackathon` repository, file
///      `test/FixedRateOracle.t.sol`. The three original cases are carried over; the import paths were
///      repointed at this repository's own `IRateOracle` (that repository carried a vendored copy), and
///      the boundary-value and no-privileged-surface cases below are new.
///
///      This suite does NOT extend `RegistryFixture`, which is the local convention for a contract that
///      has nothing to do with the registry — `ConversionFeed.t.sol` and `AggregatorV2V3Adapter.t.sol`
///      both extend `Test` directly, and only the registry-centred suites
///      (`AssetEnumOffset`, `Deploy`, `HopGraph`, `Recipe`) take the fixture. A `FixedRateOracle` needs
///      one constructor argument and no registry, no owner, no tokens and no feeds, so the fixture would
///      only add setup that every case here ignores.
///
///      The registry-level entrypoints that reach this contract (`deployFixedRateOracle` /
///      `predictFixedRateOracle`) are covered in `Governance.t.sol` and are deliberately not repeated
///      here. This suite is the contract on its own terms.
///
///      Every `vm.expectRevert` carries an explicit error selector.
contract FixedRateOracleTest is Test {
    /// @dev The rate is 1 Reference Asset quoted in Collateral Asset, scaled by 1e18. `0.8e18` means one
    ///      unit of the reference asset is worth 0.8 units of the collateral asset.
    uint256 internal constant RATE = 0.8e18;

    // ── the constructor argument round-trips ────────────────────────────────────

    /// @notice `rate()` returns exactly the value handed to the constructor.
    function test_rate_returnsConstructorRate() public {
        FixedRateOracle oracle = new FixedRateOracle(RATE);
        assertEq(oracle.rate(), RATE, "rate mismatch");
    }

    /// @notice The round-trip holds for every non-zero rate, not just the tidy one above.
    /// @dev Bounded away from zero because zero is the one rejected value, asserted separately.
    function testFuzz_rate_returnsConstructorRate(uint256 rate) public {
        rate = bound(rate, 1, type(uint256).max);
        FixedRateOracle oracle = new FixedRateOracle(rate);
        assertEq(oracle.rate(), rate, "rate mismatch");
    }

    /// @notice Both ends of the `uint256` range construct and report back unchanged.
    /// @dev One wei is the smallest legal rate — the zero-check is `== 0`, not a minimum-sensible-value
    ///      check, so a rate of 1 is accepted and must not be rounded, clamped or reinterpreted. The
    ///      maximum is here because the value is stored in a full `uint256` immutable with no arithmetic
    ///      applied to it, and this is what pins that: nothing in the constructor scales or shifts it, so
    ///      there is no width left to overflow into.
    function test_rate_boundaryRates_roundTrip() public {
        assertEq(new FixedRateOracle(1).rate(), 1, "one wei must survive construction verbatim");
        assertEq(
            new FixedRateOracle(type(uint256).max).rate(),
            type(uint256).max,
            "the maximum uint256 must survive construction verbatim"
        );
    }

    /// @notice A zero rate is refused at construction with the shared `InvalidRate()` selector.
    /// @dev The selector is declared on `IRateOracle`, not on this contract, so every rate oracle in the
    ///      repository fails a bad rate the same way. Naming it through the interface is what keeps that
    ///      true — if the error were ever moved onto the implementation this line stops compiling.
    function test_constructor_zeroRate_reverts() public {
        vm.expectRevert(IRateOracle.InvalidRate.selector);
        new FixedRateOracle(0);
    }

    // ── the rate is immutable, and that is a structural fact ────────────────────

    /// @notice Nothing about the passage of time or blocks moves the rate.
    /// @dev This is the property the contract is FOR: a market that adopts a fixed-rate oracle is quoting
    ///      one number for its whole (roughly 24-hour) life. A wrapper over a live feed would move here.
    function test_rate_doesNotMoveWithTimeOrBlockNumber() public {
        FixedRateOracle oracle = new FixedRateOracle(RATE);

        vm.warp(block.timestamp + 3650 days);
        vm.roll(block.number + 10_000_000);

        assertEq(oracle.rate(), RATE, "the rate must not move with time or block height");
    }

    /// @notice The same reader gets the same answer no matter who is asking.
    /// @dev `rate()` takes no arguments and reads one immutable, so there is no caller-dependent branch
    ///      for a market to be fooled by. Asserted rather than inferred.
    function test_rate_isTheSameForEveryCaller() public {
        FixedRateOracle oracle = new FixedRateOracle(RATE);

        vm.prank(makeAddr("alice"));
        uint256 fromAlice = oracle.rate();
        vm.prank(makeAddr("bob"));
        uint256 fromBob = oracle.rate();

        assertEq(fromAlice, RATE, "alice's read");
        assertEq(fromBob, RATE, "bob's read");
    }

    /// @notice There is NO privileged surface: no owner, no setter, no upgrade hook, no fallback.
    /// @dev This is the local way of pinning an absence — the same shape `Governance.t.sol` uses for the
    ///      missing owner gate on `deployFixedRateOracle`, so that the absence reads as a decision rather
    ///      than an oversight. `FixedRateOracle` declares no `fallback` and no `receive`, so a call to a
    ///      selector it does not implement dies in the dispatcher and returns NO data at all. Each probe
    ///      below therefore asserts two things: the call failed, and it failed with empty return data
    ///      (which is what "this function does not exist" looks like, as opposed to "it exists and
    ///      rejected me", which would carry an error selector).
    ///
    ///      The control is the first assertion: the identical low-level call shape aimed at `rate()`
    ///      SUCCEEDS. Without it a typo in any signature string below would produce the same empty revert
    ///      and the test would pass for the wrong reason.
    function test_hasNoPrivilegedSurface() public {
        FixedRateOracle oracle = new FixedRateOracle(RATE);

        // Control: the one function that does exist answers through this exact call shape.
        (bool okRate, bytes memory retRate) = address(oracle).call(abi.encodeWithSignature("rate()"));
        assertTrue(okRate, "control: rate() must be reachable by low-level call");
        assertEq(abi.decode(retRate, (uint256)), RATE, "control: rate() must return the constructor rate");

        string[7] memory absent = [
            "owner()",
            "setRate(uint256)",
            "updateRate(uint256)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "initialize(uint256)",
            "upgradeTo(address)"
        ];

        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) = address(oracle).call(abi.encodeWithSignature(absent[i]));
            assertFalse(ok, string.concat("no such function must exist: ", absent[i]));
            assertEq(ret.length, 0, string.concat("an absent function returns no data: ", absent[i]));
        }

        // No fallback and no receive either: bare calldata and bare value both die the same way.
        (bool okFallback, bytes memory retFallback) = address(oracle).call(hex"deadbeef");
        assertFalse(okFallback, "there must be no fallback");
        assertEq(retFallback.length, 0, "a missing fallback returns no data");

        assertEq(oracle.rate(), RATE, "the rate must be untouched after every probe");
    }

    // ── interface conformance ───────────────────────────────────────────────────

    /// @notice The oracle presents as `IRateOracle`, which is the shape a market consumes it through.
    /// @dev Nothing in the registry calls `rate()`; markets do, at fill time. So the only thing that has
    ///      to line up is the interface, and this is where that is pinned for this implementation.
    function test_satisfiesIRateOracle() public {
        FixedRateOracle oracle = new FixedRateOracle(RATE);
        IRateOracle asInterface = IRateOracle(address(oracle));
        assertEq(asInterface.rate(), RATE, "must answer through the interface type");
    }
}
