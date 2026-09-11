// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketRegistryLib} from "../src/MarketRegistryLib.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {
    WalkTestBase,
    TenAssetSet,
    mkNavSource,
    mkPriceSource,
    mkSourcelessAsset,
    noSource
} from "./fixtures/TenAssetSet.sol";
import {
    MockERC20,
    MockVaultAsset,
    RevertingAsset,
    ShortReturnAsset,
    EmptyReturnAsset,
    DirtyBitsAsset,
    ZeroAddressAsset,
    GasBurningAsset,
    ReturnBombAsset,
    SelfLoopAsset,
    CycleNodeAsset,
    WriteVictim,
    ReentrantProbeAsset,
    WellFormedLiarAsset
} from "./mocks/HostileAssets.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title WalkHarness — the ONLY caller of `MarketRegistryLib.deriveDenomination` left anywhere
/// @notice A `MarketRegistry` plus one external `view` that runs the underlying-asset walk against the
///         registry's own asset store, so a test can read the walk's RETURN VALUE.
/// @dev THIS HARNESS EXISTS BECAUSE THE WALK IS NO LONGER ON ANY PRODUCTION PATH. `_addAsset` used to
///      call `deriveDenomination`, take its answer over the caller's, and pin the winner into
///      `Asset.denomination`. That field is deleted: the denomination lives on each `AssetSource` and is
///      validated per source, so there is nothing left to pin and nothing for the walk to feed.
///
///      `deriveDenomination` was nevertheless kept, deliberately, and this harness is what keeps it
///      honest. It is the on-chain AUTHORITY on what an asset's real denomination is, because it probes
///      `asset()` live rather than trusting a hand-written rule or a label a proposer typed — and the
///      onboarding tooling derives denominations by simulating against a fork, so the library it
///      simulates has to keep working. Deleting the suite would leave that function unexercised.
///
///      Subclassing rather than mirroring the store is the whole point. The walk's mid-chain terminal
///      reads the REGISTRY'S OWN `_assetIndex` / `_assets`, so a test seeds a terminator with a plain
///      `iReg.addAssets(one(...))` and the walk sees it. A separate mock store would have to be kept in step
///      by hand, and the first divergence would be a silently wrong test.
contract WalkHarness is MarketRegistry {
    /// @notice Run the underlying-asset walk for `e` and return what it derived.
    /// @dev The zero address is UNRESOLVED and is a real answer, not an error — the walk has no revert of
    ///      its own any more. `view`, so solc reaches it with a `STATICCALL`, which is what keeps the
    ///      reentrant-probe test meaningful.
    function derive(IMarketRegistry.Asset calldata e) external view returns (address) {
        return MarketRegistryLib.deriveDenomination(_assetIndex, _assets, e);
    }
}

/// @title Walk.t.sol — underlying-asset walk + hostile-probe suite
///
/// @notice THE WALK IS NO LONGER ON THE `addAsset` PATH. Read that sentence before reading any test
///         below, because it changes what every assertion in this file can possibly mean.
///
///         `MarketRegistryLib.deriveDenomination` is not called from anywhere in `src/`. It is reachable
///         only from here, through {WalkHarness}. The suite is kept — and must not be deleted as dead —
///         because the walk is the on-chain authority on an asset's real denomination: it derives the
///         answer by probing `asset()` live, which is exactly the property the onboarding tool depends
///         on when it simulates a proposal against a fork. What this suite guards is therefore a LIBRARY
///         FUNCTION HELD FOR THAT AUTHORITY, not a step in a write path.
///
/// @dev Covers every walk terminal (depth cap, cycle / self-loop, the registered-denominated terminal,
///      the leaf source-denomination rule, the unregistered mid-chain leaf, the sourceless entry) and
///      the hostile-shape probe matrix.
///
///      ## What the successor shape changed here, in four points
///
///      1. **There is no caller residual and no `EmptyDenomination`.** The asset-level `denomination`
///         field is deleted, so there is no caller-supplied value for the walk to fall back to and no
///         post-walk guard to fire. Every terminal that used to "fall to the residual" now simply
///         returns the EMPTY STRING, and the empty string is a legitimate answer meaning UNRESOLVED.
///         The `EmptyDenomination` and `EmptySources` selectors are deleted from `IMarketRegistry`, so
///         no assertion here names either one, and none was re-pointed at a substitute selector.
///      2. **Nothing the walk derives is stored.** Assertions moved from `_storedDenomination(...)` —
///         which now only reads back the label a source STATED — to `_derive(...)`, which is the walk's
///         return value. Reading storage would have been asserting that `addAsset` copied a string.
///      3. **The malformed-probe reverts now bubble out of the WALK, not out of `addAsset`.** `addAsset`
///         does not probe, so it accepts a hostile-shaped asset without complaint. The uncatchable
///         ABI-decode revert is still real; it is just reachable through `derive` only.
///      4. **A sourceless asset is legal.** `mkSourcelessAsset` builds the state `EmptySources` used to
///         forbid, and the walk answers UNRESOLVED for it without reverting.
///
///      ## Malformed probe returns BUBBLE, and there is no selector to name
///
///      `probeAsset` is a `try`/`catch` around `asset()`. A SUCCESS that returns fewer than 32 bytes, no
///      bytes at all, or a dirty word makes the ABI decode revert in the LIBRARY's own frame, where
///      `catch` cannot see it. That revert carries no error data, so those tests assert an empty-data
///      failure through a raw call rather than `vm.expectRevert` — there is no selector, and a bare
///      `vm.expectRevert()` would accept any revert at all, including the ones they exist to rule out.
contract WalkTest is WalkTestBase {
    /// @dev The registry every test here uses, typed as the harness so `derive` is reachable.
    WalkHarness internal walkReg;

    function setUp() public override {
        super.setUp();

        // Re-point the whole suite at a HARNESS registry. It is a `MarketRegistry` with one extra
        // external view on it, so `iReg`, `_storedDenomination`, `_addFeed` and every other fixture
        // helper keep working unchanged; `reg` is assignable because `WalkHarness` derives from
        // `MarketRegistry`. The fixture's own `_deployRegistry` is not modified for this — one suite
        // needing a subclass is not a reason to push a test-only entrypoint into the shared harness.
        walkReg = new WalkHarness();
        walkReg.initialize(address(this), address(wrapperFactory), address(fixedRateOracleFactory));
        reg = walkReg;
        iReg = IMarketRegistry(address(walkReg));

        // `super.setUp()` put the `ETH → USD` edge on the registry it deployed, so the harness needs its
        // own copy before any `"ETH"`-denominated source is writable here.
        _addEthUsdFeed();
    }

    // ── the leaf source-denomination terminal ─────────────────────────────────────

    /// @notice Two present sources carrying the SAME denomination derive it.
    function test_walk_leafAgreeingSources_derives() public {
        address a = address(new RevertingAsset()); // probe reverts → leaf; cur == e.addr
        IMarketRegistry.Asset memory e =
            _asset2(a, "AGREE", mkPriceSource(makeAddr("srcA"), USD_UNIT), mkNavSource(makeAddr("srcB"), USD_UNIT));

        assertEq(_derive(e), USD_UNIT);
    }

    /// @notice Two present sources whose denominations DISAGREE ("USD" on the price source, "ETH" on the
    ///         net-asset-value source) leave the walk UNRESOLVED — and `addAsset` accepts the entry
    ///         anyway.
    /// @dev Both halves matter and they used to be one contradiction. The registry validates each
    ///      present source's label SEPARATELY and never compares the two, because the two legs of a
    ///      Morpho oracle resolve their conversion paths independently — so disagreement is legal. What
    ///      disagreement costs is the walk: there is no single unit that speaks for the whole asset, so
    ///      `leafQuote` returns the zero address.
    ///
    ///      Migrated from "the caller residual stands". There is no residual to stand any more, so the
    ///      assertion is the zero address, which is UNRESOLVED and not an error.
    function test_walk_leafDisagreeingSources_unresolvedButAccepted() public {
        address a = address(new RevertingAsset());
        IMarketRegistry.Asset memory e =
            _asset2(a, "DISAGREE", mkPriceSource(makeAddr("srcA"), USD_UNIT), mkNavSource(makeAddr("srcB"), ETH_UNIT));

        assertEq(_derive(e), address(0), "disagreeing sources give the walk no single unit");

        iReg.addAssets(one(e));
        assertEq(_storedDenomination(a, IMarketRegistry.SourceType.PRICE), USD_UNIT);
        assertEq(_storedDenomination(a, IMarketRegistry.SourceType.NAV), ETH_UNIT, "both units are stored as stated");
    }

    /// @notice A ZERO `denomination` on a PRESENT source is refused at write time, naming the zero
    ///         address — it never reaches the walk.
    /// @dev The zero address is not a registered denomination, so `_validateSourcePath` rejects the
    ///      source before anything else runs. This is what the deleted `EmptyDenomination` guard is NOT:
    ///      that one fired once, after a walk, about a field that no longer exists; this one fires per
    ///      present source, at write time, about the unit that source states. Different question, and
    ///      the answer here is strictly stronger — a missing unit fails loudly instead of quietly
    ///      falling back to something the caller supplied.
    function test_walk_leafZeroDenomination_rejectedAtWriteTime() public {
        address a = address(new RevertingAsset());
        IMarketRegistry.Asset memory e = _asset2(
            a, "EMPTYQUOTE", mkPriceSource(makeAddr("srcA"), USD_UNIT), mkNavSource(makeAddr("srcB"), address(0))
        );

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, address(0)));
        iReg.addAssets(one(e));
    }

    /// @notice A leaf derives from its source's `denomination` WITHOUT the walk ever calling the source
    ///         contract. The source address here reverts on every call, yet the walk resolves.
    function test_walk_acrdxShapedLeaf_derivesWithoutCallingSource() public {
        address a = address(new RevertingAsset()); // e.addr leaf
        address sourceThatRevertsIfCalled = address(new RevertingAsset());

        // Had the walk called the source, this would have bubbled instead of returning a unit.
        assertEq(_derive(_asset1(a, "ACRDX", mkPriceSource(sourceThatRevertsIfCalled, USD_UNIT))), USD_UNIT);
    }

    /// @notice An asset with NEITHER source is UNRESOLVED, and both the walk and `addAsset` accept it
    ///         without reverting.
    /// @dev This is the state the deleted `EmptySources` error used to forbid. It is now a legal entry:
    ///      with no source present there is no denomination anywhere on it, so there is nothing for the
    ///      leaf rule to read and nothing that has to reach US Dollars. The walk says so by returning
    ///      the zero address, which is why zero had to stop meaning "error" — see the deleted
    ///      `EmptyDenomination` note in the file header.
    ///
    ///      The address must be a real CONTRACT even though nothing about the asset is source-shaped:
    ///      the walk still probes `asset()` on the head, and a codeless address makes that probe's ABI
    ///      decode revert uncatchably (see `test_probe_emptyReturn_bubblesUncatchably`).
    function test_walk_sourcelessAsset_unresolvedButAccepted() public {
        address a = address(new RevertingAsset());
        IMarketRegistry.Asset memory e = mkSourcelessAsset(a, "SOURCELESS");

        assertEq(_derive(e), address(0), "no source means no unit for the leaf rule to read");

        iReg.addAssets(one(e));
        (bool found, IMarketRegistry.Asset memory got) = iReg.lookupAssetByAddress(a);
        assertTrue(found, "a sourceless asset is a legal entry");
        assertEq(got.priceSource.addr, address(0));
        assertEq(got.navSource.addr, address(0));
    }

    // ── the registered-denominated terminal (a hop that lands on a stored asset) ──

    /// @notice A vault hops through `asset()` onto an already-stored asset and derives THAT asset's
    ///         denomination.
    /// @dev The mid-chain terminal reads the registry's own asset store, which is the whole reason the
    ///      harness subclasses `MarketRegistry` rather than mirroring a store of its own: the terminator
    ///      is seeded with a plain `addAsset` and the walk finds it.
    function test_walk_hopToRegisteredTerminator_derives() public {
        address term = address(new RevertingAsset());
        iReg.addAssets(one(_asset1(term, "TERM", mkPriceSource(term, USD_UNIT))));

        address vault = address(new MockVaultAsset(term));
        IMarketRegistry.Asset memory e = _asset2(vault, "VAULT", noSource(), mkNavSource(vault, USD_UNIT));

        assertEq(_derive(e), USD_UNIT, "the hop must inherit the terminator's denomination");
    }

    /// @notice A derived terminal BEATS the head's own source label: the vault below states "USD" on its
    ///         source but hops onto a terminator denominated in Ether, and Ether is what the walk returns.
    /// @dev The leaf rule is only consulted when the head does not hop. Ordering the two the other way
    ///      round would let a unit somebody typed outrank a live chain read — which would defeat the
    ///      entire reason this function was kept.
    function test_walk_hopTerminalBeatsLeafQuote() public {
        address term = address(new RevertingAsset());
        iReg.addAssets(one(_asset1(term, "ETHTERM2", mkPriceSource(term, ETH_UNIT))));

        address vault = address(new MockVaultAsset(term));
        IMarketRegistry.Asset memory e = _asset2(vault, "HEADTERM", noSource(), mkNavSource(vault, USD_UNIT));

        assertEq(_derive(e), ETH_UNIT, "the hop terminal must outrank the leaf unit");
    }

    /// @notice A mid-chain leaf that is NOT a stored asset is UNRESOLVED — the walk hops once, finds
    ///         nothing registered, and returns the zero address.
    /// @dev This is the case that used to be `test_walk_unresolvableWithEmptyCaller_reverts`
    ///      asserting `EmptyDenomination`. Nothing reverts now: the walk returns UNRESOLVED and
    ///      `addAsset` stores the entry regardless, because the NAV source's own unit is registered and
    ///      reachable and that is the only question the write path asks.
    function test_walk_unregisteredMidChainLeaf_unresolvedButAccepted() public {
        address underlying = address(new MockERC20("Nobody", "NOBODY", 18));
        address vault = address(new MockVaultAsset(underlying));
        IMarketRegistry.Asset memory e = _asset2(vault, "UNRESEMPTY", noSource(), mkNavSource(vault, USD_UNIT));

        assertEq(_derive(e), address(0), "an unregistered mid-chain leaf resolves to nothing");

        iReg.addAssets(one(e));
        assertEq(_storedDenomination(vault, IMarketRegistry.SourceType.NAV), USD_UNIT, "the stated unit is stored");
    }

    // ── cycle / self-loop ─────────────────────────────────────────────────────────

    /// @notice A two-node cycle (A→B→A) is detected and the walk returns UNRESOLVED.
    function test_walk_cycleInAssetChain_unresolved() public {
        CycleNodeAsset a = new CycleNodeAsset();
        CycleNodeAsset b = new CycleNodeAsset();
        a.setNext(address(b));
        b.setNext(address(a)); // B unstored → the hop back to A trips cycle detection

        IMarketRegistry.Asset memory e = _asset2(address(a), "CYCLE", noSource(), mkNavSource(address(a), USD_UNIT));

        assertEq(_derive(e), address(0));
    }

    // ── depth limit ───────────────────────────────────────────────────────────────

    /// @notice A 12-deep chain exceeds `MAX_DEPTH` (10) and is UNRESOLVED; a 3-deep control chain
    ///         resolves normally. Proves depth — not a missing terminal — is the discriminator.
    function test_walk_depthLimitExceeded_unresolved() public {
        // Stored terminators both chains eventually point at.
        address deepTerminator = address(new RevertingAsset());
        iReg.addAssets(one(_asset1(deepTerminator, "DEEPTERM", mkPriceSource(deepTerminator, USD_UNIT))));
        address ctrlTerminator = address(new RevertingAsset());
        iReg.addAssets(one(_asset1(ctrlTerminator, "CTRLTERM", mkPriceSource(ctrlTerminator, USD_UNIT))));

        // 12-hop chain: head → 11 intermediates → deepTerminator. Bails past depth 10.
        address deepHead = _buildChain(deepTerminator, 12);
        IMarketRegistry.Asset memory deep = _asset2(deepHead, "DEEPHEAD", noSource(), mkNavSource(deepHead, USD_UNIT));
        assertEq(_derive(deep), address(0), "12-deep must exceed the cap and resolve to nothing");

        // 3-hop control chain reaches its terminator well inside the cap.
        address ctrlHead = _buildChain(ctrlTerminator, 3);
        IMarketRegistry.Asset memory ctrl = _asset2(ctrlHead, "CTRLHEAD", noSource(), mkNavSource(ctrlHead, USD_UNIT));
        assertEq(_derive(ctrl), USD_UNIT, "3-deep control must resolve");
    }

    // ── hostile-probe matrix: shapes the probe CATCHES → leaf ──────────────────────

    /// @notice `asset()` reverting is caught: the node degrades to a leaf and the leaf rule answers.
    function test_probe_assetReverts_degradesToLeaf() public {
        address a = address(new RevertingAsset());

        assertEq(_derive(_asset1(a, "PROBEREVERT", mkPriceSource(a, USD_UNIT))), USD_UNIT);
    }

    /// @notice A target with NO `asset()` at all — a plain token — is caught the same way.
    /// @dev A local {MockERC20}, deliberately NOT a Phoenix `DummyERC20`: those mint on fallback, so the
    ///      probe would burn essentially all the gas forwarded to it and the failure would look like a
    ///      library bug.
    function test_probe_noAssetFunction_degradesToLeaf() public {
        address a = address(new MockERC20("Plain", "PLAIN", 6));

        assertEq(_derive(_asset1(a, "PLAINTOKEN", mkPriceSource(a, USD_UNIT))), USD_UNIT);
    }

    /// @notice A clean ZERO-address return is refused as a hop (never a hop to `address(0)`) → leaf.
    function test_probe_zeroAddressReturn_degradesToLeaf() public {
        address a = address(new ZeroAddressAsset());

        assertEq(_derive(_asset1(a, "ZEROADDR", mkPriceSource(a, USD_UNIT))), USD_UNIT);
    }

    /// @notice A SELF-REFERENCE is caught by the cycle log, not by a special case: the head is recorded
    ///         as seen before the probe runs, so `asset() == address(this)` terminates the walk instead
    ///         of looping.
    /// @dev The load-bearing fact is that the call RETURNS at all. An unguarded self-loop would spin
    ///      until the gas ran out, so a clean UNRESOLVED is the observable difference.
    function test_probe_selfReference_hitsCycleGuard() public {
        address a = address(new SelfLoopAsset());
        IMarketRegistry.Asset memory e = _asset2(a, "SELFREF", noSource(), mkNavSource(a, USD_UNIT));

        assertEq(_derive(e), address(0));
    }

    /// @notice A three-node cycle (A→B→C→A) terminates too — the guard scans every prior node, not just
    ///         the immediate predecessor.
    function test_probe_multiNodeCycle_hitsCycleGuard() public {
        CycleNodeAsset a = new CycleNodeAsset();
        CycleNodeAsset b = new CycleNodeAsset();
        CycleNodeAsset c = new CycleNodeAsset();
        a.setNext(address(b));
        b.setNext(address(c));
        c.setNext(address(a));

        IMarketRegistry.Asset memory e = _asset2(address(a), "CYCLE3", noSource(), mkNavSource(address(a), USD_UNIT));

        assertEq(_derive(e), address(0));
    }

    /// @notice A 100-kilobyte return whose FIRST word is a clean address is accepted and hopped: the
    ///         return bomb costs memory-expansion gas and cannot brick the walk.
    /// @dev The one shape the current probe treats MORE permissively than the predecessor, which copied
    ///      at most 32 bytes and rejected anything larger. The bomb points at a stored terminator, so a
    ///      successful hop is observable as a derived denomination rather than merely as an absence of
    ///      failure.
    function test_probe_returnBomb_hopsAndDoesNotBrick() public {
        address term = address(new RevertingAsset());
        iReg.addAssets(one(_asset1(term, "BOMBTERM", mkPriceSource(term, ETH_UNIT))));

        address bomb = address(new ReturnBombAsset(term, 100_000));
        IMarketRegistry.Asset memory e = _asset2(bomb, "BOMB", noSource(), mkNavSource(bomb, USD_UNIT));

        assertEq(_derive(e), ETH_UNIT, "a bomb with a clean first word must still hop");
    }

    /// @notice A well-formed LIE (clean, non-zero, but the wrong underlying) is undetectable on-chain:
    ///         the probe accepts it and hops. Detection is admission-gated.
    function test_probe_wellFormedLiar_hopsAccepted() public {
        address ethTerminator = address(new RevertingAsset());
        iReg.addAssets(one(_asset1(ethTerminator, "ETHTERM", mkPriceSource(ethTerminator, ETH_UNIT))));

        address liar = address(new WellFormedLiarAsset(ethTerminator));
        IMarketRegistry.Asset memory e = _asset2(liar, "LIAR", noSource(), mkNavSource(liar, USD_UNIT));

        // The undetectable lie is followed, so the walk speaks for the node the liar named.
        assertEq(_derive(e), ETH_UNIT);
    }

    /// @notice A reentrant probe attempting a state write during the probe cannot write: the victim
    ///         counter stays 0, and the node degrades to a leaf.
    /// @dev `derive` is `view`, so solc reaches it with a `STATICCALL` and any `SSTORE` below it throws
    ///      in the callee's frame. The mock swallows that failure and returns `address(0)`, which the
    ///      probe reads as a leaf.
    ///
    ///      The load-bearing assertion is `counter == 0`. The denomination assertion corroborates it: the
    ///      node was CAUGHT rather than hopped, so the leaf rule ran and answered from the NAV source's
    ///      own label.
    function test_probe_reentrantWrite_cannotWrite() public {
        WriteVictim victim = new WriteVictim();
        bytes memory payload = abi.encodeWithSelector(WriteVictim.poke.selector);
        address a = address(new ReentrantProbeAsset(address(victim), payload));

        IMarketRegistry.Asset memory e = _asset2(a, "REENTRANT", noSource(), mkNavSource(a, USD_UNIT));

        assertEq(_derive(e), USD_UNIT, "a caught probe must fall through to the leaf rule");
        assertEq(victim.counter(), 0, "the probe must not be able to write");
    }

    /// @notice A probe target that BURNS the gas forwarded to it makes the walk cost essentially the
    ///         WHOLE budget it was given — `probeAsset` forwards everything it has and caps nothing.
    /// @dev This pins a real consequence of the S2 reversal recorded on `probeAsset`. The predecessor's
    ///      assembly probe capped the sub-call at 50,000 gas; `try IWrapper(target).asset()` forwards
    ///      63/64 of the remaining gas instead. The burner's `asset()` writes storage, so under the
    ///      `STATICCALL` the walk makes it aborts EXCEPTIONALLY rather than with a plain revert, and an
    ///      exceptional abort consumes every unit of gas that was forwarded to it. The walk keeps only
    ///      the 1/64 it withheld.
    ///
    ///      The assertion is a PAIR, and it has to be. An absolute gas number would be a brittle
    ///      snapshot of the compiler, so the test measures the SAME walk shape twice under the same
    ///      8,000,000 cap — once against a burner, once against an honest leaf — and asserts the burner
    ///      costs orders of magnitude more. That is the claim "the probe caps nothing" stated in the only
    ///      terms that are observable from outside.
    ///
    ///      This is documented behaviour, not a defect claim. It IS the reason a walk over a hostile
    ///      token can be unaffordable on a real chain, which is why it is pinned rather than left as
    ///      folklore. Note it no longer says anything about `addAsset`: the write path does not probe, so
    ///      a hostile token is now perfectly addable and only the walk pays.
    function test_probe_gasBurningProbe_consumesTheWholeBudget() public {
        address burner = address(new GasBurningAsset());
        address honest = address(new RevertingAsset());

        uint256 burnerCost = _deriveGasCost(_asset2(burner, "GASBURN", noSource(), mkNavSource(burner, USD_UNIT)));
        uint256 honestCost = _deriveGasCost(_asset2(honest, "HONEST", noSource(), mkNavSource(honest, USD_UNIT)));

        assertLt(honestCost, 100_000, "an honest leaf walk is cheap");
        assertGt(burnerCost, 7_000_000, "an uncapped probe against a gas burner consumes the whole budget");
    }

    // ── hostile-probe matrix: MALFORMED returns that bubble ────────────────────────
    //
    // These are the deliberate reversal recorded on `probeAsset`: a target either implements `asset()`
    // returning a proper address, or does not implement it at all. A target that RETURNS MALFORMED DATA
    // makes solc's return-data decode revert inside the LIBRARY's own frame, where `try`/`catch` cannot
    // reach it, and the revert bubbles out of the walk carrying NO error data. The assertions therefore
    // go through a raw call: there is no selector to name, and a bare `vm.expectRevert()` would accept
    // literally any revert, including the ones these tests exist to distinguish from.
    //
    // These used to be asserted against `addAsset`, which probed. It does not probe any more, so the
    // bubble is reachable through the walk only — and `addAsset` will happily store every one of these
    // shapes, which is why each test below also confirms the write path is unbothered.

    /// @notice A short (<32-byte) `asset()` return bubbles out of the walk with empty revert data.
    function test_probe_shortReturn_bubblesUncatchably() public {
        address a = address(new ShortReturnAsset());
        IMarketRegistry.Asset memory e = _asset2(a, "SHORTRET", noSource(), mkNavSource(a, USD_UNIT));

        (bool ok, bytes memory ret) = _tryDerive(e);
        assertFalse(ok, "a short probe return must not be reclassified as a leaf");
        assertEq(ret.length, 0, "the ABI-decode revert carries no error data");

        // The write path never probes, so the same entry stores without complaint.
        iReg.addAssets(one(e));
        (bool found,) = iReg.lookupAssetByAddress(a);
        assertTrue(found, "addAsset does not probe, so a malformed target is still addable");
    }

    /// @notice A ZERO-LENGTH `asset()` return bubbles the same way.
    /// @dev This is also exactly what a call to an address with NO CODE looks like, which is why a
    ///      codeless address cannot be walked. `probeAsset`'s NatSpec spells that out; it is easy to get
    ///      backwards, because a `staticcall` to a codeless address SUCCEEDS and returns zero bytes.
    function test_probe_emptyReturn_bubblesUncatchably() public {
        address a = address(new EmptyReturnAsset());

        (bool ok, bytes memory ret) = _tryDerive(_asset2(a, "EMPTYRET", noSource(), mkNavSource(a, USD_UNIT)));
        assertFalse(ok, "an empty probe return must not be reclassified as a leaf");
        assertEq(ret.length, 0, "the ABI-decode revert carries no error data");
    }

    /// @notice A 32-byte return with DIRTY upper bits bubbles rather than being masked into an address.
    /// @dev The low 160 bits of the mock's word form a plausible-looking address. An implementation that
    ///      masked instead of validating would have hopped to a fabricated node.
    function test_probe_dirtyBits_bubblesUncatchably() public {
        address a = address(new DirtyBitsAsset());

        (bool ok, bytes memory ret) = _tryDerive(_asset2(a, "DIRTYBITS", noSource(), mkNavSource(a, USD_UNIT)));
        assertFalse(ok, "a dirty address word must not be masked into a hop");
        assertEq(ret.length, 0, "the ABI-decode revert carries no error data");
    }

    /// @notice The bubble happens MID-CHAIN too: a well-formed vault over a malformed one takes the
    ///         whole walk down, it does not degrade the bad node to a leaf.
    function test_probe_malformedMidChain_bubblesUncatchably() public {
        address bad = address(new ShortReturnAsset());
        address head = address(new MockVaultAsset(bad));

        (bool ok, bytes memory ret) = _tryDerive(_asset2(head, "MIDCHAINBAD", noSource(), mkNavSource(head, USD_UNIT)));
        assertFalse(ok, "a malformed node mid-chain must bubble");
        assertEq(ret.length, 0, "the ABI-decode revert carries no error data");
    }

    // ── the write-time unit check (what replaced the post-walk guard) ──────────────

    /// @notice A source's `denomination` must be a REGISTERED unit, so an unregistered value can never
    ///         enter the store in the first place.
    /// @dev The write path's whole denomination rule, and the reason the walk needs no guard of its own.
    ///      It used to matter that a DERIVED value be registered too, because the derived value got
    ///      pinned onto the asset; nothing is pinned now, so the only question left is about the unit a
    ///      source states.
    function test_walk_sourceDenominationMustBeRegistered() public {
        address a = address(new RevertingAsset());
        address madeUpUnit = makeAddr("madeUpUnit");
        IMarketRegistry.Asset memory e = _asset1(a, "UNREGQUOTE", mkPriceSource(a, madeUpUnit));

        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.UnregisteredDenomination.selector, madeUpUnit));
        iReg.addAssets(one(e));
    }

    // ── the ten-asset replica ─────────────────────────────────────────────────────

    /// @notice The whole deterministic replica seeds in dependency order and every entry stores the
    ///         denomination the fixture predicts.
    /// @dev `expected[i]` used to mean "what the walk will derive and pin". With no walk on the write
    ///      path it means "the unit this entry's one present source states, which `addAsset` must store
    ///      verbatim". The values are unchanged; the claim is now about faithful storage.
    ///
    ///      Which of the two slots to read follows the entry itself rather than a hard-coded band table,
    ///      so the assertion survives the topology being extended.
    function test_walk_tenAssetSet_storesExpected() public {
        TenAssetSet fixtureSet = new TenAssetSet();
        (IMarketRegistry.Asset[] memory entries, address[] memory expected) = fixtureSet.build();

        iReg.addAssets(entries);

        for (uint256 i = 0; i < entries.length; i++) {
            IMarketRegistry.SourceType which = entries[i].priceSource.addr != address(0)
                ? IMarketRegistry.SourceType.PRICE
                : IMarketRegistry.SourceType.NAV;
            assertEq(_storedDenomination(entries[i].addr, which), expected[i], entries[i].name);
        }

        (, uint256 total) = iReg.getAssets(0, entries.length + 5);
        assertEq(total, entries.length, "every fixture entry should be stored");
    }

    // ── internal helpers ──────────────────────────────────────────────────────────

    /// @dev The walk's return value for `e`. This — not `_storedDenomination` — is what a walk assertion
    ///      has to read now, because nothing the walk derives is ever written anywhere.
    function _derive(IMarketRegistry.Asset memory e) internal view returns (address) {
        return walkReg.derive(e);
    }

    /// @dev Raw `derive` call that never bubbles, so a test can assert on EMPTY revert data. A malformed
    ///      probe return reverts with no selector at all (see `probeAsset`), and an empty-data revert is
    ///      not something `vm.expectRevert` can name.
    function _tryDerive(IMarketRegistry.Asset memory e) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(walkReg).call(abi.encodeWithSelector(WalkHarness.derive.selector, e));
    }

    /// @dev Gas consumed by one `derive` call under a fixed 8,000,000 cap, whatever its outcome. The cap
    ///      is generous — far more than an honest walk needs, well under a mainnet block limit — so the
    ///      number it returns is about how much of the budget the PROBE took, not about a tight bound.
    function _deriveGasCost(IMarketRegistry.Asset memory e) internal returns (uint256) {
        bytes memory payload = abi.encodeWithSelector(WalkHarness.derive.selector, e);
        uint256 before = gasleft();
        (bool ok,) = address(walkReg).call{gas: 8_000_000}(payload);
        uint256 used = before - gasleft();
        ok; // the outcome is not the claim here; the cost is
        return used;
    }

    /// @dev Build a linear vault chain of `hops` unstored nodes whose tail points at `terminal`. Returns
    ///      the head. Walking from the head needs exactly `hops` probe hops to reach `terminal`.
    function _buildChain(address terminal, uint256 hops) internal returns (address head) {
        address prev = terminal;
        for (uint256 i = 0; i < hops; i++) {
            prev = address(new MockVaultAsset(prev));
        }
        head = prev;
    }
}
