// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {stdError} from "forge-std/Test.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {RegistryFixture, mkAsset, mkNavSource, mkPriceSource, noSource} from "./helpers/RegistryFixture.sol";
import {one} from "./helpers/ArrayHelpers.sol";

/// @title AssetEnumOffset.t.sol — the regression guard for `validateAssetEnums`' hard-coded offsets
///
/// @notice DO NOT DELETE THIS SUITE AS REDUNDANT. ITS JOB IS TO GUARD A SILENT FAILURE.
///
///         `MarketRegistryLib.validateAssetEnums` reads three enum ordinals RAW from calldata, in
///         assembly, at hard-coded byte offsets. If one of those numbers goes stale, NOTHING FAILS
///         LOUDLY. The read lands on a different word, the range check silently stops checking the field
///         it names, the `Panic(0x21)` path quietly stops working, and every other test in the repo
///         keeps passing — because every other test encodes its `Asset` through solc, which never
///         produces an out-of-range ordinal in the first place. There is no compiler error, no revert,
///         and no failing assertion anywhere. Only a suite that hand-patches the calldata can see it.
///
///         This has already happened THREE times. First: the predecessor hard-coded `96` for `kind`
///         against the head `addr:0, chainId:32, name-offset:64, kind:96`; dropping `chainId` from
///         `Asset` moved `kind` to `64`. Then: deleting the asset-level `denomination`, which sat between
///         `kind` and `priceSource`, moved the two nested-SOURCE offset words down from 128/160 to 96/128
///         while leaving `kind` alone. Then: turning `AssetSource.denomination` from a string into an
///         address made each source a STATIC tuple, so the two offset words disappeared and the sources
///         moved INLINE into the head at 96 and 224. None of those shifts left a trace of any kind.
///
/// @dev ## How this differs from the enum tests in `AssetStore.t.sol`
///
///      `AssetStore.t.sol` asserts the NEGATIVE half: patch a word to an out-of-range ordinal, expect
///      `Panic(0x21)`. That catches an offset that has drifted onto a word which is not enum-shaped.
///      It does NOT catch an offset that has drifted onto a DIFFERENT ENUM word — the panic fires either
///      way, so the test stays green while the field it claims to check goes unchecked.
///
///      This suite adds the POSITIVE half, which is what actually pins each offset to its own field:
///
///      - Patch the word to a VALID-but-different ordinal and assert the field-specific consequence.
///        `kind ← 1` must come back out of storage as `ERC4626`. `priceSource.sourceType ← 1` must
///        revert `SourceTypeMismatch(PRICE, NAV)`. `navSource.sourceType ← 0` must revert
///        `SourceTypeMismatch(NAV, PRICE)` — DIFFERENT arguments, which is what proves the two source
///        heads are told apart rather than both resolving to the same one.
///      - Assert a word that must NOT be range-checked is not: patching a source's `addr` sails through,
///        so the validator is reading `+32` / `+64` and not `+0`.
///      - Assert the unpatched calldata SUCCEEDS, so a failure here is always about the patch and never
///        about the harness having the layout wrong.
///
///      ## The layout the offsets are derived from
///
///      Stated once here and once in the library. `addAssets(Asset[])` takes an ARRAY of dynamic
///      tuples, so calldata is `selector(4) · array-offset(32) · length(32) · element-offsets · elements`.
///      The tuple no longer sits at a fixed byte, and `_tupleHead` walks in to find it: the array's
///      length word is at `4 + word(4)`, the element-offset region starts one word later, and element
///      0's offset is relative to the START of that region. For a one-element array that lands the
///      tuple at byte 100 — but the harness computes it rather than naming it, because this number
///      moved once already when `addAsset` became `addAssets` and a stale constant does not fail
///      loudly. It lands on a different word, and an out-of-range enum then PASSES the check.
///
///      Whatever `_tupleHead` returns is the value the library's assembly sees as `e`. Its head is
///      ELEVEN words. Only `name` is dynamic; each `AssetSource` is a STATIC four-word tuple (its
///      `denomination` is an address), so both sources are laid out INLINE rather than behind an
///      offset word:
///
///          addr:0 · name-offset:32 · kind:64
///          priceSource: addr:96 · sourceType:128 · sourceInterface:160 · denomination:192
///          navSource:   addr:224 · sourceType:256 · sourceInterface:288 · denomination:320
///
///      It used to be FIVE words with the two sources behind offset words at 96 and 128, back when a
///      source carried a `string` denomination. Making the source static removed the indirection: a
///      source head now sits at a FIXED offset from the tuple head, and `_priceHead` / `_navHead` add
///      that constant instead of reading an offset word. Each source head is four words:
///
///          addr:0 · sourceType:32 · sourceInterface:64 · denomination:96
///
///      All three enums have exactly TWO members, so `0` and `1` are in range and `2` and up are not.
contract AssetEnumOffsetTest is RegistryFixture {
    /// @dev Where the one `Asset` tuple in a one-element `Asset[]` argument begins. Walked in from the
    ///      selector rather than hard-coded — see the layout note on the contract for why a constant
    ///      here would be a silent hazard. This is the number the library's assembly knows as `e`.
    function _tupleHead(bytes memory cd) internal pure returns (uint256) {
        uint256 region = 4 + _readWord(cd, 4) + 32; // past the array offset and its length word
        return region + _readWord(cd, region); // element 0's offset is relative to the region
    }

    /// @dev Word positions inside the `Asset` head, as byte offsets from the tuple head. `KIND_WORD`
    ///      has not moved through any of the three layout changes; the two source heads are now
    ///      INLINE at fixed offsets rather than behind offset words.
    uint256 internal constant KIND_WORD = 64;
    uint256 internal constant PRICE_SOURCE_HEAD = 96;
    uint256 internal constant NAV_SOURCE_HEAD = 224;

    /// @dev Word positions inside an `AssetSource` head, as byte offsets from that head.
    uint256 internal constant SOURCE_ADDR = 0;
    uint256 internal constant SOURCE_TYPE = 32;
    uint256 internal constant SOURCE_INTERFACE = 64;

    address internal token;
    address internal priceAggregator = makeAddr("enumPriceAggregator");
    address internal navVault;
    address internal stranger = makeAddr("enumStranger");

    function setUp() public {
        _deployRegistry(address(this));

        // A {MockERC20}: real code and a readable `decimals()`. `addAsset` no longer probes `asset()`
        // at all, so nothing here depends on the probe — but everything downstream still needs real
        // code, and a local mock is the fixture default. Never a Phoenix `DummyERC20` — those mint on
        // fallback and burn the gas forwarded to them.
        token = _newToken("ENUM", 18);
        navVault = _newToken("ENUMVAULT", 18);
    }

    // ── the harness control: unpatched calldata must succeed ────────────────────────

    /// @notice The unpatched hand-built calldata is accepted and stored. Every other test in this file
    ///         depends on this, so it is asserted rather than assumed.
    /// @dev If this fails, the layout constants above are wrong and every "expected Panic" below is
    ///      passing for the wrong reason. It is the first thing to look at.
    function test_enumOffset_control_unpatchedCalldataSucceeds() public {
        this.rawCall(_dualSourceCalldata());

        (bool found, IMarketRegistry.Asset memory got) = iReg.lookupAssetByAddress(token);
        assertTrue(found, "the hand-built calldata must be a valid addAsset call");
        assertEq(uint256(got.kind), uint256(IMarketRegistry.AssetKind.ERC20));
        assertEq(uint256(got.priceSource.sourceType), uint256(IMarketRegistry.SourceType.PRICE));
        assertEq(uint256(got.navSource.sourceType), uint256(IMarketRegistry.SourceType.NAV));
    }

    // ── AssetKind: offset 64 ────────────────────────────────────────────────────────

    /// @notice An out-of-range `AssetKind` ordinal reverts `Panic(0x21)`.
    /// @dev The negative half. On its own this only proves the word at offset 64 is read by SOME enum
    ///      conversion; `test_enumOffset_kind_validOrdinalIsStored` is what ties it to `kind`.
    function test_enumOffset_kind_outOfRangeOrdinalPanics() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _tupleHead(cd) + KIND_WORD, 2); // members: ERC20 = 0, ERC4626 = 1

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice The word at offset 64 IS `kind`: patched to the other valid ordinal, the add succeeds and
    ///         the asset comes back out of storage as `ERC4626`.
    /// @dev The positive half, and the assertion that actually pins the offset. A stale offset pointing
    ///      at any other word would leave `kind` reading `ERC20` here while the panic test above went
    ///      green on whatever word it had drifted onto.
    function test_enumOffset_kind_validOrdinalIsStored() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _tupleHead(cd) + KIND_WORD, 1);

        this.rawCall(cd);

        (, IMarketRegistry.Asset memory got) = iReg.lookupAssetByAddress(token);
        assertEq(uint256(got.kind), uint256(IMarketRegistry.AssetKind.ERC4626), "offset 64 is not `kind`");
    }

    /// @notice A colossal ordinal panics too — it does not reach the accumulator guard in `addAsset`.
    /// @dev `addAsset` ends its check with `if (validateAssetEnums(e) == type(uint256).max) revert();`,
    ///      which exists ONLY so the optimizer cannot delete the conversions. That bare `revert()` must
    ///      stay unreachable: the enum conversion panics first. If this ever started reverting with empty
    ///      data instead of `Panic(0x21)`, the conversion would have been optimized away and the whole
    ///      check would be doing nothing.
    function test_enumOffset_kind_maxOrdinalStillPanics() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _tupleHead(cd) + KIND_WORD, type(uint256).max);

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    // ── SourceType / SourceInterface on the PRICE source: offsets +32 and +64 ────────

    /// @notice An out-of-range `SourceType` in the PRICE source reverts `Panic(0x21)`.
    function test_enumOffset_priceSourceType_outOfRangeOrdinalPanics() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _priceHead(cd) + SOURCE_TYPE, 2); // members: PRICE = 0, NAV = 1

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice That word IS the PRICE source's `sourceType`: patched to `NAV`, the add is refused with
    ///         `SourceTypeMismatch(PRICE, NAV)` — the field's own error, naming the field's own slot.
    /// @dev The arguments are the assertion. `expected = PRICE` can only come from the price FIELD's
    ///      check, so this pins the word to `priceSource.sourceType` and not to the nav source's.
    function test_enumOffset_priceSourceType_validOrdinalHitsTheFieldsOwnCheck() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _priceHead(cd) + SOURCE_TYPE, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistry.SourceTypeMismatch.selector,
                IMarketRegistry.SourceType.PRICE,
                IMarketRegistry.SourceType.NAV
            )
        );
        this.rawCall(cd);
    }

    /// @notice An out-of-range `SourceInterface` in the PRICE source reverts `Panic(0x21)`.
    function test_enumOffset_priceSourceInterface_outOfRangeOrdinalPanics() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _priceHead(cd) + SOURCE_INTERFACE, 2); // AGGREGATOR_V3 = 0, ERC4626 = 1

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice That word IS the PRICE source's `sourceInterface`: patched to `ERC4626`, the add succeeds
    ///         and storage reads back `ERC4626`.
    /// @dev Distinguishes `+64` from `+32`. Had the two been transposed, the patch would have landed on
    ///      `sourceType` and reverted `SourceTypeMismatch` instead of storing anything.
    function test_enumOffset_priceSourceInterface_validOrdinalIsStored() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _priceHead(cd) + SOURCE_INTERFACE, 1);

        this.rawCall(cd);

        (, IMarketRegistry.Asset memory got) = iReg.lookupAssetByAddress(token);
        assertEq(
            uint256(got.priceSource.sourceInterface),
            uint256(IMarketRegistry.SourceInterface.ERC4626),
            "source head +64 is not `sourceInterface`"
        );
    }

    /// @notice A source's `addr` word is NOT range-checked — patching it to a clean tiny address sails
    ///         through and is stored verbatim.
    /// @dev The over-read guard. `validateAssetEnums` must read `+32` and `+64` of a source head and
    ///      nothing else; an off-by-one-word slip onto `+0` would turn every real aggregator address
    ///      into an out-of-range ordinal and reject every honest asset. Asserting the absence of a panic
    ///      here is what keeps that slip visible.
    function test_enumOffset_sourceAddrWordIsNotRangeChecked() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _priceHead(cd) + SOURCE_ADDR, 2); // a clean, tiny, non-zero address

        this.rawCall(cd);

        (, IMarketRegistry.Asset memory got) = iReg.lookupAssetByAddress(token);
        assertEq(got.priceSource.addr, address(2), "the addr word must be stored, not range-checked");
    }

    // ── SourceType / SourceInterface on the NAV source: offset word 128 ──────────────

    /// @notice An out-of-range `SourceType` in the NAV source reverts `Panic(0x21)`.
    /// @dev The nav source's head offset is a SEPARATELY hard-coded constant (224), so it goes stale
    ///      independently of the price source's.
    function test_enumOffset_navSourceType_outOfRangeOrdinalPanics() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _navHead(cd) + SOURCE_TYPE, 2);

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice That word IS the NAV source's `sourceType`: patched to `PRICE`, the add is refused with
    ///         `SourceTypeMismatch(NAV, PRICE)` — the MIRROR of the price-source case.
    /// @dev The pair of arguments is the whole point. `(NAV, PRICE)` here against `(PRICE, NAV)` in
    ///      `test_enumOffset_priceSourceType_validOrdinalHitsTheFieldsOwnCheck` proves the two source
    ///      heads resolve to two different places. Had offsets 96 and 224 both been read as the same
    ///      head, both tests would still panic on an out-of-range ordinal and only this pair would
    ///      notice.
    function test_enumOffset_navSourceType_validOrdinalHitsTheFieldsOwnCheck() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _navHead(cd) + SOURCE_TYPE, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistry.SourceTypeMismatch.selector,
                IMarketRegistry.SourceType.NAV,
                IMarketRegistry.SourceType.PRICE
            )
        );
        this.rawCall(cd);
    }

    /// @notice An out-of-range `SourceInterface` in the NAV source reverts `Panic(0x21)`.
    function test_enumOffset_navSourceInterface_outOfRangeOrdinalPanics() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _navHead(cd) + SOURCE_INTERFACE, 3);

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    /// @notice An ABSENT source's enum words are range-checked as well — the check does not gate on
    ///         presence.
    /// @dev An honest encoder writes `0` into both words of an absent source, which is in range for both
    ///      enums, so checking it costs a comparison and never rejects an honest caller. A hostile
    ///      encoder can put anything there, and those words are read back by every consumer that decodes
    ///      a stored `Asset`. This also re-checks the nav head offset against a DIFFERENT encoding — an
    ///      absent source's words are all zero, which is exactly what a hostile encoder would not send.
    function test_enumOffset_absentSource_isStillRangeChecked() public {
        bytes memory cd = _priceOnlyCalldata();
        _patchWord(cd, _navHead(cd) + SOURCE_TYPE, 2);

        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    // ── the check runs regardless of caller ─────────────────────────────────────────

    /// @notice A STRANGER submitting a malformed ordinal gets `Panic(0x21)`, not
    ///         `OwnableUnauthorizedAccount`.
    /// @dev `addAsset` calls `validateAssetEnums` BEFORE `_checkOwner()`, alone among the owner-only
    ///      functions. That ordering is what makes this whole offset guard reachable by anyone: a
    ///      malformed enum ordinal is a malformed CALL and fails as one whoever sent it, instead of being
    ///      masked by the authority error for every caller but the owner. A refactor that "tidied up" by
    ///      moving the owner gate first would make the panic path owner-only and this assertion is what
    ///      would catch it.
    function test_enumOffset_panicsBeforeTheOwnerGate() public {
        bytes memory cd = _dualSourceCalldata();
        _patchWord(cd, _tupleHead(cd) + KIND_WORD, 2);

        vm.prank(stranger);
        vm.expectRevert(stdError.enumConversionError);
        this.rawCall(cd);
    }

    // ── calldata plumbing ───────────────────────────────────────────────────────────

    /// @dev Forward hand-built calldata to the registry and re-throw its revert data verbatim, so
    ///      `vm.expectRevert` sees the real selector. `external` because `vm.expectRevert` needs a call
    ///      boundary to attach to.
    function rawCall(bytes memory cd) external {
        (bool ok, bytes memory ret) = address(reg).call(cd);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev An `addAssets` call with BOTH source slots present, each carrying its own matching
    ///      `sourceType` and the same US Dollar denomination. Both present is what makes the two source
    ///      heads distinguishable, and US Dollars is what makes the unpatched control succeed: it is
    ///      seeded into the denomination set by `initialize` and resolves to US Dollars in zero hops.
    ///
    ///      The two sources quoting the SAME unit is a convenience here, not a requirement — each
    ///      present source is validated on its own and the registry never compares them.
    ///
    ///      ONE element, always. The offsets this suite patches are computed for element 0 of a
    ///      one-element array; a second element would move nothing about element 0, but every helper
    ///      below assumes there is only one asset to talk about.
    function _dualSourceCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IMarketRegistry.addAssets.selector,
            one(
                mkAsset(
                    token,
                    "ENUMASSET",
                    IMarketRegistry.AssetKind.ERC20,
                    mkPriceSource(priceAggregator, USD_UNIT),
                    mkNavSource(navVault, USD_UNIT)
                )
            )
        );
    }

    /// @dev An `addAssets` call whose NAV slot is ABSENT — a zeroed struct with a zero `denomination`.
    function _priceOnlyCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IMarketRegistry.addAssets.selector,
            one(
                mkAsset(
                    token,
                    "ENUMASSET",
                    IMarketRegistry.AssetKind.ERC20,
                    mkPriceSource(priceAggregator, USD_UNIT),
                    noSource()
                )
            )
        );
    }

    /// @dev Absolute byte offset of the PRICE source's head. A static tuple sits inline, so this is a
    ///      fixed distance from the tuple head — no offset word to read, and `name`'s length does not
    ///      move it.
    function _priceHead(bytes memory cd) internal pure returns (uint256) {
        return _tupleHead(cd) + PRICE_SOURCE_HEAD;
    }

    /// @dev Absolute byte offset of the NAV source's head.
    function _navHead(bytes memory cd) internal pure returns (uint256) {
        return _tupleHead(cd) + NAV_SOURCE_HEAD;
    }

    function _readWord(bytes memory cd, uint256 byteOffset) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(cd, add(0x20, byteOffset)))
        }
    }

    function _patchWord(bytes memory cd, uint256 byteOffset, uint256 value) internal pure {
        assembly {
            mstore(add(cd, add(0x20, byteOffset)), value)
        }
    }
}
