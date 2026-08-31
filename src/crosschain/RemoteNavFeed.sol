// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IRemoteNavFeed} from "../interfaces/IRemoteNavFeed.sol";
import {VaultRateLens} from "./VaultRateLens.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EVMCallRequestV1, ReadCodecV1} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";

/// @title RemoteNavFeed
/// @notice Chainlink-compatible feed whose answer is an ERC-4626 vault's
///         share-to-assets conversion read from another chain via LayerZero Read.
///         `answer` means: underlying assets per `sample` shares, in the
///         underlying's decimals.
///
///         Round semantics follow the Chainlink Flux model: `refresh` starts a
///         round (`startedAt`), the delivered response answers it (`updatedAt`,
///         stamped on arrival, like Chainlink does). Every answered round is kept
///         in storage, so `getRoundData` serves real history. The source-chain
///         block number and timestamp of each reading are stored alongside as
///         audit data, so transit delay stays visible.
contract RemoteNavFeed is IRemoteNavFeed, AggregatorV3Interface, ILayerZeroReceiver {
    using OptionsBuilder for bytes;

    /// @inheritdoc IRemoteNavFeed
    uint256 public constant override ROUND_TIMEOUT = 1 hours;

    /// @inheritdoc IRemoteNavFeed
    /// @dev The lens response is the abi.encoding of five 32-byte words:
    ///      sample, assets, assetDecimals, blockNumber, timestamp.
    uint32 public constant override RESPONSE_SIZE = 160;

    /// @inheritdoc IRemoteNavFeed
    /// @dev LayerZero Read Channel 1 (type(uint32).max), the only read channel
    ///      LayerZero operates.
    uint32 public constant override READ_CHANNEL = 4294967295;

    /// @inheritdoc IRemoteNavFeed
    /// @dev Above the measured ~50.5k worst-case first delivery plus endpoint
    ///      overhead, so a too-low value cannot brick refresh delivery.
    uint128 public constant override MIN_GAS_ALLOWANCE = 60_000;

    /// @inheritdoc IRemoteNavFeed
    ILayerZeroEndpointV2 public immutable override ENDPOINT;
    /// @inheritdoc IRemoteNavFeed
    uint32 public immutable override TARGET_EID;
    /// @inheritdoc IRemoteNavFeed
    address public immutable override LENS;
    /// @inheritdoc IRemoteNavFeed
    address public immutable override VAULT;
    /// @inheritdoc IRemoteNavFeed
    uint16 public immutable override CONFIRMATIONS;
    /// @inheritdoc IRemoteNavFeed
    uint128 public immutable override GAS_ALLOWANCE;
    /// @inheritdoc IRemoteNavFeed
    uint256 public immutable override MAX_STALENESS;

    /// @dev Fixed at deployment; strings cannot be immutable, so this is the
    ///      contract's only non-round storage written outside `lzReceive`.
    string private _description;

    // Frozen on first response. sample == 0 means not yet initialized.
    uint256 public override sample;
    uint8 private _assetDecimals;

    /// @inheritdoc IRemoteNavFeed
    uint80 public override latestRound;
    /// @inheritdoc IRemoteNavFeed
    uint80 public override latestAnsweredRound;

    mapping(uint80 roundId => Round) private _rounds;

    constructor(
        ILayerZeroEndpointV2 endpoint,
        uint32 targetEid,
        address targetChainLens,
        address targetChainVault,
        uint16 confirmations,
        uint128 gasAllowance,
        uint256 maxStaleness,
        string memory description_
    ) {
        if (gasAllowance < MIN_GAS_ALLOWANCE) revert GasAllowanceTooLow(gasAllowance);
        ENDPOINT = endpoint;
        TARGET_EID = targetEid;
        LENS = targetChainLens;
        VAULT = targetChainVault;
        CONFIRMATIONS = confirmations;
        GAS_ALLOWANCE = gasAllowance;
        MAX_STALENESS = maxStaleness;
        _description = description_;
    }

    // ---------------------------------------------------------------------
    // Refresh (ungated)
    // ---------------------------------------------------------------------

    /// @inheritdoc IRemoteNavFeed
    function refresh() external payable returns (MessagingReceipt memory receipt) {
        uint80 pending = latestRound;
        if (pending != 0) {
            Round storage p = _rounds[pending];
            if (p.updatedAt == 0 && block.timestamp - p.startedAt < ROUND_TIMEOUT) {
                revert RoundAlreadyActive(pending);
            }
        }

        receipt = ENDPOINT.send{value: msg.value}(_readParams(), msg.sender);

        // The round id IS the LayerZero outbound nonce: the response's
        // Origin.nonce echoes it back, enforced on-chain by the read library's
        // cmdHash check. Nonces start at 1 and increment by one per send on
        // this single path, so round ids stay dense and sequential.
        uint80 roundId = uint80(receipt.nonce);
        latestRound = roundId;
        _rounds[roundId].startedAt = uint64(block.timestamp);

        emit NewRound(roundId, msg.sender, block.timestamp);
    }

    /// @inheritdoc IRemoteNavFeed
    function refreshOptions() external view returns (bytes memory) {
        return _options();
    }

    /// @inheritdoc IRemoteNavFeed
    function quoteRefresh() external view returns (MessagingFee memory) {
        return ENDPOINT.quote(_readParams(), address(this));
    }

    function _options() internal view returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReadOption(GAS_ALLOWANCE, RESPONSE_SIZE, 0);
    }

    function _readParams() internal view returns (MessagingParams memory) {
        EVMCallRequestV1[] memory requests = new EVMCallRequestV1[](1);
        requests[0] = EVMCallRequestV1({
            appRequestLabel: 1,
            targetEid: TARGET_EID,
            isBlockNum: false,
            blockNumOrTimestamp: uint64(block.timestamp),
            confirmations: CONFIRMATIONS,
            to: LENS,
            callData: abi.encodeCall(VaultRateLens.read, (IERC4626(VAULT)))
        });
        return MessagingParams({
            dstEid: READ_CHANNEL,
            receiver: bytes32(uint256(uint160(address(this)))),
            message: ReadCodecV1.encode(0, requests),
            options: _options(),
            payInLzToken: false
        });
    }

    // ---------------------------------------------------------------------
    // Receive
    // ---------------------------------------------------------------------

    /// @inheritdoc ILayerZeroReceiver
    function lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        external
        payable
    {
        if (msg.sender != address(ENDPOINT)) revert OnlyEndpoint();
        if (origin.srcEid != READ_CHANNEL || origin.sender != bytes32(uint256(uint160(address(this))))) {
            revert InvalidOrigin();
        }

        // Origin.nonce is the outbound nonce of the request this response
        // answers, so it names the round directly.
        uint80 roundId = uint80(origin.nonce);
        if (_rounds[roundId].startedAt == 0) revert UnknownResponse(roundId);

        Round storage round = _rounds[roundId];
        if (round.updatedAt != 0) revert RoundAlreadyAnswered(roundId);

        (uint256 sample_, uint256 assets, uint8 assetDecimals_, uint256 blockNumber, uint256 timestamp) =
            abi.decode(message, (uint256, uint256, uint8, uint256, uint256));

        if (sample == 0) {
            // First response initializes and freezes the scale.
            if (sample_ == 0) revert ScaleMismatch(sample_, assetDecimals_);
            sample = sample_;
            _assetDecimals = assetDecimals_;
        } else if (sample_ != sample || assetDecimals_ != _assetDecimals) {
            revert ScaleMismatch(sample_, assetDecimals_);
        }

        if (assets == 0) revert NonPositiveAnswer();
        if (assets > uint256(type(int256).max) || blockNumber > type(uint64).max || timestamp > type(uint64).max) {
            revert AnswerOverflow();
        }

        round.answer = int256(assets);
        round.updatedAt = uint64(block.timestamp);
        round.sourceBlockNumber = uint64(blockNumber);
        round.sourceTimestamp = uint64(timestamp);

        // The latest pointer only moves forward, and only to a reading taken at a
        // newer source block than the one currently served.
        uint80 served = latestAnsweredRound;
        if (roundId > served && (served == 0 || uint64(blockNumber) > _rounds[served].sourceBlockNumber)) {
            latestAnsweredRound = roundId;
            emit AnswerUpdated(round.answer, roundId, block.timestamp);
        } else {
            emit AnswerRecorded(round.answer, roundId, block.timestamp);
        }
    }

    /// @inheritdoc ILayerZeroReceiver
    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return origin.srcEid == READ_CHANNEL && origin.sender == bytes32(uint256(uint160(address(this))));
    }

    /// @inheritdoc ILayerZeroReceiver
    /// @dev Unordered delivery; ordering is enforced per round instead.
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    // ---------------------------------------------------------------------
    // AggregatorV3Interface
    // ---------------------------------------------------------------------

    /// @inheritdoc AggregatorV3Interface
    /// @dev Reverts until the first response arrives; the feed is unusable before
    ///      it is seeded anyway, so nothing can integrate against a wrong scale.
    function decimals() external view returns (uint8) {
        if (sample == 0) revert NotInitialized();
        return _assetDecimals;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Fails closed on staleness: reverts when the served reading's
    ///      source-chain timestamp is older than MAX_STALENESS. Callers get local
    ///      arrival timestamps (`startedAt`/`updatedAt`); the source timestamp
    ///      only drives this gate, so remote clock quirks never leak to consumers.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = latestAnsweredRound;
        if (roundId == 0) revert NotInitialized();
        Round storage round = _rounds[roundId];
        if (block.timestamp > uint256(round.sourceTimestamp) + MAX_STALENESS) {
            revert StaleAnswer(roundId, round.sourceTimestamp);
        }
        return (roundId, round.answer, round.startedAt, round.updatedAt, roundId);
    }

    /// @inheritdoc AggregatorV3Interface
    /// @dev Serves any answered round from history; unanswered rounds revert
    ///      rather than returning zeroed data.
    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round storage round = _rounds[roundId_];
        if (round.updatedAt == 0) revert NoDataPresent(roundId_);
        return (roundId_, round.answer, round.startedAt, round.updatedAt, roundId_);
    }

    /// @inheritdoc IRemoteNavFeed
    function roundData(uint80 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }
}
