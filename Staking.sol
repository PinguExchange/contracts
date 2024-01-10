// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './AssetStore.sol';
import './DataStore.sol';
import './FundStore.sol';
import './StakingStore.sol';

import './Roles.sol';

/**
 * @title  Staking
 * @notice Stake CAP to receive rewards
 */
contract Staking is Roles {
    // Constants
    uint256 public constant UNIT = 10 ** 18;

    // Events
    event CAPStaked(address indexed user, uint256 amount);
    event CAPUnstaked(address indexed user, uint256 amount);
    event CollectedReward(address indexed user, address indexed asset, uint256 amount);

    // Contracts
    DataStore public DS;

    AssetStore public assetStore;
    FundStore public fundStore;
    StakingStore public stakingStore;

    address public cap;

    /// @dev Initializes DataStore address
    constructor(RoleStore rs, DataStore ds) Roles(rs) {
        DS = ds;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        assetStore = AssetStore(DS.getAddress('AssetStore'));
        fundStore = FundStore(payable(DS.getAddress('FundStore')));
        stakingStore = StakingStore(DS.getAddress('StakingStore'));
        cap = DS.getAddress('CAP');
    }

    /// @notice Stake `amount` of CAP to receive rewards
    function stake(uint256 amount) external {
        require(amount > 0, '!amount');

        updateRewards(msg.sender);

        stakingStore.incrementSupply(amount);
        stakingStore.incrementBalance(msg.sender, amount);

        fundStore.transferIn(cap, msg.sender, amount);

        emit CAPStaked(msg.sender, amount);
    }

    /// @notice Unstake `amount` of CAP
    function unstake(uint256 amount) external {
        require(amount > 0, '!amount');

        // Set to max if above max
        if (amount >= stakingStore.getBalance(msg.sender)) {
            amount = stakingStore.getBalance(msg.sender);
        }

        updateRewards(msg.sender);

        stakingStore.decrementSupply(amount);
        stakingStore.decrementBalance(msg.sender, amount);

        fundStore.transferOut(cap, msg.sender, amount);

        emit CAPUnstaked(msg.sender, amount);
    }

    /// @notice Collect multiple rewards
    function collectMultiple(address[] calldata assets) external {
        for (uint256 i = 0; i < assets.length; i++) {
            collectReward(assets[i]);
        }
    }

    /// @notice Collect reward of `asset`
    function collectReward(address asset) public {
        updateRewards(msg.sender);

        uint256 rewardToSend = stakingStore.getClaimableReward(asset, msg.sender);
        stakingStore.setClaimableReward(asset, msg.sender, 0);

        if (rewardToSend > 0) {
            fundStore.transferOut(asset, msg.sender, rewardToSend);

            emit CollectedReward(msg.sender, asset, rewardToSend);
        }
    }

    /// @notice Update rewards of `account`
    function updateRewards(address account) public {
        if (account == address(0)) return;
        for (uint256 i = 0; i < assetStore.getAssetCount(); i++) {
            address asset = assetStore.getAssetByIndex(i);
            stakingStore.incrementRewardPerToken(asset);
            stakingStore.updateClaimableReward(asset, account);
        }
    }

    /// @notice Get claimable reward of `account` and `asset`
    function getClaimableReward(address asset, address account) public view returns (uint256) {
        uint256 currentClaimableReward = stakingStore.getClaimableReward(asset, account);

        uint256 capSupply = stakingStore.getTotalSupply();
        if (capSupply == 0) return currentClaimableReward;

        uint256 _rewardPerTokenStored = stakingStore.getRewardPerTokenSum(asset) +
            (stakingStore.getPendingReward(asset) * UNIT) /
            capSupply;
        if (_rewardPerTokenStored == 0) return currentClaimableReward; // no rewards yet

        uint256 capBalance = stakingStore.getBalance(account);

        return
            currentClaimableReward +
            (capBalance * (_rewardPerTokenStored - stakingStore.getPreviousReward(asset, account))) /
            UNIT;
    }

    /// @notice Get claimable reward of `account` and `assets`
    function getClaimableRewards(address[] calldata assets, address account) external view returns (uint256[] memory) {
        uint256 length = assets.length;
        uint256[] memory _rewards = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            _rewards[i] = getClaimableReward(assets[i], account);
        }

        return _rewards;
    }
}
