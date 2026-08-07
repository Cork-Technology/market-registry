// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";

// ─────────────────────────────────────────────────────────────────────────────
// One-element array builders
// ─────────────────────────────────────────────────────────────────────────────
//
// Every mutation on `IMarketRegistry` takes arrays and there are no single-item variants, so a suite
// that means "add exactly this one asset" has to build a one-element array to say it. These exist so
// that intent stays on one line: `iReg.addAssets(one(entry))`.
//
// Free functions rather than methods on a fixture, because half the suites in this repository stand
// up their own registry and do not inherit `RegistryFixture`.

/// @notice A one-element `Asset` array.
function one(IMarketRegistry.Asset memory e) pure returns (IMarketRegistry.Asset[] memory a) {
    a = new IMarketRegistry.Asset[](1);
    a[0] = e;
}

/// @notice A one-element `ConversionFeed` array.
function one(IMarketRegistry.ConversionFeed memory f) pure returns (IMarketRegistry.ConversionFeed[] memory a) {
    a = new IMarketRegistry.ConversionFeed[](1);
    a[0] = f;
}

/// @notice A one-element `address` array — asset removals, feed sides, recipes, denomination units.
function one(address addr) pure returns (address[] memory a) {
    a = new address[](1);
    a[0] = addr;
}

/// @notice A one-element `string` array — denomination labels.
function one(string memory s) pure returns (string[] memory a) {
    a = new string[](1);
    a[0] = s;
}
