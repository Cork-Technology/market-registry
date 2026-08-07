// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title Denomination enumeration suite
/// @notice `getDenominations` is the read side of the denomination store: it answers with (label hash,
///         unit) pairs, in registration order, and it has to keep agreeing with the mapping after the
///         owner re-points a label.
/// @dev The store has the same shape as the asset, feed and recipe stores now: add and remove, keys
///      held in an array, swap-and-pop on the way out. So positions are NOT permanent here either, and
///      the suite pins the consequence — a removal moves the tail label down into the freed slot.
///
///      The array holds label HASHES rather than unit addresses, and the removal tests are what make
///      that visible: the mapping entry and the array slot are cleared together, so no enumerated hash
///      can ever resolve to a zero unit. `MarketRegistryLib.resolvePath` walks this array and would
///      silently probe `feedKey(fromUnit, address(0))` if one ever did.
contract DenominationEnumerationTest is Test {
    MarketRegistry internal reg;
    IMarketRegistry internal iReg;

    address internal owner = makeAddr("owner");

    function setUp() public {
        reg = new MarketRegistry();
        reg.initialize(owner, address(new MockWrapperFactory()), address(new FixedRateOracleFactory()));
        iReg = IMarketRegistry(address(reg));
    }

    // ── the constructor seed ────────────────────────────────────────────────────

    /// @notice A fresh registry enumerates exactly the two seeded denominations, in the order the
    ///         constructor registered them, each pointing at its Chainlink `Denominations`
    ///         pseudo-address.
    function test_getDenominations_freshRegistry_returnsTheSeed() public view {
        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 10);

        assertEq(total, 2, "a fresh registry holds exactly the two seeded denominations");
        assertEq(page.length, 2, "the whole seed should fit in the page");

        assertEq(page[0].labelHash, keccak256(bytes("USD")), "USD is seeded first");
        assertEq(page[0].unit, MarketRegistryLib.USD_DENOMINATION, "USD must name the dollar pseudo-address");
        assertEq(page[1].labelHash, keccak256(bytes("ETH")), "ETH is seeded second");
        assertEq(page[1].unit, MarketRegistryLib.ETH_DENOMINATION, "ETH must name the ether pseudo-address");
    }

    // ── registration ────────────────────────────────────────────────────────────

    /// @notice A newly registered label is appended after the seed, hash and unit intact.
    function test_getDenominations_newLabel_appended() public {
        address usdc = makeAddr("usdc");
        vm.prank(owner);
        iReg.addDenominations(one("USDC"), one(usdc));

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 3, "the new label should extend the store");
        assertEq(page[2].labelHash, keccak256(bytes("USDC")), "the new label lands after the seed");
        assertEq(page[2].unit, usdc, "the enumerated unit must be the one registered");
    }

    /// @notice Registering the SAME label twice is refused — registration is add-only.
    function test_addDenominations_duplicateLabel_reverts() public {
        vm.startPrank(owner);
        iReg.addDenominations(one("GBPX"), one(makeAddr("firstUnit")));
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        iReg.addDenominations(one("GBPX"), one(makeAddr("secondUnit")));
        vm.stopPrank();
    }

    /// @notice Re-pointing a label is remove-then-add, and the re-added label lands at the END of the
    ///         enumeration rather than back in its old slot.
    /// @dev The whole reason `_denominationKeys` holds label HASHES rather than unit addresses. An array
    ///      of addresses would still be offering `first` as a legal bridge here, because nothing would
    ///      have told it the label moved.
    function test_getDenominations_rePointedLabel_movesToTheEnd() public {
        address first = makeAddr("firstUnit");
        address second = makeAddr("secondUnit");

        vm.startPrank(owner);
        iReg.addDenominations(one("GBPX"), one(first));
        iReg.addDenominations(one("USDC"), one(makeAddr("usdc")));
        iReg.removeDenominations(one("GBPX"));
        iReg.addDenominations(one("GBPX"), one(second));
        vm.stopPrank();

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 4, "a re-point must not leave a second entry behind");
        assertEq(page[3].labelHash, keccak256(bytes("GBPX")), "the re-added label sits at the end");
        assertEq(page[3].unit, second, "the enumerated unit must follow the re-point");
    }

    // ── removal ─────────────────────────────────────────────────────────────────

    /// @notice Removing a label drops it from the enumeration and swaps the tail into the freed slot.
    /// @dev The same swap-and-pop the other three stores use, which is why positions are not stable
    ///      names here either.
    function test_getDenominations_removal_swapsTheTailIn() public {
        vm.startPrank(owner);
        iReg.addDenominations(one("USDC"), one(makeAddr("usdc")));
        iReg.addDenominations(one("USDT"), one(makeAddr("usdt")));
        iReg.removeDenominations(one("USDC")); // slot 2, with USDT at slot 3 behind it
        vm.stopPrank();

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 3, "removal must shrink the store");
        assertEq(page[2].labelHash, keccak256(bytes("USDT")), "the tail label must be swapped into the freed slot");
    }

    /// @notice Every enumerated label hash resolves to a NON-ZERO unit, including after removals.
    /// @dev The pairing invariant `resolvePath` depends on. If a removal ever cleared the array without
    ///      the mapping — or the other way round — this is the assertion that catches it, and nothing
    ///      else would: a stale hash resolving to zero makes the hop search probe a zero unit, find
    ///      nothing, and carry on silently.
    function test_getDenominations_everyEnumeratedHashResolves() public {
        vm.startPrank(owner);
        iReg.addDenominations(one("USDC"), one(makeAddr("usdc")));
        iReg.addDenominations(one("USDT"), one(makeAddr("usdt")));
        iReg.addDenominations(one("GBPX"), one(makeAddr("gbpx")));
        iReg.removeDenominations(one("ETH")); // a seeded label, from the middle
        iReg.removeDenominations(one("USDT"));
        vm.stopPrank();

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 100);
        assertEq(total, 3, "two of five removed");
        for (uint256 i = 0; i < page.length; i++) {
            assertTrue(page[i].unit != address(0), "an enumerated label hash must resolve to a real unit");
        }
    }

    /// @notice Removing the only remaining labels empties the store without leaving a phantom entry.
    function test_getDenominations_removingEverything_leavesAnEmptyStore() public {
        vm.startPrank(owner);
        iReg.removeDenominations(one("USD"));
        iReg.removeDenominations(one("ETH"));
        vm.stopPrank();

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 0, "the store should be empty");
        assertEq(page.length, 0, "an empty store yields an empty page");
    }

    /// @notice Labels are exact bytes: `"usd"` is a different denomination from the seeded `"USD"` and
    ///         gets its own entry.
    function test_getDenominations_caseSensitive_lowercaseIsItsOwnEntry() public {
        address impostor = makeAddr("lowercaseUsdUnit");
        vm.prank(owner);
        iReg.addDenominations(one("usd"), one(impostor));

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(0, 10);
        assertEq(total, 3, "a differently-cased label is a separate denomination");
        assertEq(page[0].unit, MarketRegistryLib.USD_DENOMINATION, "the seeded USD must be untouched");
        assertEq(page[2].unit, impostor, "the lowercase label gets its own entry");
    }

    // ── pagination ──────────────────────────────────────────────────────────────

    /// @notice The same `pageBounds` clamp the other three enumerations use: a mid-array slice, a limit
    ///         past the end, an offset at the boundary, and an offset far past it.
    function test_getDenominations_paginationBounds() public {
        vm.startPrank(owner);
        iReg.addDenominations(one("USDC"), one(makeAddr("usdc")));
        iReg.addDenominations(one("USDT"), one(makeAddr("usdt")));
        vm.stopPrank(); // four denominations: USD, ETH, USDC, USDT

        (IMarketRegistry.Denomination[] memory page, uint256 total) = iReg.getDenominations(1, 2);
        assertEq(total, 4, "total is the full count, not the page length");
        assertEq(page.length, 2, "slice [1,3) should have length 2");
        assertEq(page[0].labelHash, keccak256(bytes("ETH")), "the slice must start at the offset");

        (page, total) = iReg.getDenominations(3, 100);
        assertEq(page.length, 1, "a limit past the end must clamp to what remains");

        (page, total) = iReg.getDenominations(4, 10);
        assertEq(total, 4, "total is still reported at the boundary offset");
        assertEq(page.length, 0, "offset == length must yield an empty page");

        (page, total) = iReg.getDenominations(type(uint256).max, type(uint256).max);
        assertEq(total, 4, "total is still reported at the extreme");
        assertEq(page.length, 0, "an offset past the end must yield an empty page, not an overflow");
    }
}
