// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {FixedRateOracleFactory} from "../src/FixedRateOracleFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {mkAsset, mkPriceSource, noSource} from "./fixtures/TenAssetSet.sol";
import {MockERC20} from "./mocks/HostileAssets.sol";
import {MockWrapperFactory} from "./mocks/MockWrapperFactory.sol";

/// @title addAssets BATCH STRUCTURAL half
/// @notice Covers batch atomicity and in-batch duplicate rejection only. The batch ordering
///         semantics live in `AddAssetsBatchOrdering.t.sol` — this file deliberately does not touch them.
/// @dev NOTHING IS DERIVED ON THIS PATH ANY MORE, so there is no walk to keep neutral. `addAsset`
///      stores each PRESENT source's own `denomination` string verbatim and validates it against the
///      denomination registry and the conversion-feed graph; it never probes `asset()`. Every entry
///      below therefore states `"USD"` on its one price source, which is seeded by the constructor and
///      reaches US Dollars in zero hops.
///
///      Asset addresses are still deployed {MockERC20} contracts rather than `makeAddr` labels. The add
///      path no longer needs the code, but `deploy` reads each leg's live `decimals()` and
///      `MarketRegistryLib.deriveDenomination` still probes `asset()` where a codeless target makes the
///      ABI decode revert uncatchably (see `Walk.t.sol`), so real code stays the house style.
contract AddAssetsBatchStructuralTest is Test {
    MarketRegistry internal registry;
    IMarketRegistry internal reg;

    address internal owner = makeAddr("owner");
    address internal tokenA;
    address internal tokenB;
    address internal tokenC;

    address internal constant SRC = address(0x5A25);

    MockWrapperFactory internal wrapperFactory;

    /// @dev Third constructor argument, zero-checked by the registry. This suite never reads a rate.
    FixedRateOracleFactory internal fixedRateOracleFactory;

    function setUp() public {
        wrapperFactory = new MockWrapperFactory();
        fixedRateOracleFactory = new FixedRateOracleFactory();
        registry = new MarketRegistry();
        registry.initialize(owner, address(wrapperFactory), address(fixedRateOracleFactory));
        reg = IMarketRegistry(address(registry));

        tokenA = address(new MockERC20("Token A", "AAA", 6));
        tokenB = address(new MockERC20("Token B", "BBB", 18));
        tokenC = address(new MockERC20("Token C", "CCC", 8));
    }

    /// @dev One price source stating `denomination_`, NAV slot absent. There is no asset-level
    ///      denomination argument any more — the label belongs to the source.
    function _asset(address addr_, string memory name_, string memory denomination_)
        internal
        pure
        returns (IMarketRegistry.Asset memory)
    {
        return mkAsset(addr_, name_, IMarketRegistry.AssetKind.ERC20, mkPriceSource(SRC, denomination_), noSource());
    }

    /// @notice A duplicate natural key WITHIN a single batch reverts `EntryAlreadyExists`, and the whole
    ///         batch is atomic: no entry from the batch is persisted. The third entry repeats the first
    ///         entry's address, so the per-entry insert path hits the occupied primary key left by entry
    ///         0 and reverts the entire transaction.
    function test_addAssetsBatch_duplicateInBatch_reverts() public {
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](3);
        batch[0] = _asset(tokenA, "AAA", "USD");
        batch[1] = _asset(tokenB, "BBB", "USD");
        batch[2] = _asset(tokenA, "CCC", "USD"); // duplicate natural key of batch[0]

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        reg.addAssets(batch);

        // Atomicity: the revert rolled back entries 0 and 1 too — nothing persisted.
        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 0, "batch not atomic: entries persisted after an in-batch duplicate revert");
        (bool fa,) = reg.lookupAssetByAddress(tokenA);
        (bool fb,) = reg.lookupAssetByAddress(tokenB);
        assertFalse(fa, "batch entry 0 persisted after revert");
        assertFalse(fb, "batch entry 1 persisted after revert");
    }

    /// @notice A duplicate FOLDED NAME inside a batch reverts the same way, even though the addresses
    ///         differ — the name index is checked per entry, on the state prior entries left behind.
    function test_addAssetsBatch_duplicateNameInBatch_reverts() public {
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](2);
        batch[0] = _asset(tokenA, "USDC", "USD");
        batch[1] = _asset(tokenB, "usdc", "USD"); // same folded name, different address

        vm.prank(owner);
        vm.expectRevert(IMarketRegistry.EntryAlreadyExists.selector);
        reg.addAssets(batch);

        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 0, "batch not atomic after an in-batch name collision");
    }

    /// @notice One unwritable entry takes the whole batch down. Here entry 1's source names an
    ///         UNREGISTERED denomination, so the write-time source validation rejects it — and entries 0
    ///         and 2 roll back with it.
    /// @dev This is the batch-shaped consequence of moving validation to write time: a seed batch is
    ///      all-or-nothing, so a single mis-typed source `denomination` invalidates the whole Safe
    ///      transaction rather than quietly landing eight of nine entries.
    function test_addAssetsBatch_unregisteredDenominationInBatch_revertsWholeBatch() public {
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](3);
        batch[0] = _asset(tokenA, "AAA", "USD");
        batch[1] = _asset(tokenB, "BBB", "MADEUP"); // never registered
        batch[2] = _asset(tokenC, "CCC", "USD");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, "MADEUP"));
        reg.addAssets(batch);

        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 0, "batch not atomic after a rejected source");
    }

    /// @notice The happy path: three well-formed entries all land, and enumeration reports all three.
    function test_addAssetsBatch_batch_allPersisted() public {
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](3);
        batch[0] = _asset(tokenA, "AAA", "USD");
        batch[1] = _asset(tokenB, "BBB", "USD");
        batch[2] = _asset(tokenC, "CCC", "USD");

        vm.prank(owner);
        reg.addAssets(batch);

        (, uint256 total) = reg.getAssets(0, 10);
        assertEq(total, 3, "every batch entry should be stored");
        for (uint256 i = 0; i < batch.length; i++) {
            (bool found, IMarketRegistry.Asset memory got) = reg.lookupAssetByAddress(batch[i].addr);
            assertTrue(found, "seeded asset missing");
            // The label lives on the SOURCE now, and `addAsset` stores it verbatim. The absent NAV slot
            // reads back as the empty string, because an absent source is zeroed rather than copied.
            assertEq(got.priceSource.denomination, "USD", "seeded price source denomination mismatch");
            assertEq(got.navSource.addr, address(0), "absent NAV slot should be zeroed");
            assertEq(got.navSource.denomination, "", "absent NAV slot should carry no denomination");
        }
    }
}
