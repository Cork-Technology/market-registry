// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

import {AggregatorV2V3Adapter} from "./AggregatorV2V3Adapter.sol";
import {IAggregatorV2V3AdapterFactory} from "../interfaces/IAggregatorV2V3AdapterFactory.sol";
import {IVersion} from "../interfaces/IVersion.sol";

/// @title AggregatorV2V3AdapterFactory
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Deploys `AggregatorV2V3Adapter` instances at deterministic (CREATE2) addresses. The salt is a
///         caller-supplied argument, so a single source can back several adapters.
contract AggregatorV2V3AdapterFactory is IAggregatorV2V3AdapterFactory, IVersion {
    /// @inheritdoc IAggregatorV2V3AdapterFactory
    mapping(address adapter => bool created) public override isAdapter;

    /// @inheritdoc IAggregatorV2V3AdapterFactory
    function createAdapter(address source, uint8 decimals, string calldata description, bytes32 salt)
        external
        override
        returns (address adapter)
    {
        require(source != address(0), ZeroAddress());

        // Duplicate protection is CREATE2's, not ours. A second deployment with the same arguments
        // targets an address that already holds code and the creation fails on its own; we only compute
        // the address up front so the failure surfaces as a named error instead of the bare revert solc
        // emits for a failed `new`.
        //
        // Do not re-key this guard on `keccak256(source, salt)`: that key is narrower than the deployment
        // identity, which also includes `decimals` and `description`, so it would refuse deployments
        // CREATE2 itself would happily accept. Deriving it from the predicted address makes the two
        // identities the same by construction.
        //
        // There is deliberately no per-source list for enumeration. This factory is permissionless, so an
        // unbounded array per source would be a griefing vector on its own getter, and the address is a
        // pure function of the arguments: callers use `predictAdapter`, and `isAdapter` answers provenance.
        address predicted = _predict(source, decimals, description, salt);
        require(predicted.code.length == 0, AdapterExists(predicted));

        adapter = address(new AggregatorV2V3Adapter{salt: salt}(source, decimals, description));

        isAdapter[adapter] = true;
        emit CreateAdapter(msg.sender, adapter, source);
    }

    /// @inheritdoc IAggregatorV2V3AdapterFactory
    function predictAdapter(address source, uint8 decimals, string calldata description, bytes32 salt)
        external
        view
        override
        returns (address adapter)
    {
        adapter = _predict(source, decimals, description, salt);
    }

    /// @dev The CREATE2 address for these arguments. `decimals` and `description` stay in the init-code
    ///      hash and are deliberately kept OUT of the salt: CREATE2 hashes the salt and the init code
    ///      together, so the address already separates on them, and folding them into the salt as well
    ///      would buy no extra separation while taking the salt away from the caller as the one value they
    ///      alone control.
    ///
    ///      Already-deployed adapters never move: an address is fixed by the CREATE2 preimage that produced
    ///      it and this factory is not upgradeable. `address(this)` is part of that preimage, so a fresh
    ///      factory deployment places adapters at new addresses even for byte-identical arguments.
    function _predict(address source, uint8 decimals, string calldata description, bytes32 salt)
        private
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(AggregatorV2V3Adapter).creationCode, abi.encode(source, decimals, description))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @inheritdoc IVersion
    function version() external pure returns (string memory) {
        return "0.2.0";
    }
}
