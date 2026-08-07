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
///         `updatedAt` are stamped with `block.timestamp` on every call, so any downstream staleness
///         check of the form `block.timestamp - updatedAt` is effectively a no-op. `roundId` and
///         `answeredInRound` are always `0` — the source has no round history. Use this only where the
///         source value's freshness and sign are guaranteed by other means. The answer is passed through
///         verbatim (not validated `> 0`); consumers that require a positive price must check themselves.
contract AggregatorV2V3Adapter is AggregatorV3Interface {
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

    /// @notice Legacy V2 read, forwarded verbatim from the source.
    function latestAnswer() external view returns (int256) {
        return ILatestAnswerFeed(source).latestAnswer();
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev roundId/answeredInRound are 0 and startedAt/updatedAt are block.timestamp (see contract warning).
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, ILatestAnswerFeed(source).latestAnswer(), block.timestamp, block.timestamp, 0);
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
        return (_roundId, ILatestAnswerFeed(source).latestAnswer(), block.timestamp, block.timestamp, _roundId);
    }
}
