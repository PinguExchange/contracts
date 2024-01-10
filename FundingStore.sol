// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './Roles.sol';

/// @title FundingStore
/// @notice Storage of funding trackers for all supported markets
contract FundingStore is Roles {
    // interval used to calculate accrued funding
    uint256 public fundingInterval = 1 hours;

    // asset => market => funding tracker (long) (short is opposite)
    mapping(address => mapping(string => int256)) private fundingTrackers;

    // asset => market => last time fundingTracker was updated. In seconds.
    mapping(address => mapping(string => uint256)) private lastUpdated;

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice updates `fundingInterval`
    /// @dev Only callable by governance
    /// @param interval new funding interval, in seconds
    function setFundingInterval(uint256 interval) external onlyGov {
        require(interval > 0, '!interval');
        fundingInterval = interval;
    }

    /// @notice Updates `lastUpdated` mapping
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Funding.updateFundingTracker
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param market Market, e.g. "ETH-USD"
    /// @param timestamp Timestamp in seconds
    function setLastUpdated(address asset, string calldata market, uint256 timestamp) external onlyContract {
        lastUpdated[asset][market] = timestamp;
    }

    /// @notice updates `fundingTracker` mapping
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Funding.updateFundingTracker
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param market Market, e.g. "ETH-USD"
    /// @param fundingIncrement Accrued funding of given asset and market
    function updateFundingTracker(
        address asset,
        string calldata market,
        int256 fundingIncrement
    ) external onlyContract {
        fundingTrackers[asset][market] += fundingIncrement;
    }

    /// @notice Returns last update timestamp of `asset` and `market`
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param market Market, e.g. "ETH-USD"
    function getLastUpdated(address asset, string calldata market) external view returns (uint256) {
        return lastUpdated[asset][market];
    }

    /// @notice Returns funding tracker of `asset` and `market`
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param market Market, e.g. "ETH-USD"
    function getFundingTracker(address asset, string calldata market) external view returns (int256) {
        return fundingTrackers[asset][market];
    }

    /// @notice Returns funding trackers of `assets` and `markets`
    /// @param assets Array of asset addresses
    /// @param markets Array of market strings
    function getFundingTrackers(
        address[] calldata assets,
        string[] calldata markets
    ) external view returns (int256[] memory fts) {
        uint256 length = assets.length;
        fts = new int256[](length);
        for (uint256 i = 0; i < length; i++) {
            fts[i] = fundingTrackers[assets[i]][markets[i]];
        }
        return fts;
    }
}
