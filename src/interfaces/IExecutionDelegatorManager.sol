// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IExecutionDelegatorManager {
    function isAuthorized(address executor, address to, bytes calldata data) external view returns (bool);
}
