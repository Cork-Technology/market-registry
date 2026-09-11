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
    /// @notice Deployment was attempted with a staleness bound above MAX_STALENESS_CEILING.
    error MaxStalenessTooHigh(uint256 maxStaleness);
    /// @notice Deployment was attempted with the zero address as read library.
    error ZeroReadLibrary();
    /// @notice Deployment was attempted with no verifier configuration.
    error EmptyReadConfig();
    /// @notice `skipStuckRound` found no round at the endpoint's next inbound nonce.
    error UnknownRound(uint80 roundId);
    /// @notice `skipStuckRound` was called before the stuck round reached SKIP_TIMEOUT.
    error RoundNotStuck(uint80 roundId);

    /// @notice Chainlink convention: a new round was started.
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    /// @notice Chainlink convention: emitted when an answer becomes the latest.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    /// @notice A round was answered but does not become latest; kept in history.
    event AnswerRecorded(int256 answer, uint256 indexed roundId, uint256 updatedAt);
    /// @notice A round whose response never verified was skipped on the endpoint.
    ///         The round record stays in history, unanswered, so readers can tell
    ///         "definitively dead" from "possibly in flight".
    event RoundSkipped(uint256 indexed roundId, address indexed skippedBy);

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

    /// @notice Unstick the feed after a response that never verified. LayerZero
    ///         delivers in verification order, so one response that is never
    ///         verified blocks every later response; retrying `refresh` only
    ///         queues more behind it. Anyone can call. The endpoint names the
    ///         target (its next inbound nonce) and the feed's own state
    ///         authorizes the skip: the round must exist, be unanswered, and be
    ///         older than SKIP_TIMEOUT. Under those conditions the message being
    ///         destroyed is one nobody wants, so no owner or delegate is needed.
    ///         Reverts with UnknownRound, RoundAlreadyAnswered or RoundNotStuck
    ///         otherwise. Skipping a run of stuck rounds takes one call per round.
    function skipStuckRound() external;

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

    /// @notice How old an unanswered round must be before `skipStuckRound` may
    ///         destroy its response. Well above ROUND_TIMEOUT, so a merely slow
    ///         response is never skipped.
    function SKIP_TIMEOUT() external view returns (uint256);

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
    ///         Never above MAX_STALENESS_CEILING, so the staleness check cannot
    ///         overflow.
    function MAX_STALENESS() external view returns (uint256);

    /// @notice Upper bound on MAX_STALENESS, enforced at deployment.
    function MAX_STALENESS_CEILING() external view returns (uint256);

    /// @notice The LayerZero read library the feed registered on the endpoint at
    ///         deployment as both its send and receive library for READ_CHANNEL.
    ///         The feed has no owner and no delegate, so this and the verifier
    ///         configuration applied to it can never change. Both are part of
    ///         the feed's identity (CREATE2 salt); read the applied verifier set
    ///         from `ENDPOINT.getConfig(feed, READ_LIBRARY, READ_CHANNEL, ...)`.
    function READ_LIBRARY() external view returns (address);
}
