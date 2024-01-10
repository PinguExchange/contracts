// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './DataStore.sol';
import './FundingStore.sol';
import './MarketStore.sol';
import './PositionStore.sol';

import './Roles.sol';

/**
 * @title  Funding
 * @notice Funding rates are calculated hourly for each market and collateral
 *         asset based on the real-time open interest imbalance
 */
contract Funding is Roles {
    // Events
    event FundingUpdated(address indexed asset, string market, int256 fundingTracker, int256 fundingIncrement);

    // Constants
    uint256 public constant UNIT = 10 ** 18;

    // Contracts
    DataStore public DS;
    FundingStore public fundingStore;
    MarketStore public marketStore;
    PositionStore public positionStore;

    /// @dev Initializes DataStore address
    constructor(RoleStore rs, DataStore ds) Roles(rs) {
        DS = ds;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        fundingStore = FundingStore(DS.getAddress('FundingStore'));
        marketStore = MarketStore(DS.getAddress('MarketStore'));
        positionStore = PositionStore(DS.getAddress('PositionStore'));
    }

    /// @notice Updates funding tracker of `market` and `asset`
    /// @dev Only callable by other protocol contracts
    function updateFundingTracker(address asset, string calldata market) external onlyContract {
        uint256 lastUpdated = fundingStore.getLastUpdated(asset, market);
        uint256 _now = block.timestamp;

        // condition is true only on the very first execution
        if (lastUpdated == 0) {
            fundingStore.setLastUpdated(asset, market, _now);
            return;
        }

        // returns if block.timestamp - lastUpdated is less than funding interval
        if (lastUpdated + fundingStore.fundingInterval() > _now) return;

        // positive funding increment indicates that shorts pay longs, negative that longs pay shorts
        int256 fundingIncrement = getAccruedFunding(asset, market, 0); // in UNIT * bps

        // return if funding increment is zero
        if (fundingIncrement == 0) return;

        fundingStore.updateFundingTracker(asset, market, fundingIncrement);
        fundingStore.setLastUpdated(asset, market, _now);

        emit FundingUpdated(asset, market, fundingStore.getFundingTracker(asset, market), fundingIncrement);
    }

    /// @notice Returns accrued funding of `market` and `asset`
    function getAccruedFunding(address asset, string memory market, uint256 intervals) public view returns (int256) {
        if (intervals == 0) {
            intervals = (block.timestamp - fundingStore.getLastUpdated(asset, market)) / fundingStore.fundingInterval();
        }

        if (intervals == 0) return 0;

        uint256 OILong = positionStore.getOILong(asset, market);
        uint256 OIShort = positionStore.getOIShort(asset, market);

        if (OIShort == 0 && OILong == 0) return 0;

        uint256 OIDiff = OIShort > OILong ? OIShort - OILong : OILong - OIShort;

        MarketStore.Market memory marketInfo = marketStore.get(market);
        uint256 yearlyFundingFactor = marketInfo.fundingFactor;

        uint256 accruedFunding = (UNIT * yearlyFundingFactor * OIDiff * intervals) / (24 * 365 * (OILong + OIShort)); // in UNIT * bps

        if (OILong > OIShort) {
            // Longs pay shorts. Increase funding tracker.
            return int256(accruedFunding);
        } else {
            // Shorts pay longs. Decrease funding tracker.
            return -1 * int256(accruedFunding);
        }
    }
}
