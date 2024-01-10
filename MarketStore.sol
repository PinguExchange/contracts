// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './Roles.sol';

/// @title MarketStore
/// @notice Persistent storage of supported markets
contract MarketStore is Roles {
    // Market struct
    struct Market {
        string name; // Market's full name, e.g. Bitcoin / U.S. Dollar
        string category; // crypto, fx, commodities, or indices
        address chainlinkFeed; // Price feed contract address
        uint256 maxLeverage; // No decimals
        uint256 maxDeviation; // In bps, max price difference from oracle to chainlink price
        uint256 fee; // In bps. 10 = 0.1%
        uint256 liqThreshold; // In bps
        uint256 fundingFactor; // Yearly funding rate if OI is completely skewed to one side. In bps.
        uint256 minOrderAge; // Min order age before is can be executed. In seconds
        uint256 pythMaxAge; // Max Pyth submitted price age, in seconds
        bytes32 pythFeed; // Pyth price feed id
        bool allowChainlinkExecution; // Allow anyone to execute orders with chainlink
        bool isReduceOnly; // accepts only reduce only orders
    }

    // Constants to limit gov power
    uint256 public constant MAX_FEE = 1000; // 10%
    uint256 public constant MAX_DEVIATION = 1000; // 10%
    uint256 public constant MAX_LIQTHRESHOLD = 10000; // 100%
    uint256 public constant MAX_MIN_ORDER_AGE = 30;
    uint256 public constant MIN_PYTH_MAX_AGE = 3;

    // list of supported markets
    string[] public marketList; // "ETH-USD", "BTC-USD", etc
    mapping(string => Market) private markets;

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice Set or update a market
    /// @dev Only callable by governance
    /// @param market String identifier, e.g. "ETH-USD"
    /// @param marketInfo Market struct containing required market data
    function set(string calldata market, Market memory marketInfo) external onlyGov {
        require(marketInfo.fee <= MAX_FEE, '!max-fee');
        require(marketInfo.maxLeverage >= 1, '!max-leverage');
        require(marketInfo.maxDeviation <= MAX_DEVIATION, '!max-deviation');
        require(marketInfo.liqThreshold <= MAX_LIQTHRESHOLD, '!max-liqthreshold');
        require(marketInfo.minOrderAge <= MAX_MIN_ORDER_AGE, '!max-minorderage');
        require(marketInfo.pythMaxAge >= MIN_PYTH_MAX_AGE, '!min-pythmaxage');

        markets[market] = marketInfo;
        for (uint256 i = 0; i < marketList.length; i++) {
            // check if market already exists, if yes return
            if (keccak256(abi.encodePacked(marketList[i])) == keccak256(abi.encodePacked(market))) return;
        }
        marketList.push(market);
    }

    /// @notice Returns market struct of `market`
    /// @param market String identifier, e.g. "ETH-USD"
    function get(string calldata market) external view returns (Market memory) {
        return markets[market];
    }

    /// @notice Returns market struct array of specified markets
    /// @param _markets Array of market strings, e.g. ["ETH-USD", "BTC-USD"]
    function getMany(string[] calldata _markets) external view returns (Market[] memory) {
        uint256 length = _markets.length;
        Market[] memory _marketInfos = new Market[](length);
        for (uint256 i = 0; i < length; i++) {
            _marketInfos[i] = markets[_markets[i]];
        }
        return _marketInfos;
    }

    /// @notice Returns market identifier at `index`
    /// @param index index of marketList
    function getMarketByIndex(uint256 index) external view returns (string memory) {
        return marketList[index];
    }

    /// @notice Get a list of all supported markets
    function getMarketList() external view returns (string[] memory) {
        return marketList;
    }

    /// @notice Get number of supported markets
    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }
}
