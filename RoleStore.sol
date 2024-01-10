// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./EnumerableSet.sol";
import './Governable.sol';

/**
 * @title  RoleStore
 * @notice Role-based access control mechanism. Governance can grant and
 *         revoke roles dynamically via {grantRole} and {revokeRole}
 */
contract RoleStore is Governable {
    // Libraries
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // Set of roles
    EnumerableSet.Bytes32Set internal roles;

    // Role -> address
    mapping(bytes32 => EnumerableSet.AddressSet) internal roleMembers;

    constructor() Governable() {}

    /// @notice Grants `role` to `account`
    /// @dev Only callable by governance
    function grantRole(address account, bytes32 role) external onlyGov {
        // add role if not already present
        if (!roles.contains(role)) roles.add(role);

        require(roleMembers[role].add(account));
    }

    /// @notice Revokes `role` from `account`
    /// @dev Only callable by governance
    function revokeRole(address account, bytes32 role) external onlyGov {
        require(roleMembers[role].remove(account));

        // Remove role if it has no longer any members
        if (roleMembers[role].length() == 0) {
            roles.remove(role);
        }
    }

    /// @notice Returns `true` if `account` has been granted `role`
    function hasRole(address account, bytes32 role) external view returns (bool) {
        return roleMembers[role].contains(account);
    }

    /// @notice Returns number of roles
    function getRoleCount() external view returns (uint256) {
        return roles.length();
    }
}