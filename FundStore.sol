// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './Roles.sol';

/// @title FundStore
/// @notice Storage of protocol funds
contract FundStore is Roles, ReentrancyGuard {
    // Libraries
    using SafeERC20 for IERC20;
    using Address for address payable;

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice Transfers `amount` of `asset` in
    /// @dev Only callable by other protocol contracts
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param from Address where asset is transferred from
    function transferIn(address asset, address from, uint256 amount) external payable onlyContract {
        if (amount == 0 || asset == address(0)) return;
        IERC20(asset).safeTransferFrom(from, address(this), amount);
    }

    /// @notice Transfers `amount` of `asset` out
    /// @dev Only callable by other protocol contracts
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param to Address where asset is transferred to
    function transferOut(address asset, address to, uint256 amount) external nonReentrant onlyContract {
        if (amount == 0 || to == address(0)) return;
        if (asset == address(0)) {
            payable(to).sendValue(amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
