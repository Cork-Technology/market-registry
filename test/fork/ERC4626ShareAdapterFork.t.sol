// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {ERC4626ShareAdapter} from "../../src/adapters/ERC4626ShareAdapter.sol";
import {IERC4626ShareAdapter} from "../../src/interfaces/IERC4626ShareAdapter.sol";

/// @title ERC4626ShareAdapterFork — env-gated Arbitrum-fork check for the two live deployments.
/// @notice The deterministic suite ({ERC4626ShareAdapterTest}) pins the math against mocks with zero
///         RPC dependency. THIS suite points the same adapter at the REAL vaults, so the one thing
///         mocks cannot prove gets proven: that `convertToAssets` / `asset()` / `decimals()` are
///         genuinely `staticcall`-safe on both live builds — the Autopool's `previewRedeem` and
///         `maxWithdraw` are not `view` and the Lagoon vault's whole `preview*` family reverts by
///         ERC-7540 mandate, so a wrong method choice fails here and only here.
///
///         CI CONTRACT — never block on a missing RPC endpoint: the fork URL is read with `vm.envOr`
///         defaulting to an empty string, and each test SKIPS CLEANLY (`vm.skip(true)`) before any
///         fork call when it is absent. `CORK_RPC_URL_42161` does NOT need to be an archive node:
///         `_forkOrSkip` calls `createSelectFork` with NO block pin, so every read in this suite lands
///         at the chain head and the manifest's public Arbitrum endpoint
///         (https://arb1.arbitrum.io/rpc) serves all of them. Pin a block here and that stops being
///         true — a pinned fork does need archive depth.
///
///         NO EXACT SNAPSHOT EQUALITY. arbUSD's `totalAssets()` unlocks profit continuously over an
///         86400-second window, so its share price moves every second and any hardcoded equality would
///         be flaky by construction. Both tests assert a tolerance band plus an exact recomputation
///         against values read in the SAME call, which is the part that actually pins the formula.
contract ERC4626ShareAdapterForkTest is Test {
    /// @dev Empty => skip. Any latest-block Arbitrum endpoint works; no archive depth is required.
    string internal constant RPC_ENV = "CORK_RPC_URL_42161";

    /// @dev Tokemak Autopool "Tokemak arbUSD", 18-decimal shares over native USDC.
    address internal constant ARBUSD = 0xf63b7F49B4f5Dc5D0e7e583Cfd79DC64E646320c;

    /// @dev Lagoon v0.5.0 "DACM LIT Strategy" (`symbol()` is "USDACM", `name()` is "Sandbox"),
    ///      an ERC-7540 asynchronous vault, 18-decimal shares over native USDC.
    address internal constant DACM_LIT = 0x018282d5b510F00dCacB8F4a81c3901d2FC9Da51;

    /// @dev Native USDC on Arbitrum, 6 decimals — the `asset()` of both vaults.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev Chainlink USDC / USD on Arbitrum, 8 decimals.
    address internal constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    uint8 internal constant OUT_DECIMALS = 8;

    /// @dev Both vaults hold a roughly-dollar-denominated book. A share outside $0.50-$2.00 means the
    ///      adapter is wired wrong (bad feed, bad decimals), not that the strategy moved.
    int256 internal constant MIN_REASONABLE = 50_000_000; // $0.50
    int256 internal constant MAX_REASONABLE = 200_000_000; // $2.00

    // ---------------------------------------------------------------------------------------------
    // Phase 2 rows — config/erc4626-share-adapter/42161.toml indices 2-7.
    // ---------------------------------------------------------------------------------------------

    /// @dev Fluid fUSDT lending receipt — 6-decimal shares over USD₮0 (Tether), also 6 decimals.
    address internal constant FLUID_FUSDT = 0x4A03F37e7d3fC243e3f99341d36f4b829BEe5E03;

    /// @dev Fluid fWETH lending receipt — 18-decimal shares over WETH, also 18 decimals.
    address internal constant FLUID_FWETH = 0x45Df0656F8aDf017590009d2f1898eeca4F0a205;

    /// @dev Morpho MEV Capital USDC (MetaMorpho) — 18-decimal shares over 6-decimal native USDC.
    address internal constant MC_USDC = 0xa60643c90A542A95026C0F1dbdB0615fF42019Cf;

    /// @dev Dolomite dUSDC (DolomiteMargin market 17) — 6-decimal shares over native USDC.
    address internal constant DOLOMITE_DUSDC = 0x444868B6e8079ac2c55eea115250f92C2b2c4D14;

    /// @dev Dolomite dWETH (DolomiteMargin market 0) — 18-decimal shares over WETH.
    address internal constant DOLOMITE_DWETH = 0xf7b5127B510E568fdC39e6Bb54e2081BFaD489AF;

    /// @dev Euler Earn USDC aggregator — 6-decimal shares over 6-decimal native USDC.
    address internal constant EULER_EARN_USDC = 0xe4783824593a50Bfe9dc873204CEc171ebC62dE0;

    /// @dev USD₮0 on Arbitrum, 6 decimals — the post-rebrand canonical Tether, `asset()` of fUSDT.
    address internal constant USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    /// @dev WETH on Arbitrum, 18 decimals — the `asset()` of both WETH-underlying vaults.
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @dev Chainlink USDT / USD on Arbitrum, 8 decimals. Pivots against USD₮0.
    address internal constant USDT_USD_FEED = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;

    /// @dev Chainlink ETH / USD on Arbitrum, 8 decimals. Pivots against WETH.
    address internal constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    /// @dev Basis-point denominator for the band edges below.
    uint256 internal constant BPS = 10_000;

    /// @dev The default band: the share is worth between half and twice ONE UNIT OF ITS OWN
    ///      UNDERLYING, measured against the same feed answer the adapter itself just used. Stated as
    ///      a ratio, never as a dollar figure, so it does not rot when USD prices move — a WETH share
    ///      is checked against live ETH / USD, a USDC share against live USDC / USD. It is a wiring
    ///      check, not a strategy check: every failure mode this catches (wrong feed, wrong decimals,
    ///      wrong pivot) is off by 1e6 or more, never by 20%.
    uint256 internal constant BAND_MIN_BPS = 5_000; // 0.50x underlying
    uint256 internal constant BAND_MAX_BPS = 20_000; // 2.00x underlying

    /// @dev dUSDC is the one row that is NOT near parity: Dolomite's share price is a monotonically
    ///      rising interest index, currently ~1.27 USDC per share. A 0.50x floor would be vacuous for
    ///      it — a share that fell to parity would still pass — so it gets a floor ABOVE parity. The
    ///      ceiling leaves room for years of accrual at Dolomite's supply rates.
    uint256 internal constant DUSDC_BAND_MIN_BPS = 10_500; // 1.05x USDC
    uint256 internal constant DUSDC_BAND_MAX_BPS = 17_500; // 1.75x USDC

    /// @dev One row of `config/erc4626-share-adapter/42161.toml`, plus the construction facts the
    ///      adapter should derive from chain and the band its answer must land in.
    struct Row {
        address vault;
        address feed;
        address underlying;
        string description;
        uint256 expectedSample;
        uint256 expectedScaleNumerator;
        uint256 expectedScaleDenominator;
        uint256 minBps;
        uint256 maxBps;
    }

    function _forkOrSkip() internal returns (bool ok) {
        string memory rpc = vm.envOr(RPC_ENV, string(""));
        if (bytes(rpc).length == 0) {
            emit log_string(string.concat(
                    "SKIP: ",
                    RPC_ENV,
                    " unset - set it to any Arbitrum RPC (e.g. https://arb1.arbitrum.io/rpc) to run the fork checks"
                ));
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        return true;
    }

    function _assertLiveAdapter(address vault, string memory description) internal {
        ERC4626ShareAdapter adapter = new ERC4626ShareAdapter(vault, USDC_USD_FEED, OUT_DECIMALS, description);

        // Construction reads the three decimals off-chain-free; confirm they are what we assumed.
        assertEq(adapter.sample(), 1e18, "share decimals");
        assertEq(adapter.scaleNumerator(), 1, "numerator");
        assertEq(adapter.scaleDenominator(), 1e6, "denominator: underlying decimals");
        assertEq(adapter.decimals(), OUT_DECIMALS, "output decimals");
        assertEq(adapter.description(), description, "description");
        assertEq(IERC4626(vault).asset(), USDC, "asset");

        (, int256 answer,,,) = adapter.latestRoundData();
        emit log_named_decimal_int(description, answer, OUT_DECIMALS);

        // Tolerance band, NOT an equality: arbUSD's price drifts every second.
        assertGt(answer, MIN_REASONABLE, "share price implausibly low");
        assertLt(answer, MAX_REASONABLE, "share price implausibly high");

        // Exact recomputation from the same block — this is what pins the formula.
        uint256 assets = IERC4626(vault).convertToAssets(1e18);
        (, int256 feedAnswer,,,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        // casting to 'int256'/'uint256' is safe because the band assertions above already pin the
        // result to roughly 1e8, and `feedAnswer` is a live Chainlink USD price.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(answer, int256(assets * uint256(feedAnswer) / 1e6), "formula");
    }

    /// @dev Also the live proof that `convertToAssets` survives `staticcall` on the Autopool build,
    ///      where `previewRedeem` and `maxWithdraw` do not.
    function test_fork_arbUsd_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertLiveAdapter(ARBUSD, "arbUSD / USD");
    }

    /// @dev Also the live proof that `convertToAssets` survives on an ERC-7540 async vault, where the
    ///      whole `preview*` family reverts by mandate.
    function test_fork_dacmLit_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertLiveAdapter(DACM_LIT, "USDACM / USD");
    }

    /// @dev The adapter is only ever consumed through `STATICCALL` (Morpho's oracle reads are `view`).
    ///      Assert that explicitly rather than relying on the solc-level `view` modifier, which cannot
    ///      see through the external calls.
    function test_fork_latestRoundDataIsStaticcallSafe() public {
        if (!_forkOrSkip()) return;

        address[2] memory vaults = [ARBUSD, DACM_LIT];
        string[2] memory descriptions = ["arbUSD / USD", "USDACM / USD"];

        for (uint256 i = 0; i < vaults.length; ++i) {
            address adapter = address(new ERC4626ShareAdapter(vaults[i], USDC_USD_FEED, OUT_DECIMALS, descriptions[i]));
            (bool success, bytes memory data) =
                adapter.staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
            assertTrue(success, "latestRoundData reverted under staticcall");

            (, int256 answer,,,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
            assertGt(answer, MIN_REASONABLE);
            assertLt(answer, MAX_REASONABLE);
        }
    }

    // =============================================================================================
    // Phase 2 rows — one test per new entry in config/erc4626-share-adapter/42161.toml.
    //
    // Every band below is derived FROM THE LIVE FEED ANSWER read in the same call, never from a
    // hardcoded dollar figure, so none of these rot as prices move. The unit each share is measured
    // against is its own underlying: fWETH is judged against ETH / USD, MCUSDC against USDC / USD.
    // =============================================================================================

    /// @dev Counts "/" in a description. The onboarding CLI's `parseQuoteUnit` (enrich/sources.ts)
    ///      does `description.split("/")` and reads the LAST segment as the source's quote unit. Zero
    ///      slashes yields no quote unit and silently downgrades the source to `judgment`; two or more
    ///      makes the parsed quote unit a fragment of the real one. Exactly one is the contract.
    function _slashCount(string memory s) internal pure returns (uint256 count) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == "/") ++count;
        }
    }

    /// @dev Full check for one config row against the live chain.
    function _assertRow(Row memory row) internal returns (ERC4626ShareAdapter adapter) {
        adapter = new ERC4626ShareAdapter(row.vault, row.feed, OUT_DECIMALS, row.description);

        assertEq(adapter.vault(), row.vault, "vault");
        assertEq(adapter.feed(), row.feed, "feed");
        assertEq(adapter.decimals(), OUT_DECIMALS, "answer decimals must equal the configured 8");
        assertEq(adapter.description(), row.description, "description");
        assertEq(_slashCount(adapter.description()), 1, "description must contain exactly one '/'");

        // The pivot the two legs have to meet at. Nothing on-chain can verify it; this test does.
        assertEq(IERC4626(row.vault).asset(), row.underlying, "pivot: vault.asset() is not the feed's base");

        // The three scale constants are derived from three on-chain decimal readings — pin all three.
        assertEq(adapter.sample(), row.expectedSample, "sample: one whole share");
        assertEq(adapter.scaleNumerator(), row.expectedScaleNumerator, "scale numerator");
        assertEq(adapter.scaleDenominator(), row.expectedScaleDenominator, "scale denominator");

        // Read through STATICCALL — the only way Morpho's oracle stack ever calls this.
        (bool success, bytes memory data) =
            address(adapter).staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        assertTrue(success, "latestRoundData reverted under staticcall");
        (, int256 answer,,,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));

        assertGt(answer, 0, "answer must be strictly positive");

        (, int256 feedAnswer,,,) = AggregatorV3Interface(row.feed).latestRoundData();
        assertGt(feedAnswer, 0, "feed answer must be positive for the band to mean anything");

        // casting to 'int256' is safe: both bounds are basis points of a live Chainlink USD price.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 lowerBound = feedAnswer * int256(row.minBps) / int256(BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 upperBound = feedAnswer * int256(row.maxBps) / int256(BPS);
        assertGe(answer, lowerBound, "share price implausibly low against its own underlying");
        assertLe(answer, upperBound, "share price implausibly high against its own underlying");

        // Exact recomputation from the same block — this is what pins the formula.
        uint256 assets = IERC4626(row.vault).convertToAssets(row.expectedSample);
        // casting to 'uint256' is safe because `feedAnswer` was asserted strictly positive above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 feedAnswerUint = uint256(feedAnswer);
        // casting to 'int256' is safe because the band assertions above already pin the result to
        // roughly the feed's own magnitude.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 expected = int256(assets * feedAnswerUint * row.expectedScaleNumerator / row.expectedScaleDenominator);
        assertEq(answer, expected, "formula");

        emit log_named_decimal_int(row.description, answer, OUT_DECIMALS);
        emit log_named_decimal_int(
            string.concat(row.description, " [underlying per share]"), answer * 1e8 / feedAnswer, OUT_DECIMALS
        );
    }

    /// @dev Row 2. Fluid lending receipt, 6-decimal shares over 6-decimal USD₮0. The underlying's
    ///      `symbol()` is "USD₮0" against a feed described "USDT / USD" — that mismatch is the
    ///      post-rebrand canonical Arbitrum Tether and is expected; the address is what matters.
    function test_fork_fluidFusdt_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertRow(
            Row({
                vault: FLUID_FUSDT,
                feed: USDT_USD_FEED,
                underlying: USDT0,
                description: "fUSDT / USD",
                expectedSample: 1e6,
                expectedScaleNumerator: 1,
                expectedScaleDenominator: 1e6,
                minBps: BAND_MIN_BPS,
                maxBps: BAND_MAX_BPS
            })
        );
    }

    /// @dev Row 3. Fluid lending receipt, 18-decimal shares over WETH. Priced against live ETH / USD,
    ///      so the band is 0.5x-2x the current ether price rather than a dollar range.
    function test_fork_fluidFweth_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertRow(
            Row({
                vault: FLUID_FWETH,
                feed: ETH_USD_FEED,
                underlying: WETH,
                description: "fWETH / USD",
                expectedSample: 1e18,
                expectedScaleNumerator: 1,
                expectedScaleDenominator: 1e18,
                minBps: BAND_MIN_BPS,
                maxBps: BAND_MAX_BPS
            })
        );
    }

    /// @dev Row 4. MetaMorpho's asymmetric shape: 18-decimal shares over a 6-decimal underlying. The
    ///      1e18 sample with a 1e6 denominator is exactly the case a hand-written rule gets wrong.
    function test_fork_mevCapitalUsdc_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertRow(
            Row({
                vault: MC_USDC,
                feed: USDC_USD_FEED,
                underlying: USDC,
                description: "MCUSDC / USD",
                expectedSample: 1e18,
                expectedScaleNumerator: 1,
                expectedScaleDenominator: 1e6,
                minBps: BAND_MIN_BPS,
                maxBps: BAND_MAX_BPS
            })
        );
    }

    /// @dev Row 5. Dolomite market 17 (NATIVE USDC — a different Arbitrum contract also reports
    ///      symbol "dUSDC" but wraps bridged USDC.e, so the pivot assertion is load-bearing here).
    ///      Its share is an interest index well above parity, hence the raised floor.
    function test_fork_dolomiteDusdc_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertRow(
            Row({
                vault: DOLOMITE_DUSDC,
                feed: USDC_USD_FEED,
                underlying: USDC,
                description: "dUSDC / USD",
                expectedSample: 1e6,
                expectedScaleNumerator: 1,
                expectedScaleDenominator: 1e6,
                minBps: DUSDC_BAND_MIN_BPS,
                maxBps: DUSDC_BAND_MAX_BPS
            })
        );
    }

    /// @dev Row 6. Dolomite market 0, 18-decimal shares over WETH, priced against live ETH / USD.
    function test_fork_dolomiteDweth_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertRow(
            Row({
                vault: DOLOMITE_DWETH,
                feed: ETH_USD_FEED,
                underlying: WETH,
                description: "dWETH / USD",
                expectedSample: 1e18,
                expectedScaleNumerator: 1,
                expectedScaleDenominator: 1e18,
                minBps: BAND_MIN_BPS,
                maxBps: BAND_MAX_BPS
            })
        );
    }

    /// @dev Row 7. Euler Earn aggregator, 6-decimal shares over 6-decimal native USDC. The vault
    ///      carries already-socialized bad debt (`lostAssets()`), which is priced into
    ///      `convertToAssets` rather than hidden — the band still holds.
    function test_fork_eulerEarnUsdc_sharePriceInUsd() public {
        if (!_forkOrSkip()) return;
        _assertRow(
            Row({
                vault: EULER_EARN_USDC,
                feed: USDC_USD_FEED,
                underlying: USDC,
                description: "eeUSDC / USD",
                expectedSample: 1e6,
                expectedScaleNumerator: 1,
                expectedScaleDenominator: 1e6,
                minBps: BAND_MIN_BPS,
                maxBps: BAND_MAX_BPS
            })
        );
    }

    // =============================================================================================
    // The asymmetric zero handling. Documented here, NOT fixed in this phase.
    // =============================================================================================

    /// @dev KNOWN DEFECT — this test asserts the WRONG behaviour on purpose, so that a later fix has
    ///      to come here and delete it deliberately rather than discover the gap in production.
    ///
    ///      `_sharePrice` guards only one of its two legs. The feed leg is checked
    ///      (`require(feedAnswer > 0, InvalidFeedAnswer(...))`, proven by the companion test below),
    ///      but the vault leg is not: when `convertToAssets(oneShare)` returns 0 the product is 0 and
    ///      the adapter PUBLISHES that zero, carrying the feed's genuine, fresh round metadata with
    ///      it. A consumer applying a staleness policy to `updatedAt` sees a perfectly current round
    ///      and has no signal that the price is meaningless.
    ///
    ///      This is reachable on real vaults, not just under a mock: any vault whose share price
    ///      underflows the underlying's precision returns 0 from `convertToAssets`. A 1e18-share
    ///      vault over a 6-decimal underlying needs a share worth under 1e-6 of the underlying — a
    ///      near-total loss, but a state a live vault can enter.
    function test_fork_zeroConvertToAssets_publishesConfidentZero() public {
        if (!_forkOrSkip()) return;

        ERC4626ShareAdapter adapter = new ERC4626ShareAdapter(MC_USDC, USDC_USD_FEED, OUT_DECIMALS, "MCUSDC / USD");

        (, int256 liveAnswer,,,) = adapter.latestRoundData();
        assertGt(liveAnswer, 0, "precondition: the real vault prices above zero");

        vm.mockCall(MC_USDC, abi.encodeCall(IERC4626.convertToAssets, (adapter.sample())), abi.encode(uint256(0)));

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();

        assertEq(answer, 0, "DEFECT: a zero conversion publishes zero instead of reverting");
        assertGt(roundId, 0, "DEFECT: the zero ships with a real round id");
        assertGt(updatedAt, 0, "DEFECT: the zero ships with a fresh updatedAt, so staleness gates pass");

        vm.clearMockedCalls();
    }

    /// @dev The other half of the asymmetry, and the behaviour the vault leg should mirror: a
    ///      non-positive FEED answer reverts with a typed error rather than publishing.
    function test_fork_zeroFeedAnswer_revertsInvalidFeedAnswer() public {
        if (!_forkOrSkip()) return;

        ERC4626ShareAdapter adapter = new ERC4626ShareAdapter(MC_USDC, USDC_USD_FEED, OUT_DECIMALS, "MCUSDC / USD");

        vm.mockCall(
            USDC_USD_FEED,
            abi.encodeCall(AggregatorV3Interface.latestRoundData, ()),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert(abi.encodeWithSelector(IERC4626ShareAdapter.InvalidFeedAnswer.selector, int256(0)));
        adapter.latestRoundData();

        vm.clearMockedCalls();
    }
}
