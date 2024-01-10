// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './Governable.sol';
import './RoleStore.sol';

/// @title Roles
/// @notice Role-based access control mechanism via onlyContract modifier
contract Roles is Governable {
    bytes32 public constant CONTRACT = keccak256('CONTRACT');

    RoleStore public roleStore;

    /// @dev Initializes roleStore address
    constructor(RoleStore rs) Governable() {
        roleStore = rs;
    }

    /// @dev Reverts if caller address has not the contract role
    modifier onlyContract() {
        require(roleStore.hasRole(msg.sender, CONTRACT), '!contract-role');
        _;
    }
}
