// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title ConversionFeed store CRUD suite
/// @notice Covers `addConversionFeeds` (single and batch), `removeConversionFeeds`,
///         `lookupConversionFeed`, and the feed-side raise sites of `EntryAlreadyExists`,
///         `EntryNotFound` and `ZeroAddress`, plus owner gating.
/// @dev THE NATURAL KEY IS (base, quote) AND NOTHING ELSE. `chainId` is gone: a registry instance
///      holds only its own chain's feeds, so the chain was never a discriminator — it was a field that
///      could disagree with reality. The predecessor's "two feeds differing only by chainId are two
///      entries" case is therefore unconstructable, and it is replaced by the rule that actually
///      carries weight now: DIRECTION is part of the key. `(base, quote)` and `(quote, base)` are two
///      different entries, because `resolvePath` follows forward edges only — the Morpho oracle
///      multiplies the feeds it is handed and cannot invert one.
///
///      This store IS the denomination hop graph (one record = one directed edge). The graph WALK is
///      exercised in `HopGraph.t.sol`; this suite is only the create / read / delete surface.
///
///      Every `vm.expectRevert` carries an explicit selector.
contract ConversionFeedTest is Test {
    MarketRegistry internal registry;
    IMarketRegistry internal reg;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    // Taken from the interface rather than restated, so a change to the enum reaches this suite.
    IMarketRegistry.Namespace internal constant NS_FEED = IMarketRegistry.Namespace.ConversionFeed;

    // Chainlink Denominations pseudo-addresses — valid non-zero feed endpoints, taken from the
    // library so a change there cannot leave this suite asserting against a stale sentinel.
    address internal constant CHAINLINK_USD = MarketRegistryLib.USD_DENOMINATION;
    address internal constant CHAINLINK_ETH = MarketRegistryLib.ETH_DENOMINATION;

    MockWrapperFactory internal wrapperFactory;

    /// @dev The registry constructor takes a THIRD argument now — the fixed-rate-oracle factory — and
    ///      zero-checks it, so this suite deploys a real one even though it never reads a rate. Nothing
    ///      in the conversion-feed store touches it.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    function setUp() public {
        wrapperFactory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        registry = new MarketRegistry();
        registry.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
        reg = IMarketRegistry(address(registry));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _feed(address base, address quote, address agg)
        internal
        pure
        returns (IMarketRegistry.ConversionFeed memory f)
    {
        f.base = base;
        f.quote = quote;
        f.aggregatorAddress = agg;
    }

    function _feedKey(address base, address quote) internal pure returns (bytes32) {
        return keccak256(abi.encode(base, quote));
    }

    function _addFeed(IMarketRegistry.ConversionFeed memory f) internal {
        vm.prank(owner);
        reg.addConversionFeeds(one(f));
    }

    // ── addConversionFeed ────────────────────────────────────────────────────────

    function test_addConversionFeeds_happyPath_storesAndIndexes() public {
        address agg = makeAddr("agg");
        IMarketRegistry.ConversionFeed memory f = _feed(CHAINLINK_ETH, CHAINLINK_USD, agg);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IMarketRegistry.EntryAdded(NS_FEED, _feedKey(CHAINLINK_ETH, CHAINLINK_USD), abi.encode(f));
        _addFeed(f);

        (bool found, IMarketRegistry.ConversionFeed memory got) = reg.lookupConversionFeed(CHAINLINK_ETH, CHAINLINK_USD);
        assertTrue(found, "feed not found after add");
        assertEq(got.base, CHAINLINK_ETH, "base mismatch");
        assertEq(got.quote, CHAINLINK_USD, "quote mismatch");
        assertEq(got.aggregatorAddress, agg, "aggregator mismatch");

        (, uint256 total) = reg.getConversionFeeds(0, 10);
        assertEq(total, 1, "total should be 1");
    }

    function test_addConversionFeeds_zeroBase_reverts() public {
        IMarketRegistry.ConversionFeed memory f = _feed(address(0), CHAINLINK_USD, makeAddr("agg"));
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        _addFeed(f);
    }

    function test_addConversionFeeds_zeroQuote_reverts() public {
        IMarketRegistry.ConversionFeed memory f = _feed(CHAINLINK_ETH, address(0), makeAddr("agg"));
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        _addFeed(f);
    }

    function test_addConversionFeeds_zeroAggregator_reverts() public {
        IMarketRegistry.ConversionFeed memory f = _feed(CHAINLINK_ETH, CHAINLINK_USD, address(0));
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        _addFeed(f);
    }

    function test_addConversionFeeds_duplicateNaturalKey_reverts() public {
        IMarketRegistry.ConversionFeed memory f = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg"));
        _addFeed(f);

        // Same (base, quote); a differing aggregator must NOT matter — the natural key is
        // only the address pair.
        IMarketRegistry.ConversionFeed memory dup = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg2"));
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        _addFeed(dup);
    }

    /// @notice DIRECTION is part of the identity: `(base, quote)` and `(quote, base)` are two separate
    ///         entries and neither implies the other.
    /// @dev Replaces the predecessor's "differs only by chainId" case. This is the rule with teeth:
    ///      `resolvePath` probes forward edges only, so approving `ETH → USD` does NOT make
    ///      `USD → ETH` usable, and a pair needing the inverse has to have the inverse approved.
    function test_addConversionFeeds_directionIsPartOfTheKey_bothStored() public {
        _addFeed(_feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("aggForward")));
        _addFeed(_feed(CHAINLINK_USD, CHAINLINK_ETH, makeAddr("aggInverse")));

        (bool forwardFound, IMarketRegistry.ConversionFeed memory forward) =
            reg.lookupConversionFeed(CHAINLINK_ETH, CHAINLINK_USD);
        (bool inverseFound, IMarketRegistry.ConversionFeed memory inverse) =
            reg.lookupConversionFeed(CHAINLINK_USD, CHAINLINK_ETH);
        assertTrue(forwardFound, "forward edge missing");
        assertTrue(inverseFound, "inverse edge missing");
        assertTrue(
            forward.aggregatorAddress != inverse.aggregatorAddress, "the two directions collapsed onto one record"
        );

        (, uint256 total) = reg.getConversionFeeds(0, 10);
        assertEq(total, 2, "the two directions should be distinct entries");
    }

    function test_addConversionFeeds_nonOwner_reverts() public {
        IMarketRegistry.ConversionFeed memory f = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.addConversionFeeds(one(f));
    }

    // ── removeConversionFeed ──────────────────────────────────────────────────────

    function test_removeConversionFeeds_happyPath_swapAndPop() public {
        _addFeed(_feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg1")));
        _addFeed(_feed(CHAINLINK_USD, CHAINLINK_ETH, makeAddr("agg2")));

        vm.expectEmit(true, true, false, true, address(registry));
        emit IMarketRegistry.EntryRemoved(
            NS_FEED, _feedKey(CHAINLINK_ETH, CHAINLINK_USD), abi.encode(CHAINLINK_ETH, CHAINLINK_USD)
        );
        vm.prank(owner);
        reg.removeConversionFeeds(one(CHAINLINK_ETH), one(CHAINLINK_USD));

        (bool foundRemoved,) = reg.lookupConversionFeed(CHAINLINK_ETH, CHAINLINK_USD);
        assertFalse(foundRemoved, "removed feed still found");

        // The surviving feed (swapped into the freed slot) remains present and enumerable.
        (bool foundOther,) = reg.lookupConversionFeed(CHAINLINK_USD, CHAINLINK_ETH);
        assertTrue(foundOther, "survivor lost after swap-and-pop");

        (, uint256 total) = reg.getConversionFeeds(0, 10);
        assertEq(total, 1, "total should drop to 1");
    }

    function test_removeConversionFeeds_missing_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        reg.removeConversionFeeds(one(CHAINLINK_ETH), one(CHAINLINK_USD));
    }

    function test_removeConversionFeeds_nonOwner_reverts() public {
        _addFeed(_feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg")));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.removeConversionFeeds(one(CHAINLINK_ETH), one(CHAINLINK_USD));
    }

    /// @notice Bases and quotes must be the same length: a short quotes array reverts rather than
    ///         removing only the pairs it happens to cover.
    /// @dev The one place a key arrives as two parallel arrays, so the one place they can disagree.
    ///      Silently removing the prefix would be the worst outcome — a partly-applied governance action
    ///      that reports success.
    function test_removeConversionFeeds_lengthMismatch_reverts() public {
        _addFeed(_feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg")));

        address[] memory bases = new address[](2);
        bases[0] = CHAINLINK_ETH;
        bases[1] = CHAINLINK_USD;

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.ArrayLengthMismatch.selector);
        reg.removeConversionFeeds(bases, one(CHAINLINK_USD));
    }

    /// @notice A removal batch is all-or-nothing: one missing key reverts the whole call and the feed
    ///         that WOULD have been removed is still there.
    function test_removeConversionFeeds_batchIsAtomic() public {
        _addFeed(_feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("agg")));

        address[] memory bases = new address[](2);
        address[] memory quotes = new address[](2);
        bases[0] = CHAINLINK_ETH;
        quotes[0] = CHAINLINK_USD; // exists
        bases[1] = CHAINLINK_USD;
        quotes[1] = CHAINLINK_ETH; // does not

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        reg.removeConversionFeeds(bases, quotes);

        (bool stillThere,) = reg.lookupConversionFeed(CHAINLINK_ETH, CHAINLINK_USD);
        assertTrue(stillThere, "a reverted batch must not have removed the first element");
    }

    // ── addConversionFeeds, multi-entry ────────────────────────────────────────────

    function test_addConversionFeedsBatch_batch() public {
        IMarketRegistry.ConversionFeed[] memory batch = new IMarketRegistry.ConversionFeed[](3);
        batch[0] = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("a0"));
        batch[1] = _feed(CHAINLINK_USD, CHAINLINK_ETH, makeAddr("a1"));
        batch[2] = _feed(makeAddr("tokenA"), makeAddr("tokenB"), makeAddr("a2"));

        vm.prank(owner);
        reg.addConversionFeeds(batch);

        (, uint256 total) = reg.getConversionFeeds(0, 10);
        assertEq(total, 3, "all three feeds should be stored");

        for (uint256 i = 0; i < batch.length; i++) {
            (bool found,) = reg.lookupConversionFeed(batch[i].base, batch[i].quote);
            assertTrue(found, "seeded feed missing");
        }
    }

    /// @notice A duplicate natural key inside a seed batch reverts the whole atomic transaction.
    function test_addConversionFeedsBatch_duplicateInBatch_reverts() public {
        IMarketRegistry.ConversionFeed[] memory batch = new IMarketRegistry.ConversionFeed[](2);
        batch[0] = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("a0"));
        batch[1] = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("a1")); // same key

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        reg.addConversionFeeds(batch);

        // Atomicity: nothing from the batch survived.
        (, uint256 total) = reg.getConversionFeeds(0, 10);
        assertEq(total, 0, "batch not atomic after an in-batch duplicate");
    }

    function test_addConversionFeedsBatch_nonOwner_reverts() public {
        IMarketRegistry.ConversionFeed[] memory batch = new IMarketRegistry.ConversionFeed[](1);
        batch[0] = _feed(CHAINLINK_ETH, CHAINLINK_USD, makeAddr("a0"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.addConversionFeeds(batch);
    }
}
