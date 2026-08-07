// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Vendored (minimal) from 1inch `limit-order-protocol` master (v4.3.x, the code deployed as
// LOP v4 inside Aggregation Router v6 at 0x111111125421cA6dc452d289314280a0f8842A65 — same
// canonical address on Ethereum mainnet and Arbitrum One) and `1inch/solidity-utils`
// `AddressLib.sol`. Only the `Order` struct, its two value types, the address unwrap helper,
// and the two callback interfaces our contracts implement are vendored.

/// @notice 1inch address value type: an address in the low 160 bits, flags in the high bits.
type Address is uint256;

/// @notice 1inch maker traits bitfield (flags in the high bits, expiry/nonce/series in the low).
///         Opaque to our contracts — carried through, never decoded here.
type MakerTraits is uint256;

/// @dev Minimal mirror of `1inch/solidity-utils` AddressLib: unwrap the low 160 bits.
library AddressLib {
    uint256 private constant _LOW_160_BIT_MASK = (1 << 160) - 1;

    /// @notice Returns the payload address from a 1inch `Address` value (drops the flag bits).
    function get(Address a) internal pure returns (address) {
        return address(uint160(Address.unwrap(a) & _LOW_160_BIT_MASK));
    }
}

/// @title IOrderMixin (vendored subset)
/// @notice Only the `Order` struct is vendored; field ORDER IS LOAD-BEARING (the LOP hashes the
///         struct for the EIP-712 order hash), so it must match 1inch exactly.
interface IOrderMixin {
    struct Order {
        uint256 salt;
        Address maker;
        Address receiver;
        Address makerAsset;
        Address takerAsset;
        uint256 makingAmount;
        uint256 takingAmount;
        MakerTraits makerTraits;
    }
}

/// @title IPreInteraction
/// @notice Maker-side hook. The LOP calls this AFTER validation and invalidator update but
///         BEFORE the maker->taker transfer (verified against `OrderMixin._fill`: preInteraction
///         fires before the maker-asset pull), so it is the maker's last chance to stage funds.
///         The callee address + `extraData` live in the maker-signed extension.
interface IPreInteraction {
    function preInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata extension,
        bytes32 orderHash,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 remainingMakingAmount,
        bytes calldata extraData
    ) external;
}

/// @title ITakerInteraction
/// @notice Taker-side hook. The LOP calls this BETWEEN the two transfers: maker assets have
///         already been pushed to the taker's target, taker assets have NOT yet been pulled from
///         `msg.sender` (verified against `OrderMixin._fill`). Chosen freely by the taker per
///         fill (`interaction` arg) — NOT signed by the maker.
interface ITakerInteraction {
    function takerInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata extension,
        bytes32 orderHash,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 remainingMakingAmount,
        bytes calldata extraData
    ) external;
}
