// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './Roles.sol';

/// @title AssetStore
/// @notice Persistent storage of supported assets
contract AssetStore is Roles {
    // Asset info struct
    struct Asset {
        uint256 minSize;
        address chainlinkFeed;
    }

    // Asset list
    address[] public assetList;
    mapping(address => Asset) private assets;

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice Set or update an asset
    /// @dev Only callable by governance
    /// @param asset Asset address, e.g. address(0) for ETH
    /// @param assetInfo Struct containing minSize and chainlinkFeed
    function set(address asset, Asset memory assetInfo) external onlyGov {
        assets[asset] = assetInfo;
        for (uint256 i = 0; i < assetList.length; i++) {
            if (assetList[i] == asset) return;
        }
        assetList.push(asset);
    }

    /// @notice Returns asset struct of `asset`
    /// @param asset Asset address, e.g. address(0) for ETH
    function get(address asset) external view returns (Asset memory) {
        return assets[asset];
    }

    /// @notice Get a list of all supported assets
    function getAssetList() external view returns (address[] memory) {
        return assetList;
    }

    /// @notice Get number of supported assets
    function getAssetCount() external view returns (uint256) {
        return assetList.length;
    }

    /// @notice Returns asset address at `index`
    /// @param index index of asset
    function getAssetByIndex(uint256 index) external view returns (address) {
        return assetList[index];
    }

    /// @notice Returns true if `asset` is supported
    /// @param asset Asset address, e.g. address(0) for ETH
    function isSupported(address asset) external view returns (bool) {
        return assets[asset].minSize > 0;
    }
}
