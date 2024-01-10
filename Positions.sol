// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import './AssetStore.sol';
import './DataStore.sol';
import './FundStore.sol';
import './FundingStore.sol';
import './MarketStore.sol';
import './OrderStore.sol';
import './PoolStore.sol';
import './PositionStore.sol';
import './RiskStore.sol';
import './StakingStore.sol';

import './Funding.sol';
import './Orders.sol';
import './Pool.sol';

import './Chainlink.sol';
import './Roles.sol';

/**
 * @title  Positions
 * @notice Implementation of position related logic, i.e. increase positions,
 *         decrease positions, close positions, add/remove margin
 */
contract Positions is Roles {

    // Constants
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant BPS_DIVIDER = 10000;

    // Events
    event PositionIncreased(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        string market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 positionMargin,
        uint256 positionSize,
        uint256 positionPrice,
        int256 fundingTracker,
        uint256 fee
    );

    event PositionDecreased(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        string market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 positionMargin,
        uint256 positionSize,
        uint256 positionPrice,
        int256 fundingTracker,
        uint256 fee,
        int256 pnl,
        int256 pnlUsd,
        int256 fundingFee
    );

    event MarginIncreased(
        address indexed user,
        address indexed asset,
        string market,
        uint256 marginDiff,
        uint256 positionMargin
    );

    event MarginDecreased(
        address indexed user,
        address indexed asset,
        string market,
        uint256 marginDiff,
        uint256 positionMargin
    );

    event FeePaid(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        string market,
        uint256 fee,
        uint256 poolFee,
        uint256 stakingFee,
        uint256 treasuryFee,
        uint256 keeperFee,
        bool isLiquidation
    );

    // Contracts
    DataStore public DS;

    AssetStore public assetStore;
    FundStore public fundStore;
    FundingStore public fundingStore;
    MarketStore public marketStore;
    OrderStore public orderStore;
    PoolStore public poolStore;
    PositionStore public positionStore;
    RiskStore public riskStore;
    StakingStore public stakingStore;

    Funding public funding;
    Pool public pool;

    Chainlink public chainlink;

    /// @dev Initializes DataStore address
    constructor(RoleStore rs, DataStore ds) Roles(rs) {
        DS = ds;
    }

    /// @dev Reverts if new orders are paused
    modifier ifNotPaused() {
        require(!orderStore.areNewOrdersPaused(), '!paused');
        _;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        assetStore = AssetStore(DS.getAddress('AssetStore'));
        fundStore = FundStore(payable(DS.getAddress('FundStore')));
        fundingStore = FundingStore(DS.getAddress('FundingStore'));
        marketStore = MarketStore(DS.getAddress('MarketStore'));
        orderStore = OrderStore(DS.getAddress('OrderStore'));
        poolStore = PoolStore(DS.getAddress('PoolStore'));
        positionStore = PositionStore(DS.getAddress('PositionStore'));
        riskStore = RiskStore(DS.getAddress('RiskStore'));
        stakingStore = StakingStore(DS.getAddress('StakingStore'));
        funding = Funding(DS.getAddress('Funding'));
        pool = Pool(DS.getAddress('Pool'));
        chainlink = Chainlink(DS.getAddress('Chainlink'));
    }

    /// @notice Opens a new position or increases existing one
    /// @dev Only callable by other protocol contracts
    function increasePosition(uint256 orderId, uint256 price, address keeper) public onlyContract {
        OrderStore.Order memory order = orderStore.get(orderId);

        // Check if maximum open interest is reached
        riskStore.checkMaxOI(order.asset, order.market, order.size);
        positionStore.incrementOI(order.asset, order.market, order.size, order.isLong);
        funding.updateFundingTracker(order.asset, order.market);

        PositionStore.Position memory position = positionStore.getPosition(order.user, order.asset, order.market);
        uint256 averagePrice = (position.size * position.price + order.size * price) / (position.size + order.size);

        // Populate position fields if new position
        if (position.size == 0) {
            position.user = order.user;
            position.asset = order.asset;
            position.market = order.market;
            position.timestamp = block.timestamp;
            position.isLong = order.isLong;
            position.fundingTracker = fundingStore.getFundingTracker(order.asset, order.market);
        }

        // Add or update position
        position.size += order.size;
        position.margin += order.margin;
        position.price = averagePrice;

        positionStore.addOrUpdate(position);

        // Remove order
        orderStore.remove(orderId);

        // Credit fee to keeper, pool, stakers, treasury
        creditFee(orderId, order.user, order.asset, order.market, order.fee, false, keeper);

        emit PositionIncreased(
            orderId,
            order.user,
            order.asset,
            order.market,
            order.isLong,
            order.size,
            order.margin,
            price,
            position.margin,
            position.size,
            position.price,
            position.fundingTracker,
            order.fee
        );
    }

    /// @notice Decreases or closes an existing position
    /// @dev Only callable by other protocol contracts
    function decreasePosition(uint256 orderId, uint256 price, address keeper) external onlyContract {
        OrderStore.Order memory order = orderStore.get(orderId);
        PositionStore.Position memory position = positionStore.getPosition(order.user, order.asset, order.market);

        // If position size is less than order size, not all will be executed
        uint256 executedOrderSize = position.size > order.size ? order.size : position.size;
        uint256 remainingOrderSize = order.size - executedOrderSize;

        uint256 remainingOrderMargin;
        uint256 amountToReturnToUser;

        if (!order.isReduceOnly) {
            // User submitted order.margin when sending the order. Refund the portion of order.margin
            // that executes against the position
            uint256 executedOrderMargin = (order.margin * executedOrderSize) / order.size;
            amountToReturnToUser += executedOrderMargin;
            remainingOrderMargin = order.margin - executedOrderMargin;
        }

        // Calculate fee based on executed order size
        uint256 fee = (order.fee * executedOrderSize) / order.size;

        creditFee(orderId, order.user, order.asset, order.market, fee, false, keeper);

        // If an order is reduce-only, fee is taken from the position's margin.
        uint256 feeToPay = order.isReduceOnly ? fee : 0;

        // Funding update
        positionStore.decrementOI(order.asset, order.market, order.size, position.isLong);
        funding.updateFundingTracker(order.asset, order.market);

        // Get PNL of position
        (int256 pnl, int256 fundingFee) = getPnL(
            order.asset,
            order.market,
            position.isLong,
            price,
            position.price,
            executedOrderSize,
            position.fundingTracker
        );

        uint256 executedPositionMargin = (position.margin * executedOrderSize) / position.size;

        // If PNL is less than position margin, close position, else update position
        if (pnl <= -1 * int256(position.margin)) {
            pnl = -1 * int256(position.margin);
            executedPositionMargin = position.margin;
            executedOrderSize = position.size;
            position.size = 0;
        } else {
            position.margin -= executedPositionMargin;
            position.size -= executedOrderSize;
            position.fundingTracker = fundingStore.getFundingTracker(order.asset, order.market);
        }

        // Check for maximum pool drawdown
        riskStore.checkPoolDrawdown(order.asset, pnl);

        // Credit trader loss or debit trader profit based on pnl
        if (pnl < 0) {
            uint256 absPnl = uint256(-1 * pnl);
            pool.creditTraderLoss(order.user, order.asset, order.market, absPnl);

            uint256 totalPnl = absPnl + feeToPay;

            // If an order is reduce-only, fee is taken from the position's margin as the order's margin is zero.
            if (totalPnl < executedPositionMargin) {
                amountToReturnToUser += executedPositionMargin - totalPnl;
            }
        } else {
            pool.debitTraderProfit(order.user, order.asset, order.market, uint256(pnl));

            // If an order is reduce-only, fee is taken from the position's margin as the order's margin is zero.
            amountToReturnToUser += executedPositionMargin - feeToPay;
        }

        if (position.size == 0) {
            // Remove position if size == 0
            positionStore.remove(order.user, order.asset, order.market);
        } else {
            positionStore.addOrUpdate(position);
        }

        // Remove order and transfer funds out
        orderStore.remove(orderId);
        fundStore.transferOut(order.asset, order.user, amountToReturnToUser);

        emit PositionDecreased(
            orderId,
            order.user,
            order.asset,
            order.market,
            order.isLong,
            executedOrderSize,
            executedPositionMargin,
            price,
            position.margin,
            position.size,
            position.price,
            position.fundingTracker,
            feeToPay,
            pnl,
            _getUsdAmount(order.asset, pnl),
            fundingFee
        );

        // Open position in opposite direction if size remains
        if (!order.isReduceOnly && remainingOrderSize > 0) {
            OrderStore.Order memory nextOrder = OrderStore.Order({
                orderId: 0,
                user: order.user,
                market: order.market,
                asset: order.asset,
                margin: remainingOrderMargin,
                size: remainingOrderSize,
                price: 0,
                isLong: order.isLong,
                fee: (order.fee * remainingOrderSize) / order.size,
                orderType: 0,
                isReduceOnly: false,
                timestamp: block.timestamp,
                expiry: 0,
                cancelOrderId: 0
            });

            uint256 nextOrderId = orderStore.add(nextOrder);

            increasePosition(nextOrderId, price, keeper);
        }
    }

    /// @notice Close position without taking profits to retrieve margin in black swan scenarios
    /// @dev Only works for chainlink supported markets
    function closePositionWithoutProfit(address _asset, string calldata _market) external {
        address user = msg.sender;

        // check if positions exists
        PositionStore.Position memory position = positionStore.getPosition(user, _asset, _market);
        require(position.size > 0, '!position');

        // update funding tracker
        positionStore.decrementOI(_asset, _market, position.size, position.isLong);
        funding.updateFundingTracker(_asset, _market);

        // This is not available for markets without Chainlink
        MarketStore.Market memory market = marketStore.get(_market);
        uint256 price = chainlink.getPrice(market.chainlinkFeed);
        require(price > 0, '!price');

        (int256 pnl, ) = getPnL(
            _asset,
            _market,
            position.isLong,
            price,
            position.price,
            position.size,
            position.fundingTracker
        );

        // Only profitable positions can be closed this way
        require(pnl >= 0, '!pnl-positive');

        // Remove position and transfer margin out
        positionStore.remove(user, _asset, _market);
        fundStore.transferOut(_asset, user, position.margin);

        emit PositionDecreased(
            0,
            user,
            _asset,
            _market,
            !position.isLong,
            position.size,
            position.margin,
            price,
            position.margin,
            position.size,
            position.price,
            position.fundingTracker,
            0,
            0,
            0,
            0
        );
    }

    /// @notice Add margin to a position to decrease its leverage and push away its liquidation price
    function addMargin(address asset, string calldata market, uint256 margin) external payable ifNotPaused {
        address user = msg.sender;

        PositionStore.Position memory position = positionStore.getPosition(user, asset, market);
        require(position.size > 0, '!position');

        // Transfer additional margin in
        if (asset == address(0)) {
            margin = msg.value;
            fundStore.transferIn{value: margin}(asset, user, margin);
        } else {
            fundStore.transferIn(asset, user, margin);
        }

        require(margin > 0, '!margin');

        // update position margin
        position.margin += margin;

        // Check if leverage is above minimum leverage
        uint256 leverage = (UNIT * position.size) / position.margin;
        require(leverage >= UNIT, '!min-leverage');

        // update position
        positionStore.addOrUpdate(position);

        emit MarginIncreased(user, asset, market, margin, position.margin);
    }

    /// @notice Remove margin from a position to increase its leverage
    /// @dev Margin removal is only available on markets supported by Chainlink
    function removeMargin(address asset, string calldata market, uint256 margin) external ifNotPaused {
        address user = msg.sender;

        MarketStore.Market memory marketInfo = marketStore.get(market);

        PositionStore.Position memory position = positionStore.getPosition(user, asset, market);
        require(position.size > 0, '!position');
        require(position.margin > margin, '!margin');

        uint256 remainingMargin = position.margin - margin;

        // Leverage
        uint256 leverageAfterRemoval = (UNIT * position.size) / remainingMargin;
        require(leverageAfterRemoval <= marketInfo.maxLeverage * UNIT, '!max-leverage');

        // This is not available for markets without Chainlink
        uint256 price = chainlink.getPrice(marketInfo.chainlinkFeed);
        require(price > 0, '!price');

        (int256 upl, ) = getPnL(
            asset,
            market,
            position.isLong,
            price,
            position.price,
            position.size,
            position.fundingTracker
        );

        if (upl < 0) {
            uint256 absUpl = uint256(-1 * upl);
            require(
                absUpl < (remainingMargin * (BPS_DIVIDER - positionStore.removeMarginBuffer())) / BPS_DIVIDER,
                '!upl'
            );
        }

        // Update position and transfer margin out
        position.margin = remainingMargin;
        positionStore.addOrUpdate(position);

        fundStore.transferOut(asset, user, margin);

        emit MarginDecreased(user, asset, market, margin, position.margin);
    }

    /// @notice Credit fee to Keeper, Pool, Stakers, and Treasury
    /// @dev Only callable by other protocol contracts
    function creditFee(
        uint256 orderId,
        address user,
        address asset,
        string memory market,
        uint256 fee,
        bool isLiquidation,
        address keeper
    ) public onlyContract {
        if (fee == 0) return;

        // multiply fee by UNIT (10^18) to increase position
        fee = fee * UNIT;

        uint256 keeperFee;
        if (keeper != address(0)) {
            keeperFee = (fee * positionStore.keeperFeeShare()) / BPS_DIVIDER;
        }

        // Calculate fees
        uint256 netFee = fee - keeperFee;
        uint256 feeToStaking = (netFee * stakingStore.feeShare()) / BPS_DIVIDER;
        uint256 feeToPool = (netFee * poolStore.feeShare()) / BPS_DIVIDER;
        uint256 feeToTreasury = netFee - feeToStaking - feeToPool;

        // Increment balances, transfer fees out
        // Divide fee by UNIT to get original fee value back
        poolStore.incrementBalance(asset, feeToPool / UNIT);
        stakingStore.incrementPendingReward(asset, feeToStaking / UNIT);
        fundStore.transferOut(asset, DS.getAddress('treasury'), feeToTreasury / UNIT);
        fundStore.transferOut(asset, keeper, keeperFee / UNIT);

        emit FeePaid(
            orderId,
            user,
            asset,
            market,
            fee / UNIT, // paid by user
            feeToPool / UNIT,
            feeToStaking / UNIT,
            feeToTreasury / UNIT,
            keeperFee / UNIT,
            isLiquidation
        );
    }

    /// @notice Get pnl of a position
    /// @param asset Base asset of position
    /// @param market Market position was submitted on
    /// @param isLong Wether position is long or short
    /// @param price Current price of market
    /// @param positionPrice Average execution price of position
    /// @param size Positions size (margin * leverage) in wei
    /// @param fundingTracker Market funding rate tracker
    /// @return pnl Profit and loss of position
    /// @return fundingFee Funding fee of position
    function getPnL(
        address asset,
        string memory market,
        bool isLong,
        uint256 price,
        uint256 positionPrice,
        uint256 size,
        int256 fundingTracker
    ) public view returns (int256 pnl, int256 fundingFee) {
        if (price == 0 || positionPrice == 0 || size == 0) return (0, 0);

        if (isLong) {
            pnl = (int256(size) * (int256(price) - int256(positionPrice))) / int256(positionPrice);
        } else {
            pnl = (int256(size) * (int256(positionPrice) - int256(price))) / int256(positionPrice);
        }

        int256 currentFundingTracker = fundingStore.getFundingTracker(asset, market);
        fundingFee = (int256(size) * (currentFundingTracker - fundingTracker)) / (int256(BPS_DIVIDER) * int256(UNIT)); // funding tracker is in UNIT * bps

        if (isLong) {
            pnl -= fundingFee; // positive = longs pay, negative = longs receive
        } else {
            pnl += fundingFee; // positive = shorts receive, negative = shorts pay
        }

        return (pnl, fundingFee);
    }

    /// @dev Returns USD value of `amount` of `asset`
    /// @dev Used for PositionDecreased event
    function _getUsdAmount(address asset, int256 amount) internal view returns (int256) {
        AssetStore.Asset memory assetInfo = assetStore.get(asset);
        uint256 chainlinkPrice = chainlink.getPrice(assetInfo.chainlinkFeed);
        uint256 decimals = 18;
        if (asset != address(0)) {
            decimals = IERC20Metadata(asset).decimals();
        }
        // amount is in the asset's decimals, convert to 18. Price is 18 decimals
        return (amount * int256(chainlinkPrice)) / int256(10 ** decimals);
    }
}