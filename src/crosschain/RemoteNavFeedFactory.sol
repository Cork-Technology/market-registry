// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IRemoteNavFeedFactory} from "../interfaces/IRemoteNavFeedFactory.sol";
import {IVersion} from "../interfaces/IVersion.sol";
import {RemoteNavFeed} from "./RemoteNavFeed.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title RemoteNavFeedFactory
/// @notice Permissionless, idempotent factory for RemoteNavFeed. The factory fixes
///         only the LayerZero endpoint, and the read channel is a constant baked
///         into the feed; every other value a feed reads (target chain, lens,
///         vault, confirmations, gas allowance, staleness bound, read library and
///         verifier configuration, description) is committed by
///         the caller of `deploy` and covered by the
///         init-code hash, so it is visible in the feed's address — but the caller,
///         not the factory, declares it. Deployers of consumer integrations must
///         therefore verify a feed's immutables (or its factory-computed address),
///         not just `isFeed`. Different salts allow multiple feeds with identical
///         config.
contract RemoteNavFeedFactory is IRemoteNavFeedFactory, IVersion {
    /// @inheritdoc IRemoteNavFeedFactory
    ILayerZeroEndpointV2 public immutable ENDPOINT;

    /// @inheritdoc IRemoteNavFeedFactory
    mapping(address feed => bool) public isFeed;

    /// @notice Every feed this factory deployed, in deployment order, so
    ///         offchain tooling can enumerate them.
    address[] private _feeds;

    constructor(ILayerZeroEndpointV2 endpoint) {
        ENDPOINT = endpoint;
    }

    /// @inheritdoc IRemoteNavFeedFactory
    function deploy(FeedParams calldata params) external returns (address feed) {
        feed = computeAddress(params);
        if (feed.code.length > 0) return feed;

        feed = address(
            new RemoteNavFeed{salt: params.salt}(
                ENDPOINT,
                params.eid,
                params.targetChainLens,
                params.targetChainVault,
                params.confirmations,
                params.gasAllowance,
                params.maxStaleness,
                params.readLibrary,
                params.readConfig,
                params.description
            )
        );
        isFeed[feed] = true;
        _feeds.push(feed);
        emit Deploy(msg.sender, feed, params);
    }

    /// @inheritdoc IRemoteNavFeedFactory
    function computeAddress(FeedParams calldata params) public view returns (address) {
        return Create2.computeAddress(
            params.salt,
            keccak256(
                abi.encodePacked(
                    type(RemoteNavFeed).creationCode,
                    abi.encode(
                        ENDPOINT,
                        params.eid,
                        params.targetChainLens,
                        params.targetChainVault,
                        params.confirmations,
                        params.gasAllowance,
                        params.maxStaleness,
                        params.readLibrary,
                        params.readConfig,
                        params.description
                    )
                )
            )
        );
    }

    /// @inheritdoc IRemoteNavFeedFactory
    function feedsLength() external view returns (uint256) {
        return _feeds.length;
    }

    /// @inheritdoc IRemoteNavFeedFactory
    function getFeeds(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 length = _feeds.length;
        if (offset >= length) return new address[](0);

        uint256 remaining = length - offset;
        if (limit > remaining) limit = remaining;

        page = new address[](limit);
        for (uint256 i = 0; i < page.length; ++i) {
            page[i] = _feeds[offset + i];
        }
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.2.0";
    }
}
