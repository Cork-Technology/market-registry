// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {VaultRateLens} from "../src/crosschain/VaultRateLens.sol";
import {MockERC4626, MockMetaERC20} from "./mocks/CrosschainMocks.sol";

/// @title VaultRateLens.t.sol — the single-call vault reading lens
/// @notice Covers `read` against a mock ERC-4626 vault: the sample is `10 ** vault.decimals()`,
///         the conversion is passed through verbatim, the underlying's decimals are reported,
///         and the block fields reflect the current block.
contract VaultRateLensTest is Test {
    VaultRateLens internal lens;
    MockMetaERC20 internal underlying;
    MockERC4626 internal vault;

    function setUp() public {
        lens = new VaultRateLens();
        underlying = new MockMetaERC20(18);
        vault = new MockERC4626(18, address(underlying));
    }

    function test_read_returnsRawFacts() public {
        // Only the exact sample input is armed, so a wrong sample would read zero.
        vault.setConversion(1e18, 1.07e18);

        vm.roll(123_456);
        vm.warp(1_777_000_000);

        (uint256 sample, uint256 assets, uint8 assetDecimals, uint256 blockNumber, uint256 timestamp) =
            lens.read(IERC4626(address(vault)));

        assertEq(sample, 1e18, "sample");
        assertEq(assets, 1.07e18, "assets");
        assertEq(assetDecimals, 18, "assetDecimals");
        assertEq(blockNumber, 123_456, "blockNumber");
        assertEq(timestamp, 1_777_000_000, "timestamp");
    }

    /// @notice The vault's own decimals drive the sample and the underlying's decimals are
    ///         reported independently — an 8-decimal vault over a 6-decimal asset stays raw.
    function test_read_oddDecimalCombo() public {
        vault.setDecimals(8);
        underlying.setDecimals(6);
        vault.setConversion(1e8, 25e6);

        (uint256 sample, uint256 assets, uint8 assetDecimals,,) = lens.read(IERC4626(address(vault)));

        assertEq(sample, 1e8, "sample tracks vault decimals");
        assertEq(assets, 25e6, "assets verbatim");
        assertEq(assetDecimals, 6, "underlying decimals");
    }

    function test_read_zeroConversionPassesThrough() public {
        // The lens is unopinionated: a zero conversion is reported, not rejected.
        (, uint256 assets,,,) = lens.read(IERC4626(address(vault)));
        assertEq(assets, 0, "zero passes through");
    }
}
