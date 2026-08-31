// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal surface an adapter source must expose: the legacy Chainlink V2 read.
interface ILatestAnswerFeed {
    function latestAnswer() external view returns (int256);
}

/// @title AggregatorV2V3Adapter
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Presents a source that only exposes the legacy `latestAnswer()` (Chainlink V2) as a full
///         `AggregatorV3Interface`, so it can be registered as a Chainlink-style price source in the
///         MarketRegistry / consumed by the Morpho oracle stack. `decimals` and `description` are fixed
///         at construction because the V2 surface does not expose them.
/// @dev    FRESHNESS WARNING: this adapter carries NO heartbeat from the source. `startedAt` and
///         `updatedAt` are always `0` — the V2 surface exposes no timestamps, and the adapter does not
///         invent any, so a downstream staleness check of the form `block.timestamp - updatedAt` FAILS
///         rather than silently passing. `roundId` and `answeredInRound` are always `0` — the source
///         has no round history. Use this only where the source value's freshness is guaranteed by
///         other means. A zero or negative answer from the source reverts `NonPositiveAnswer` instead
///         of being passed through.
contract AggregatorV2V3Adapter is AggregatorV3Interface {
    /// @notice The source reported a price that cannot be a valid positive price.
    error NonPositiveAnswer(int256 answer);

    /// @notice The V2 source whose `latestAnswer()` this adapter re-exposes.
    address public immutable source;

    /// @inheritdoc AggregatorV3Interface
    uint8 public immutable override decimals;

    /// @inheritdoc AggregatorV3Interface
    string public override description;

    /// @inheritdoc AggregatorV3Interface
    uint256 public constant override version = 4;

    constructor(address source_, uint8 decimals_, string memory description_) {
        source = source_;
        decimals = decimals_;
        description = description_;
    }

    /// @notice Legacy V2 read; a zero or negative source answer reverts rather than passing through.
    function latestAnswer() external view returns (int256) {
        return _answer();
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev roundId/answeredInRound and startedAt/updatedAt are 0 (see contract warning).
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer(), 0, 0, 0);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev The source has no round history, so this returns the current answer regardless of `_roundId`
    ///      and echoes `_roundId` back as both the round id and answered-in round.
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer(), 0, 0, _roundId);
    }

    /// @dev A price that is zero or negative is never usable by the oracle stack this adapter feeds,
    ///      so it reverts here instead of poisoning a downstream product.
    function _answer() private view returns (int256 answer) {
        answer = ILatestAnswerFeed(source).latestAnswer();
        if (answer <= 0) revert NonPositiveAnswer(answer);
    }
}
