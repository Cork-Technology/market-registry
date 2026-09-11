// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title Denomination store suite
/// @notice The denomination store is a set of unit addresses and nothing more: `addDenominations`,
///         `removeDenominations`, `isDenomination` and `getDenominations`, plus the two events every
///         store shares. This suite pins the membership rules, the event shape, and the enumeration.
/// @dev The store has the same shape as the recipe store: an address array and a position mapping,
///      swap-and-pop on the way out. So positions are NOT permanent, and the suite pins the
///      consequence — a removal moves the tail unit down into the freed slot.
contract DenominationEnumerationTest is Test {
    MarketRegistry internal reg;
    IMarketRegistry internal iReg;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    address internal constant USD = MarketRegistryLib.USD_DENOMINATION;
    address internal constant ETH = MarketRegistryLib.ETH_DENOMINATION;

    function setUp() public {
        reg = new MarketRegistry();
        reg.initialize(owner, address(new MockWrapperFactory()), address(new FixedRateOracleFactory()));
        iReg = IMarketRegistry(address(reg));
    }

    /// @dev The event key for a denomination is the unit address itself, widened to 32 bytes.
    function _key(address unit) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(unit)));
    }

    // ── the initialize seed ─────────────────────────────────────────────────────

    /// @notice A fresh registry enumerates exactly the two seeded pseudo-units, in the order
    ///         `initialize` registered them.
    function test_getDenominations_freshRegistry_returnsTheSeed() public {
        (address[] memory page, uint256 total) = iReg.getDenominations(0, 10);

        assertEq(total, 2, "a fresh registry holds exactly the two seeded denominations");
        assertEq(page.length, 2, "the whole seed should fit in the page");
        assertEq(page[0], USD, "the dollar pseudo-address is seeded first");
        assertEq(page[1], ETH, "the ether pseudo-address is seeded second");

        assertTrue(iReg.isDenomination(USD), "USD must be registered on a fresh registry");
        assertTrue(iReg.isDenomination(ETH), "ETH must be registered on a fresh registry");
        assertFalse(iReg.isDenomination(makeAddr("never")), "an unknown unit must not read as registered");
    }

    // ── add and remove: the round trip ──────────────────────────────────────────

    /// @notice Registering a unit emits `EntryAdded` keyed on the unit, makes `isDenomination` true,
    ///         and appends the unit after the seed. Removing it emits `EntryRemoved` with the same key,
    ///         makes `isDenomination` false, and drops it from the enumeration.
    function test_denominations_addThenRemove_roundTripWithEvents() public {
        address usdc = makeAddr("usdc");

        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.EntryAdded(IMarketRegistry.Namespace.Denomination, _key(usdc), abi.encode(usdc));
        vm.prank(owner);
        iReg.addDenominations(one(usdc));

        assertTrue(iReg.isDenomination(usdc), "the unit must be registered after the add");
        (address[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 3, "the new unit should extend the store");
        assertEq(page[2], usdc, "the new unit lands after the seed");

        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.EntryRemoved(IMarketRegistry.Namespace.Denomination, _key(usdc), abi.encode(usdc));
        vm.prank(owner);
        iReg.removeDenominations(one(usdc));

        assertFalse(iReg.isDenomination(usdc), "the unit must not be registered after the remove");
        (page, total) = iReg.getDenominations(0, 10);
        assertEq(total, 2, "the store must be back to the seed");
        assertEq(page[0], USD);
        assertEq(page[1], ETH);
    }

    /// @notice One call may register several units, and each one gets its own event.
    function test_addDenominations_batch_oneEventPerUnit() public {
        address[] memory units = new address[](2);
        units[0] = makeAddr("usdc");
        units[1] = makeAddr("usdt");

        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.EntryAdded(IMarketRegistry.Namespace.Denomination, _key(units[0]), abi.encode(units[0]));
        vm.expectEmit(true, true, true, true, address(reg));
        emit IMarketRegistry.EntryAdded(IMarketRegistry.Namespace.Denomination, _key(units[1]), abi.encode(units[1]));
        vm.prank(owner);
        iReg.addDenominations(units);

        (, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 4);
    }

    /// @notice Registering a unit that is already in the set reverts `EntryAlreadyExists` — the set
    ///         never holds a duplicate, so the bridge search never tries the same intermediate twice.
    function test_addDenominations_duplicate_reverts() public {
        address usdc = makeAddr("usdc");
        vm.startPrank(owner);
        iReg.addDenominations(one(usdc));
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        iReg.addDenominations(one(usdc));
        vm.stopPrank();
    }

    /// @notice A seeded pseudo-unit counts as already registered too.
    function test_addDenominations_seededUnit_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        iReg.addDenominations(one(USD));
    }

    /// @notice The zero address is not a unit and is refused with `ZeroAddress`.
    function test_addDenominations_zeroUnit_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        iReg.addDenominations(one(address(0)));
    }

    /// @notice A batch is all-or-nothing: one bad element writes nothing.
    function test_addDenominations_batchWithZero_writesNothing() public {
        address[] memory units = new address[](2);
        units[0] = makeAddr("usdc");
        units[1] = address(0);

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.ZeroAddress.selector);
        iReg.addDenominations(units);

        assertFalse(iReg.isDenomination(units[0]), "the good element must not survive the failed batch");
    }

    /// @notice Removing a unit that is not registered reverts `EntryNotFound`.
    function test_removeDenominations_unknown_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        iReg.removeDenominations(one(makeAddr("neverRegistered")));
    }

    /// @notice Removing twice is refused the second time.
    function test_removeDenominations_twice_reverts() public {
        address usdc = makeAddr("usdc");
        vm.startPrank(owner);
        iReg.addDenominations(one(usdc));
        iReg.removeDenominations(one(usdc));
        vm.expectRevert(IMarketRegistry.EntryNotFound.selector);
        iReg.removeDenominations(one(usdc));
        vm.stopPrank();
    }

    /// @notice Both verbs are owner-only.
    function test_denominations_strangerCannotWrite() public {
        address usdc = makeAddr("usdc");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), stranger));
        iReg.addDenominations(one(usdc));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), stranger));
        iReg.removeDenominations(one(USD));
    }

    /// @notice A unit removed and re-added lands at the END of the enumeration rather than back in its
    ///         old slot — positions are not stable names.
    function test_getDenominations_reAddedUnit_movesToTheEnd() public {
        address gbp = makeAddr("gbp");
        address usdc = makeAddr("usdc");

        vm.startPrank(owner);
        iReg.addDenominations(one(gbp));
        iReg.addDenominations(one(usdc));
        iReg.removeDenominations(one(gbp));
        iReg.addDenominations(one(gbp));
        vm.stopPrank();

        (address[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 4, "a re-add must not leave a second entry behind");
        assertEq(page[2], usdc, "the unit that stayed was swapped down into the freed slot");
        assertEq(page[3], gbp, "the re-added unit sits at the end");
    }

    // ── removal ─────────────────────────────────────────────────────────────────

    /// @notice Removing a unit drops it from the enumeration and swaps the tail into the freed slot.
    /// @dev The same swap-and-pop the other stores use, which is why positions are not stable names
    ///      here either.
    function test_getDenominations_removal_swapsTheTailIn() public {
        address usdc = makeAddr("usdc");
        address usdt = makeAddr("usdt");
        vm.startPrank(owner);
        iReg.addDenominations(one(usdc));
        iReg.addDenominations(one(usdt));
        iReg.removeDenominations(one(usdc)); // slot 2, with USDT at slot 3 behind it
        vm.stopPrank();

        (address[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 3, "removal must shrink the store");
        assertEq(page[2], usdt, "the tail unit must be swapped into the freed slot");
        assertFalse(iReg.isDenomination(usdc));
        assertTrue(iReg.isDenomination(usdt));
    }

    /// @notice Membership and enumeration agree after a mix of adds and removals, including a seeded
    ///         unit removed from the middle.
    function test_getDenominations_membershipMatchesEnumeration() public {
        address usdc = makeAddr("usdc");
        address usdt = makeAddr("usdt");
        address gbp = makeAddr("gbp");
        vm.startPrank(owner);
        iReg.addDenominations(one(usdc));
        iReg.addDenominations(one(usdt));
        iReg.addDenominations(one(gbp));
        iReg.removeDenominations(one(ETH)); // a seeded unit, from the middle
        iReg.removeDenominations(one(usdt));
        vm.stopPrank();

        (address[] memory page, uint256 total) = iReg.getDenominations(0, 100);
        assertEq(total, 3, "two of five removed");
        for (uint256 i = 0; i < page.length; i++) {
            assertTrue(page[i] != address(0), "an enumerated unit is never zero");
            assertTrue(iReg.isDenomination(page[i]), "every enumerated unit must read as registered");
        }
        assertFalse(iReg.isDenomination(ETH));
        assertFalse(iReg.isDenomination(usdt));
    }

    /// @notice Removing the last remaining units empties the store without leaving a phantom entry.
    function test_getDenominations_removingEverything_leavesAnEmptyStore() public {
        vm.startPrank(owner);
        iReg.removeDenominations(one(USD));
        iReg.removeDenominations(one(ETH));
        vm.stopPrank();

        (address[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 0, "the store should be empty");
        assertEq(page.length, 0, "an empty store yields an empty page");
        assertFalse(iReg.isDenomination(USD));
    }

    // ── pagination ──────────────────────────────────────────────────────────────

    /// @notice The same `pageBounds` clamp the other enumerations use: a mid-array slice, a limit past
    ///         the end, an offset at the boundary, and an offset far past it.
    function test_getDenominations_paginationBounds() public {
        address usdc = makeAddr("usdc");
        address usdt = makeAddr("usdt");
        vm.startPrank(owner);
        iReg.addDenominations(one(usdc));
        iReg.addDenominations(one(usdt));
        vm.stopPrank(); // four denominations: USD, ETH, usdc, usdt

        (address[] memory page, uint256 total) = iReg.getDenominations(1, 2);
        assertEq(total, 4, "total is the full count, not the page length");
        assertEq(page.length, 2, "slice [1,3) should have length 2");
        assertEq(page[0], ETH, "the slice must start at the offset");
        assertEq(page[1], usdc);

        (page, total) = iReg.getDenominations(3, 100);
        assertEq(page.length, 1, "a limit past the end must clamp to what remains");
        assertEq(page[0], usdt);

        (page, total) = iReg.getDenominations(0, 0);
        assertEq(total, 4, "total is still reported for a zero limit");
        assertEq(page.length, 0, "a zero limit yields an empty page");

        (page, total) = iReg.getDenominations(4, 10);
        assertEq(total, 4, "total is still reported at the boundary offset");
        assertEq(page.length, 0, "offset == length must yield an empty page");

        (page, total) = iReg.getDenominations(type(uint256).max, type(uint256).max);
        assertEq(total, 4, "total is still reported at the extreme");
        assertEq(page.length, 0, "an offset past the end must yield an empty page, not an overflow");
    }
}
