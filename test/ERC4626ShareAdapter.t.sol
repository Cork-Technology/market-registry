// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ShareAdapter} from "../src/adapters/ERC4626ShareAdapter.sol";
import {IERC4626ShareAdapter} from "../src/interfaces/IERC4626ShareAdapter.sol";
import {AggregatorV3Interface} from "@morpho-oracle/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "./mocks/JITMocks.sol";

/// @dev Settable Chainlink-style V3 feed. The repo's only aggregator double (`MockLatestAnswerFeed`
///      in AggregatorV2V3Adapter.t.sol) is V2-only, so this suite brings its own.
contract MockAggregatorV3 {
    uint8 public decimals;
    string public description;
    uint256 public constant version = 6; // what Chainlink's real USDC/USD reports on Arbitrum

    int256 internal answer;
    uint80 internal roundId;
    uint256 internal startedAt;
    uint256 internal updatedAt;
    uint80 internal answeredInRound;

    constructor(uint8 decimals_, int256 answer_, string memory description_) {
        decimals = decimals_;
        answer = answer_;
        description = description_;
        roundId = 1;
        answeredInRound = 1;
        startedAt = 1;
        updatedAt = 1;
    }

    function set(int256 answer_) external {
        answer = answer_;
    }

    function setRound(uint80 roundId_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @dev ERC-4626 stand-in exposing ONLY the three methods the adapter is allowed to touch. The
///      `preview*` family is deliberately absent: it reverts on the ERC-7540 async vault and is
///      non-`view` on the Autopool build, so a mock that answered it would hide the real constraint.
contract MockVault4626 {
    uint8 public decimals;
    address public asset;

    /// @notice Underlying assets returned for exactly one whole share (`10 ** decimals`).
    uint256 public assetsPerShare;

    constructor(uint8 decimals_, address asset_, uint256 assetsPerShare_) {
        decimals = decimals_;
        asset = asset_;
        assetsPerShare = assetsPerShare_;
    }

    function set(uint256 assetsPerShare_) external {
        assetsPerShare = assetsPerShare_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsPerShare / (10 ** decimals);
    }
}

contract ERC4626ShareAdapterTest is Test {
    MockERC20 internal usdc;
    MockAggregatorV3 internal usdcUsd;
    MockVault4626 internal arbUsdVault;
    MockVault4626 internal dacmVault;

    uint8 internal constant OUT_DECIMALS = 8;
    uint8 internal constant SHARE_DECIMALS = 18;
    uint8 internal constant UNDERLYING_DECIMALS = 6;
    uint8 internal constant FEED_DECIMALS = 8;

    /// @dev Live Chainlink USDC/USD sample on Arbitrum: $0.99987179 at 8 decimals.
    int256 internal constant USDC_USD = 99_987_179;

    /// @dev `convertToAssets(1e18)` snapshots off the two live vaults, in 6-decimal USDC.
    uint256 internal constant ARBUSD_RATE = 1_123_274; // 1 share = 1.123274 USDC
    uint256 internal constant DACM_RATE = 1_026_847; // 1 share = 1.026847 USDC

    /// @dev Worked results: rate * feed / 1e6, floored. $1.12312998 and $1.02671534.
    int256 internal constant ARBUSD_EXPECTED = 112_312_998;
    int256 internal constant DACM_EXPECTED = 102_671_534;

    string internal constant ARBUSD_DESCRIPTION = "arbUSD / USD";
    string internal constant DACM_DESCRIPTION = "USDACM / USD";

    function setUp() public {
        usdc = new MockERC20("USDC", UNDERLYING_DECIMALS, false);
        usdcUsd = new MockAggregatorV3(FEED_DECIMALS, USDC_USD, "USDC / USD");
        arbUsdVault = new MockVault4626(SHARE_DECIMALS, address(usdc), ARBUSD_RATE);
        dacmVault = new MockVault4626(SHARE_DECIMALS, address(usdc), DACM_RATE);
    }

    function _create(MockVault4626 vault_, string memory description_) internal returns (ERC4626ShareAdapter) {
        return new ERC4626ShareAdapter(address(vault_), address(usdcUsd), OUT_DECIMALS, description_);
    }

    // ── worked values ────────────────────────────────────────────────────────────

    function testArbUsdWorkedValue() public {
        (, int256 answer,,,) = _create(arbUsdVault, ARBUSD_DESCRIPTION).latestRoundData();
        assertEq(answer, ARBUSD_EXPECTED);
        // Sanity on the human reading: $1.12313 to five decimal places.
        assertEq(answer / 1000, 112_312);
    }

    function testDacmLitWorkedValue() public {
        (, int256 answer,,,) = _create(dacmVault, DACM_DESCRIPTION).latestRoundData();
        assertEq(answer, DACM_EXPECTED);
        assertEq(answer / 1000, 102_671);
    }

    function testTracksVaultRateChange() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        arbUsdVault.set(DACM_RATE);
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, DACM_EXPECTED);
    }

    function testTracksFeedAnswerChange() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        usdcUsd.set(1_0000_0000); // exactly $1.00
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, 112_327_400); // rate carried straight through: 1.123274 USDC at $1
    }

    // ── decimal derivation ───────────────────────────────────────────────────────

    function testDerivesSampleFromShareDecimals() public {
        assertEq(_create(arbUsdVault, ARBUSD_DESCRIPTION).sample(), 1e18);

        MockVault4626 eightDecimalVault = new MockVault4626(8, address(usdc), 1e8);
        ERC4626ShareAdapter adapter =
            new ERC4626ShareAdapter(address(eightDecimalVault), address(usdcUsd), OUT_DECIMALS, "x / USD");
        assertEq(adapter.sample(), 1e8);
    }

    function testScaleConstantsFor18Over6Vault() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        // Feed decimals already equal the output decimals, so the only divisor is the underlying's.
        assertEq(adapter.scaleNumerator(), 1);
        assertEq(adapter.scaleDenominator(), 10 ** UNDERLYING_DECIMALS);
    }

    function testScalesUpFromLowerDecimalFeed() public {
        MockAggregatorV3 sixDecimalFeed = new MockAggregatorV3(6, 999_872, "USDC / USD");
        ERC4626ShareAdapter adapter =
            new ERC4626ShareAdapter(address(arbUsdVault), address(sixDecimalFeed), OUT_DECIMALS, ARBUSD_DESCRIPTION);

        assertEq(adapter.scaleNumerator(), 100); // 10 ** (8 - 6)
        assertEq(adapter.scaleDenominator(), 10 ** UNDERLYING_DECIMALS);

        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(adapter.decimals(), OUT_DECIMALS);
        assertEq(answer, 112_313_022); // same price, coarser feed input
    }

    function testScalesDownFromHigherDecimalFeed() public {
        MockAggregatorV3 eighteenDecimalFeed = new MockAggregatorV3(18, 999_871_790_000_000_000, "USDC / USD");
        ERC4626ShareAdapter adapter = new ERC4626ShareAdapter(
            address(arbUsdVault), address(eighteenDecimalFeed), OUT_DECIMALS, ARBUSD_DESCRIPTION
        );

        assertEq(adapter.scaleNumerator(), 1);
        assertEq(adapter.scaleDenominator(), 10 ** UNDERLYING_DECIMALS * 10 ** 10); // 10 ** (18 - 8)

        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(adapter.decimals(), OUT_DECIMALS);
        assertEq(answer, ARBUSD_EXPECTED); // identical to the 8-decimal feed
    }

    function testEighteenDecimalOutputAgainstEightDecimalFeed() public {
        ERC4626ShareAdapter adapter =
            new ERC4626ShareAdapter(address(arbUsdVault), address(usdcUsd), 18, ARBUSD_DESCRIPTION);

        assertEq(adapter.decimals(), 18);
        assertEq(adapter.scaleNumerator(), 10 ** 10); // 10 ** (18 - 8)

        // Scaling up happens BEFORE the divide, so the digits below 8 decimals survive rather than
        // being truncated — this is strictly more precise than restating the 8-decimal answer.
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, 1_123_129_985_040_460_000);
        assertEq(answer / int256(10 ** 10), ARBUSD_EXPECTED);
    }

    // ── metadata ─────────────────────────────────────────────────────────────────

    function testMetadata() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        assertEq(adapter.decimals(), OUT_DECIMALS);
        assertEq(adapter.description(), ARBUSD_DESCRIPTION);
        assertEq(adapter.version(), 1);
        assertEq(adapter.vault(), address(arbUsdVault));
        assertEq(adapter.feed(), address(usdcUsd));
    }

    function testAdapterSatisfiesAggregatorV3() public {
        // Must present as the exact interface the Morpho oracle + Cork admission consume.
        AggregatorV3Interface v3 = AggregatorV3Interface(address(_create(arbUsdVault, ARBUSD_DESCRIPTION)));
        (, int256 answer,,,) = v3.latestRoundData();
        assertEq(answer, ARBUSD_EXPECTED);
        assertEq(v3.decimals(), OUT_DECIMALS);
        assertEq(v3.description(), ARBUSD_DESCRIPTION);
        assertGt(v3.version(), 0);
    }

    /// @dev `enrich/sources.ts` splits `description()` on "/" and reads the last segment as the quote
    ///      unit, so the trailing token has to be exactly "USD" once trimmed.
    function testDescriptionQuoteUnitIsUsd() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        bytes memory d = bytes(adapter.description());
        assertEq(string(abi.encodePacked(d[d.length - 3], d[d.length - 2], d[d.length - 1])), "USD");
    }

    // ── round metadata ───────────────────────────────────────────────────────────

    function testLatestRoundDataForwardsFeedRoundMetadata() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        usdcUsd.setRound(77, 1_700_000_000, 1_700_000_500, 76);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();
        assertEq(roundId, 77);
        assertEq(answer, ARBUSD_EXPECTED);
        assertEq(startedAt, 1_700_000_000);
        assertEq(updatedAt, 1_700_000_500);
        assertEq(answeredInRound, 76);
    }

    function testGetRoundDataEchoesRoundIdAndReturnsCurrentAnswer() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        usdcUsd.setRound(77, 1_700_000_000, 1_700_000_500, 76);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.getRoundData(42);
        assertEq(roundId, 42);
        assertEq(answeredInRound, 42);
        assertEq(answer, ARBUSD_EXPECTED);
        assertEq(startedAt, 1_700_000_000);
        assertEq(updatedAt, 1_700_000_500);
    }

    // ── reverts ──────────────────────────────────────────────────────────────────

    function testRevertOnZeroFeedAnswer() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        usdcUsd.set(0);
        vm.expectRevert(abi.encodeWithSelector(IERC4626ShareAdapter.InvalidFeedAnswer.selector, int256(0)));
        adapter.latestRoundData();
    }

    function testRevertOnNegativeFeedAnswer() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        usdcUsd.set(-1);
        vm.expectRevert(abi.encodeWithSelector(IERC4626ShareAdapter.InvalidFeedAnswer.selector, int256(-1)));
        adapter.latestRoundData();
    }

    function testRevertGetRoundDataOnZeroFeedAnswer() public {
        ERC4626ShareAdapter adapter = _create(arbUsdVault, ARBUSD_DESCRIPTION);
        usdcUsd.set(0);
        vm.expectRevert(abi.encodeWithSelector(IERC4626ShareAdapter.InvalidFeedAnswer.selector, int256(0)));
        adapter.getRoundData(1);
    }

    function testRevertOnZeroVault() public {
        vm.expectRevert(IERC4626ShareAdapter.ZeroAddress.selector);
        new ERC4626ShareAdapter(address(0), address(usdcUsd), OUT_DECIMALS, ARBUSD_DESCRIPTION);
    }

    function testRevertOnZeroFeed() public {
        vm.expectRevert(IERC4626ShareAdapter.ZeroAddress.selector);
        new ERC4626ShareAdapter(address(arbUsdVault), address(0), OUT_DECIMALS, ARBUSD_DESCRIPTION);
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────────

    /// @dev The answer must stay the plain product of the two legs for any plausible pair, with no
    ///      overflow inside the checked arithmetic.
    function testFuzzMatchesReferenceFormula(uint256 rate, int256 feedAnswer) public {
        rate = bound(rate, 1, 1e18); // up to 1e12 USDC per share
        // casting to 'int256' is safe because bound() caps the value at 1e18
        // forge-lint: disable-next-line(unsafe-typecast)
        feedAnswer = int256(bound(uint256(feedAnswer), 1, 1e18));

        arbUsdVault.set(rate);
        usdcUsd.set(feedAnswer);

        (, int256 answer,,,) = _create(arbUsdVault, ARBUSD_DESCRIPTION).latestRoundData();
        // casting to 'int256'/'uint256' is safe because both legs are bounded at 1e18, so the product
        // is at most 1e36 — far inside int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(answer, int256(rate * uint256(feedAnswer) / 10 ** UNDERLYING_DECIMALS));
    }
}
