// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";

/// @title IERC4626ShareAdapter
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice The `AggregatorV3Interface` an ERC-4626 share-price adapter presents, plus the immutable
///         construction facts a reviewer needs to verify a deployed instance without decoding
///         constructor calldata: which vault it reads, which feed it multiplies by, the share sample
///         it converts, and the two scaling constants derived from the three decimal readings.
/// @dev    The adapter reports the pair `share:quote` by hopping through the vault's underlying:
///         `share:underlying` from the vault times `underlying:quote` from the feed, e.g.
///         `arbUSD:USDC x USDC:USD = arbUSD:USD`. The underlying is the pivot and cancels. `vault()`
///         is therefore the base end of the pair and `feed()` the quote end. See
///         `ERC4626ShareAdapter` for the full rationale.
interface IERC4626ShareAdapter is AggregatorV3Interface {
    /// @notice Thrown when the vault or the feed is supplied as the zero address.
    error ZeroAddress();

    /// @notice Thrown when the underlying feed reports a non-positive answer. A zero or negative USD
    ///         price for the vault's underlying is never legitimate, and Morpho rejects a negative
    ///         answer anyway (`ErrorsLib.NEGATIVE_ANSWER`) — failing here keeps the cause legible.
    error InvalidFeedAnswer(int256 answer);

    /// @notice Leg 1 of the hop, `share:underlying`. The ERC-4626 vault whose share is the BASE of the
    ///         reported pair; its `asset()` is the pivot the two legs meet at.
    function vault() external view returns (address);

    /// @notice Leg 2 of the hop, `underlying:quote`. The Chainlink-style feed whose base must be
    ///         `vault().asset()` and whose quote (USD here) becomes the QUOTE of the reported pair.
    function feed() external view returns (address);

    /// @notice One whole share, `10 ** vault.decimals()` — the base amount leg 1 is evaluated at.
    function sample() external view returns (uint256);

    /// @notice Numerator of the fixed scale applied after `convertToAssets(sample) * feedAnswer`.
    function scaleNumerator() external view returns (uint256);

    /// @notice Denominator of that same fixed scale. Folds the underlying's decimals together with
    ///         any gap between the feed's decimals and this adapter's output decimals.
    function scaleDenominator() external view returns (uint256);
}
