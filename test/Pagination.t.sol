// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title Enumeration pagination bounds suite
/// @notice Clamping semantics for `getConversionFeeds`: the slice is [offset, offset+limit) clamped to
///         the array length; an offset at or past the end yields an empty page; a limit past the end is
///         truncated; and `total` always reports the full count regardless of the page window.
/// @dev Wrappers are not enumerable (they are keyed by pair + resolved sources and read one at a time
///      via `lookupWrapper`), so the conversion-feed store is the cheapest pagination subject: its
///      entries need no denomination registration, no dollar path, and no probe-safe address. The same
///      `MarketRegistryLib.pageBounds` clamp backs `getAssets` and `getRecipes`, so exercising it once
///      here covers all three.
contract PaginationTest is Test {
    MarketRegistry internal registry;
    IMarketRegistry internal reg;
    MockWrapperFactory internal factory;

    /// @dev The registry constructor takes a THIRD argument now — the fixed-rate oracle factory — and
    ///      zero-checks it, so even a suite that never deploys a fixed-rate oracle has to supply one.
    ///      The real factory is used rather than a mock: it has no admin surface and nothing to stub.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    address internal owner = makeAddr("owner");

    uint256 internal constant N = 5;

    function setUp() public {
        factory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        registry = new MarketRegistry();
        registry.initialize(owner, address(factory), address(fixedRateOracleFactory));
        reg = IMarketRegistry(address(registry));

        // Five distinct edges. The natural key is (base, quote) with no chain component, so the pairs
        // themselves have to differ — a repeated pair would revert `EntryAlreadyExists`.
        for (uint256 i = 0; i < N; i++) {
            IMarketRegistry.ConversionFeed memory f;
            f.base = makeAddr(string(abi.encodePacked("base", i)));
            f.quote = makeAddr(string(abi.encodePacked("quote", i)));
            f.aggregatorAddress = makeAddr(string(abi.encodePacked("agg", i)));
            f.feedDecimals = 8;
            vm.prank(owner);
            reg.addConversionFeeds(one(f));
        }
    }

    // ── conversion feeds ────────────────────────────────────────────────────────

    function test_pagination_bounds_feeds_normalSlice() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(1, 2);
        assertEq(total, N, "total should be full count");
        assertEq(page.length, 2, "slice [1,3) should have length 2");
    }

    function test_pagination_bounds_feeds_limitPastEnd_clamped() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(3, 100);
        assertEq(total, N, "total should be full count");
        assertEq(page.length, 2, "limit past end must clamp to remaining");
    }

    function test_pagination_bounds_feeds_offsetEqualsLength_emptyPage() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(N, 10);
        assertEq(total, N, "total still reported at boundary offset");
        assertEq(page.length, 0, "offset == length must yield empty page");
    }

    function test_pagination_bounds_feeds_offsetPastLength_emptyPage() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(N + 7, 10);
        assertEq(total, N, "total still reported past end");
        assertEq(page.length, 0, "offset > length must yield empty page");
    }

    function test_pagination_bounds_feeds_zeroLimit_emptyPage() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(0, 0);
        assertEq(total, N, "total still reported with zero limit");
        assertEq(page.length, 0, "zero limit must yield empty page");
    }

    function test_pagination_bounds_feeds_fullRange() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) = reg.getConversionFeeds(0, N);
        assertEq(total, N, "total mismatch");
        assertEq(page.length, N, "full range should return every element");
    }

    /// @notice An enormous offset cannot overflow the clamp: `count` is derived from `total - offset`,
    ///         never from `offset + limit`.
    function test_pagination_bounds_feeds_maxOffsetAndLimit_noOverflow() public view {
        (IMarketRegistry.ConversionFeed[] memory page, uint256 total) =
            reg.getConversionFeeds(type(uint256).max, type(uint256).max);
        assertEq(total, N, "total still reported at the extreme");
        assertEq(page.length, 0, "an offset past the end must yield an empty page, not an overflow");
    }

    // ── empty store ────────────────────────────────────────────────────────────

    function test_pagination_bounds_emptyStore_zeroTotalEmptyPage() public {
        MarketRegistry fresh = new MarketRegistry();
        fresh.initialize(owner, address(factory), address(fixedRateOracleFactory));
        IMarketRegistry freshReg = IMarketRegistry(address(fresh));

        (IMarketRegistry.ConversionFeed[] memory cpage, uint256 ctotal) = freshReg.getConversionFeeds(0, 10);
        assertEq(ctotal, 0, "empty feed store total should be 0");
        assertEq(cpage.length, 0, "empty feed store page should be empty");

        (IMarketRegistry.Asset[] memory apage, uint256 atotal) = freshReg.getAssets(0, 10);
        assertEq(atotal, 0, "empty asset store total should be 0");
        assertEq(apage.length, 0, "empty asset store page should be empty");

        (address[] memory rpage, uint256 rtotal) = freshReg.getRecipes(0, 10);
        assertEq(rtotal, 0, "empty recipe store total should be 0");
        assertEq(rpage.length, 0, "empty recipe store page should be empty");
    }
}
