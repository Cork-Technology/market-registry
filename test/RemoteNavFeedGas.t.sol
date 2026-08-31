// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {RemoteNavFeed} from "../src/crosschain/RemoteNavFeed.sol";
import {
    ILayerZeroEndpointV2,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MockLayerZeroEndpoint} from "./mocks/CrosschainMocks.sol";

/// @title RemoteNavFeedGas.t.sol — gas measurements for the refresh round trip
/// @notice Measures the outer-call gas of `lzReceive` as paid by the endpoint's
///         caller (what the LayerZero executor's options gas must cover), for the
///         three delivery shapes: first response (seeds the scale — worst case),
///         steady-state response (advances `latestAnsweredRound`), and a late
///         response that is only recorded. Also measures `refresh` through the
///         mock endpoint; that number is a lower bound, since the real
///         endpoint + read library path costs more than the mock's `send`.
contract RemoteNavFeedGasTest is Test {
    uint32 internal constant READ_CHANNEL = 4_294_967_295;
    uint32 internal constant TARGET_EID = 30_101;
    uint16 internal constant CONFIRMATIONS = 15;
    uint256 internal constant MAX_STALENESS = 1 days;

    uint256 internal constant SAMPLE = 1e18;
    uint8 internal constant ASSET_DECIMALS = 6;

    MockLayerZeroEndpoint internal endpoint;
    RemoteNavFeed internal feed;

    function setUp() public {
        vm.warp(1_777_000_000);
        endpoint = new MockLayerZeroEndpoint();
        feed = new RemoteNavFeed(
            ILayerZeroEndpointV2(address(endpoint)),
            TARGET_EID,
            makeAddr("lens"),
            makeAddr("vault"),
            CONFIRMATIONS,
            100_000,
            MAX_STALENESS,
            "vault NAV (LayerZero Read)"
        );
    }

    function _origin(uint64 nonce) internal view returns (Origin memory) {
        return Origin({srcEid: READ_CHANNEL, sender: bytes32(uint256(uint160(address(feed)))), nonce: nonce});
    }

    /// @dev Delivers a response as the endpoint and returns the outer-call gas of
    ///      `lzReceive` — call overhead included, measured with a gasleft() delta
    ///      around the external call only.
    function _deliverMeasured(uint64 nonce, uint256 assets, uint256 blockNumber) internal returns (uint256 gasUsed) {
        Origin memory origin = _origin(nonce);
        bytes memory message = abi.encode(SAMPLE, assets, ASSET_DECIMALS, blockNumber, vm.getBlockTimestamp());
        vm.prank(address(endpoint));
        uint256 before = gasleft();
        feed.lzReceive(origin, bytes32(0), message, address(0), "");
        gasUsed = before - gasleft();
    }

    function test_gas_lzReceive_firstDelivery() public {
        MessagingReceipt memory receipt = feed.refresh();
        uint256 gasUsed = _deliverMeasured(receipt.nonce, 1.07e6, 500);
        emit log_named_uint("lzReceive: first delivery (seeds scale, advances pointer)", gasUsed);
    }

    function test_gas_lzReceive_steadyState() public {
        MessagingReceipt memory first = feed.refresh();
        _deliverMeasured(first.nonce, 1.07e6, 500);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory second = feed.refresh();
        uint256 gasUsed = _deliverMeasured(second.nonce, 1.08e6, 600);
        emit log_named_uint("lzReceive: steady-state delivery (advances pointer)", gasUsed);
    }

    function test_gas_lzReceive_recordOnly() public {
        MessagingReceipt memory seed = feed.refresh();
        _deliverMeasured(seed.nonce, 1.07e6, 500);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory second = feed.refresh();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        MessagingReceipt memory third = feed.refresh();

        // Round 3 answers first from a newer source block; round 2's late answer
        // is then recorded without moving the latest pointer.
        _deliverMeasured(third.nonce, 1.09e6, 700);
        uint256 gasUsed = _deliverMeasured(second.nonce, 1.08e6, 600);
        assertEq(feed.latestAnsweredRound(), 3, "late answer recorded, not served");
        emit log_named_uint("lzReceive: record-only delivery (pointer unmoved)", gasUsed);
    }

    /// @dev Lower bound only: the mock endpoint's `send` is far cheaper than the
    ///      real EndpointV2 + ReadLib1002 path (fee handling, cmdHash storage,
    ///      executor/verifier fee splits).
    function test_gas_refresh_lowerBound() public {
        // First round (cold latestRound slot).
        uint256 before = gasleft();
        feed.refresh();
        uint256 firstGas = before - gasleft();
        emit log_named_uint("refresh: first round (mock endpoint, lower bound)", firstGas);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        before = gasleft();
        feed.refresh();
        uint256 steadyGas = before - gasleft();
        emit log_named_uint("refresh: subsequent round (mock endpoint, lower bound)", steadyGas);
    }
}
