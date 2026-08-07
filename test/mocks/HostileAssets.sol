// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title HostileAssets — probe-target mock family for the denomination walk
/// @notice One mock per misbehaviour class the registry's `asset()` probe can meet, plus the
///         well-formed shapes the ten-asset replica needs. Every mock's only job is to make
///         `asset()` (selector 0x38d52e0f) behave in one specific way so that
///         `MarketRegistryLib.probeAsset` is forced down each branch of its acceptance rule.
///
///         ## The probe changed shape, and so did this file (#82)
///
///         The predecessor probe was an inline-assembly `staticcall` with a 50,000-gas cap and a
///         32-byte returndata cap: it classified EVERY hostile return shape as a leaf and could never
///         revert. `probeAsset` is now a plain `try IWrapper(target).asset()`, which is a deliberate
///         reversal (validation finding S2). Three consequences shape the mocks below:
///
///         1. A revert, and a target with NO `asset()` at all, are still caught → leaf.
///         2. MALFORMED return data — fewer than 32 bytes, no data at all, or a word whose upper 96
///            bits are dirty — makes the ABI decode revert UNCATCHABLY. That revert bubbles out of
///            `addAsset` carrying NO error data. It is not reclassified as a leaf.
///         3. There is no gas cap and no returndata cap any more. A large return is copied into
///            memory before it is decoded, so a return bomb costs gas but cannot brick an add; the
///            {ReturnBombAsset} test pins that.
///
///         Every mock here is LOCAL. Do NOT reach for a Phoenix `DummyERC20` as a probe target: those
///         mint on fallback, so the probe burns essentially all the gas forwarded to it and the
///         failure looks like a registry bug rather than a fixture one.

// ─────────────────────────────────────────────────────────────────────────────
// Well-formed shapes
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A plain token: real code, a `decimals()` the deploy path can read, and NO `asset()`.
/// @dev The "nothing to unwrap" shape, and the default stand-in for a token anywhere an asset
///      address is needed. Two properties are load-bearing:
///
///      - It has CODE. An address with no code makes the probe's ABI decode revert uncatchably
///        (see the file header), so a codeless `makeAddr` cannot be used as an asset address at all
///        any more.
///      - It has no `asset()` and no fallback, so the probe's call reverts and is caught → leaf.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }
}

/// @notice ERC-4626-shaped vault: `asset()` returns a clean, stored, non-zero underlying.
/// @dev The only shape the probe accepts. Used for vault chains and the N-deep chain.
contract MockVaultAsset {
    address private immutable _underlying;

    constructor(address underlying_) {
        _underlying = underlying_;
    }

    function asset() external view returns (address) {
        return _underlying;
    }
}

/// @notice Names the "well-formed liar" role explicitly for readers: a clean, non-zero address that
///         is a lie — it points somewhere the asset does not really unwrap to.
/// @dev The probe accepts it and hops. Detection is impossible on-chain and is admission-gated.
contract WellFormedLiarAsset {
    address private immutable _lie;

    constructor(address lie_) {
        _lie = lie_;
    }

    function asset() external view returns (address) {
        return _lie;
    }
}

/// @notice `asset()` returns a huge amount of returndata whose FIRST word is a clean, non-zero
///         address.
/// @dev Return-bomb posture under the new try/catch probe. solc copies the whole return buffer into
///      memory before decoding, so the bomb inflates memory-expansion gas — but the decode reads the
///      first word, finds a clean address, and the walk HOPS. That is the assertion: a bomb costs gas
///      and cannot brick an add. (Under the predecessor's 32-byte copy cap this shape was a leaf.)
contract ReturnBombAsset {
    address private immutable _underlying;
    uint256 private immutable _size;

    constructor(address underlying_, uint256 size_) {
        _underlying = underlying_;
        _size = size_;
    }

    function asset() external view returns (address) {
        address u = _underlying;
        uint256 n = _size;
        assembly {
            mstore(0x00, u) // first word: a clean address
            return(0x00, n) // everything past it is zero
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hostile shapes that are CAUGHT → the node degrades to a leaf
// ─────────────────────────────────────────────────────────────────────────────

/// @notice `asset()` reverts with a named error. Caught → leaf.
/// @dev Also the terminator shape in the ten-asset replica: a plain token with an `asset()` that
///      refuses is indistinguishable, to the walk, from one that has none.
contract RevertingAsset {
    error ProbeReverted();

    function asset() external pure returns (address) {
        revert ProbeReverted();
    }
}

/// @notice `asset()` returns a clean but ZERO address. Caught by the presence check → leaf.
/// @dev Distinct from the reverting case: the call and the decode both succeed, and `probeAsset`
///      refuses the hop because a zero underlying is never a node.
contract ZeroAddressAsset {
    function asset() external pure returns (address) {
        return address(0);
    }
}

/// @notice `asset()` returns its own address — a one-node self-loop. Cycle detection → UNRESOLVED.
contract SelfLoopAsset {
    function asset() external view returns (address) {
        return address(this);
    }
}

/// @notice A settable node for building multi-node cycles (A→B, B→A) and unregistered mid-chain hops.
/// @dev `setNext` lets tests wire circular references that immutables cannot express.
contract CycleNodeAsset {
    address public next;

    function setNext(address next_) external {
        next = next_;
    }

    function asset() external view returns (address) {
        return next;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Malformed-return shapes that BUBBLE — the ABI decode reverts uncatchably
// ─────────────────────────────────────────────────────────────────────────────

/// @notice `asset()` returns fewer than 32 bytes (here 20 — an address's worth of bytes, which is
///         exactly the plausible mistake).
/// @dev solc's return-data decode requires at least one full word, so this reverts INSIDE the
///      caller's frame, after the external call has already succeeded. `try`/`catch` cannot see it,
///      and it bubbles out of `addAsset` with EMPTY revert data.
contract ShortReturnAsset {
    function asset() external pure returns (address) {
        assembly {
            return(0x00, 20)
        }
    }
}

/// @notice `asset()` returns NOTHING — a zero-length success, which is also what a call to an address
///         with no code looks like.
/// @dev Same uncatchable decode revert as {ShortReturnAsset}. This mock is what makes the "no code at
///      the address" shape testable without needing a codeless address: the two are the same event as
///      far as the decode is concerned.
contract EmptyReturnAsset {
    function asset() external pure returns (address) {
        assembly {
            return(0x00, 0)
        }
    }
}

/// @notice `asset()` returns a full 32-byte word whose upper 96 bits are NOT clean.
/// @dev The low 160 bits form a plausible-looking address on purpose. solc validates address
///      cleanliness when decoding, so this reverts uncatchably rather than masking to
///      `address(uint160(word))` — a masking implementation would have hopped to a made-up address.
contract DirtyBitsAsset {
    function asset() external pure returns (address) {
        assembly {
            mstore(0x00, 0x0000000000000000000000010000000000000000000000000000000000000abc)
            return(0x00, 32)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reentrancy posture
// ─────────────────────────────────────────────────────────────────────────────

/// @notice A victim holding mutable state, used to prove the probe cannot write.
contract WriteVictim {
    uint256 public counter;

    function poke() external {
        counter += 1;
    }
}

/// @notice `asset()` attempts a state-changing call into a target during the probe.
/// @dev The probe is a `staticcall` (it sits in a `view` function), so any SSTORE anywhere in the
///      sub-tree throws in the callee frame. The nested `poke()` on {WriteVictim} therefore fails and
///      the counter stays 0. This mock returns `address(0)` afterwards so the node classifies as a
///      leaf; the test asserts the write never landed. `asset()` is intentionally non-view — it makes
///      a low-level call — because staticcall permits the call and forbids only the write inside it.
contract ReentrantProbeAsset {
    address private immutable _target;
    bytes private _payload;

    constructor(address target_, bytes memory payload_) {
        _target = target_;
        _payload = payload_;
    }

    function asset() external returns (address) {
        // Under the probe's staticcall this inner call's SSTORE reverts the callee; ok == false.
        (bool ok,) = _target.call(_payload);
        ok; // silence — the point is that the write cannot happen, not the return value
        return address(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Gas posture
// ─────────────────────────────────────────────────────────────────────────────

/// @notice `asset()` consumes every unit of gas forwarded to it and then reverts.
/// @dev The probe has NO GAS CAP any more — that went with the assembly probe the S2 reversal replaced
///      (the predecessor capped the sub-call at 50,000 gas). `try IWrapper(target).asset()` forwards
///      63/64 of the remaining gas, so this mock leaves the walk 1/64 of the budget to finish in, which
///      is not enough: the add dies of out-of-gas rather than degrading this node to a leaf.
///
///      The infinite loop is what makes the burn total and deterministic — no gas figure is hard-coded
///      here, so the mock stays correct whatever the caller's budget is. It also makes this the exact
///      shape a Phoenix `DummyERC20` accidentally has (those mint on FALLBACK, so the probe's call is
///      answered by an expensive state-changing path). That is the recorded reason those tokens must
///      never be used as probe targets, and this mock is the deliberate version of it.
contract GasBurningAsset {
    uint256 private _sink;

    function asset() external returns (address) {
        // No bound: run until the forwarded gas is gone. `_sink` makes the loop unremovable.
        while (true) {
            _sink = _sink + 1;
        }
        return address(0); // unreachable; present so the ABI signature is honest
    }
}
