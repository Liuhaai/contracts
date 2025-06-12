// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IExecutionDelegatorManager} from "../interfaces/IExecutionDelegatorManager.sol";

// TODO: limit ownership to NFT token owner
/**
 * @title ExecutionDelegatorManager
 * @notice Manages authorization for specific function calls from designated delegator addresses to target contracts.
 * @dev This contract allows the owner to authorize or revoke permissions for a `delegator` to call a specific `functionSignature` on a `to` address.
 *         It uses a mapping `_authorizedCall` where the key is a hash combining the delegator, target address, and function signature.
 */
contract ExecutionDelegatorManager is IExecutionDelegatorManager, Ownable2Step {
    /**
     * @notice Mapping storing authorization status for specific calls.
     * @dev Key is keccak256(abi.encode(delegator, to, functionSignature)), value is boolean indicating authorization.
     */
    mapping(bytes32 => bool) private _authorizedCall;

    /**
     * @notice Emitted when a delegator is authorized for a specific call.
     * @param delegator The address authorized to make the call.
     * @param to The target contract address.
     * @param functionSignature The 4-byte signature of the function being authorized.
     * @param authorized The authorization status.
     */
    event DelegatorUpdated(address delegator, address to, bytes4 functionSignature, bool authorized);

    constructor(address owner) {
        _transferOwnership(owner);
    }

    /**
     * @dev Internal function to compute the authorization hash.
     * @param delegator The address authorized to make the call.
     * @param to The target contract address.
     * @param functionSignature The 4-byte signature of the function being authorized.
     * @return keccak256 hash used as the key in the `_authorizedCall` mapping.
     */
    function _callHash(address delegator, address to, bytes4 functionSignature) internal pure returns (bytes32) {
        return keccak256(abi.encode(delegator, to, functionSignature));
    }

    /**
     * @notice Authorizes a delegator to call a specific function on a target contract.
     * @dev Only the contract owner can call this function. Sets the corresponding entry in `_authorizedCall` to true.
     * @param delegator The address to authorize.
     * @param to The target contract address.
     * @param functionSignature The 4-byte signature of the function to authorize.
     */
    function authorizeDelegator(address delegator, address to, bytes4 functionSignature) external onlyOwner {
        bytes32 h = _callHash(delegator, to, functionSignature);
        _authorizedCall[h] = true;
        emit DelegatorUpdated(delegator, to, functionSignature, true); // Use DelegatorUpdated
    }

    /**
     * @notice Revokes authorization for a delegator to call a specific function on a target contract.
     * @dev Only the contract owner can call this function. Deletes the corresponding entry from `_authorizedCall`.
     * @param delegator The address whose authorization to revoke.
     * @param to The target contract address.
     * @param functionSignature The 4-byte signature of the function to revoke authorization for.
     */
    function revokeDelegator(address delegator, address to, bytes4 functionSignature) external onlyOwner {
        bytes32 h = _callHash(delegator, to, functionSignature);
        delete _authorizedCall[h];
        emit DelegatorUpdated(delegator, to, functionSignature, false); // Use DelegatorUpdated
    }

    /**
     * @notice Checks if a specific call is authorized for a given executor and call data.
     * @param executor The address attempting the call (delegator).
     * @param to The target contract address.
     * @param data The full calldata, including the function signature (first 4 bytes).
     * @return bool True if the call is authorized, false otherwise.
     */
    function isAuthorized(address executor, address to, bytes calldata data) external view override returns (bool) {
        // Extract function signature from the first 4 bytes of data
        if (data.length < 4) return false;
        bytes4 functionSignature = bytes4(data[:4]);

        bytes32 h = _callHash(executor, to, functionSignature);
        return _authorizedCall[h];
    }
}
