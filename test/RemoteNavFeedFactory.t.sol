// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {RemoteNavFeed} from "../src/crosschain/RemoteNavFeed.sol";
import {RemoteNavFeedFactory} from "../src/crosschain/RemoteNavFeedFactory.sol";
import {IRemoteNavFeed} from "../src/interfaces/IRemoteNavFeed.sol";
import {IRemoteNavFeedFactory} from "../src/interfaces/IRemoteNavFeedFactory.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {MockLayerZeroEndpoint} from "./mocks/CrosschainMocks.sol";

/// @title RemoteNavFeedFactory.t.sol — the idempotent CREATE2 feed factory
/// @notice Covers `deploy`/`computeAddress` parity, the `Deploy` event, idempotent re-deploys,
///         address sensitivity to the caller's salt and to every per-call parameter, the enumeration
///         surface (`feedsLength`, `getFeeds` pagination), and the constructor wiring of a
///         deployed feed.
/// @dev No test asserts a hard-coded address: `computeAddress` hashes the feed's creation
///      code, so every prediction is compared against a value computed in the same build.
contract RemoteNavFeedFactoryTest is Test {
    uint32 internal constant READ_CHANNEL = 4_294_967_295;
    uint32 internal constant TARGET_EID = 30_101;
    uint16 internal constant CONFIRMATIONS = 15;
    uint128 internal constant GAS_ALLOWANCE = 100_000;
    uint256 internal constant MAX_STALENESS = 1 days;
    bytes32 internal constant SALT = keccak256("remote-nav-feed-salt");
    string internal constant DESCRIPTION = "vault NAV (LayerZero Read)";

    MockLayerZeroEndpoint internal endpoint;
    RemoteNavFeedFactory internal factory;
    address internal lens = makeAddr("lens");
    address internal vault = makeAddr("vault");
    address internal readLibrary = makeAddr("read library");

    function setUp() public {
        endpoint = new MockLayerZeroEndpoint();
        factory = new RemoteNavFeedFactory(ILayerZeroEndpointV2(address(endpoint)));
    }

    function _readConfig() internal pure returns (SetConfigParam[] memory config) {
        config = new SetConfigParam[](1);
        config[0] = SetConfigParam({eid: READ_CHANNEL, configType: 1, config: hex"c0ffee"});
    }

    /// @dev Baseline params; individual tests mutate one field at a time.
    function _params() internal view returns (IRemoteNavFeedFactory.FeedParams memory) {
        return IRemoteNavFeedFactory.FeedParams({
            salt: SALT,
            eid: TARGET_EID,
            targetChainLens: lens,
            targetChainVault: vault,
            confirmations: CONFIRMATIONS,
            gasAllowance: GAS_ALLOWANCE,
            maxStaleness: MAX_STALENESS,
            readLibrary: readLibrary,
            readConfig: _readConfig(),
            description: DESCRIPTION
        });
    }

    function _deploy(bytes32 salt, uint256 maxStaleness, string memory description_) internal returns (address) {
        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.salt = salt;
        params.maxStaleness = maxStaleness;
        params.description = description_;
        return factory.deploy(params);
    }

    // ── deploy ──────────────────────────────────────────────────────────────────

    function test_deploy_matchesComputeAddress_andRecords() public {
        IRemoteNavFeedFactory.FeedParams memory params = _params();
        address predicted = factory.computeAddress(params);
        assertEq(predicted.code.length, 0, "nothing deployed yet");

        vm.expectEmit(true, true, true, true, address(factory));
        emit IRemoteNavFeedFactory.Deploy(address(this), predicted, params);
        address feed = factory.deploy(params);

        assertEq(feed, predicted, "computeAddress parity");
        assertGt(feed.code.length, 0, "code deployed");
        assertTrue(factory.isFeed(feed), "isFeed");
        assertEq(factory.feedsLength(), 1, "registry length");
        assertEq(factory.getFeeds(0, 1)[0], feed, "registry entry");
    }

    function test_deploy_idempotent() public {
        address first = _deploy(SALT, MAX_STALENESS, DESCRIPTION);

        vm.recordLogs();
        address second = _deploy(SALT, MAX_STALENESS, DESCRIPTION);

        assertEq(second, first, "same address");
        assertEq(factory.feedsLength(), 1, "no double record");
        assertEq(vm.getRecordedLogs().length, 0, "no re-emit");
    }

    function test_deploy_differentMaxStaleness_differentAddress() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);
        address b = _deploy(SALT, MAX_STALENESS + 1, DESCRIPTION);

        assertTrue(a != b, "staleness is part of the identity");
        assertEq(factory.feedsLength(), 2, "both recorded");
    }

    function test_deploy_differentDescription_differentAddress() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);
        address b = _deploy(SALT, MAX_STALENESS, "another description");

        assertTrue(a != b, "description is part of the identity");
        assertEq(factory.feedsLength(), 2, "both recorded");
    }

    function test_deploy_differentEidOrLens_differentAddress() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);

        IRemoteNavFeedFactory.FeedParams memory otherEid = _params();
        otherEid.eid = TARGET_EID + 1;
        address b = factory.deploy(otherEid);

        IRemoteNavFeedFactory.FeedParams memory otherLens = _params();
        otherLens.targetChainLens = makeAddr("another lens");
        address c = factory.deploy(otherLens);

        assertTrue(a != b, "target eid is part of the identity");
        assertTrue(a != c, "lens is part of the identity");
        assertTrue(b != c, "distinct feeds");
        assertEq(factory.feedsLength(), 3, "all recorded");
    }

    function test_deploy_differentGasAllowance_differentAddress() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);

        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.gasAllowance = GAS_ALLOWANCE + 1;
        address b = factory.deploy(params);

        assertTrue(a != b, "gas allowance is part of the identity");
        assertEq(factory.feedsLength(), 2, "both recorded");
    }

    // Regression: the LayerZero security configuration is part of the feed's
    // identity, so checking the address checks the verifier set.
    function test_deploy_differentReadLibrary_differentAddress() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);

        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.readLibrary = makeAddr("another read library");
        address b = factory.deploy(params);

        assertTrue(a != b, "read library is part of the identity");
        assertEq(factory.feedsLength(), 2, "both recorded");
    }

    function test_deploy_differentReadConfig_differentAddress() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);

        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.readConfig[0].config = hex"decaf0";
        address b = factory.deploy(params);

        assertTrue(a != b, "verifier config is part of the identity");
        assertEq(factory.feedsLength(), 2, "both recorded");
    }

    function test_deploy_zeroReadLibrary_reverts() public {
        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.readLibrary = address(0);
        vm.expectRevert(IRemoteNavFeed.ZeroReadLibrary.selector);
        factory.deploy(params);
    }

    function test_deploy_emptyReadConfig_reverts() public {
        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.readConfig = new SetConfigParam[](0);
        vm.expectRevert(IRemoteNavFeed.EmptyReadConfig.selector);
        factory.deploy(params);
    }

    function test_deploy_gasAllowanceBelowFloor_reverts() public {
        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.gasAllowance = 59_999;
        vm.expectRevert(abi.encodeWithSelector(IRemoteNavFeed.GasAllowanceTooLow.selector, uint128(59_999)));
        factory.deploy(params);
    }

    function test_deploy_gasAllowanceAtFloor_succeeds() public {
        IRemoteNavFeedFactory.FeedParams memory params = _params();
        params.gasAllowance = 60_000;
        address feed = factory.deploy(params);
        assertEq(RemoteNavFeed(feed).GAS_ALLOWANCE(), 60_000, "floor value accepted");
    }

    function test_deploy_differentSalt_sameArgs_distinctFeeds() public {
        address a = _deploy(SALT, MAX_STALENESS, DESCRIPTION);
        address b = _deploy(keccak256("another salt"), MAX_STALENESS, DESCRIPTION);

        assertTrue(a != b, "salt is part of the identity");
        assertTrue(factory.isFeed(a), "first recorded");
        assertTrue(factory.isFeed(b), "second recorded");
        assertEq(factory.feedsLength(), 2, "both recorded");
    }

    function test_deploy_feedImmutablesMatch() public {
        address feedAddr = _deploy(SALT, MAX_STALENESS, DESCRIPTION);
        RemoteNavFeed feed = RemoteNavFeed(feedAddr);

        assertEq(address(feed.ENDPOINT()), address(endpoint), "endpoint");
        assertEq(feed.READ_CHANNEL(), READ_CHANNEL, "read channel");
        assertEq(feed.TARGET_EID(), TARGET_EID, "target eid");
        assertEq(feed.LENS(), lens, "lens");
        assertEq(feed.VAULT(), vault, "vault");
        assertEq(feed.CONFIRMATIONS(), CONFIRMATIONS, "confirmations");
        assertEq(feed.GAS_ALLOWANCE(), GAS_ALLOWANCE, "gas allowance");
        assertEq(feed.MAX_STALENESS(), MAX_STALENESS, "max staleness");
        assertEq(feed.READ_LIBRARY(), readLibrary, "read library");
        assertEq(feed.description(), DESCRIPTION, "description");

        // The feed configured itself on the endpoint and appointed nobody.
        assertEq(endpoint.sendLibrary(feedAddr, READ_CHANNEL), readLibrary, "send library on the endpoint");
        assertEq(endpoint.receiveLibrary(feedAddr, READ_CHANNEL), readLibrary, "receive library on the endpoint");
        SetConfigParam[] memory applied = endpoint.config(feedAddr, readLibrary);
        assertEq(applied.length, 1, "one config entry");
        assertEq(applied[0].config, hex"c0ffee", "config bytes on the endpoint");
        assertEq(endpoint.delegates(feedAddr), address(0), "no delegate on the endpoint");
    }

    // ── enumeration ─────────────────────────────────────────────────────────────

    function _deployThree() internal returns (address[] memory feeds) {
        feeds = new address[](3);
        feeds[0] = _deploy(SALT, 1 days, DESCRIPTION);
        feeds[1] = _deploy(SALT, 2 days, DESCRIPTION);
        feeds[2] = _deploy(SALT, 3 days, DESCRIPTION);
    }

    function test_getFeeds_fullPage() public {
        address[] memory feeds = _deployThree();
        assertEq(factory.feedsLength(), 3, "length");

        address[] memory page = factory.getFeeds(0, 3);
        assertEq(page.length, 3, "page length");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(page[i], feeds[i], "deployment order");
        }
    }

    function test_getFeeds_partialPageViaOffset() public {
        address[] memory feeds = _deployThree();

        address[] memory page = factory.getFeeds(1, 1);
        assertEq(page.length, 1, "page length");
        assertEq(page[0], feeds[1], "offset entry");
    }

    function test_getFeeds_offsetPastEnd_returnsEmpty() public {
        _deployThree();
        assertEq(factory.getFeeds(3, 1).length, 0, "offset == length");
        assertEq(factory.getFeeds(100, 10).length, 0, "offset > length");
    }

    function test_getFeeds_limitClampedToRemainder() public {
        address[] memory feeds = _deployThree();

        address[] memory page = factory.getFeeds(1, 10);
        assertEq(page.length, 2, "clamped");
        assertEq(page[0], feeds[1], "first of remainder");
        assertEq(page[1], feeds[2], "last of remainder");
    }

    function test_getFeeds_maxLimit_doesNotRevert() public {
        address[] memory feeds = _deployThree();

        address[] memory page = factory.getFeeds(0, type(uint256).max);
        assertEq(page.length, 3, "clamped to length");
        assertEq(page[2], feeds[2], "last entry");
    }
}
