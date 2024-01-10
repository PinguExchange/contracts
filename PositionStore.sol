// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./EnumerableSet.sol";

import './Roles.sol';

/// @title PositionStore
/// @notice Persistent storage for Positions.sol
contract PositionStore is Roles {
    // Libraries
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // Position struct
    struct Position {
        address user; // User that submitted the position
        address asset; // Asset address, e.g. address(0) for ETH
        string market; // Market this position was submitted on
        bool isLong; // Wether the position is long or short
        uint256 size; // The position's size (margin * leverage)
        uint256 margin; // Collateral tied to this position. In wei
        int256 fundingTracker; // Market funding rate tracker
        uint256 price; // The position's average execution price
        uint256 timestamp; // Time at which the position was created
    }

    // Constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_KEEPER_FEE_SHARE = 2000; // 20%

    // State variables
    uint256 public removeMarginBuffer = 1000;
    uint256 public keeperFeeShare = 500;

    // Mappings
    mapping(address => mapping(string => uint256)) private OI; // open interest. market => asset => amount
    mapping(address => mapping(string => uint256)) private OILong; // open interest. market => asset => amount
    mapping(address => mapping(string => uint256)) private OIShort; // open interest. market => asset => amount]

    mapping(bytes32 => Position) private positions; // key = asset,user,market
    EnumerableSet.Bytes32Set private positionKeys; // [position keys..]
    mapping(address => EnumerableSet.Bytes32Set) private positionKeysForUser; // user => [position keys..]

    constructor(RoleStore rs) Roles(rs) {}

    /// @notice Updates `removeMarginBuffer`
    /// @dev Only callable by governance
    /// @param bps new `removeMarginBuffer` in bps
    function setRemoveMarginBuffer(uint256 bps) external onlyGov {
        require(bps < BPS_DIVIDER, '!bps');
        removeMarginBuffer = bps;
    }

    /// @notice Sets keeper fee share
    /// @dev Only callable by governance
    /// @param bps new `keeperFeeShare` in bps
    function setKeeperFeeShare(uint256 bps) external onlyGov {
        require(bps <= MAX_KEEPER_FEE_SHARE, '!keeper-fee-share');
        keeperFeeShare = bps;
    }

    /// @notice Adds new position or updates exisiting one
    /// @dev Only callable by other protocol contracts
    /// @param position Position to add/update
    function addOrUpdate(Position memory position) external onlyContract {
        bytes32 key = _getPositionKey(position.user, position.asset, position.market);
        positions[key] = position;
        positionKeysForUser[position.user].add(key);
        positionKeys.add(key);
    }

    /// @notice Removes position
    /// @dev Only callable by other protocol contracts
    function remove(address user, address asset, string calldata market) external onlyContract {
        bytes32 key = _getPositionKey(user, asset, market);
        positionKeysForUser[user].remove(key);
        positionKeys.remove(key);
        delete positions[key];
    }

    /// @notice Increments open interest
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked by Positions.increasePosition
    function incrementOI(address asset, string calldata market, uint256 amount, bool isLong) external onlyContract {
        OI[asset][market] += amount;
        if (isLong) {
            OILong[asset][market] += amount;
        } else {
            OIShort[asset][market] += amount;
        }
    }

    /// @notice Decrements open interest
    /// @dev Only callable by other protocol contracts
    /// @dev Invoked whenever a position is closed or decreased
    function decrementOI(address asset, string calldata market, uint256 amount, bool isLong) external onlyContract {
        OI[asset][market] = OI[asset][market] <= amount ? 0 : OI[asset][market] - amount;
        if (isLong) {
            OILong[asset][market] = OILong[asset][market] <= amount ? 0 : OILong[asset][market] - amount;
        } else {
            OIShort[asset][market] = OIShort[asset][market] <= amount ? 0 : OIShort[asset][market] - amount;
        }
    }

    /// @notice Returns open interest of `asset` and `market`
    function getOI(address asset, string calldata market) external view returns (uint256) {
        return OI[asset][market];
    }

    /// @notice Returns open interest of long positions
    function getOILong(address asset, string calldata market) external view returns (uint256) {
        return OILong[asset][market];
    }

    /// @notice Returns open interest of short positions
    function getOIShort(address asset, string calldata market) external view returns (uint256) {
        return OIShort[asset][market];
    }

    /// @notice Returns position of `user`
    /// @param asset Base asset of position
    /// @param market Market this position was submitted on
    function getPosition(address user, address asset, string memory market) public view returns (Position memory) {
        bytes32 key = _getPositionKey(user, asset, market);
        return positions[key];
    }

    /// @notice Returns positions of `users`
    /// @param assets Base assets of positions
    /// @param markets Markets of positions
    function getPositions(
        address[] calldata users,
        address[] calldata assets,
        string[] calldata markets
    ) external view returns (Position[] memory) {
        uint256 length = users.length;
        Position[] memory _positions = new Position[](length);

        for (uint256 i = 0; i < length; i++) {
            _positions[i] = getPosition(users[i], assets[i], markets[i]);
        }

        return _positions;
    }

    /// @notice Returns positions
    /// @param keys Position keys
    function getPositions(bytes32[] calldata keys) external view returns (Position[] memory) {
        uint256 length = keys.length;
        Position[] memory _positions = new Position[](length);

        for (uint256 i = 0; i < length; i++) {
            _positions[i] = positions[keys[i]];
        }

        return _positions;
    }

    /// @notice Returns number of positions
    function getPositionCount() external view returns (uint256) {
        return positionKeys.length();
    }

    /// @notice Returns `length` amount of positions starting from `offset`
    function getPositions(uint256 length, uint256 offset) external view returns (Position[] memory) {
        uint256 _length = positionKeys.length();
        if (length > _length) length = _length;
        Position[] memory _positions = new Position[](length);

        for (uint256 i = offset; i < length + offset; i++) {
            _positions[i] = positions[positionKeys.at(i)];
        }

        return _positions;
    }

    /// @notice Returns all positions of `user`
    function getUserPositions(address user) external view returns (Position[] memory) {
        uint256 length = positionKeysForUser[user].length();
        Position[] memory _positions = new Position[](length);

        for (uint256 i = 0; i < length; i++) {
            _positions[i] = positions[positionKeysForUser[user].at(i)];
        }

        return _positions;
    }

    /// @dev Returns position key by hashing (user, asset, market)
    function _getPositionKey(address user, address asset, string memory market) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, asset, market));
    }
}
