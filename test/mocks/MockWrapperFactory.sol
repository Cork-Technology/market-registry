// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IWrapperFactory} from "../../src/interfaces/IWrapperFactory.sol";
import {IMarketRegistry} from "../../src/interfaces/IMarketRegistry.sol";

/// @title MockToken — minimal token exposing a settable `decimals()` for the deploy path.
/// @notice `MarketRegistry.deploy` re-reads each asset's live `decimals()` (never stored), so any
///         address used as a `ca` / `ref` in a deploy test MUST be a contract that answers
///         `decimals()`. A NAV leg additionally reads `decimals()` off the VAULT (the conversion
///         sample is `10 ** shareDecimals`), so a vault-shaped source needs this too. The value is
///         settable so decimal-orientation cases can vary it.
/// @dev Deliberately NOT a Phoenix `DummyERC20`: those mint on fallback, so the registry's
///      `asset()` probe burns essentially all forwarded gas against them. Local mocks only.
contract MockToken {
    uint8 public decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }
}

/// @title MockWrapperFactory — configurable stand-in for `WrapperRateConsumerFactory`.
/// @notice `MarketRegistry.deploy` calls `createWrapperRateConsumer(...)` on the one immutable
///         factory it was constructed with, and records the returned `wrapper`. The real factory
///         reaches into the private Phoenix submodule, so tests wire this mock in instead. Its
///         behavior is selected by {Mode} so the deploy suite can drive every branch of `deploy`:
///
///           - Deterministic (default): returns a wrapper derived purely from `wrapperSalt` (and an
///             oracle from `morphoSalt`). Because `deploy` sets
///             `salt = keccak256(abi.encode(registry, ca, ref, caSource, refSource))`, a test can predict the
///             exact wrapper for a given pair AND resolved-source combination — that determinism is
///             what makes the repeat / mode-separation cases assertable.
///           - ZeroWrapper: returns `address(0)` — drives the `ZeroAddress` gate.
///           - Fixed: returns a caller-set fixed wrapper on every call — drives the
///             arbitrary-return-recorded-verbatim case.
///           - Revert: reverts with {FactoryReverted} — proves a factory revert bubbles out of deploy.
///           - Reentrant: on its FIRST invocation (the outer deploy) it re-enters
///             `registry.deploy(ca2, ref2, mode2)` for a second registered pair, then returns the
///             fixed wrapper. Because wrappers are keyed by pair AND resolved sources, the nested and
///             outer keys record independently. The mock snapshots whether the OUTER key was already
///             recorded at the moment the factory is entered — it must be false, proving `deploy`
///             writes nothing before the external call (CEI-by-construction).
///
///         EVERY argument of the twelve-argument factory call is recorded from the last invocation,
///         because the vault slots and conversion samples stopped being hard-coded: a NAV leg now
///         passes a real vault and `10 ** shareDecimals`, and that wiring is exactly what the deploy
///         suite has to assert.
contract MockWrapperFactory is IWrapperFactory {
    enum Mode {
        Deterministic,
        ZeroWrapper,
        Fixed,
        Revert,
        Reentrant
    }

    error FactoryReverted();

    Mode public mode;
    address public fixedWrapper;

    // Reentrancy configuration (Mode.Reentrant).
    IMarketRegistry public registry;
    address public reentrantCa;
    address public reentrantRef;
    IMarketRegistry.OracleMode public reentrantMode;
    address public outerCa;
    address public outerRef;
    IMarketRegistry.OracleMode public outerMode;
    bool internal _reentered;

    // Observation captured at the moment the OUTER deploy invokes the factory. If `deploy` obeys
    // checks-effects-interactions-by-construction, the outer key has NOT been recorded yet, so this
    // reads false.
    bool public outerRecordedAtEntry;

    // Every argument of the LAST `createWrapperRateConsumer` call, so the wiring tests can assert
    // what each leg was resolved to. Test-mock storage only — does NOT touch the MarketRegistry
    // storage layout under test.
    address public lastBaseVault;
    uint256 public lastBaseSample;
    address public lastBaseFeed1;
    address public lastBaseFeed2;
    uint256 public lastBaseDecimals;
    address public lastQuoteVault;
    uint256 public lastQuoteSample;
    address public lastQuoteFeed1;
    address public lastQuoteFeed2;
    uint256 public lastQuoteDecimals;
    bytes32 public lastMorphoSalt;
    bytes32 public lastWrapperSalt;
    uint256 public callCount;

    // ── configuration ────────────────────────────────────────────────────────────

    function setMode(Mode m) external {
        mode = m;
    }

    /// @notice Return `w` verbatim on every call (Mode.Fixed).
    function setFixedWrapper(address w) external {
        fixedWrapper = w;
        mode = Mode.Fixed;
    }

    /// @notice Re-enter `reg.deploy(ca2, ref2, mode2)` during the outer
    ///         `deploy(outerCa_, outerRef_, outerMode_)` call, then return `wrapper`. The outer pair
    ///         and mode are recorded so the mock can prove the outer key was NOT yet written when the
    ///         factory was entered.
    function configureReentrant(
        IMarketRegistry reg,
        address ca2,
        address ref2,
        IMarketRegistry.OracleMode mode2,
        address outerCa_,
        address outerRef_,
        IMarketRegistry.OracleMode outerMode_,
        address wrapper
    ) external {
        registry = reg;
        reentrantCa = ca2;
        reentrantRef = ref2;
        reentrantMode = mode2;
        outerCa = outerCa_;
        outerRef = outerRef_;
        outerMode = outerMode_;
        fixedWrapper = wrapper;
        mode = Mode.Reentrant;
    }

    // ── deterministic predictors (mirror the mock's own derivation) ────────────────

    function predictWrapper(bytes32 wrapperSalt) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("wrapper", wrapperSalt)))));
    }

    function predictOracle(bytes32 morphoSalt) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("oracle", morphoSalt)))));
    }

    /// @notice The wrapper `deploy` will return in Deterministic mode. The salt is
    ///         `keccak256(abi.encode(registry, ca, ref, caSource, refSource))`, matching
    ///         `MarketRegistry.deploy` — the two source addresses are the ones the requested
    ///         `OracleMode` actually resolved to, which is why a NAV and a PRICE wrapper for the same
    ///         pair land on different addresses, and the registry address is in the hash so two
    ///         registry instances sharing one factory never derive the same salt.
    function predictWrapperFor(address registry_, address ca, address ref, address caSource, address refSource)
        external
        pure
        returns (address)
    {
        return predictWrapper(keccak256(abi.encode(registry_, ca, ref, caSource, refSource)));
    }

    // ── IWrapperFactory ────────────────────────────────────────────────────────────

    function createWrapperRateConsumer(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 morphoSalt,
        bytes32 wrapperSalt
    ) external override returns (address wrapper, address oracle) {
        _record(baseVault, baseVaultConversionSample, baseFeed1, baseFeed2, baseTokenDecimals, true);
        _record(quoteVault, quoteVaultConversionSample, quoteFeed1, quoteFeed2, quoteTokenDecimals, false);
        lastMorphoSalt = morphoSalt;
        lastWrapperSalt = wrapperSalt;
        callCount++;

        if (mode == Mode.ZeroWrapper) {
            return (address(0), address(0));
        }
        if (mode == Mode.Revert) {
            revert FactoryReverted();
        }
        if (mode == Mode.Fixed) {
            return (fixedWrapper, predictOracle(morphoSalt));
        }
        if (mode == Mode.Reentrant) {
            if (!_reentered) {
                // Snapshot the outer key as observed from inside the factory (CEI proof): the outer
                // `deploy` must not have recorded its wrapper yet.
                outerRecordedAtEntry = registry.lookupWrapper(outerCa, outerRef, outerMode) != address(0);
                _reentered = true;
                // Nested deploy records `fixedWrapper` under the nested key (it is this same factory
                // in Reentrant mode, so it also returns `fixedWrapper`); the outer call then records
                // the same address under its own key.
                registry.deploy(reentrantCa, reentrantRef, reentrantMode);
            }
            return (fixedWrapper, predictOracle(morphoSalt));
        }
        // Deterministic (default).
        return (predictWrapper(wrapperSalt), predictOracle(morphoSalt));
    }

    /// @dev One side's five arguments. Split out so the twelve-argument frame stays under the legacy
    ///      (non-`via_ir`) stack limit, the same reason the registry splits its own deploy path.
    function _record(address vault, uint256 sample, address feed1, address feed2, uint256 decimals_, bool isBase)
        private
    {
        if (isBase) {
            lastBaseVault = vault;
            lastBaseSample = sample;
            lastBaseFeed1 = feed1;
            lastBaseFeed2 = feed2;
            lastBaseDecimals = decimals_;
        } else {
            lastQuoteVault = vault;
            lastQuoteSample = sample;
            lastQuoteFeed1 = feed1;
            lastQuoteFeed2 = feed2;
            lastQuoteDecimals = decimals_;
        }
    }
}
