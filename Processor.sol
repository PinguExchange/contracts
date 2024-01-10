// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import "pyth-sdk-solidity/IPyth.sol";
import "pyth-sdk-solidity/PythStructs.sol";

import './AssetStore.sol';
import './DataStore.sol';
import './FundStore.sol';
import './MarketStore.sol';
import './OrderStore.sol';
import './PoolStore.sol';
import './PositionStore.sol';
import './RiskStore.sol';

import './Funding.sol';
import './Orders.sol';
import './Pool.sol';
import './Positions.sol';

import './Chainlink.sol';
import './Roles.sol';

/**
 * @title  Processor
 * @notice Implementation of order execution and position liquidation.
 *         Orders are settled on-demand by the Pyth network. Keepers, which
 *         anyone can run, execute orders as they are submitted to CAP's
 *         contracts using Pyth prices. Orders can also be self executed after
 *         a cooldown period
 */
contract Processor is Roles, ReentrancyGuard {
    // Libraries
    using Address for address payable;

    // Constants
    uint256 public constant BPS_DIVIDER = 10000;

    // Events
    event LiquidationError(address user, address asset, string market, uint256 price, string reason);
    event PositionLiquidated(
        address indexed user,
        address indexed asset,
        string market,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 marginUsd,
        uint256 price,
        uint256 fee
    );
    event OrderSkipped(uint256 indexed orderId, string market, uint256 price, uint256 publishTime, string reason);
    event UserSkipped(
        address indexed user,
        address indexed asset,
        string market,
        uint256 price,
        uint256 publishTime,
        string reason
    );
    event PythPriceChecked(uint256 price, uint256 publishTime, uint256 confidence);


    // Contracts
    DataStore public DS;

    AssetStore public assetStore;
    FundStore public fundStore;
    MarketStore public marketStore;
    OrderStore public orderStore;
    PoolStore public poolStore;
    PositionStore public positionStore;
    RiskStore public riskStore;

    Funding public funding;
    Orders public orders;
    Pool public pool;
    Positions public positions;

    Chainlink public chainlink;
    IPyth public pyth;

    /// @dev Initializes DataStore address
    constructor(RoleStore rs, DataStore ds) Roles(rs) {
        DS = ds;
    }

    /// @dev Reverts if order processing is paused
    modifier ifNotPaused() {
        require(!orderStore.isProcessingPaused(), '!paused');
        _;
    }

    /// @notice Initializes protocol contracts
    /// @dev Only callable by governance
    function link() external onlyGov {
        assetStore = AssetStore(DS.getAddress('AssetStore'));
        fundStore = FundStore(payable(DS.getAddress('FundStore')));
        marketStore = MarketStore(DS.getAddress('MarketStore'));
        orderStore = OrderStore(DS.getAddress('OrderStore'));
        poolStore = PoolStore(DS.getAddress('PoolStore'));
        positionStore = PositionStore(DS.getAddress('PositionStore'));
        riskStore = RiskStore(DS.getAddress('RiskStore'));
        funding = Funding(DS.getAddress('Funding'));
        pool = Pool(DS.getAddress('Pool'));
        orders = Orders(DS.getAddress('Orders'));
        positions = Positions(DS.getAddress('Positions'));
        chainlink = Chainlink(DS.getAddress('Chainlink'));
        pyth = IPyth(DS.getAddress('Pyth'));
    }

    // ORDER EXECUTION

    /// @notice Self execution of order using Chainlink (after a cooldown period)
    /// @dev Anyone can call this in case order isn't executed from keeper via {executeOrders}
    /// @param orderId order id to execute
    function selfExecuteOrder(uint256 orderId) external nonReentrant ifNotPaused {
        (bool status, string memory reason) = _executeOrder(orderId, 0, true, address(0), 999999999999);
        require(status, reason);
    }

    /// @notice Order execution by keeper with Pyth priceUpdateData
    /// @param orderIds order id's to execute
    /// @param priceUpdateData Pyth priceUpdateData, see docs.pyth.network
    function executeOrders(
        uint256[] calldata orderIds,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant ifNotPaused {
        // updates price for all submitted price feeds
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, '!fee');
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        if (!pool.isKeeperYellowlisted(msg.sender)) {
            return;
        }

        // Get the price for each order
        for (uint256 i = 0; i < orderIds.length; i++) {
            OrderStore.Order memory order = orderStore.get(orderIds[i]);
            MarketStore.Market memory market = marketStore.get(order.market);

            if (block.timestamp - order.timestamp < market.minOrderAge) {
                // Order too early (front run prevention)
                emit OrderSkipped(orderIds[i], order.market, 0, 0, '!early');
                continue;
            }

            (uint256 price, uint256 publishTime, uint256 confidence) = _getPythPrice(market.pythFeed);

            emit PythPriceChecked(price, publishTime, confidence);

            if (publishTime <= order.timestamp) {
                // Price older than order submission time
                emit OrderSkipped(orderIds[i], order.market, price, publishTime, '!not-updated');
                continue;
            }

            if (block.timestamp - publishTime > market.pythMaxAge) {
                // Price too old
                emit OrderSkipped(orderIds[i], order.market, price, publishTime, '!stale');
                continue;
            }

            (bool status, string memory reason) = _executeOrder(orderIds[i], price, false, msg.sender, confidence);
            if (!status) orders.cancelOrder(orderIds[i], reason);
        }

        // Refund msg.value excess, if any
        if (msg.value > fee) {
            uint256 diff = msg.value - fee;
            payable(msg.sender).sendValue(diff);
        }
    }

    /// @dev Executes submitted order
    /// @param orderId Order to execute
    /// @param price Pyth price (0 if self-executed since Chainlink price will be used)
    /// @param withChainlink Wether to use Chainlink or not (i.e. if self executed or not)
    /// @param keeper Address of keeper which executes the order (address(0) if self execution)
    function _executeOrder(
        uint256 orderId,
        uint256 price,
        bool withChainlink,
        address keeper,
        uint256 confidence
    ) internal returns (bool, string memory) {
        OrderStore.Order memory order = orderStore.get(orderId);

        // Validations

        if (order.size == 0) {
            return (false, '!order');
        }

        if (order.expiry > 0 && order.expiry <= block.timestamp) {
            return (false, '!expired');
        }

        // cancel if order is too old
        // By default, market orders expire after 30 minutes and trigger orders after 180 days
        uint256 ttl = block.timestamp - order.timestamp;
        if ((order.orderType == 0 && ttl > orderStore.maxMarketOrderTTL()) || ttl > orderStore.maxTriggerOrderTTL()) {
            return (false, '!too-old');
        }

        MarketStore.Market memory market = marketStore.get(order.market);

        uint256 chainlinkPrice = chainlink.getPrice(market.chainlinkFeed);

        if (withChainlink) {
            if (chainlinkPrice == 0) {
                return (false, '!no-chainlink-price');
            }
            if (!market.allowChainlinkExecution) {
                return (false, '!chainlink-not-allowed');
            }
            if (order.timestamp > block.timestamp - orderStore.chainlinkCooldown()) {
                return (false, '!chainlink-cooldown');
            }
            price = chainlinkPrice;
        }

        if (price == 0) {
            return (false, '!no-price');
        }

        // Bound provided price with chainlink
        if (!_boundPriceWithChainlink(market.maxDeviation, chainlinkPrice, price)) {
            return (true, '!chainlink-deviation'); // returns true so as not to trigger order cancellation
        }

        // Is trigger order executable at provided price?
        if (order.orderType != 0) {
            if (
                (order.orderType == 1 && order.isLong && price > order.price) ||
                (order.orderType == 1 && !order.isLong && price < order.price) || // limit buy // limit sell
                (order.orderType == 2 && order.isLong && price < order.price) || // stop buy
                (order.orderType == 2 && !order.isLong && price > order.price) // stop sell
            ) {
                return (true, '!no-execution'); // don't cancel order
            }
        } else if (order.price > 0) {
            // protected market order (market order with a price). It will execute only if the execution price
            // is better than the submitted price. Otherwise, it will be cancelled
            if ((order.isLong && price > order.price) || (!order.isLong && price < order.price)) {
                return (false, '!protected');
            }
        }

        // One-cancels-the-Other (OCO)
        // `cancelOrderId` is an existing order which should be cancelled when the current order executes
        if (order.cancelOrderId > 0) {
            try orders.cancelOrder(order.cancelOrderId, '!oco') {} catch Error(string memory reason) {
                return (false, reason);
            }
        }

        // Check if there is a position
        PositionStore.Position memory position = positionStore.getPosition(order.user, order.asset, order.market);

        uint256 scaledConfidencePriceRatio = (confidence * 1e18) / price;
        uint256 scaledMarketFee = market.fee * 1e14;

        bool doAdd = (!order.isReduceOnly && scaledConfidencePriceRatio < scaledMarketFee) && (position.size == 0 || order.isLong == position.isLong);
        bool doReduce = position.size > 0 && order.isLong != position.isLong;

        if (doAdd) {
            try positions.increasePosition(orderId, price, keeper) {} catch Error(string memory reason) {
                return (false, reason);
            }
        } else if (doReduce) {
            try positions.decreasePosition(orderId, price, keeper) {} catch Error(string memory reason) {
                return (false, reason);
            }
        } else {
            return (false, '!reduce');
        }

        return (true, '');
    }

    // POSITION LIQUIDATION

    /// @notice Self liquidation of order using Chainlink price
    /// @param user User address to liquidate
    /// @param asset Base asset of position
    /// @param market Market this position was submitted on
    function selfLiquidatePosition(
        address user,
        address asset,
        string memory market
    ) external nonReentrant ifNotPaused {
        (bool status, string memory reason) = _liquidatePosition(user, asset, market, 0, true, address(0));
        require(status, reason);
    }

    /// @notice Position liquidation by keeper (anyone) with Pyth priceUpdateData
    /// @param users User addresses to liquidate
    /// @param assets Base asset array
    /// @param markets Market array
    /// @param priceUpdateData Pyth priceUpdateData, see docs.pyth.network
    function liquidatePositions(
        address[] calldata users,
        address[] calldata assets,
        string[] calldata markets,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant ifNotPaused {
        // updates price for all submitted price feeds
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, '!fee');

        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        for (uint256 i = 0; i < users.length; i++) {
            MarketStore.Market memory market = marketStore.get(markets[i]);

            (uint256 price, uint256 publishTime, uint256 confidence) = _getPythPrice(market.pythFeed);

            if (block.timestamp - publishTime > market.pythMaxAge) {
                // Price too old
                emit UserSkipped(users[i], assets[i], markets[i], price, publishTime, '!stale');
                continue;
            }

            (bool status, string memory reason) = _liquidatePosition(
                users[i],
                assets[i],
                markets[i],
                price,
                false,
                msg.sender
            );
            if (!status) {
                emit LiquidationError(users[i], assets[i], markets[i], price, reason);
            }
        }

        // Refund msg.value excess, if any
        if (msg.value > fee) {
            uint256 diff = msg.value - fee;
            payable(msg.sender).sendValue(diff);
        }
    }

    /// @dev Liquidates position
    /// @param user User address to liquidate
    /// @param asset Base asset of position
    /// @param market Market this position was submitted on
    /// @param price Pyth price (0 if self liquidation since Chainlink price will be used)
    /// @param withChainlink Wether to use Chainlink or not (i.e. if self liquidation or not)
    /// @param keeper Address of keeper which liquidates position (address(0) if self liquidation)
    function _liquidatePosition(
        address user,
        address asset,
        string memory market,
        uint256 price,
        bool withChainlink,
        address keeper
    ) internal returns (bool, string memory) {
        PositionStore.Position memory position = positionStore.getPosition(user, asset, market);
        if (position.size == 0) {
            return (false, '!position');
        }

        MarketStore.Market memory marketInfo = marketStore.get(market);

        uint256 chainlinkPrice = chainlink.getPrice(marketInfo.chainlinkFeed);

        if (withChainlink) {
            if (chainlinkPrice == 0) {
                return (false, '!no-chainlink-price');
            }
            price = chainlinkPrice;
        }

        if (price == 0) {
            return (false, '!no-price');
        }

        // Bound provided price with chainlink
        if (!_boundPriceWithChainlink(marketInfo.maxDeviation, chainlinkPrice, price)) {
            return (false, '!chainlink-deviation');
        }

        // Get PNL of position
        (int256 pnl, ) = positions.getPnL(
            asset,
            market,
            position.isLong,
            price,
            position.price,
            position.size,
            position.fundingTracker
        );

        // Treshold after which position will be liquidated
        uint256 threshold = (position.margin * marketInfo.liqThreshold) / BPS_DIVIDER;

        // Liquidate position if PNL is less than required threshold
        if (pnl <= -1 * int256(threshold)) {
            uint256 fee = (position.size * marketInfo.fee) / BPS_DIVIDER;

            // Credit trader loss and fee
            pool.creditTraderLoss(user, asset, market, position.margin - fee);
            positions.creditFee(0, user, asset, market, fee, true, keeper);

            // Update funding
            positionStore.decrementOI(asset, market, position.size, position.isLong);
            funding.updateFundingTracker(asset, market);

            // Remove position
            positionStore.remove(user, asset, market);

            emit PositionLiquidated(
                user,
                asset,
                market,
                position.isLong,
                position.size,
                position.margin,
                _getUsdAmount(asset, position.margin),
                price,
                fee
            );
        }

        return (true, '');
    }

    // -- Utils -- //

    /// @dev Returns pyth price converted to 18 decimals
    function _getPythPrice(bytes32 priceFeedId) internal view returns (uint256, uint256, uint256) {
        // It will revert if the price is older than maxAge
        PythStructs.Price memory retrievedPrice = pyth.getPriceUnsafe(priceFeedId);
        uint256 baseConversion = 10 ** uint256(int256(18) + retrievedPrice.expo);

        // Convert price to 18 decimals
        uint256 price = uint256(retrievedPrice.price * int256(baseConversion));
        uint256 publishTime = retrievedPrice.publishTime;
        uint256 confidence = retrievedPrice.conf;

        return (price, publishTime, confidence);
    }

    /// @dev Returns USD value of `amount` of `asset`
    /// @dev Used for PositionLiquidated event
    function _getUsdAmount(address asset, uint256 amount) internal view returns (uint256) {
        AssetStore.Asset memory assetInfo = assetStore.get(asset);
        uint256 chainlinkPrice = chainlink.getPrice(assetInfo.chainlinkFeed);
        uint256 decimals = 18;
        if (asset != address(0)) {
            decimals = IERC20Metadata(asset).decimals();
        }
        // amount is in the asset's decimals, convert to 18. Price is 18 decimals
        return (amount * chainlinkPrice) / 10 ** decimals;
    }

    /// @dev Submitted Pyth price is bound by the Chainlink price
    function _boundPriceWithChainlink(
        uint256 maxDeviation,
        uint256 chainlinkPrice,
        uint256 price
    ) internal pure returns (bool) {
        if (chainlinkPrice == 0 || maxDeviation == 0) return true;
        if (
            price >= (chainlinkPrice * (BPS_DIVIDER - maxDeviation)) / BPS_DIVIDER &&
            price <= (chainlinkPrice * (BPS_DIVIDER + maxDeviation)) / BPS_DIVIDER
        ) {
            return true;
        }
        return false;
    }
}
