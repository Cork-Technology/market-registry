// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title IRemoteNavFeed
/// @notice The feed-specific surface of RemoteNavFeed: its errors, events, round
///         history, and refresh entry points. The Chainlink and LayerZero surfaces
///         live on AggregatorV3Interface and ILayerZeroReceiver, which the feed
///         inherits separately.
interface IRemoteNavFeed {
    /// @notice `lzReceive` was called by an address other than the LayerZero endpoint.
    error OnlyEndpoint();
    /// @notice A response arrived from a channel or sender the feed does not trust.
    error InvalidOrigin();
    /// @notice The feed has not received its first response yet.
    error NotInitialized();
    /// @notice A response carried a zero or negative NAV reading.
    error NonPositiveAnswer();
    /// @notice The computed answer does not fit in Chainlink's int256 answer type.
    error AnswerOverflow();
    /// @notice A response's sample or asset decimals differ from the frozen first reading.
    error ScaleMismatch(uint256 sample, uint8 assetDecimals);
    /// @notice The requested round does not exist or has no answer.
    error NoDataPresent(uint80 roundId);
    /// @notice The latest answer's source reading is older than MAX_STALENESS.
    error StaleAnswer(uint80 roundId, uint256 sourceTimestamp);
    /// @notice `refresh` was called while a round is pending and younger than ROUND_TIMEOUT.
    error RoundAlreadyActive(uint80 roundId);
    /// @notice A response arrived for a round that already has an answer.
    error RoundAlreadyAnswered(uint80 roundId);
    /// @notice A response arrived for a round the feed never started.
    error UnknownResponse(uint80 roundId);
    /// @notice Deployment was attempted with a gas allowance below MIN_GAS_ALLOWANCE.
    error GasAllowanceTooLow(uint128 gasAllowance);

    /// @notice Chainlink convention: a new round was started.
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    /// @notice Chainlink convention: emitted when an answer becomes the latest.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    /// @notice A round was answered but does not become latest; kept in history.
    event AnswerRecorded(int256 answer, uint256 indexed roundId, uint256 updatedAt);

    struct Round {
        int256 answer;
        uint64 startedAt; // this chain, when refresh() opened the round
        uint64 updatedAt; // this chain, when the response arrived
        uint64 sourceBlockNumber; // audit data: where the reading was taken
        uint64 sourceTimestamp; // audit data: when the reading was taken
    }

    /// @notice Start a new round: request a fresh reading from the target chain.
    ///         Anyone can call; the caller pays the LayerZero fee and receives any
    ///         refund. Reverts while a round is pending and younger than
    ///         ROUND_TIMEOUT. The executor options are fixed at deployment
    ///         (`refreshOptions`), so a caller cannot start a round whose delivery
    ///         is doomed by an under-gassed executor option; every permissionless
    ///         refresh is a useful one.
    function refresh() external payable returns (MessagingReceipt memory receipt);

    /// @notice Quote the native fee for `refresh`.
    function quoteRefresh() external view returns (MessagingFee memory);

    /// @notice The exact executor options every `refresh` uses: a type-3 container
    ///         with a single lzRead executor option carrying GAS_ALLOWANCE and
    ///         RESPONSE_SIZE. The value component is 0 because `lzReceive` needs
    ///         no native value.
    function refreshOptions() external view returns (bytes memory);

    /// @notice Full round record, including the source-chain audit fields.
    function roundData(uint80 roundId) external view returns (Round memory);

    /// @notice Shares sampled per reading. Frozen on the first response;
    ///         0 means not yet initialized.
    function sample() external view returns (uint256);

    /// @notice Highest round ever started. Rounds start at 1. A round id is the
    ///         LayerZero outbound nonce of the round's read request; the response
    ///         echoes it back in `Origin.nonce`, which correlates the two.
    function latestRound() external view returns (uint80);

    /// @notice The round `latestRoundData` serves. 0 until the first answer.
    function latestAnsweredRound() external view returns (uint80);

    /// @notice An unanswered round blocks new rounds until this much time passes.
    ///         Bounds the damage of a lost response: the feed pauses, never bricks.
    function ROUND_TIMEOUT() external view returns (uint256);

    /// @notice Byte size of the lens response: the abi.encoding of five 32-byte
    ///         words (sample, assets, assetDecimals, blockNumber, timestamp).
    ///         Used as the return-data size in `refreshOptions`.
    function RESPONSE_SIZE() external view returns (uint32);

    function ENDPOINT() external view returns (ILayerZeroEndpointV2);

    /// @notice The LayerZero read-channel endpoint id this feed sends requests on.
    ///         Fixed to LayerZero Read Channel 1, the only read channel LayerZero
    ///         operates.
    function READ_CHANNEL() external view returns (uint32);

    /// @notice Endpoint id of the chain the vault lives on.
    function TARGET_EID() external view returns (uint32);

    /// @notice The lens on the target chain (same address on every chain via CREATE2).
    function LENS() external view returns (address);

    /// @notice The ERC-4626 vault being read on the target chain.
    function VAULT() external view returns (address);

    /// @notice Source-chain block confirmations the verifiers wait for before reading.
    function CONFIRMATIONS() external view returns (uint16);

    /// @notice Executor gas allowance for delivering the response to `lzReceive`
    ///         on this chain. Fixed at deployment and part of the feed's identity
    ///         (CREATE2 salt), so no caller can under-gas a round's delivery.
    function GAS_ALLOWANCE() external view returns (uint128);

    /// @notice Floor on GAS_ALLOWANCE, enforced at deployment.
    function MIN_GAS_ALLOWANCE() external view returns (uint128);

    /// @notice Max age of the served reading, measured from its source-chain
    ///         timestamp, before `latestRoundData` fails closed. Chosen per feed
    ///         at deployment and part of the feed's identity (CREATE2 salt).
    function MAX_STALENESS() external view returns (uint256);
}
