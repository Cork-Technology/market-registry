// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @dev Records what `RemoteNavFeed` sends and answers `quote` with a settable fee.
///      Mirrors the real endpoint's application-side surface the feed depends on:
///      the `msg.sender == oapp || msg.sender == delegates[oapp]` guard on the
///      configuration and `skip` functions, and the `inboundNonce` / `skip` nonce
///      rules from `MessagingChannel` (tests mark nonces verified with
///      `setVerified`). Deliberately NOT an `ILayerZeroEndpointV2` implementation:
///      implementing the full inherited interface tree would bloat the mock for
///      nothing. Tests cast this contract's address into the interface type at the
///      feed's constructor.
contract MockLayerZeroEndpoint {
    error Unauthorized();
    error InvalidNonce(uint64 nonce);

    event InboundNonceSkipped(uint32 srcEid, bytes32 sender, address receiver, uint64 nonce);

    MessagingParams private _lastParams;
    uint256 public lastValue;
    address public lastRefundAddress;
    uint256 public sendCount;
    uint256 public quoteFee;

    mapping(address oapp => address delegate) public delegates;
    mapping(address oapp => mapping(uint32 eid => address lib)) public sendLibrary;
    mapping(address oapp => mapping(uint32 eid => address lib)) public receiveLibrary;
    mapping(address oapp => mapping(uint32 eid => uint256 gracePeriod)) public receiveLibraryGracePeriod;
    mapping(address oapp => mapping(address lib => SetConfigParam[] params)) private _config;

    mapping(address receiver => mapping(uint32 srcEid => mapping(bytes32 sender => uint64 nonce))) public
        lazyInboundNonce;
    mapping(
        address receiver => mapping(uint32 srcEid => mapping(bytes32 sender => mapping(uint64 nonce => bytes32 hash)))
    ) public inboundPayloadHash;

    function _assertAuthorized(address oapp) internal view {
        if (msg.sender != oapp && msg.sender != delegates[oapp]) revert Unauthorized();
    }

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function setSendLibrary(address oapp, uint32 eid, address lib) external {
        _assertAuthorized(oapp);
        sendLibrary[oapp][eid] = lib;
    }

    function setReceiveLibrary(address oapp, uint32 eid, address lib, uint256 gracePeriod) external {
        _assertAuthorized(oapp);
        receiveLibrary[oapp][eid] = lib;
        receiveLibraryGracePeriod[oapp][eid] = gracePeriod;
    }

    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external {
        _assertAuthorized(oapp);
        delete _config[oapp][lib];
        for (uint256 i = 0; i < params.length; ++i) {
            _config[oapp][lib].push(params[i]);
        }
    }

    function config(address oapp, address lib) external view returns (SetConfigParam[] memory) {
        return _config[oapp][lib];
    }

    /// @dev Test hook standing in for verification by the receive library.
    function setVerified(address receiver, uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 payloadHash) external {
        inboundPayloadHash[receiver][srcEid][sender][nonce] = payloadHash;
    }

    function inboundNonce(address receiver, uint32 srcEid, bytes32 sender) public view returns (uint64) {
        uint64 cursor = lazyInboundNonce[receiver][srcEid][sender];
        while (inboundPayloadHash[receiver][srcEid][sender][cursor + 1] != bytes32(0)) {
            ++cursor;
        }
        return cursor;
    }

    function skip(address oapp, uint32 srcEid, bytes32 sender, uint64 nonce) external {
        _assertAuthorized(oapp);
        if (nonce != inboundNonce(oapp, srcEid, sender) + 1) revert InvalidNonce(nonce);
        lazyInboundNonce[oapp][srcEid][sender] = nonce;
        emit InboundNonceSkipped(srcEid, sender, oapp, nonce);
    }

    function setQuoteFee(uint256 fee) external {
        quoteFee = fee;
    }

    function lastParams() external view returns (MessagingParams memory) {
        return _lastParams;
    }

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        _lastParams = params;
        lastValue = msg.value;
        lastRefundAddress = refundAddress;

        sendCount += 1;
        receipt = MessagingReceipt({
            guid: bytes32(sendCount), nonce: uint64(sendCount), fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }
}

/// @dev Minimal metadata-only token: `VaultRateLens` reads nothing but `decimals()`.
contract MockMetaERC20 {
    uint8 public decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }
}

/// @dev Minimal ERC-4626 surface for the lens: `decimals`, `asset`, `convertToAssets`.
///      `convertToAssets` answers only inputs armed via `setConversion`, so a test also
///      proves the lens sampled exactly `10 ** decimals()` shares.
contract MockERC4626 {
    uint8 public decimals;
    address public asset;
    mapping(uint256 shares => uint256 assets) public conversionOf;

    constructor(uint8 decimals_, address asset_) {
        decimals = decimals_;
        asset = asset_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setConversion(uint256 shares, uint256 assets) external {
        conversionOf[shares] = assets;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return conversionOf[shares];
    }
}
