// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev Records what `RemoteNavFeed` sends and answers `quote` with a settable fee.
///      Deliberately NOT an `ILayerZeroEndpointV2` implementation: the feed only ever
///      calls `send` and `quote`, and implementing the full inherited interface tree
///      would bloat the mock for nothing. Tests cast this contract's address into the
///      interface type at the feed's constructor.
contract MockLayerZeroEndpoint {
    MessagingParams private _lastParams;
    uint256 public lastValue;
    address public lastRefundAddress;
    uint256 public sendCount;
    uint256 public quoteFee;

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
