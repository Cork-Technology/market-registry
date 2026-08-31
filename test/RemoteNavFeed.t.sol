// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {RemoteNavFeed} from "../src/crosschain/RemoteNavFeed.sol";
import {VaultRateLens} from "../src/crosschain/VaultRateLens.sol";
import {IRemoteNavFeed} from "../src/interfaces/IRemoteNavFeed.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EVMCallRequestV1, ReadCodecV1} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
import {MockLayerZeroEndpoint} from "./mocks/CrosschainMocks.sol";

/// @title RemoteNavFeed.t.sol — the LayerZero-Read-backed Chainlink-style feed
/// @notice Covers the round lifecycle (`refresh`, timeout, response delivery), the
///         learn-and-freeze scale, `lzReceive` guards and response validation, the
///         staleness gate on `latestRoundData`, out-of-order late answers, and history
///         via `getRoundData`. Responses are delivered by pranking as the mock endpoint
///         with the exact `Origin` the read channel would use and a message ABI-encoded
///         like `VaultRateLens.read`'s return data.
contract RemoteNavFeedTest is Test {
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event AnswerRecorded(int256 answer, uint256 indexed roundId, uint256 updatedAt);

    uint32 internal constant READ_CHANNEL = 4_294_967_295;
    uint32 internal constant TARGET_EID = 30_101;
    uint16 internal constant CONFIRMATIONS = 15;
    uint128 internal constant GAS_ALLOWANCE = 100_000;
    uint256 internal constant MAX_STALENESS = 1 days;
    string internal constant DESCRIPTION = "vault NAV (LayerZero Read)";

    // Canonical response scale: an 18-decimal vault over a 6-decimal underlying.
    uint256 internal constant SAMPLE = 1e18;
    uint8 internal constant ASSET_DECIMALS = 6;

    MockLayerZeroEndpoint internal endpoint;
    RemoteNavFeed internal feed;
    address internal lens = makeAddr("lens");
    address internal vault = makeAddr("vault");

    function setUp() public {
        vm.warp(1_777_000_000);
        endpoint = new MockLayerZeroEndpoint();
        feed = new RemoteNavFeed(
            ILayerZeroEndpointV2(address(endpoint)),
            TARGET_EID,
            lens,
            vault,
            CONFIRMATIONS,
            GAS_ALLOWANCE,
            MAX_STALENESS,
            DESCRIPTION
        );
    }

    // ── constructor ─────────────────────────────────────────────────────────────

    function test_constructor_gasAllowanceBelowFloor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.GasAllowanceTooLow.selector, uint128(59_999)));
        new RemoteNavFeed(
            ILayerZeroEndpointV2(address(endpoint)),
            TARGET_EID,
            lens,
            vault,
            CONFIRMATIONS,
            59_999,
            MAX_STALENESS,
            DESCRIPTION
        );
    }

    function test_constructor_gasAllowanceAtFloor_succeeds() public {
        RemoteNavFeed atFloor = new RemoteNavFeed(
            ILayerZeroEndpointV2(address(endpoint)),
            TARGET_EID,
            lens,
            vault,
            CONFIRMATIONS,
            60_000,
            MAX_STALENESS,
            DESCRIPTION
        );
        assertEq(atFloor.GAS_ALLOWANCE(), 60_000, "floor value accepted");
        assertEq(atFloor.MIN_GAS_ALLOWANCE(), 60_000, "floor constant");
    }

    function test_description_fromConstructor() public view {
        assertEq(feed.description(), DESCRIPTION, "description set at deployment");
    }

    /// @dev Mirrors real endpoint behavior: the delivered Origin echoes the
    ///      outbound nonce of the request being answered.
    function _origin(uint64 nonce) internal view returns (Origin memory) {
        return Origin({srcEid: READ_CHANNEL, sender: bytes32(uint256(uint160(address(feed)))), nonce: nonce});
    }

    function _deliver(
        uint64 nonce,
        uint256 sample,
        uint256 assets,
        uint8 assetDecimals,
        uint256 blockNumber,
        uint256 timestamp
    ) internal {
        vm.prank(address(endpoint));
        feed.lzReceive(
            _origin(nonce),
            bytes32(0),
            abi.encode(sample, assets, assetDecimals, blockNumber, timestamp),
            address(0),
            ""
        );
    }

    // ── refresh ─────────────────────────────────────────────────────────────────

    function test_refresh_startsRoundOne_andSendsReadRequest() public {
        vm.expectEmit(true, true, true, true, address(feed));
        emit NewRound(1, address(this), vm.getBlockTimestamp());
        MessagingReceipt memory receipt = feed.refresh{value: 0.01 ether}();

        assertEq(feed.latestRound(), 1, "round started");
        assertEq(receipt.nonce, 1, "round id is the outbound nonce");
        assertEq(endpoint.lastValue(), 0.01 ether, "fee forwarded");
        assertEq(endpoint.lastRefundAddress(), address(this), "caller gets the refund");

        // The endpoint must receive a single-request read command aimed at the lens.
        MessagingParams memory params = endpoint.lastParams();
        assertEq(params.dstEid, READ_CHANNEL, "sent on the read channel");
        assertEq(params.receiver, bytes32(uint256(uint160(address(feed)))), "self-addressed response");
        assertEq(params.options, feed.refreshOptions(), "the feed's fixed options, never caller-supplied");
        assertFalse(params.payInLzToken, "native fee only");

        EVMCallRequestV1[] memory requests = new EVMCallRequestV1[](1);
        requests[0] = EVMCallRequestV1({
            appRequestLabel: 1,
            targetEid: TARGET_EID,
            isBlockNum: false,
            blockNumOrTimestamp: uint64(vm.getBlockTimestamp()),
            confirmations: CONFIRMATIONS,
            to: lens,
            callData: abi.encodeCall(VaultRateLens.read, (IERC4626(vault)))
        });
        assertEq(params.message, ReadCodecV1.encode(0, requests), "read command");
    }

    function test_refresh_whilePending_reverts() public {
        feed.refresh();
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.RoundAlreadyActive.selector, 1));
        feed.refresh();
    }

    function test_refresh_afterTimeout_startsNextRound() public {
        feed.refresh();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory receipt = feed.refresh();

        assertEq(feed.latestRound(), 2, "round two");
        assertEq(receipt.nonce, 2, "new nonce, new round");
    }

    function test_refreshOptions_matchesOptionsBuilder() public view {
        bytes memory expected =
            OptionsBuilder.addExecutorLzReadOption(OptionsBuilder.newOptions(), GAS_ALLOWANCE, feed.RESPONSE_SIZE(), 0);
        assertEq(feed.refreshOptions(), expected, "same bytes as OptionsBuilder");
        assertEq(feed.GAS_ALLOWANCE(), GAS_ALLOWANCE, "gas allowance fixed at deployment");
    }

    function test_refreshOptions_isType3ContainerWithLzReadOption() public view {
        bytes memory options = feed.refreshOptions();

        // type-3 container prefix, then one executor lzRead option:
        // worker id 1, option length 21 (type byte + gas16 + size4), option type 5.
        assertEq(options.length, 2 + 1 + 2 + 1 + 16 + 4, "container + one lzRead option");
        assertEq(uint16(bytes2(options)), 3, "type-3 options container");
        assertEq(uint8(options[2]), 1, "executor worker id");
        assertEq(uint8(options[5]), 5, "lzRead option type");
    }

    function test_quoteRefresh_asksEndpoint() public {
        endpoint.setQuoteFee(0.02 ether);
        MessagingFee memory fee = feed.quoteRefresh();
        assertEq(fee.nativeFee, 0.02 ether, "native fee");
        assertEq(fee.lzTokenFee, 0, "no lz token fee");
    }

    // ── delivery: happy path ────────────────────────────────────────────────────

    function test_lzReceive_firstResponse_seedsScaleAndAnswers() public {
        uint256 startedAt = vm.getBlockTimestamp();
        MessagingReceipt memory receipt = feed.refresh();
        uint256 sourceTimestamp = vm.getBlockTimestamp() + 100;
        vm.warp(vm.getBlockTimestamp() + 300);

        vm.expectEmit(true, true, true, true, address(feed));
        emit AnswerUpdated(1.07e6, 1, vm.getBlockTimestamp());
        _deliver(receipt.nonce, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, sourceTimestamp);

        assertEq(feed.sample(), SAMPLE, "scale learned");
        assertEq(feed.decimals(), ASSET_DECIMALS, "decimals learned");
        assertEq(feed.latestAnsweredRound(), 1, "answered");

        (uint80 roundId, int256 answer, uint256 startedAt_, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1, "roundId");
        assertEq(answer, 1.07e6, "answer");
        assertEq(startedAt_, startedAt, "startedAt is the local refresh time");
        assertEq(updatedAt, vm.getBlockTimestamp(), "updatedAt is the local arrival time");
        assertEq(answeredInRound, 1, "answeredInRound");

        IRemoteNavFeed.Round memory round = feed.roundData(1);
        assertEq(round.sourceBlockNumber, 500, "audit: source block");
        assertEq(round.sourceTimestamp, sourceTimestamp, "audit: source timestamp");
    }

    function test_beforeFirstAnswer_readsRevertNotInitialized() public {
        vm.expectRevert(IRemoteNavFeed.NotInitialized.selector);
        feed.latestRoundData();
        vm.expectRevert(IRemoteNavFeed.NotInitialized.selector);
        feed.decimals();
    }

    // ── delivery: guards ────────────────────────────────────────────────────────

    function test_lzReceive_notEndpoint_reverts() public {
        MessagingReceipt memory receipt = feed.refresh();
        bytes memory message = abi.encode(SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp());
        vm.expectRevert(IRemoteNavFeed.OnlyEndpoint.selector);
        feed.lzReceive(_origin(receipt.nonce), bytes32(0), message, address(0), "");
    }

    function test_lzReceive_wrongSrcEid_reverts() public {
        MessagingReceipt memory receipt = feed.refresh();
        Origin memory origin = _origin(receipt.nonce);
        origin.srcEid = TARGET_EID;
        vm.prank(address(endpoint));
        vm.expectRevert(IRemoteNavFeed.InvalidOrigin.selector);
        feed.lzReceive(
            origin, bytes32(0), abi.encode(SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp()), address(0), ""
        );
    }

    function test_lzReceive_wrongSender_reverts() public {
        MessagingReceipt memory receipt = feed.refresh();
        Origin memory origin = _origin(receipt.nonce);
        origin.sender = bytes32(uint256(uint160(makeAddr("impostor"))));
        vm.prank(address(endpoint));
        vm.expectRevert(IRemoteNavFeed.InvalidOrigin.selector);
        feed.lzReceive(
            origin, bytes32(0), abi.encode(SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp()), address(0), ""
        );
    }

    function test_lzReceive_nonceOfNeverStartedRound_reverts() public {
        feed.refresh();
        // Nonce 2 was never sent, so round 2 was never started.
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.UnknownResponse.selector, uint80(2)));
        _deliver(2, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp());
    }

    function test_lzReceive_sameNonceTwice_reverts() public {
        MessagingReceipt memory receipt = feed.refresh();
        _deliver(receipt.nonce, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.RoundAlreadyAnswered.selector, 1));
        _deliver(receipt.nonce, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp());
    }

    // ── delivery: response validation ───────────────────────────────────────────

    function test_lzReceive_zeroAssets_reverts() public {
        MessagingReceipt memory receipt = feed.refresh();
        vm.expectRevert(IRemoteNavFeed.NonPositiveAnswer.selector);
        _deliver(receipt.nonce, SAMPLE, 0, ASSET_DECIMALS, 500, vm.getBlockTimestamp());
    }

    function test_lzReceive_assetsOverInt256Max_reverts() public {
        MessagingReceipt memory receipt = feed.refresh();
        vm.expectRevert(IRemoteNavFeed.AnswerOverflow.selector);
        _deliver(receipt.nonce, SAMPLE, uint256(type(int256).max) + 1, ASSET_DECIMALS, 500, vm.getBlockTimestamp());
    }

    function test_lzReceive_sampleDriftAfterFreeze_reverts() public {
        MessagingReceipt memory first = feed.refresh();
        _deliver(first.nonce, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory second = feed.refresh();
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.ScaleMismatch.selector, 1e8, ASSET_DECIMALS));
        _deliver(second.nonce, 1e8, 1.07e6, ASSET_DECIMALS, 600, vm.getBlockTimestamp());
    }

    function test_lzReceive_decimalsDriftAfterFreeze_reverts() public {
        MessagingReceipt memory first = feed.refresh();
        _deliver(first.nonce, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory second = feed.refresh();
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.ScaleMismatch.selector, SAMPLE, uint8(18)));
        _deliver(second.nonce, SAMPLE, 1.07e18, 18, 600, vm.getBlockTimestamp());
    }

    // ── staleness ───────────────────────────────────────────────────────────────

    function test_latestRoundData_staleAnswer_failsClosed() public {
        MessagingReceipt memory receipt = feed.refresh();
        uint256 sourceTimestamp = vm.getBlockTimestamp();
        _deliver(receipt.nonce, SAMPLE, 1.07e6, ASSET_DECIMALS, 500, sourceTimestamp);

        // Fresh: within the bound it serves.
        vm.warp(sourceTimestamp + MAX_STALENESS);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 1.07e6, "still fresh at the bound");

        // One second past the bound: latest fails closed, history stays readable.
        vm.warp(sourceTimestamp + MAX_STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.StaleAnswer.selector, 1, sourceTimestamp));
        feed.latestRoundData();

        (, int256 historical,,,) = feed.getRoundData(1);
        assertEq(historical, 1.07e6, "getRoundData ignores staleness");
    }

    // ── out-of-order delivery ───────────────────────────────────────────────────

    function test_lzReceive_lateAnswerToOldRound_isRecordedNotServed() public {
        MessagingReceipt memory first = feed.refresh();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory second = feed.refresh();

        // Round 2 answers first, from a newer source block.
        _deliver(second.nonce, SAMPLE, 2e6, ASSET_DECIMALS, 200, vm.getBlockTimestamp());
        assertEq(feed.latestAnsweredRound(), 2, "round 2 served");

        // Round 1's late answer, from an older source block, is kept but not served.
        vm.expectEmit(true, true, true, true, address(feed));
        emit AnswerRecorded(1e6, 1, vm.getBlockTimestamp());
        _deliver(first.nonce, SAMPLE, 1e6, ASSET_DECIMALS, 100, vm.getBlockTimestamp());

        assertEq(feed.latestAnsweredRound(), 2, "latest pointer never moves back");
        (, int256 latest,,,) = feed.latestRoundData();
        assertEq(latest, 2e6, "still serves round 2");
        (, int256 late,,,) = feed.getRoundData(1);
        assertEq(late, 1e6, "round 1 kept in history");
    }

    // ── history ─────────────────────────────────────────────────────────────────

    function test_getRoundData_unansweredRound_reverts() public {
        feed.refresh();
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.NoDataPresent.selector, 1));
        feed.getRoundData(1);
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.NoDataPresent.selector, 99));
        feed.getRoundData(99);
    }
}
