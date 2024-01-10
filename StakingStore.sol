// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './Roles.sol';

/// @title StakingStore
/// @notice Persistent storage for Staking.sol
contract StakingStore is Roles {
    // Constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant UNIT = 10 ** 18;

    // Fee share for CAP stakers
    uint256 public feeShare = 500;

    // Total amount of CAP (ticker: CAP) staked
    uint256 totalSupply;

    // Account to cap staked
    mapping(address => uint256) private balances;

    // Rewards
    mapping(address => uint256) private rewardPerTokenSum;
    mapping(address => uint256) private pendingReward;
    mapping(address => mapping(address => uint256)) private previousReward;
    mapping(address => mapping(address => uint256)) private claimableReward;

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice Set fee share for CAP stakers
    /// @dev Only callable by governance
    /// @param bps fee share in bps
    function setFeeShare(uint256 bps) external onlyGov {
        require(bps < BPS_DIVIDER, '!bps');
        feeShare = bps;
    }

    /// @notice Increments total staked supply by `amount`
    /// @dev Only callable by other protocol contracts
    function incrementSupply(uint256 amount) external onlyContract {
        totalSupply += amount;
    }

    /// @notice Decrements total staked supply by `amount`
    /// @dev Only callable by other protocol contracts
    function decrementSupply(uint256 amount) external onlyContract {
        totalSupply = totalSupply <= amount ? 0 : totalSupply - amount;
    }

    /// @notice Increments staked balance of `user` by `amount`
    /// @dev Only callable by other protocol contracts
    function incrementBalance(address user, uint256 amount) external onlyContract {
        balances[user] += amount;
    }

    /// @notice Decrements staked balance of `user` by `amount`
    /// @dev Only callable by other protocol contracts
    function decrementBalance(address user, uint256 amount) external onlyContract {
        balances[user] = balances[user] <= amount ? 0 : balances[user] - amount;
    }

    /// @notice Increments pending reward of `asset` by `amount`
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Positions.creditFee
    function incrementPendingReward(address asset, uint256 amount) external onlyContract {
        pendingReward[asset] += amount;
    }

    /// @notice Increments `asset` reward per token
    /// @dev Only callable by other protocol contracts
    function incrementRewardPerToken(address asset) external onlyContract {
        if (totalSupply == 0) return;
        uint256 amount = (pendingReward[asset] * UNIT) / totalSupply;
        rewardPerTokenSum[asset] += amount;
        // due to rounding errors a fraction of fees stays in the contract
        // pendingReward is set to the amount which is left over, and will be distributed later
        pendingReward[asset] -= (amount * totalSupply) / UNIT;
    }

    /// @notice Updates claimable reward of `asset` by `user`
    /// @dev Only callable by other protocol contracts
    function updateClaimableReward(address asset, address user) external onlyContract {
        if (rewardPerTokenSum[asset] == 0) return;
        uint256 amount = (balances[user] * (rewardPerTokenSum[asset] - previousReward[asset][user])) / UNIT;
        claimableReward[asset][user] += amount;
        previousReward[asset][user] = rewardPerTokenSum[asset];
    }

    /// @notice Sets claimable reward of `asset` by `user`
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Staking.collectReward, sets reward to zero when an user claims his reward
    function setClaimableReward(address asset, address user, uint256 amount) external onlyContract {
        claimableReward[asset][user] = amount;
    }

    /// @notice Returns total amount of staked CAP
    function getTotalSupply() external view returns (uint256) {
        return totalSupply;
    }

    /// @notice Returns staked balance of `account`
    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }

    /// @notice Returns pending reward of `asset`
    function getPendingReward(address asset) external view returns (uint256) {
        return pendingReward[asset];
    }

    /// @notice Returns previous reward of `asset`
    function getPreviousReward(address asset, address user) external view returns (uint256) {
        return previousReward[asset][user];
    }

    /// @notice Returns rewardPerTokenSum of `asset`
    function getRewardPerTokenSum(address asset) external view returns (uint256) {
        return rewardPerTokenSum[asset];
    }

    /// @notice Returns claimable reward of `asset` by `user`
    function getClaimableReward(address asset, address user) external view returns (uint256) {
        return claimableReward[asset][user];
    }
}
