// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './DataStore.sol';
import './PoolStore.sol';
import './PositionStore.sol';

import './Roles.sol';

/// @title RiskStore
/// @notice Implementation of risk mitigation measures such as maximum open interest and maximum pool drawdown
contract RiskStore is Roles {
    // Constants
    uint256 public constant BPS_DIVIDER = 10000;

    mapping(string => mapping(address => uint256)) private maxOI; // market => asset => amount

    // Pool Risk Measures
    uint256 public poolHourlyDecay = 416; // bps = 4.16% hourly, disappears after 24 hours
    mapping(address => int256) private poolProfitTracker; // asset => amount (amortized)
    mapping(address => uint256) private poolProfitLimit; // asset => bps
    mapping(address => uint256) private poolLastChecked; // asset => timestamp

    // Contracts
    DataStore public DS;

    /// @dev Initialize DataStore address
    constructor(RoleStore rs, DataStore ds) Roles(rs) {
        DS = ds;
    }

    /// @notice Set maximum open interest
    /// @notice Once current open interest exceeds this value, orders are no longer accepted
    /// @dev Only callable by governance
    /// @param market Market to set, e.g. "ETH-USD"
    /// @param asset Address of base asset, e.g. address(0) for ETH
    /// @param amount Max open interest to set
    function setMaxOI(string calldata market, address asset, uint256 amount) external onlyGov {
        require(amount > 0, '!amount');
        maxOI[market][asset] = amount;
    }

    /// @notice Set hourly pool decay
    /// @dev Only callable by governance
    /// @param bps Hourly pool decay in bps
    function setPoolHourlyDecay(uint256 bps) external onlyGov {
        require(bps < BPS_DIVIDER, '!bps');
        poolHourlyDecay = bps;
    }

    /// @notice Set pool profit limit of `asset`
    /// @dev Only callable by governance
    /// @param asset Address of asset, e.g. address(0) for ETH
    /// @param bps Pool profit limit in bps
    function setPoolProfitLimit(address asset, uint256 bps) external onlyGov {
        require(bps < BPS_DIVIDER, '!bps');
        poolProfitLimit[asset] = bps;
    }

    /// @notice Measures the net loss of a pool over time
    /// @notice Reverts if time-weighted drawdown is higher than the allowed profit limit
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Positions.decreasePosition
    function checkPoolDrawdown(address asset, int256 pnl) external onlyContract {
        // Get available amount of `asset` in the pool (pool balance + buffer balance)
        uint256 poolAvailable = PoolStore(DS.getAddress('PoolStore')).getAvailable(asset);

        // Get profit tracker, pnl > 0 means trader win
        int256 profitTracker = getPoolProfitTracker(asset) + pnl;
        // get profit limit of pool
        uint256 profitLimit = poolProfitLimit[asset];

        // update storage vars
        poolProfitTracker[asset] = profitTracker;
        poolLastChecked[asset] = block.timestamp;

        // return if profit limit or profit tracker is zero / less than zero
        if (profitLimit == 0 || profitTracker <= 0) return;

        // revert if profitTracker > profitLimit * available funds
        require(uint256(profitTracker) < (profitLimit * poolAvailable) / BPS_DIVIDER, '!pool-risk');
    }

    /// @notice Checks if maximum open interest is reached
    /// @param market Market to check, e.g. "ETH-USD"
    /// @param asset Address of base asset, e.g. address(0) for ETH
    function checkMaxOI(address asset, string calldata market, uint256 size) external view {
        uint256 openInterest = PositionStore(DS.getAddress('PositionStore')).getOI(asset, market);
        uint256 _maxOI = maxOI[market][asset];
        if (_maxOI > 0 && openInterest + size > _maxOI) revert('!max-oi');
    }

    /// @notice Get maximum open interest of `market`
    /// @param market Market to check, e.g. "ETH-USD"
    /// @param asset Address of base asset, e.g. address(0) for ETH
    function getMaxOI(string calldata market, address asset) external view returns (uint256) {
        return maxOI[market][asset];
    }

    /// @notice Returns pool profit tracker of `asset`
    /// @dev Amortized every hour by 4.16% unless otherwise set
    function getPoolProfitTracker(address asset) public view returns (int256) {
        int256 profitTracker = poolProfitTracker[asset];
        uint256 lastCheckedHourId = poolLastChecked[asset] / (1 hours);
        uint256 currentHourId = block.timestamp / (1 hours);

        if (currentHourId > lastCheckedHourId) {
            // hours passed since last check
            uint256 hoursPassed = currentHourId - lastCheckedHourId;
            if (hoursPassed >= BPS_DIVIDER / poolHourlyDecay) {
                profitTracker = 0;
            } else {
                // reduce profit tracker by `poolHourlyDecay` for every hour that passed since last check
                for (uint256 i = 0; i < hoursPassed; i++) {
                    profitTracker *= (int256(BPS_DIVIDER) - int256(poolHourlyDecay)) / int256(BPS_DIVIDER);
                }
            }
        }

        return profitTracker;
    }

    /// @notice Returns pool profit limit of `asset`
    function getPoolProfitLimit(address asset) external view returns (uint256) {
        return poolProfitLimit[asset];
    }
}
