// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {WalkTestBase, mkNavSource, mkPriceSource, noSource} from "./fixtures/TenAssetSet.sol";
import {MockVaultAsset, RevertingAsset} from "./mocks/HostileAssets.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title AddAssetsBatchOrdering.t.sol — what in-batch order does, and no longer does, to a batch add
/// @notice The ordering half of the multi-entry `addAssets` cases. The structural half (duplicates, atomicity,
///         per-check reverts) lives in `AddAssetsBatchStructural.t.sol` and is NOT touched here.
///
/// @dev THE OLD ORDERING RULE IS GONE. It used to be that each entry's underlying-asset walk saw only
///      the registry state prior entries in the same batch had left behind, so a vault listed BEFORE the
///      terminator it hopped to could not reach it and fell back to pinning the caller's residual
///      denomination — a different stored value for the same two entries, decided purely by their order
///      in the array. That cannot happen any more: the asset-level `denomination` field is deleted,
///      `addAsset` derives nothing, and each PRESENT source carries and stores its own label verbatim.
///      Entries in one batch have no denomination-shaped dependency on each other at all.
///
///      THE SURVIVING ORDERING RULE IS THE HARSHER ONE, and it is now the whole subject of this file:
///      a denomination label and the conversion-feed edges that carry it to US Dollars must exist BEFORE
///      any asset whose source names that label, because every present source is validated at WRITE time
///      rather than at the first `deploy` against it. That ordering runs across calls (register the
///      label, add the feed, then seed the assets), not within one asset batch. `HopGraph.t.sol` covers
///      the graph search itself; what is pinned here is that a batch add is subject to the same gate
///      and that a batch is all-or-nothing against it.
contract AddAssetsBatchOrderingTest is WalkTestBase {
    /// @dev A registered label with NO dollar edge behind it, used to demonstrate the write-time gate.
    ///      `setUp` registers the label and deliberately does NOT add the feed; one test adds the edge
    ///      partway through and re-seeds the identical batch.
    address internal constant RESID_UNIT = address(0xDEC1DED);

    IMarketRegistry.SourceType internal constant PRICE = IMarketRegistry.SourceType.PRICE;
    IMarketRegistry.SourceType internal constant NAV = IMarketRegistry.SourceType.NAV;

    function setUp() public override {
        super.setUp();
        _registerDenomination("RESID", RESID_UNIT);
    }

    /// @dev Deploy a fresh (terminator, vault→terminator) pair, both stating `"USD"` on their one
    ///      present source. `suffix` keeps the two names unique so a test can build two independent
    ///      pairs without colliding on the folded-name index.
    ///
    ///      The topology is kept from the predecessor on purpose: this is the exact pair whose stored
    ///      denominations used to depend on the order they were listed in. Nothing calls `asset()` on
    ///      the add path any more, so the hop is inert here — it is still real code because
    ///      `MarketRegistryLib.deriveDenomination` and `deploy` both read the chain downstream.
    ///
    ///      The terminator's source is a PRICE source and goes in the price field; the vault's is a NAV
    ///      source and MUST go in the NAV field, because `sourceType` has to match the slot holding it
    ///      or `addAsset` reverts `SourceTypeMismatch`.
    function _pair(string memory suffix)
        internal
        returns (IMarketRegistry.Asset memory terminator, IMarketRegistry.Asset memory vault, address vaultAddr)
    {
        address termAddr = address(new RevertingAsset()); // leaf: asset() reverts
        vaultAddr = address(new MockVaultAsset(termAddr)); // vault: asset() → terminator

        terminator = _asset1(termAddr, string.concat("PAIRTERM", suffix), mkPriceSource(termAddr, "USD"));
        vault = _asset2(vaultAddr, string.concat("PAIRVAULT", suffix), noSource(), mkNavSource(vaultAddr, "USD"));
    }

    // ── in-batch order no longer changes what is stored ───────────────────────────

    /// @notice The same dependent pair seeded in BOTH orders stores exactly the same denominations.
    /// @dev This replaces the predecessor's two contrasting cases — `dependencyOrdered_derives` and
    ///      `dependencyInverted_residualOutcome` — which asserted that the vault stored `"USD"` when
    ///      listed after its terminator and the caller residual `"RESID"` when listed before it. That
    ///      contrast is unconstructable now: there is no walk to reach a prior entry and no
    ///      asset-level field for it to write, so both orders are the same write twice. Asserting the
    ///      ABSENCE of the old order-sensitivity is the only thing left worth pinning about it, and it
    ///      is worth pinning, because a reader who knows the predecessor will expect the old behaviour.
    function test_addAssetsBatch_inBatchOrderDoesNotChangeStoredDenominations() public {
        (
            IMarketRegistry.Asset memory orderedTerm,
            IMarketRegistry.Asset memory orderedVault,
            address orderedVaultAddr
        ) = _pair("ORDERED");
        IMarketRegistry.Asset[] memory ordered = new IMarketRegistry.Asset[](2);
        ordered[0] = orderedTerm; // dependency first
        ordered[1] = orderedVault;
        iReg.addAssets(ordered);

        (
            IMarketRegistry.Asset memory invertedTerm,
            IMarketRegistry.Asset memory invertedVault,
            address invertedVaultAddr
        ) = _pair("INVERTED");
        IMarketRegistry.Asset[] memory inverted = new IMarketRegistry.Asset[](2);
        inverted[0] = invertedVault; // dependent first — inverted
        inverted[1] = invertedTerm;
        iReg.addAssets(inverted);

        // Every entry stored the label its own present source stated, in both orders.
        assertTrue(_eq(_storedDenomination(orderedTerm.addr, PRICE), "USD"), "ordered terminator label wrong");
        assertTrue(_eq(_storedDenomination(invertedTerm.addr, PRICE), "USD"), "inverted terminator label wrong");
        assertTrue(_eq(_storedDenomination(orderedVaultAddr, NAV), "USD"), "ordered vault label wrong");
        assertTrue(
            _eq(_storedDenomination(invertedVaultAddr, NAV), "USD"),
            "inverted vault stored a different label: in-batch order still affects the write"
        );

        // And the two vaults agree with each other, which is the claim stated directly.
        assertTrue(
            _eq(_storedDenomination(orderedVaultAddr, NAV), _storedDenomination(invertedVaultAddr, NAV)),
            "the two orders produced different stored denominations"
        );
    }

    // ── the ordering rule that DOES survive: feeds before the assets naming them ──

    /// @notice A batch naming a label with no dollar path yet reverts `NoConversionPathToUsd` and lands
    ///         nothing; adding the edge and re-seeding the IDENTICAL batch succeeds.
    /// @dev This is the ordering requirement that replaced the walk's. It is a cross-call ordering, not
    ///      an in-batch one: the label registration and the conversion feed are separate owner writes
    ///      that must both be in place first. The hop budget in the error is 2 because the source is an
    ///      `ERC4626` NAV source; `"RESID"` is a registered label throughout, so this is the PATH check
    ///      failing rather than the label check.
    function test_addAssetsBatch_feedMustExistBeforeTheAssetNamingIt() public {
        address termAddr = address(new RevertingAsset());
        address vaultAddr = address(new MockVaultAsset(termAddr));

        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](1);
        batch[0] = _asset2(vaultAddr, "LATEFEED", noSource(), mkNavSource(vaultAddr, "RESID"));

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.NoConversionPathToUsd.selector, RESID_UNIT, uint256(2)));
        iReg.addAssets(batch);

        (bool foundBefore,) = iReg.lookupAssetByAddress(vaultAddr);
        assertFalse(foundBefore, "the rejected batch must have landed nothing");

        // Add the missing edge. Nothing about the batch changes.
        _addFeed(RESID_UNIT, USD_UNIT, makeAddr("residUsdAggregator"), 8);
        iReg.addAssets(batch);

        (bool foundAfter,) = iReg.lookupAssetByAddress(vaultAddr);
        assertTrue(foundAfter, "batch should land once the dollar edge exists");
        assertTrue(_eq(_storedDenomination(vaultAddr, NAV), "RESID"), "source label not stored verbatim");
    }

    /// @notice A batch add is the same insert path as a single-entry one, not a privileged genesis mode: a
    ///         batch and one-at-a-time adds of the same two entries store identical records.
    /// @dev Worth pinning explicitly, because "seed" reads like it might relax the rules. It does not —
    ///      there is no counter, no seed lock, and no special first-write semantics. The predecessor
    ///      made this point by showing that the INVERTED batch and inverted single adds both produced
    ///      the caller residual; with no derivation left, the point is made by the two paths agreeing
    ///      on the stored labels instead.
    function test_addAssetsBatch_hasNoSpecialGenesisSemantics() public {
        (IMarketRegistry.Asset memory batchTerm, IMarketRegistry.Asset memory batchVault, address batchVaultAddr) =
            _pair("BATCH");
        IMarketRegistry.Asset[] memory batch = new IMarketRegistry.Asset[](2);
        batch[0] = batchVault; // dependent first, in one transaction
        batch[1] = batchTerm;
        iReg.addAssets(batch);

        (IMarketRegistry.Asset memory singleTerm, IMarketRegistry.Asset memory singleVault, address singleVaultAddr) =
            _pair("SINGLE");
        iReg.addAssets(one(singleVault)); // dependent first, one at a time
        iReg.addAssets(one(singleTerm));

        assertTrue(
            _eq(_storedDenomination(batchVaultAddr, NAV), _storedDenomination(singleVaultAddr, NAV)),
            "single adds must store the same vault label as the batch"
        );
        assertTrue(
            _eq(_storedDenomination(batchTerm.addr, PRICE), _storedDenomination(singleTerm.addr, PRICE)),
            "single adds must store the same terminator label as the batch"
        );
        assertTrue(_eq(_storedDenomination(singleVaultAddr, NAV), "USD"), "expected the stated label");
    }
}
