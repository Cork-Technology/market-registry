// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title AtomicDeployer
/// @author Cork Team
/// @custom:security-contact security@cork.tech
/// @notice Deploys the whole contract set in one call: each contract is CREATE2-deployed and its initializer runs
///         in the same transaction, so a contract whose creation code carries no constructor arguments can still
///         never be seen uninitialized.
/// @dev This is the piece that makes argument-free creation code safe to use. The protocol contracts moved their
///      constructor arguments into `initialize` so that their creation code — and therefore their CREATE2 address —
///      is identical on every chain. That opens two doors this contract closes:
///
///      1. A contract that sits deployed-but-uninitialized can have `initialize` called by anyone. Deploying and
///         initializing in one transaction means that window never exists — and one {deploy} call carries the whole
///         set, so a half-deployed protocol cannot exist either: any failure rolls the entire batch back.
///      2. With public, argument-free creation code, anyone could deploy the set at its predicted addresses on a
///         chain we have not reached yet and initialize it with their own configuration. The salt is therefore
///         hashed together with `msg.sender` before it reaches CREATE2, so an address can only ever be produced by
///         the account that owns it. Copying this contract, the creation codes, and even our salt gains an attacker
///         nothing: `msg.sender` cannot be forged without the deployer key, and any other sender lands on other
///         addresses.
///
///      The creation codes arrive as calldata rather than being embedded here: embedded, the eight contracts'
///      creation codes (~44k bytes) would blow through the 24,576-byte runtime-size ceiling, so a deployer holding
///      them could not exist on-chain.
///
///      The deployer itself holds no state and no privileged role, so it is deployed once per chain — through the
///      ordinary CREATE2 factory, with argument-free creation code, so it too lands on the same address everywhere —
///      and simply left in place. It cannot remove itself when it is done: since the Cancun upgrade, `selfdestruct`
///      only deletes code when it runs in the very transaction that created the contract, and this contract must
///      outlive its creation transaction to receive the per-chain configuration as calldata. A `selfdestruct` at
///      the end of {deploy} would transfer nothing and delete nothing. A permissionless, stateless leftover is
///      harmless; the guarded salt is what keeps it unusable against us.
contract AtomicDeployer {
    /// @notice One contract in the batch: creation code and initializer call.
    struct Deployment {
        bytes initCode;
        bytes initCall;
    }

    error InitializeFailed(uint256 index, bytes reason);

    event ContractDeployed(address indexed deployed, address indexed sender, bytes32 salt);

    /// @notice Deploys and initializes a batch under the caller-guarded salt.
    /// @dev An occupied target is skipped: its CREATE2 address already commits to the exact creation code, so the
    ///      code there can only have come from the same init code. The source-owned deployment script separately
    ///      verifies initializer state and safe prefix recovery before calling this function.
    function deploy(bytes32 salt, Deployment[] calldata deployments) external returns (address[] memory deployed) {
        bytes32 guardedSalt = _guard(msg.sender, salt);
        deployed = new address[](deployments.length);

        for (uint256 i; i < deployments.length; ++i) {
            address predicted = Create2.computeAddress(guardedSalt, keccak256(deployments[i].initCode));
            if (predicted.code.length == 0) {
                predicted = Create2.deploy(0, guardedSalt, deployments[i].initCode);
                if (deployments[i].initCall.length != 0) {
                    (bool ok, bytes memory reason) = predicted.call(deployments[i].initCall);
                    if (!ok) revert InitializeFailed(i, reason);
                }
                emit ContractDeployed(predicted, msg.sender, salt);
            }

            deployed[i] = predicted;
        }
    }

    function computeAddress(address sender, bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return Create2.computeAddress(_guard(sender, salt), initCodeHash);
    }

    function _guard(address sender, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, salt));
    }
}
