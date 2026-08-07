// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626ShareAdapter} from "../interfaces/IERC4626ShareAdapter.sol";

/// @title ERC4626ShareAdapter
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @custom:deprecated Superseded by a real net-asset-value source. New onboarding must NOT use this
///         adapter — see WHY THIS IS DEPRECATED below. Kept because two instances are deployed and
///         verified on Arbitrum One and two live assets (arbUSD and USDACM) read them; deleting the
///         source would not delete those, it would only leave the next person reading those addresses
///         worse off. Re-onboarding the two assets against the new shape is migration work, deferred
///         with issue #79. Revisit deletion when #79 has a migration plan and those assets have moved.
/// @notice Prices one share of an ERC-4626 vault in the unit its underlying feed quotes (USD here),
///         and presents that price as a full `AggregatorV3Interface` so it can sit in an asset's
///         `priceSource.addr` and be consumed by the Morpho oracle stack.
///
///         WHAT THE PAIR IS. This adapter reports `share:quote` — BASE is one whole vault share, QUOTE
///         is whatever unit the feed quotes in (USD for both Arbitrum deployments) — by HOPPING through
///         the vault's underlying asset as a pivot:
///
///           leg 1   share:underlying    from the VAULT, via `convertToAssets(oneShare)`
///           leg 2   underlying:quote    from the FEED,  via `latestRoundData()`
///           out     share:quote         what this adapter reports (the pivot cancels)
///
///         So the vault supplies the base end and the feed the quote end, and the two must meet in the
///         middle: the feed's base has to BE `vault.asset()`, or the hop joins two unrelated units and
///         the answer is meaningless. Live: `arbUSD:USDC x USDC:USD = arbUSD:USD`, and the `USDACM` twin.
///
/// @dev    NOTATION. `base:quote` is a COMMENT convention only. The runtime `description()` string must
///         use the "BASE / QUOTE" slash form; see `description_` on the constructor for why.
///
///         WHY THIS IS DEPRECATED. The registry's own ERC-4626 leg is reachable directly, through
///         `deploy(ca, ref, OracleMode.NAV)`: a `NAV` source with `SourceInterface.ERC4626` puts the
///         real vault in the oracle's vault slot with a conversion sample of `10 ** shareDecimals`.
///         Mode is resolved PER LEG, so a vault on one side and a plain feed on the other is a
///         first-class configuration — arbUSD against native USDC needs no adapter on either leg. So a
///         NEW vault share gets a real `NAV` source, never another deployment of this contract; if it
///         also needs a price source for token-denominated `PRICE`-mode markets, the answer is a
///         genuine aggregator where one exists, or a bespoke wrapper — not this.
///
///         WHAT THIS STILL IS. A valid `AGGREGATOR_V3` price source reporting `share / USD`. An asset
///         is free to keep one as its `priceSource` so `PRICE`-mode markets remain available. That is
///         tolerated legacy for the two live deployments, not a part of the new shape.
///
///         WHY THE USD LEG IS FOLDED IN. These two assets onboarded as "USD", which is why the adapter
///         outputs USD directly, and that is the shape the two live deployments are frozen in. A source
///         denominated in something else is ordinary today: `MarketRegistryLib.resolvePath` walks the
///         conversion-feed graph from any registered label to US Dollars within the leg's hop budget.
///
///         WHY `convertToAssets` AND NOTHING ELSE. It is the only conversion method that is
///         `staticcall`-safe across both target vaults. `previewRedeem`/`previewDeposit`/
///         `previewMint`/`previewWithdraw` revert on ERC-7540 asynchronous vaults by mandate, and on
///         the Tokemak Autopool build `previewRedeem` and `maxWithdraw` are not `view` and fail under
///         `STATICCALL`. Any of them would brick the oracle.
///
///         DEPLOYER RESPONSIBILITY. Nothing on-chain can check that the two legs actually meet at the
///         pivot — that the feed's base IS `vault.asset()`. Hand it a vault over USDC and a DAI:USD
///         feed and it will hop straight across the seam and report a confidently wrong price. That
///         pairing is a deployment-time fact. The constructor reads all three decimal values from the
///         chain, so the pairing is the ONLY trusted input.
///
///         FRESHNESS. No staleness gate, heartbeat or circuit breaker, by design. The vault leg is read
///         live on every call so it is always current-block; the only leg that can go stale is the feed,
///         whose round metadata is forwarded verbatim rather than fabricated. A consumer that wants a
///         staleness policy applies it to that forwarded `updatedAt` itself.
///
///         PRECISION. Accuracy is bounded by the vault's own rounding of `convertToAssets`, which
///         returns underlying units — roughly 1e-6 relative for a 6-decimal underlying. That is
///         inherent to the only safe conversion method available and is not improved by scaling.
contract ERC4626ShareAdapter is IERC4626ShareAdapter {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @inheritdoc IERC4626ShareAdapter
    address public immutable override vault;

    /// @inheritdoc IERC4626ShareAdapter
    address public immutable override feed;

    /// @inheritdoc IERC4626ShareAdapter
    uint256 public immutable override sample;

    /// @inheritdoc IERC4626ShareAdapter
    uint256 public immutable override scaleNumerator;

    /// @inheritdoc IERC4626ShareAdapter
    uint256 public immutable override scaleDenominator;

    /// @inheritdoc AggregatorV3Interface
    uint8 public immutable override decimals;

    /// @inheritdoc AggregatorV3Interface
    string public override description;

    /// @inheritdoc AggregatorV3Interface
    /// @dev Informational only. Chainlink's own USDC/USD aggregator on Arbitrum reports `6` and this
    ///      repo's `AggregatorV2V3Adapter` reports `4`; nothing in this stack reads the number.
    uint256 public constant override version = 1;

    /// @param vault_ Leg 1 of the hop, `share:underlying`. Its share is the BASE of the reported pair
    ///        and its `asset()` is the pivot. Must answer `decimals()`, `asset()` and `convertToAssets()`.
    /// @param feed_ Leg 2, `underlying:quote`. Its BASE must be `vault_.asset()` — the same pivot leg 1
    ///        ends on — and its QUOTE becomes the quote of the output pair. Nothing on-chain can verify
    ///        this pairing; see DEPLOYER RESPONSIBILITY.
    /// @param decimals_ Decimals of the ANSWER this adapter reports — 8 for the Chainlink USD
    ///        convention, matching the `waArb*` feeds already registered on chain 42161. Deliberately
    ///        NOT assumed equal to the feed's own decimals: any gap is folded into the scale below.
    /// @param description_ Human-readable label for the OUTPUT pair `share:quote`, never the pivot in
    ///        the middle: so "arbUSD / USD", NOT "arbUSD / USDC". MUST be written in the slash form
    ///        "BASE / QUOTE", not the `base:quote` notation these comments use. The CLI's source
    ///        enrichment (`parseQuoteUnit`, `enrich/sources.ts`) does `description.split("/")` and reads
    ///        the last segment as the source's quote unit. A colon yields a single part, so no quote
    ///        unit is derived and the source is downgraded to `judgment` during onboarding.
    constructor(address vault_, address feed_, uint8 decimals_, string memory description_) {
        require(vault_ != address(0), ZeroAddress());
        require(feed_ != address(0), ZeroAddress());

        vault = vault_;
        feed = feed_;
        decimals = decimals_;
        description = description_;

        // All three readings come from the chain — no decimal is hardcoded here. Absurd values make
        // the exponentiations below overflow and revert construction, which is the wanted outcome.
        uint8 shareDecimals = IERC4626(vault_).decimals();
        uint8 underlyingDecimals = IERC20Metadata(IERC4626(vault_).asset()).decimals();
        uint8 feedDecimals = AggregatorV3Interface(feed_).decimals();

        sample = 10 ** uint256(shareDecimals);

        // answer = assets x feedAnswer x scaleNumerator / scaleDenominator, where `assets` carries
        // `underlyingDecimals` and `feedAnswer` carries `feedDecimals`. Dividing out the underlying
        // leaves `feedDecimals`; the remaining factor closes the gap to `decimals_` in whichever
        // direction it runs. Exactly one side is ever non-trivial.
        scaleNumerator = decimals_ > feedDecimals ? 10 ** uint256(decimals_ - feedDecimals) : 1;
        scaleDenominator = 10 ** uint256(underlyingDecimals)
            * (feedDecimals > decimals_ ? 10 ** uint256(feedDecimals - decimals_) : 1);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Round metadata is the FEED's, forwarded unchanged — the feed is the only leg that can be
    ///      stale, since the vault conversion is read in this same call.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = _sharePrice();
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev No round history: the vault leg exists only at the current block, so pairing a historical
    ///      feed answer with a present-day conversion would be a fabrication. Returns the current price
    ///      regardless of `_roundId`, echoing it back as both round ids (as `AggregatorV2V3Adapter` does).
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (, answer, startedAt, updatedAt,) = _sharePrice();
        return (_roundId, answer, startedAt, updatedAt, _roundId);
    }

    /// @dev The one place the math lives. Reads the feed, rejects a non-positive answer, then converts
    ///      one whole share and rescales. Checked arithmetic throughout — no `unchecked`.
    function _sharePrice()
        private
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        int256 feedAnswer;
        (roundId, feedAnswer, startedAt, updatedAt, answeredInRound) = AggregatorV3Interface(feed).latestRoundData();
        require(feedAnswer > 0, InvalidFeedAnswer(feedAnswer));

        uint256 assets = IERC4626(vault).convertToAssets(sample);
        answer = (assets * feedAnswer.toUint256() * scaleNumerator / scaleDenominator).toInt256();
    }
}
