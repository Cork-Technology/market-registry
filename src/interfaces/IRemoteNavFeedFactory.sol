// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @title IRemoteNavFeedFactory
/// @notice The external surface of RemoteNavFeedFactory: deterministic deployment,
///         address prediction, and enumeration of the feeds it deployed. The
///         factory fixes only the LayerZero endpoint; every other feed parameter
///         is supplied per `deploy` call by the caller.
interface IRemoteNavFeedFactory {
    /// @notice Everything that identifies a feed: all of it is covered by the
    ///         CREATE2 address, so identical params (and salt) map to one address.
    ///         Put 100k gas as allowance when in doubt.
    /// @dev    Gas consumption for a round is measured at ~58k-60k.
    ///
    ///         `readLibrary` and `readConfig` are the feed's whole LayerZero
    ///         security configuration. The feed applies them to the endpoint in
    ///         its constructor and has no owner or delegate, so they can never
    ///         change afterwards; a verifier going offline means deploying a new
    ///         feed at a new address. Both are part of the feed's address, so
    ///         checking the address checks the verifier set. `readConfig` is the
    ///         library's own `SetConfigParam` list (for ReadLib1002: eid
    ///         READ_CHANNEL, config type 1, an abi-encoded `ReadLibConfig`).
    struct FeedParams {
        bytes32 salt; // caller-chosen CREATE2 salt
        uint32 eid; // LayerZero endpoint id of the chain the vault lives on
        address targetChainLens; // the lens the feed reads through on that chain
        address targetChainVault; // the ERC-4626 vault on that chain
        uint16 confirmations; // source-chain block confirmations the verifiers wait for
        uint128 gasAllowance; // executor gas allowance for delivering responses
        uint256 maxStaleness; // the feed's staleness bound, at most MAX_STALENESS_CEILING
        address readLibrary; // the LayerZero read library, set as send and receive library for READ_CHANNEL
        SetConfigParam[] readConfig; // the verifier configuration applied to readLibrary
        string description; // the feed's Chainlink-style description
    }

    event Deploy(address indexed deployer, address indexed feed, FeedParams params);

    /// @notice Deploy (or return) the feed for the given params. Safe to re-run:
    ///         the same params return the existing feed without reverting.
    ///         Different salts allow multiple feeds with identical config. Every
    ///         param is committed by the caller and covered by the init-code
    ///         hash, so it is visible in the feed's address — but the caller,
    ///         not the factory, declares it. Consumers must verify a feed's
    ///         immutables (or its factory-computed address), not just `isFeed`.
    function deploy(FeedParams calldata params) external returns (address feed);

    /// @notice The feed address for the given params, deployed or not.
    function computeAddress(FeedParams calldata params) external view returns (address);

    /// @notice True for every feed this factory deployed. Attests deployment
    ///         provenance only, not configuration — verify the feed's immutables.
    function isFeed(address feed) external view returns (bool);

    /// @notice How many feeds this factory has deployed.
    function feedsLength() external view returns (uint256);

    /// @notice A page of deployed feeds, for offchain enumeration and indexing.
    ///         Not meant to be called from contracts. An offset past the end
    ///         returns an empty page instead of reverting.
    /// @param offset Index of the first feed to return.
    /// @param limit Maximum number of feeds to return.
    function getFeeds(uint256 offset, uint256 limit) external view returns (address[] memory page);

    /// @notice The LayerZero endpoint every feed from this factory sends through —
    ///         the only configuration the factory fixes.
    function ENDPOINT() external view returns (ILayerZeroEndpointV2);
}
