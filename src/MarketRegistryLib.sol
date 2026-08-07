// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMarketRegistry} from "./interfaces/IMarketRegistry.sol";
import {IWrapper} from "./interfaces/IWrapper.sol";

/// @title MarketRegistryLib
/// @notice Stateless helper logic for `MarketRegistry` — key derivation, store plumbing,
///         pagination, structural validators, the denomination walk, and the bounded hop-graph
///         search.
/// @dev Every function is `internal`, so the library is inlined into its consumer's bytecode: no
///      separate deployment, no delegatecall, and NO storage of its own (libraries never add slots,
///      so `MarketRegistry`'s storage layout is unchanged by this split). The functions that touch
///      registry state take the relevant storage arrays/mappings as explicit references; the rest
///      are pure/view. Event emission stays in the contract — the library never emits.
///
///      Two consumers, not one. `MarketRegistry` uses all of it; RECIPE CONTRACTS import it for
///      `applyBands` alone. Being all-`internal` is what makes that free for a recipe: no library
///      deployment to link against, just inlined arithmetic.
library MarketRegistryLib {
    // ── compile-time constants (§17 — single source of truth) ──────────────────

    /// @dev Walk hop cap for the underlying-asset walk in `deriveDenomination`. [RFC §10.2]
    ///      Unrelated to the conversion-feed hop budget in `resolvePath`, which is 1 or 2 and is set
    ///      by how many Morpho oracle feed slots the asset's source left free.
    uint256 internal constant MAX_DEPTH = 10;

    /// @dev The 100% mark for every percentage a RECIPE stores, following the Phoenix convention:
    ///      percentages carry 18 decimals and `1e18` means ONE PERCENT, so 100% is `100e18` and
    ///      every percentage arithmetic site divides by this. Phoenix's own
    ///      `MathHelper.calculatePercentageFee` divides by `100e18` for exactly this reason.
    ///
    ///      Do NOT confuse this with the rate scale. A RATE is a plain 18-decimal fixed-point number
    ///      where `1e18` means 1.0 (`IRateOracle.rate()`), while a PERCENTAGE here uses `1e18` for
    ///      1%. The two conventions differ by a factor of 100, and `applyBands` is the one place they
    ///      meet — which is why the conversion lives in a single named helper rather than being
    ///      open-coded at call sites. The registry stores no percentages; recipes do, and they call in
    ///      here to convert. Keep it that way: two copies of this arithmetic is a 100x error waiting
    ///      for the copy that drifts.
    uint256 internal constant PERCENTAGE_DENOMINATOR = 100e18;

    /// @dev Chainlink `Denominations` pseudo-address for US Dollars. A pseudo-address is a fixed,
    ///      code-less sentinel Chainlink assigns to a denomination that has no token of its own; it is
    ///      never called.
    ///
    ///      Two jobs. (1) It is the TERMINUS of `resolvePath`: the Morpho oracle always works in US
    ///      Dollars, so every bridge walk ends here, and a unit that already IS this sentinel needs no
    ///      bridge at all (the oracle reads a zero feed as the price 1). (2) It is the SEED VALUE the
    ///      `"USD"` label is registered against — nothing in this library maps a string to it; the
    ///      owner registers `"USD" → USD_DENOMINATION` once and the registry reads that mapping.
    address internal constant USD_DENOMINATION = 0x0000000000000000000000000000000000000348;

    /// @dev Chainlink `Denominations` pseudo-address for Ether. ONE job: it is the seed value the
    ///      `"ETH"` label is registered against in the denomination registry. Never called.
    ///
    ///      `resolvePath` does NOT name it as an intermediate — it iterates the registered
    ///      denominations, and Ether is simply one of them. It happens to be the first candidate tried
    ///      in practice, only because the constructor seeds `"USD"` and `"ETH"` before the owner
    ///      registers anything else and candidates are walked in registration order. That is a gas
    ///      ordering, not a rule.
    address internal constant ETH_DENOMINATION = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ── errors ──────────────────────────────────────────────────────────────────

    /// @notice A percentage band handed to `applyBands` exceeds 100% (`100e18`).
    /// @dev Declared HERE rather than on `IMarketRegistry` because the registry stores no bands —
    ///      recipes do, and the bound is a property of this arithmetic. For `rateMin` it is a hard
    ///      requirement, not a preference: the floor is `rate * (100% - rateMinPercentage)`, so a value
    ///      above 100% underflows to a bare arithmetic panic with no name on it. Catching it here turns
    ///      that into a selector a test can assert.
    ///
    ///      The other three bands are deliberately NOT bounded. A recipe that genuinely wants to grant
    ///      more than the whole rate as one day's movement allowance is the recipe author's call to
    ///      justify, and the arithmetic does not care.
    /// @param percentage The offending band, on the percentage scale (`1e18` = 1%).
    error BandOutOfRange(uint256 percentage);

    // ── natural-key hashing ─────────────────────────────────────────────────────

    /// @dev Natural-key hash for the asset store (BS-ST-03, §8/§17 normative):
    ///      keccak256(abi.encode(addr)). No `chainId` — a registry instance holds only its own chain's
    ///      assets, so the chain is not a discriminator here, it is a field that could disagree with
    ///      reality.
    function assetKey(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encode(addr));
    }

    /// @dev Secondary-index key for the asset name (BS-ST-06, §17 normative):
    ///      keccak256(abi.encode(lowercasedName)). Fold covers ONLY bytes 0x41..0x5A
    ///      (ASCII A–Z), each += 0x20; every other byte is left untouched. Operates on a memory copy
    ///      so the caller's name is never mutated. No `chainId`, for the same reason as `assetKey`.
    function nameKey(string memory name) internal pure returns (bytes32) {
        bytes memory src = bytes(name);
        uint256 len = src.length;
        bytes memory folded = new bytes(len); // fresh buffer — never mutate the caller's `name`
        for (uint256 i = 0; i < len; ++i) {
            uint8 c = uint8(src[i]);
            folded[i] = (c >= 0x41 && c <= 0x5A) ? bytes1(c + 0x20) : src[i];
        }
        return keccak256(abi.encode(string(folded)));
    }

    /// @dev Natural-key hash for the conversion-feed store (BS-ST-07, §8/§17 normative):
    ///      keccak256(abi.encode(base, quote)). No `chainId`.
    ///
    ///      Direction is part of the key and that is load-bearing: `feedKey(a, b)` and `feedKey(b, a)`
    ///      are different entries, and `resolvePath` only ever probes the forward direction because
    ///      the Morpho oracle multiplies the feeds it is handed and cannot invert one.
    function feedKey(address base, address quote) internal pure returns (bytes32) {
        return keccak256(abi.encode(base, quote));
    }

    /// @dev Event-key hash for the recipe store: keccak256(abi.encode(recipe)). The recipe STORAGE is
    ///      keyed by the raw recipe ADDRESS (see slot 10 of `MarketRegistryStorage`, which is also
    ///      where the address-as-key argument lives), so unlike `assetKey` and `feedKey` this hash
    ///      addresses nothing — it exists only so `EntryAdded` / `EntryRemoved` can emit their
    ///      fixed-width `keyHash` for the recipe namespace. The address itself travels in the event
    ///      payload, so nothing downstream has to invert this.
    function recipeKeyHash(address recipe) internal pure returns (bytes32) {
        return keccak256(abi.encode(recipe));
    }

    // ── store plumbing (shared by all three stores) ──────────────────────────────
    // Insert = push key + record index+1. Remove = swap-and-pop with the moved-entry index fix.

    /// @dev Append a bytes32 key and record its position as index + 1 (0 = absent). Used by the
    ///      asset, conversion-feed and denomination stores.
    function insertBytes32(bytes32[] storage keys, mapping(bytes32 => uint256) storage index, bytes32 key) internal {
        keys.push(key);
        index[key] = keys.length; // index + 1
    }

    /// @dev Swap-and-pop removal for a bytes32-keyed store. Caller MUST have checked existence.
    ///      Ordering is load-bearing: when the removed entry is NOT the tail, move the last key into
    ///      the freed slot AND fix the moved key's index to its new position (removed index + 1)
    ///      BEFORE popping; then clear the removed key's index LAST. When the removed entry IS the
    ///      tail (idx == last, incl. the sole-element case), skip the move so the pop-then-clear
    ///      does not resurrect the removed key.
    function removeBytes32(bytes32[] storage keys, mapping(bytes32 => uint256) storage index, bytes32 key) internal {
        uint256 idx = index[key] - 1; // index + 1 → position
        uint256 last = keys.length - 1;
        if (idx != last) {
            bytes32 moved = keys[last];
            keys[idx] = moved;
            index[moved] = idx + 1; // fix moved entry's index to its new slot
        }
        keys.pop();
        index[key] = 0; // clear removed key LAST
    }

    /// @dev Append a recipe address and record its position as index + 1 (0 = absent). Address twin
    ///      of `insertBytes32`, for the recipe store, whose keys are contract addresses rather than
    ///      hashes.
    function insertAddress(address[] storage keys, mapping(address => uint256) storage index, address key) internal {
        keys.push(key);
        index[key] = keys.length; // index + 1
    }

    /// @dev Swap-and-pop removal for the address-keyed recipe store. Caller MUST have checked
    ///      existence. Same load-bearing ordering as `removeBytes32`, for the same reasons.
    function removeAddress(address[] storage keys, mapping(address => uint256) storage index, address key) internal {
        uint256 idx = index[key] - 1; // index + 1 → position
        uint256 last = keys.length - 1;
        if (idx != last) {
            address moved = keys[last];
            keys[idx] = moved;
            index[moved] = idx + 1; // fix moved entry's index to its new slot
        }
        keys.pop();
        index[key] = 0; // clear removed key LAST
    }

    // ── pagination ──────────────────────────────────────────────────────────────

    /// @dev Pagination clamp shared by all the `get*` views (BS-VW-06..09). Returns the slice
    ///      `[offset, offset+limit)` clamped to `total`; an offset at or past the end yields an empty
    ///      page; never reverts. Overflow-safe: `count` is derived from `total - offset`, never
    ///      `offset + limit`.
    function pageBounds(uint256 total, uint256 offset, uint256 limit)
        internal
        pure
        returns (uint256 start, uint256 count)
    {
        if (offset >= total) return (0, 0);
        uint256 remaining = total - offset;
        count = limit < remaining ? limit : remaining;
        start = offset;
    }

    // ── band resolution (the ONE place percentages become rates) ─────────────────

    /// @dev Turn a set of percentage bands into concrete rate quantities around `rate`.
    ///
    ///      This is the ONLY place the PERCENTAGE scale meets the RATE scale — see
    ///      `PERCENTAGE_DENOMINATOR` for the two conventions and why a second copy of this arithmetic
    ///      is a 100x error waiting to happen. It lives in an all-`internal` library so a RECIPE
    ///      CONTRACT can reuse it by import, with no deployment and no linking, instead of open-coding
    ///      the conversion. Keep it that way.
    ///
    ///      ## What it computes
    ///
    ///      `rate` is a plain 18-decimal rate. Every `*Percentage` argument is a percentage. Both
    ///      bounds are deviations FROM `rate`:
    ///
    ///          rateMin  = rate * (100% - rateMinPercentage) / 100%     — the floor, below `rate`
    ///          rateMax  = rate * (100% + rateMaxPercentage) / 100%     — the ceiling, above `rate`
    ///          perDay   = rate *  rateChangePerDayMaxPercentage   / 100%
    ///          capacity = rate *  rateChangeCapacityMaxPercentage / 100%
    ///
    ///      So bands of (min 5%, max 10%) at rate 1.0 resolve to a floor of 0.95 and a ceiling of
    ///      1.10, and bands of (min 0%, max 1%) resolve to a floor of exactly `rate`. Bands rather than
    ///      stored absolute limits, because "floor 5% below the rate" stays correct at every rate while
    ///      a stored "floor 0.95" is only correct while the rate sits at 1.0.
    ///
    ///      The band form makes an inverted window unrepresentable rather than merely invalid: given
    ///      `rateMinPercentage <= 100%` (enforced below), the floor is always <= `rate` and the ceiling
    ///      always >= `rate`, so `rateMin <= rateMax` holds for free and no cross-field check is needed.
    ///
    ///      Rounding always moves toward the TIGHTER constraint — the floor rounds up, the other three
    ///      round down — so a sub-wei remainder can never widen what a policy permits. `mulDiv` carries
    ///      the intermediate product at 512 bits, so `rate * 200%` cannot overflow on the way through.
    ///      A `rate` of 0 resolves every field to 0 without reverting, and `rate` is never validated,
    ///      because the caller owns the oracle read.
    /// @param rate The rate to resolve against, 18-decimal fixed point (`1e18` = 1.0).
    /// @param rateMinPercentage How far BELOW `rate` the floor sits (`1e18` = 1%); must be <= 100e18.
    /// @param rateMaxPercentage How far ABOVE `rate` the ceiling sits (`1e18` = 1%).
    /// @param rateChangePerDayMaxPercentage Rate movement allowed per day, as a percentage of `rate`.
    /// @param rateChangeCapacityMaxPercentage Ceiling on accumulated allowance, as a percentage.
    /// @return r The four concrete limits, all on the RATE scale.
    function applyBands(
        uint256 rate,
        uint256 rateMinPercentage,
        uint256 rateMaxPercentage,
        uint256 rateChangePerDayMaxPercentage,
        uint256 rateChangeCapacityMaxPercentage
    ) internal pure returns (IMarketRegistry.ResolvedConstraint memory r) {
        // Hard arithmetic requirement, not a preference: above 100% the subtraction below underflows
        // into an unnamed panic. See `BandOutOfRange` for why the other three are unbounded.
        if (rateMinPercentage > PERCENTAGE_DENOMINATOR) revert BandOutOfRange(rateMinPercentage);

        r.rateMin =
            Math.mulDiv(rate, PERCENTAGE_DENOMINATOR - rateMinPercentage, PERCENTAGE_DENOMINATOR, Math.Rounding.Ceil);
        r.rateMax =
            Math.mulDiv(rate, PERCENTAGE_DENOMINATOR + rateMaxPercentage, PERCENTAGE_DENOMINATOR, Math.Rounding.Floor);
        r.rateChangePerDayMax =
            Math.mulDiv(rate, rateChangePerDayMaxPercentage, PERCENTAGE_DENOMINATOR, Math.Rounding.Floor);
        r.rateChangeCapacityMax =
            Math.mulDiv(rate, rateChangeCapacityMaxPercentage, PERCENTAGE_DENOMINATOR, Math.Rounding.Floor);
    }

    // ── structural validators ────────────────────────────────────────────────────

    /// @dev Range-checks every enum ordinal reachable from an `Asset` and reverts panic 0x21 if one is
    ///      out of range. solc reverts a *typed* calldata enum read with EMPTY data, not Panic(0x21);
    ///      only an explicit `EnumType(uint)` conversion yields the canonical enum panic. So each
    ///      ordinal is read raw from calldata and converted explicitly. Called before the owner gate
    ///      so a malformed enum fails regardless of caller. The accumulator is returned and consumed
    ///      by the caller so the conversions are never optimized away.
    ///
    ///      ## The calldata offsets — RECOMPUTE THESE IF `Asset` IS EVER REORDERED
    ///
    ///      Nothing fails loudly if an offset here goes stale. The read simply lands on a different
    ///      word, and because a string-offset word holds a large number an out-of-range enum then
    ///      PASSES the range check instead of reverting. Two field changes have already shifted these
    ///      offsets by one word each, and neither left any other trace.
    ///
    ///      `e` is the calldata offset of the `Asset` head. Its ABI head is FIVE words, because `name`
    ///      and BOTH `AssetSource` members are dynamic types (each `AssetSource` contains a `string`),
    ///      so each of those contributes an OFFSET word rather than its data:
    ///
    ///          addr:0  ·  name-offset:32  ·  kind:64  ·  priceSource-offset:96
    ///          navSource-offset:128
    ///
    ///      Per the ABI, an offset inside a tuple is relative to the start of that tuple's encoding,
    ///      so an `AssetSource` head sits at `e + calldataload(e + <offsetWord>)`. Each `AssetSource`
    ///      head is four words, only the last of which is dynamic:
    ///
    ///          addr:0  ·  sourceType:32  ·  sourceInterface:64  ·  denomination-offset:96
    ///
    ///      ## Why both sources are checked, including absent ones
    ///
    ///      An absent source (`addr == 0`) still occupies a full encoding, and a well-formed encoder
    ///      writes 0 into both of its enum words — in range for both enums, so checking an absent source
    ///      costs a comparison and never rejects an honest caller. A HOSTILE encoder can write anything
    ///      there, and those words are read later by every consumer that decodes a stored `Asset`, so
    ///      checking unconditionally is both cheaper to reason about and strictly safer.
    function validateAssetEnums(IMarketRegistry.Asset calldata e) internal pure returns (uint256 acc) {
        uint256 rawKind;
        uint256 priceHead;
        uint256 navHead;
        assembly {
            rawKind := calldataload(add(e, 64)) // kind: 3rd static head word
            priceHead := add(e, calldataload(add(e, 96))) // priceSource: 4th head word is its offset
            navHead := add(e, calldataload(add(e, 128))) // navSource: 5th head word is its offset
        }
        acc = uint256(IMarketRegistry.AssetKind(rawKind)); // Panic(0x21) if > last member

        acc += _validateSourceEnums(priceHead);
        acc += _validateSourceEnums(navHead);
    }

    /// @dev Range-check one `AssetSource`'s two enum ordinals, given the calldata offset of its head.
    ///      Split out so the two source fields cannot drift apart, and so the offsets are stated once.
    ///      See `validateAssetEnums` for the head layout and for why this is called unconditionally.
    function _validateSourceEnums(uint256 sourceHead) private pure returns (uint256 acc) {
        uint256 rawType;
        uint256 rawInterface;
        assembly {
            rawType := calldataload(add(sourceHead, 32)) // sourceType: 2nd word of the AssetSource head
            rawInterface := calldataload(add(sourceHead, 64)) // sourceInterface: 3rd word
        }
        acc = uint256(IMarketRegistry.SourceType(rawType)); // Panic(0x21) if > last member
        acc += uint256(IMarketRegistry.SourceInterface(rawInterface)); // Panic(0x21) if > last member
    }

    /// @dev BS-WLK-06 leaf source-quote rule, over the two NAMED source fields. Resolves iff every
    ///      PRESENT source carries the SAME non-empty `denomination` (exact bytes, case-sensitive); any
    ///      empty or disagreeing label → UNRESOLVED (empty string). No source contract is ever called —
    ///      the label is read straight off the struct it is handed (INV-X-05).
    ///
    ///      ## This is an AGREEMENT test, not the denomination itself
    ///
    ///      An asset's two sources may legitimately name DIFFERENT labels — `addAssets` validates each
    ///      separately rather than requiring a match. So a `""` return does not mean "this asset has no
    ///      denomination"; it means "these two sources do not agree on one". Only the underlying-asset
    ///      walk needs a single label, and only to decide a mid-chain terminal. `""` is not an error.
    ///
    ///      Parameters are `memory` rather than `calldata` so the same rule serves a caller holding a
    ///      caller-supplied entry and a caller reading a STORED one; both locations copy in implicitly.
    ///
    ///      Presence is `addr != 0`, matching every other reader. Three shapes: both present → they must
    ///      agree, and the agreed label is returned; exactly one present → that one's label (if
    ///      non-empty); neither present → UNRESOLVED, which is a real accepted registry state, since
    ///      `addAssets` takes an asset with no source at all.
    function leafQuote(IMarketRegistry.AssetSource memory priceSource, IMarketRegistry.AssetSource memory navSource)
        internal
        pure
        returns (string memory)
    {
        bool hasPrice = priceSource.addr != address(0);
        bool hasNav = navSource.addr != address(0);

        if (hasPrice && hasNav) {
            bytes memory p = bytes(priceSource.denomination);
            bytes memory n = bytes(navSource.denomination);
            if (p.length == 0 || n.length == 0) return "";
            if (keccak256(p) != keccak256(n)) return "";
            return priceSource.denomination;
        }

        if (hasPrice) {
            if (bytes(priceSource.denomination).length == 0) return "";
            return priceSource.denomination;
        }

        if (hasNav) {
            if (bytes(navSource.denomination).length == 0) return "";
            return navSource.denomination;
        }

        return ""; // neither source present → UNRESOLVED
    }

    // ── conversion-feed hop graph ─────────────────────────────────────────────────

    /// @dev Resolve the chain of approved conversion feeds that carries `fromUnit` to US Dollars, and
    ///      return their aggregator addresses in the order the Morpho oracle must be handed them.
    ///      This walks the conversion-feed store, which is already a directed graph of unit → unit
    ///      edges with an aggregator on each, so there is no second graph type.
    ///
    ///      ## The hop budget is arithmetic, not a policy choice
    ///
    ///      Each side of the Morpho oracle has one vault slot plus two feed slots, and the three are
    ///      orthogonal. A `PRICE` / `AGGREGATOR_V3` source consumes `feed1`, leaving `feed2`: budget
    ///      **1**. A `NAV` / `ERC4626` source consumes the vault slot instead, leaving `feed1` and
    ///      `feed2`: budget **2**. `maxDepth` is therefore only ever 1 or 2, and the returned array's
    ///      length is at most `maxDepth`.
    ///
    ///      ## The search, in three levels
    ///
    ///      No queue and no recursion. Levels 0 and 1 are single hashed probes; level 2 is one loop over
    ///      the REGISTERED DENOMINATIONS, and nothing enumerates the feed store:
    ///
    ///      0. `fromUnit` IS the US Dollar sentinel → return an EMPTY array. Zero hops is a success, not
    ///         a failure: the Morpho oracle reads a zero feed as the price 1.
    ///      1. A direct `fromUnit → USD` edge → return `[thatAggregator]`.
    ///      2. Only when `maxDepth >= 2`: for each registered denomination unit `u`, in REGISTRATION
    ///         ORDER, if both `fromUnit → u` and `u → USD` exist → return `[firstAggregator,
    ///         secondAggregator]`, nearest-to-the-asset first, which is the order `feed1` then `feed2`
    ///         must be filled in. The FIRST complete pair wins, so registration order is the tie-break
    ///         when two intermediates would both work — a governance decision rather than an accident,
    ///         and exactly what `docs/decisions/denomination-and-hop-graph.md` §(d) specifies.
    ///
    ///      Two candidates are skipped inside the loop. `u == fromUnit`, because a unit cannot bridge
    ///      through itself — the guard an Ether-quoted source with no direct dollar edge lands on. And
    ///      `u == USD_DENOMINATION`, because a path through the terminus is not a two-hop path: its
    ///      first edge IS level 1's, and the second would have to be a `USD → USD` self-loop.
    ///
    ///      ## THIS IS A LOOP ON THE FILL PATH — read the bound before adding denominations
    ///
    ///      `deploy` is permissionless and calls this through `_wireLeg` twice, once per leg, on every
    ///      fresh build (`addAssets` calls it once per present source), so the cost is paid by whoever
    ///      fills an order against a newly-deployed oracle rather than by governance.
    ///
    ///      The bound is exactly **the number of registered denominations** — `_denominationKeys.length`
    ///      — and the cost grows LINEARLY with it, at two to four `SLOAD`s per candidate. That is the
    ///      whole reason the denomination set is OWNER-MANAGED: if anybody could register a label,
    ///      anybody could lengthen this loop, so a permissionless registration path would be a
    ///      gas-griefing vector against every `deploy` on the chain. Owner-curated, it stays a list of
    ///      CURRENCIES — tens of entries, growing by governance transaction.
    ///
    ///      It is deliberately NOT bounded by the FEED store, which grows without limit as assets are
    ///      onboarded. Candidates come from the denomination set and the feed store is only ever probed
    ///      by hashed key; do not swap those round. Do not add a third level either — the hop budget is
    ///      at most 2, which is arithmetic from the Morpho oracle's slot count.
    ///
    ///      Only FORWARD edges are followed, on BOTH hops. The Morpho oracle multiplies the feeds it is
    ///      handed and cannot invert one, so a `USD → someUnit` feed is useless for bridging `someUnit`
    ///      and a `u → fromUnit` edge does not make `u` a viable intermediate; the inverse edge must be
    ///      approved as its own entry.
    ///
    ///      Reads the feed and denomination stores through the passed references and writes nothing.
    /// @param feedIndex The registry's `_feedIndex` — existence is `!= 0` (it stores `index + 1`).
    /// @param feeds The registry's `_feeds` — the records the aggregator addresses come from.
    /// @param denominationKeys The registry's `_denominationKeys` — the label hashes to try as
    ///        intermediates, in registration order. One entry per label and no duplicates; removing a
    ///        label pops it from here, so the candidate list can SHRINK and a two-hop path that
    ///        bridged through a removed label stops resolving from that call onward.
    /// @param denominations The registry's `_denominations` — resolves each label hash to its unit.
    /// @param fromUnit The unit address to bridge FROM: a token address, or a Chainlink
    ///        `Denominations` pseudo-address. The caller has already resolved this from a registered
    ///        denomination label, so an unregistered label reverted before reaching here.
    /// @param maxDepth The hop budget: 1 for an `AGGREGATOR_V3` source, 2 for an `ERC4626` source.
    /// @return feeds_ The aggregator addresses along the path, `feed1` first. Empty for the zero-hop
    ///         case.
    function resolvePath(
        mapping(bytes32 => uint256) storage feedIndex,
        mapping(bytes32 => IMarketRegistry.ConversionFeed) storage feeds,
        bytes32[] storage denominationKeys,
        mapping(bytes32 => address) storage denominations,
        address fromUnit,
        uint256 maxDepth
    ) internal view returns (address[] memory feeds_) {
        // Level 0 — already in US Dollars. Zero hops is a success, not a miss: the oracle reads an
        // empty feed slot as the price 1.
        if (fromUnit == USD_DENOMINATION) return new address[](0);

        // Level 1 — one direct edge to US Dollars.
        if (maxDepth >= 1) {
            bytes32 direct = feedKey(fromUnit, USD_DENOMINATION);
            if (feedIndex[direct] != 0) {
                feeds_ = new address[](1);
                feeds_[0] = feeds[direct].aggregatorAddress;
                return feeds_;
            }
        }

        // Level 2 — two edges through a registered intermediate. Bounded by the number of registered
        // denominations; see the bound note above before treating this loop as free.
        if (maxDepth >= 2) {
            feeds_ = _twoHop(feedIndex, feeds, denominationKeys, denominations, fromUnit);
            if (feeds_.length != 0) return feeds_;
        }

        revert IMarketRegistry.NoConversionPathToUsd(fromUnit, maxDepth);
    }

    /// @dev Level 2 of `resolvePath`, in its own frame. Returns the two aggregators of the first
    ///      complete `fromUnit → u → USD` path found walking the registered denominations in
    ///      registration order, or an EMPTY array when there is none — the caller owns the revert,
    ///      because only it knows the budget the error must name.
    ///
    ///      Split out for the stack, not for reuse: the default Foundry profile has no `via_ir`, and
    ///      four storage references plus the loop's locals on top of the caller's own is over the
    ///      legacy limit.
    ///
    ///      `denominations[k]` can never be zero for a `k` in `denominationKeys` — the add path rejects
    ///      a zero unit, and the remove path clears the mapping entry and pops this array in the same
    ///      call — so there is no zero-unit branch here. That pairing is load-bearing and must stay
    ///      that way: a stale hash resolving to zero would merely probe `feedKey(fromUnit,
    ///      address(0))`, find nothing, and continue, so the failure would be silent rather than loud.
    function _twoHop(
        mapping(bytes32 => uint256) storage feedIndex,
        mapping(bytes32 => IMarketRegistry.ConversionFeed) storage feeds,
        bytes32[] storage denominationKeys,
        mapping(bytes32 => address) storage denominations,
        address fromUnit
    ) private view returns (address[] memory feeds_) {
        uint256 len = denominationKeys.length;
        for (uint256 i = 0; i < len; ++i) {
            address u = denominations[denominationKeys[i]];

            // A unit cannot bridge through itself, and the terminus is not an intermediate — see the
            // skip note on `resolvePath`.
            if (u == fromUnit || u == USD_DENOMINATION) continue;

            // FORWARD edges only, on both hops: `fromUnit → u`, then `u → USD`.
            bytes32 first = feedKey(fromUnit, u);
            if (feedIndex[first] == 0) continue;
            bytes32 second = feedKey(u, USD_DENOMINATION);
            if (feedIndex[second] == 0) continue;

            feeds_ = new address[](2);
            feeds_[0] = feeds[first].aggregatorAddress; // feed1 — nearest the asset
            feeds_[1] = feeds[second].aggregatorAddress; // feed2 — the dollar bridge
            return feeds_;
        }
        return new address[](0); // no complete pair — the caller reverts with the budget in hand
    }

    // ── denomination walk ─────────────────────────────────────────────────────────

    /// @dev Probe `asset()` via try/catch. A clean non-zero address return means "hop to the
    ///      underlying"; a REVERT — including the empty revert a contract with no matching function
    ///      gives — is caught and degrades the node to a leaf. NOTE the intentional assumption (per
    ///      contract owner): a target either implements `asset()` returning a proper address or does
    ///      not implement it at all. A target that RETURNS malformed data (fewer than 32 bytes, or an
    ///      address with dirty upper bits) makes the ABI decode revert UNCATCHABLY, and that revert
    ///      bubbles out of `addAssets` — it is NOT reclassified as a leaf.
    ///
    ///      NO CODE AT THE ADDRESS IS NOT CAUGHT, and the distinction is easy to get backwards. A
    ///      `staticcall` to a codeless address SUCCEEDS and returns zero bytes, so the `try` takes its
    ///      success branch and the decode of an empty buffer reverts in this frame — the same event as
    ///      a short return above, with the same uncatchable outcome. So a bare EOA-shaped address
    ///      cannot be registered as an asset at all; a test needs a real contract (a `MockERC20`),
    ///      not a `makeAddr` label.
    function probeAsset(address target) internal view returns (bool hops, address underlying) {
        try IWrapper(target).asset() returns (address u) {
            if (u != address(0)) {
                hops = true;
                underlying = u;
            }
        } catch {
            // reverted, or a contract with no `asset()` → leaf. NOT a codeless address: that succeeds
            // with empty returndata and reverts uncatchably on the decode.
        }
    }

    /// @dev The denomination-derivation walk (§7.1 pseudocode, BS-WLK-01..09). Returns the derived
    ///      denomination, or the empty string for UNRESOLVED — most failure terminals (depth,
    ///      cycle/self-loop, unregistered mid-chain leaf, disagreeing/empty/absent leaf sources, and
    ///      a probe target that reverts or lacks `asset()`) fall to UNRESOLVED. The exception: a probe
    ///      target that returns MALFORMED data — or that has NO CODE, which is the same event — reverts
    ///      uncatchably (see `probeAsset`) and bubbles out of the add. Reads the primary asset store
    ///      through the passed `assetIndex` / `assets` references; writes nothing.
    ///
    ///      ## NOTHING IN `src/` CALLS THIS — and it is kept deliberately
    ///
    ///      There is no asset-level `denomination` field for it to fill: the denomination lives on each
    ///      `AssetSource` and is validated per source, so nothing on the add path needs a single
    ///      derived value. It is retained anyway, and reached from tests only, because this walk is the
    ///      on-chain AUTHORITY on what an asset's denomination actually is — derived by probing
    ///      `asset()` live rather than by any hand-written rule. Deleting it to save a few lines would
    ///      throw the authority away with it. This is not dead code.
    function deriveDenomination(
        mapping(bytes32 => uint256) storage assetIndex,
        mapping(bytes32 => IMarketRegistry.Asset) storage assets,
        IMarketRegistry.Asset calldata e
    ) internal view returns (string memory) {
        address cur = e.addr;
        address[] memory seen = new address[](MAX_DEPTH + 1); // in-memory cycle log; no storage
        uint256 depth = 0;

        while (true) {
            if (depth > MAX_DEPTH) return ""; // BS-WLK-02 depth limit → UNRESOLVED

            // BS-WLK-03 cycle / self-loop: linear scan of the prior nodes.
            for (uint256 i = 0; i < depth; ++i) {
                if (seen[i] == cur) return "";
            }

            seen[depth] = cur;

            // BS-WLK-04 registered-denominated terminal: only for a node past the head. There is no
            // pinned asset-level `denomination` to read, so the stored entry is asked the same question
            // its sources answer — apply the leaf rule to the two sources the registry holds for it. An
            // entry whose sources disagree, or whose only source is absent, yields `""` and the walk
            // carries on.
            if (cur != e.addr) {
                bytes32 curKey = assetKey(cur);
                if (assetIndex[curKey] != 0) {
                    IMarketRegistry.Asset storage stored = assets[curKey];
                    string memory denom = leafQuote(stored.priceSource, stored.navSource);
                    if (bytes(denom).length != 0) return denom;
                }
            }

            // BS-WLK-09 bounded probe.
            (bool hops, address underlying) = probeAsset(cur);
            if (hops) {
                cur = underlying; // BS-WLK-05 hop
                unchecked {
                    ++depth;
                }
                continue;
            }

            // BS-WLK-06 leaf source-quote terminal — now over the two named source fields.
            if (cur == e.addr) return leafQuote(e.priceSource, e.navSource);
            return ""; // BS-WLK-07 unregistered mid-chain leaf → UNRESOLVED
        }
        // Unreachable: the loop only exits via `return`.
        revert();
    }
}
