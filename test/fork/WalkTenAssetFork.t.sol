// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";
import {RegistryFixture, mkNavOnlyAsset, mkPriceOnlyAsset} from "../helpers/RegistryFixture.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {one} from "../helpers/ArrayHelpers.sol";

/// @title WalkTenAssetFork — env-gated mainnet-fork suite over REAL assets.
/// @notice The deterministic replica ({TenAssetSet}) validates every rule against mock shapes with zero
///         RPC dependency. THIS suite is the secondary check: it points the same registry writes and the
///         same `deploy` wiring at GENUINE mainnet tokens and a GENUINE ERC-4626 vault, so the two live
///         reads the registry still performs are exercised against real implementations rather than
///         mocks.
///
///         CI CONTRACT — never block on a missing RPC endpoint: the fork URL is read from an
///         environment variable via `vm.envOr`, defaulting to an empty string. When it is absent
///         the single test SKIPS CLEANLY (`vm.skip(true)` plus a logged notice) and returns before
///         any fork call, so CI without secrets stays green. When it is present the test forks
///         mainnet and asserts the real behaviour.
///
///         Addresses are overridable via env so the suite survives redeploys / alternate forks;
///         defaults are the canonical mainnet addresses.
///
/// @dev ## WHAT THIS SUITE ASSERTS NOW, AND WHY IT IS NOT WHAT IT USED TO ASSERT
///
///      It used to assert that `addAsset` DERIVED an asset's denomination by probing `asset()` on-chain
///      and hopping to the underlying — the "walk" the file is named after. **That derivation no longer
///      happens on the add path at all.** There is no asset-level `denomination` field for a walk to
///      produce: the denomination lives on each `AssetSource`, is stated by the caller, and is VALIDATED
///      (not derived) at write time. `MarketRegistryLib.deriveDenomination` survives as the on-chain
///      authority on what an asset's denomination really is, but nothing in `MarketRegistry` calls it and
///      it takes storage references only its owner can supply — so a fork test cannot reach it through
///      the registry, and re-asserting the old outcome would be asserting a behaviour that is gone.
///
///      Rather than leave a test that only checks that a string handed in comes back out — which the
///      deterministic suites already do, without a network — the fork case was re-aimed at the two
///      things that ARE still live reads against real contracts, and that a mock cannot honestly stand
///      in for:
///
///      1. **Write-time source validation against real tokens.** A present source's `denomination` must
///         be a registered label AND must reach US Dollars inside its own hop budget — one hop for an
///         aggregator source, two for a vault source. So the `ETH → USD` conversion edge has to be in the
///         store BEFORE the Ether-quoted WETH leaf is added, or that write reverts
///         `NoConversionPathToUsd`.
///      2. **The live `decimals()` reads on the `deploy` path.** `_wireLeg` reads `decimals()` off the
///         asset on every leg, and off the VAULT as well on an ERC-4626 leg, where it becomes the
///         conversion sample `10 ** shareDecimals`. Getting that sample wrong is the documented failure
///         where `convertToAssets` truncates to zero and the oracle returns a confidently useless
///         number, and it is exactly the read a mock token cannot vouch for. Asserting it against real
///         sUSDe (18 share decimals) paired with real USDC (6 decimals) is the value this fork adds.
///
///      Only the wrapper FACTORY is mocked, because the real one reaches into the private phoenix
///      submodule. Everything it is handed comes from live mainnet reads, and {MockWrapperFactory}
///      records every argument, which is what makes point 2 assertable.
contract WalkTenAssetForkTest is RegistryFixture {
    /// @dev Primary RPC env var; `MAINNET_RPC_URL` is the Foundry convention. Empty => skip.
    string internal constant RPC_ENV = "MAINNET_RPC_URL";

    function test_fork_realAssets_validateOnWriteAndWireLiveDecimals() public {
        string memory rpc = vm.envOr(RPC_ENV, string(""));
        if (bytes(rpc).length == 0) {
            emit log_string(string.concat(
                    "[skip] ",
                    RPC_ENV,
                    " not set - skipping mainnet-fork registry check (CI-safe). ",
                    "Set ",
                    RPC_ENV,
                    " to run the real-asset validation and deploy wiring."
                ));
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);
        _setUpRegistry();

        // Canonical mainnet addresses (overridable). USDC/WETH/USDe are plain tokens; sUSDe is a real
        // ERC-4626 whose underlying is USDe.
        address usdc = vm.envOr("FORK_USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address weth = vm.envOr("FORK_WETH", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        address usde = vm.envOr("FORK_USDE", 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
        address sUsde = vm.envOr("FORK_SUSDE", 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);

        // ── Point 1: every present source is validated on the way in, and stored verbatim ──
        //
        // US Dollars reaches US Dollars in ZERO hops, so those two writes need no feed. Ether needs the
        // one edge `_setUpRegistry` added; without it this write would revert `NoConversionPathToUsd`
        // because an aggregator source has a budget of exactly one hop.
        _addLeaf(usdc, "USDC", USD_UNIT);
        _addLeaf(weth, "WETH", ETH_UNIT);
        _addLeaf(usde, "USDe", USD_UNIT);

        assertEq(_price(usdc), USD_UNIT, "fork: USDC price source did not store USD");
        assertEq(_price(weth), ETH_UNIT, "fork: WETH price source did not store ETH");
        assertEq(_price(usde), USD_UNIT, "fork: USDe price source did not store USD");

        // A vault source's unit is the unit the vault's OWN underlying is quoted in — sUSDe holds USDe,
        // which is a dollar asset — and it lands in the NAV slot with two hops of budget.
        _addVault(sUsde, "sUSDe");
        assertEq(_nav(sUsde), USD_UNIT, "fork: sUSDe NAV source did not store USD");

        // The absent slot reads back ZERO, and that is a real answer rather than an error: `addAsset`
        // zeroes an absent source instead of copying it.
        (, IMarketRegistry.Asset memory vault) = iReg.lookupAssetByAddress(sUsde);
        assertEq(vault.priceSource.addr, address(0), "fork: the vault must have no price source");
        assertEq(_price(sUsde), address(0), "fork: an absent source must carry no denomination");

        // ── Point 2: `deploy` reads both legs' decimals LIVE, off real contracts ──
        //
        // Orientation is fixed and load-bearing: REF fills the oracle's BASE slots, CA the QUOTE slots.
        // So with ca = USDC and ref = sUSDe, the base leg is the vault and the quote leg is the token.
        uint8 shareDecimals = IERC20Metadata(sUsde).decimals();
        uint8 usdcDecimals = IERC20Metadata(usdc).decimals();

        address wrapper = iReg.deploy(usdc, sUsde, IMarketRegistry.OracleMode.NAV, bytes32(0));
        assertTrue(wrapper != address(0), "fork: deploy returned no wrapper");
        assertEq(
            iReg.lookupWrapper(usdc, sUsde, IMarketRegistry.OracleMode.NAV),
            wrapper,
            "fork: the NAV wrapper is not recorded under its own mode"
        );

        // BASE = the reference leg = the real vault, read as ERC-4626.
        assertEq(wrapperFactory.lastBaseVault(), sUsde, "fork: the vault must occupy the base VAULT slot");
        assertEq(
            wrapperFactory.lastBaseSample(),
            10 ** uint256(shareDecimals),
            "fork: the conversion sample must be 10 ** the vault's LIVE share decimals"
        );
        assertEq(wrapperFactory.lastBaseDecimals(), uint256(shareDecimals), "fork: base token decimals read live");
        // `"USD"` is already the terminus, so no bridge feed is wired and a zero feed reads as price 1.
        assertEq(wrapperFactory.lastBaseFeed1(), address(0), "fork: a dollar vault leg needs no bridge feed");
        assertEq(wrapperFactory.lastBaseFeed2(), address(0), "fork: a dollar vault leg needs no second hop");

        // QUOTE = the collateral leg = USDC, which has no NAV source, so NAV mode falls back to its
        // price source. A leg with no vault MUST carry a sample of exactly 1 — the Morpho oracle
        // rejects anything else with a bare string revert.
        assertEq(wrapperFactory.lastQuoteVault(), address(0), "fork: an aggregator leg fills no vault slot");
        assertEq(wrapperFactory.lastQuoteSample(), 1, "fork: an aggregator leg's sample must be exactly 1");
        assertEq(wrapperFactory.lastQuoteFeed1(), usdc, "fork: the price source occupies feed1");
        assertEq(wrapperFactory.lastQuoteFeed2(), address(0), "fork: a dollar aggregator leg needs no bridge feed");
        assertEq(wrapperFactory.lastQuoteDecimals(), uint256(usdcDecimals), "fork: quote token decimals read live");

        // The two legs really do differ, so a decimals mix-up between them could not pass unnoticed.
        assertTrue(shareDecimals != usdcDecimals, "fork: the two legs must have different decimals to be a real check");
    }

    // ── harness ──────────────────────────────────────────────────────────────────

    /// @dev Stand the registry up ON THE FORK and put the ONE conversion edge the Ether-quoted leaf needs
    ///      into the store. `"USD"` and `"ETH"` are seeded as LABELS by the constructor, but a label is
    ///      only half of what a source needs: `addAsset` also requires a dollar PATH inside the source's
    ///      hop budget, and an `"ETH"`-quoted aggregator source has a budget of exactly one hop. Without
    ///      this edge the WETH leaf reverts `NoConversionPathToUsd`.
    ///
    ///      Deployment goes through the fixture's `_deployRegistry`, which supplies the registry's THIRD
    ///      constructor argument (the fixed-rate oracle factory) and records the mock wrapper factory as
    ///      `wrapperFactory` — the recorder the deploy-wiring assertions read.
    function _setUpRegistry() internal {
        _deployRegistry(address(this)); // test contract is the owner, so no pranking is needed
        _addEthUsdFeed();
    }

    // ── builders ─────────────────────────────────────────────────────────────────

    /// @dev A plain token with one PRICE source carrying `denomination`. The source address is the token
    ///      itself: the registry never CALLS a price source, it only records the address into `feed1` and
    ///      validates the declared unit, so no live aggregator is needed here.
    function _addLeaf(address addr, string memory name, address denomination) internal {
        iReg.addAssets(one(mkPriceOnlyAsset(addr, name, addr, denomination)));
    }

    /// @dev A real ERC-4626 vault as a NAV source. US Dollars describes the VAULT'S UNDERLYING (see
    ///      `AssetSource.denomination`), which for sUSDe is USDe, and resolves in zero hops.
    function _addVault(address addr, string memory name) internal {
        iReg.addAssets(one(mkNavOnlyAsset(addr, name, addr, USD_UNIT)));
    }

    function _price(address addr) internal view returns (address) {
        return _storedDenomination(addr, IMarketRegistry.SourceType.PRICE);
    }

    function _nav(address addr) internal view returns (address) {
        return _storedDenomination(addr, IMarketRegistry.SourceType.NAV);
    }
}
