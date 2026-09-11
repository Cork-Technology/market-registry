# Changelog

Every public release of the market-registry contracts, newest first. Each entry lists what
an integrator must know: interface changes, behaviour changes that no interface diff shows,
and removals. Deployed addresses live in the GitHub Release for each version, not here.

Versions follow semantic versioning below `1.0.0`: a breaking change on a covered surface
bumps the middle number, everything else bumps the last number.

## 0.5.0

Breaking. A registry keyed by unit address, a single market-creation path shared by direct
callers and limit-order fills, decode helpers for every opaque payload, and a set of
security fixes. Every changed contract redeploys at a new address; the
previous deployments keep running at their old addresses.

### Added

- `CorkMarketCreator`. A permissionless contract that creates the exact Cork pool a
  limit-order fill would derive, ahead of the fill. `createNewPool(MarketParams)` returns
  the pool id and both share-token addresses and is an idempotent lookup on an existing
  pool. It emits `MarketCreated` with the caller and both pool fees, so an indexer can
  rebuild the pool id from the event alone. A smart-contract account that cannot sign an
  ERC-2612 permit creates first, approves, then fills with an empty permit list.
- `MarketRegistry.isDenomination(address)` and `MarketRegistry.wrapperKey(ca, ref, mode)`.
  The wrapper key is the cache key `deploy` uses, and the CREATE2 salt handed to the
  wrapper factory is `keccak256(abi.encode(wrapperKey, oracleSalt))`.
- `encodeExtraData` and `decodeExtraData` on `CorkLimitOrderAdapter` and on every recipe.
  Each decode helper is `external pure` and shares one internal decode with the on-chain
  path that consumes the payload, so the deployed contract is the only statement of the
  layout.
- `ApySpreadImpairmentRecipe`: `MAX_APY_SPREAD_PERCENTAGE` (100 percent a year),
  `MAX_BAND_PERCENTAGE` (50 percent), `EXTRA_DATA_LENGTH`, and the `SpreadTooHigh` error.
- `RemoteNavFeed`: `skipStuckRound()`, the `RoundSkipped` event, `SKIP_TIMEOUT` (one day),
  `MAX_STALENESS_CEILING`, and `READ_LIBRARY`. `RemoteNavFeedFactory` feed parameters gain
  `readLibrary` and `readConfig`, so a feed's LayerZero read configuration is fixed in its
  constructor.
- `AtomicDeployer`: the `TargetOccupied` error.

### Changed

Interface changes, all breaking on a covered surface:

- **`MarketRegistry` keys denominations by unit address.** Labels are gone on-chain.
  `addDenominations(address[])`, `removeDenominations(address[])`, `getDenominations`
  returns `address[]`, `AssetSource.denomination` is an `address`, and
  `UnregisteredDenomination` carries the address. The `EntryAdded` and `EntryRemoved`
  payload for the denomination namespace is `abi.encode(unit)` and the key topic is the
  address widened to 32 bytes. Off-chain readers that showed a label must map the unit
  address to a name themselves.
- **`MarketRegistry.deploy` takes a fourth argument, `bytes32 oracleSalt`.** The salt only
  fixes where the first wrapper for a pair lands. A salt someone else already spent reverts
  one call, never the pair.
- **`ConversionFeed` loses `feedDecimals`.** The registry stores nothing about aggregator
  decimals; the Morpho oracle reads them live. `addConversionFeeds`, `lookupConversionFeed`,
  `getConversionFeeds` and the conversion-feed `EntryAdded` payload change shape.
- **`AssetSource` is now a static tuple**, which changes the ABI layout of `Asset` in every
  function that returns one.
- **`IMarketRecipe.verify` gains `uint256 expiryTimestamp` and `bool creating`** before the
  constraint. `additionalData` is renamed `extraData` on `resolve` and `verify`, and the
  recipe errors are renamed `MalformedExtraData` and `UnexpectedExtraData`.
  `ApySpreadImpairmentRecipe.BandTooWide` now carries the cap as a second argument.
- **`CorkLimitOrderAdapter` creates markets through `CorkMarketCreator`.** `initialize`
  takes `(limitOrderProtocol, poolManager, marketCreator)`. `JITMarketParams` nests the
  creator's `MarketParams` whole next to `enableJitMint`, so any order builder that encodes
  `extraData` must switch to the nested layout. `CONTROLLER`, `MARKET_REGISTRY` and
  `MAX_FEE_PERCENTAGE` are gone from the adapter, and the creation-time errors
  (`RateUnavailable`, `UnexpectedRateOverride`, `RecipeRejectedConstraint`,
  `ExpiryOutOfRange`) now come from the creator.
- **`RemoteNavFeedFactory.deploy`, `computeAddress` and the `Deploy` event** change through
  the enlarged feed-parameter struct.
- **Phoenix dependency moved to `v1.4.0-rc.1`.** Pool fees are fixed at creation and are
  part of the pool id, so two orders that differ only in a fee land in different pools. Share
  tokens accept ERC-1271 permit signatures; the adapter still uses the ERC-2612 form.
- **`MarketRegistry` storage layout changed.** Nothing here sits behind a proxy, so this
  only means the registry redeploys.

Behaviour changes that no interface diff shows. Read these even where the signatures are
unchanged:

- **Fees follow Phoenix's rule and nothing else.** The adapter's own 5 percent fee cap is
  gone. Phoenix refuses a fee at or above 100 percent with its own `InvalidFees`, and that
  revert surfaces through the adapter and the creator unchanged. There is no fill-time fee
  re-check.
- **Both assets are checked against the registry on every recipe path**, including the
  fixed-rate path. A delisted asset now also blocks fills into an existing fixed-rate pool.
- **A carried permit is used only when the allowance does not already cover the amount the
  protocol will pull** for that fill. A partial fill no longer replays a consumed permit on
  the next fill.
- **The wrapper cache is keyed on the oracle mode and the fully resolved wiring**, not on
  the source addresses. Removing a conversion feed or a denomination makes a repeat `deploy`
  revert with the pair's named error instead of serving the stale wrapper; re-adding one
  re-keys and rebuilds; an asset that names one source for both modes gets one wrapper per
  mode. Every `deploy`, cache hit included, now reads `decimals()` on both tokens and on a
  vault leg. Because both fill hooks call `deploy`, a governance re-key moves later fills of
  the same signed order into a fresh pool.
- **The wrapper factory canonicalises vault-side decimals** before hashing, so two calls
  that differ only in an ignored decimals value share one wrapper.
- **`lookupWrapper` returns zero for a gas-starved caller.** Zero means not found, never
  proven absent. On-chain callers under a tight stipend should use `wrapperKey`, which
  reverts.
- **The impairment recipe no longer reads the registry's expiry bound in `verify`.**
  Tightening the bound no longer strands resting orders. On the creating fill only, the
  carried duration must fit inside the market's remaining life; an expired market is
  refused. The spread is capped at 100 percent a year and the band at 50 percent, both
  inclusive. A garbage duration on a later fill now returns false instead of panicking.
- **`RemoteNavFeed` fixes its LayerZero send and receive library and read configuration in
  the constructor** and registers no delegate. Anyone can skip a round that has gone
  unanswered for a day. The staleness bound is capped so it can no longer overflow.
- **`AtomicDeployer` refuses an occupied CREATE2 target** instead of recording it as a
  success without running its initializer. The whole batch rolls back.
- **A pool created inside a fill emits `MarketCreated` from the creator's address** with the
  adapter as caller. The adapter no longer needs the pool-creator role; only the creator
  does.
- **Fill gas rises** by roughly 4k on an existing pool and 10k on a creating fill for the
  call into the creator, plus the wiring reads described above.

### Removed

- `MarketRegistry.lookupDenomination(string)`, the `Denomination` struct, and the label
  forms of `addDenominations` and `removeDenominations`.
- `ConversionFeed.feedDecimals`.
- `CorkLimitOrderAdapter.JITMarketCreated`. Listen to `CorkMarketCreator.MarketCreated`.
- `CorkLimitOrderAdapter.CONTROLLER`, `MARKET_REGISTRY`, `MAX_FEE_PERCENTAGE`, and the
  errors `SwapFeeOutOfRange` and `UnwindSwapFeeOutOfRange`.

### Deprecated

Nothing. The 0.4.0 deployments keep running at their addresses; any retirement is announced
through the Distribution that pins this version.

## 0.4.0

Adds a cross-chain net-asset-value feed, a fourth recipe, and fixes to the limit-order fill
path and the oracle factories. Removes the legacy ERC-4626 share adapter.

### Added

- `ApySpreadImpairmentRecipe`, a fourth recipe pricing a market off an annual-percentage-yield
  spread around an anchor rate.
- `RemoteNavFeedFactory`, `RemoteNavFeed` and `VaultRateLens`: a vault's net asset value
  read on another chain through LayerZero Read and served behind the Chainlink aggregator
  interface. The feed fails closed on a stale reading.
- `WrapperRateConsumerFactory.wrapperByParams`.

### Changed

- Limit-order fills execute maker permits defensively: a front-run permit no longer bricks
  the fill, and any other permit failure reverts the fill instead of being swallowed.
- Wrapper deployment is idempotent against a front-run CREATE2 deployment.
- The oracle factory no longer retries salts.
- `AggregatorV2V3Adapter` serves a zero timestamp rather than inventing one and rejects
  answers at or below zero with `NonPositiveAnswer`.

### Removed

- `ERC4626ShareAdapter` and `IERC4626ShareAdapter`. Assets that priced through a share
  adapter read their vault directly through the registry's native ERC-4626 leg.

## 0.3.3

- The registry address is part of the wrapper record key and CREATE2 salt, so a redeployed
  registry sharing the same factory derives fresh wrapper addresses instead of reverting on
  a collision for already-built pairs.

## 0.3.2

- First public release of the market-registry contracts.
