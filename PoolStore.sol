// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './Roles.sol';

/// @title PoolStore
/// @notice Persistent storage for Pool.sol
contract PoolStore is Roles {
    // Libraries
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_POOL_WITHDRAWAL_FEE = 500; // in bps = 5%

    // State variables
    uint256 public feeShare = 500;
    uint256 public bufferPayoutPeriod = 7 days;

    mapping(address => uint256) private clpSupply; // asset => clp supply
    mapping(address => uint256) private balances; // asset => balance
    mapping(address => mapping(address => uint256)) private userClpBalances; // asset => account => clp amount

    mapping(address => uint256) private bufferBalances; // asset => balance
    mapping(address => uint256) private lastPaid; // asset => timestamp

    mapping(address => uint256) private withdrawalFees; // asset => bps

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice Set pool fee
    /// @dev Only callable by governance
    /// @param bps fee share in bps
    function setFeeShare(uint256 bps) external onlyGov {
        require(bps < BPS_DIVIDER, '!bps');
        feeShare = bps;
    }

    /// @notice Set buffer payout period
    /// @dev Only callable by governance
    /// @param period Buffer payout period in seconds, default is 7 days (604800 seconds)
    function setBufferPayoutPeriod(uint256 period) external onlyGov {
        require(period > 0, '!period');
        bufferPayoutPeriod = period;
    }

    /// @notice Set pool withdrawal fee
    /// @dev Only callable by governance
    /// @param asset Pool asset, e.g. address(0) for ETH
    /// @param bps Withdrawal fee in bps
    function setWithdrawalFee(address asset, uint256 bps) external onlyGov {
        require(bps <= MAX_POOL_WITHDRAWAL_FEE, '!pool-withdrawal-fee');
        withdrawalFees[asset] = bps;
    }

    /// @notice Increments pool balance
    /// @dev Only callable by other protocol contracts
    function incrementBalance(address asset, uint256 amount) external onlyContract {
        balances[asset] += amount;
    }

    /// @notice Decrements pool balance
    /// @dev Only callable by other protocol contracts
    function decrementBalance(address asset, uint256 amount) external onlyContract {
        balances[asset] = balances[asset] <= amount ? 0 : balances[asset] - amount;
    }

    /// @notice Increments buffer balance
    /// @dev Only callable by other protocol contracts
    function incrementBufferBalance(address asset, uint256 amount) external onlyContract {
        bufferBalances[asset] += amount;
    }

    /// @notice Decrements buffer balance
    /// @dev Only callable by other protocol contracts
    function decrementBufferBalance(address asset, uint256 amount) external onlyContract {
        bufferBalances[asset] = bufferBalances[asset] <= amount ? 0 : bufferBalances[asset] - amount;
    }

    /// @notice Updates `lastPaid`
    /// @dev Only callable by other protocol contracts
    function setLastPaid(address asset, uint256 timestamp) external onlyContract {
        lastPaid[asset] = timestamp;
    }

    /// @notice Increments `clpSupply` and `userClpBalances`
    /// @dev Only callable by other protocol contracts
    function incrementUserClpBalance(address asset, address user, uint256 amount) external onlyContract {
        clpSupply[asset] += amount;

        unchecked {
            // Overflow not possible: balance + amount is at most clpSupply + amount, which is checked above.
            userClpBalances[asset][user] += amount;
        }
    }

    /// @notice Decrements `clpSupply` and `userClpBalances`
    /// @dev Only callable by other protocol contracts
    function decrementUserClpBalance(address asset, address user, uint256 amount) external onlyContract {
        clpSupply[asset] = clpSupply[asset] <= amount ? 0 : clpSupply[asset] - amount;

        userClpBalances[asset][user] = userClpBalances[asset][user] <= amount
            ? 0
            : userClpBalances[asset][user] - amount;
    }

    /// @notice Returns withdrawal fee of `asset` from pool
    function getWithdrawalFee(address asset) external view returns (uint256) {
        return withdrawalFees[asset];
    }

    /// @notice Returns the sum of buffer and pool balance of `asset`
    function getAvailable(address asset) external view returns (uint256) {
        return balances[asset] + bufferBalances[asset];
    }

    /// @notice Returns amount of `asset` in pool
    function getBalance(address asset) external view returns (uint256) {
        return balances[asset];
    }

    /// @notice Returns amount of `asset` in buffer
    function getBufferBalance(address asset) external view returns (uint256) {
        return bufferBalances[asset];
    }

    /// @notice Returns pool balances of `_assets`
    function getBalances(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            _balances[i] = balances[_assets[i]];
        }

        return _balances;
    }

    /// @notice Returns buffer balances of `_assets`
    function getBufferBalances(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            _balances[i] = bufferBalances[_assets[i]];
        }

        return _balances;
    }

    /// @notice Returns last time pool was paid
    function getLastPaid(address asset) external view returns (uint256) {
        return lastPaid[asset];
    }

    /// @notice Returns `_assets` balance of `account`
    function getUserBalances(address[] calldata _assets, address account) external view returns (uint256[] memory) {
        uint256 length = _assets.length;
        uint256[] memory _balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            _balances[i] = getUserBalance(_assets[i], account);
        }

        return _balances;
    }

    /// @notice Returns `asset` balance of `account`
    function getUserBalance(address asset, address account) public view returns (uint256) {
        if (clpSupply[asset] == 0) return 0;
        return (userClpBalances[asset][account] * balances[asset]) / clpSupply[asset];
    }

    /// @notice Returns total amount of CLP for `asset`
    function getClpSupply(address asset) public view returns (uint256) {
        return clpSupply[asset];
    }

    /// @notice Returns amount of CLP of `account` for `asset`
    function getUserClpBalance(address asset, address account) public view returns (uint256) {
        return userClpBalances[asset][account];
    }
}
