// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import '@openzeppelin/contracts/utils/Address.sol';

import './AssetStore.sol';
import './DataStore.sol';
import './FundStore.sol';
import './OrderStore.sol';
import './MarketStore.sol';
import './RiskStore.sol';

import './Chainlink.sol';
import './Roles.sol';

/**
 * @title  Orders
 * @notice Implementation of order related logic, i.e. submitting orders / cancelling them
 */
contract Orders is Roles {

    // Libraries
    using Address for address payable;

    // Constants
    uint256 public constant UNIT = 10 ** 18;
    uint256 public constant BPS_DIVIDER = 10000;

    // Events

    // Order of function / event params: id, user, asset, market
    event OrderCreated(
        uint256 indexed orderId,
        address indexed user,
        address indexed asset,
        string market,
        uint256 margin,
        uint256 size,
        uint256 price,
        uint256 fee,
        bool isLong,
        uint8 orderType,
        bool isReduceOnly,
        uint256 expiry,
        uint256 cancelOrderId
    );

    event OrderCancelled(uint256 indexed orderId, address indexed user, string reason);

    // Contracts
    DataStore public DS;

    AssetStore public assetStore;
    FundStore public fundStore;
    MarketStore public marketStore;
    OrderStore public orderStore;
    RiskStore public riskStore;

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
        marketStore = MarketStore(DS.getAddress('MarketStore'));
        orderStore = OrderStore(DS.getAddress('OrderStore'));
        riskStore = RiskStore(DS.getAddress('RiskStore'));
        chainlink = Chainlink(DS.getAddress('Chainlink'));
    }

    /// @notice Submits a new order
    /// @param params Order to submit
    /// @param tpPrice 18 decimal take profit price
    /// @param slPrice 18 decimal stop loss price
    function submitOrder(
        OrderStore.Order memory params,
        uint256 tpPrice,
        uint256 slPrice
    ) external payable ifNotPaused {
        // order cant be reduce-only if take profit or stop loss order is submitted alongside main order
        if (tpPrice > 0 || slPrice > 0) {
            params.isReduceOnly = false;
        }

        // Submit order
        uint256 valueConsumed;
        (, valueConsumed) = _submitOrder(params);

        // tp/sl price checks
        if (tpPrice > 0 || slPrice > 0) {
            if (params.price > 0) {
                if (tpPrice > 0) {
                    require(
                        (params.isLong && tpPrice > params.price) || (!params.isLong && tpPrice < params.price),
                        '!tp-invalid'
                    );
                }
                if (slPrice > 0) {
                    require(
                        (params.isLong && slPrice < params.price) || (!params.isLong && slPrice > params.price),
                        '!sl-invalid'
                    );
                }
            }

            if (tpPrice > 0 && slPrice > 0) {
                require((params.isLong && tpPrice > slPrice) || (!params.isLong && tpPrice < slPrice), '!tpsl-invalid');
            }

            // tp and sl order ids
            uint256 tpOrderId;
            uint256 slOrderId;

            // long -> short, short -> long for take profit / stop loss order
            params.isLong = !params.isLong;

            // reset order expiry for TP/SL orders
            if (params.expiry > 0) params.expiry = 0;

            // submit take profit order
            if (tpPrice > 0) {
                params.price = tpPrice;
                params.orderType = 1;
                params.isReduceOnly = true;

                // Order is reduce-only so valueConsumed is always zero
                (tpOrderId, ) = _submitOrder(params);
            }

            // submit stop loss order
            if (slPrice > 0) {
                params.price = slPrice;
                params.orderType = 2;
                params.isReduceOnly = true;

                // Order is reduce-only so valueConsumed is always zero
                (slOrderId, ) = _submitOrder(params);
            }

            // Update orders to cancel each other
            if (tpOrderId > 0 && slOrderId > 0) {
                orderStore.updateCancelOrderId(tpOrderId, slOrderId);
                orderStore.updateCancelOrderId(slOrderId, tpOrderId);
            }
        }

        // Refund msg.value excess, if any
        if (params.asset == address(0)) {
            uint256 diff = msg.value - valueConsumed;
            if (diff > 0) {
                payable(msg.sender).sendValue(diff);
            }
        }
    }

    /// @notice Submits a new order
    /// @dev Internal function invoked by {submitOrder}
    function _submitOrder(OrderStore.Order memory params) internal returns (uint256, uint256) {
        // Set user and timestamp
        params.user = msg.sender;
        params.timestamp = block.timestamp;

        // Validations
        require(params.orderType == 0 || params.orderType == 1 || params.orderType == 2, '!order-type');

        // execution price of trigger order cant be zero
        if (params.orderType != 0) {
            require(params.price > 0, '!price');
        }

        // check if base asset is supported and order size is above min size
        AssetStore.Asset memory asset = assetStore.get(params.asset);
        require(asset.minSize > 0, '!asset-exists');
        require(params.size >= asset.minSize, '!min-size');

        // check if market exists
        MarketStore.Market memory market = marketStore.get(params.market);
        require(market.maxLeverage > 0, '!market-exists');

        // Order expiry validations
        if (params.expiry > 0) {
            // expiry value cant be in the past
            require(params.expiry >= block.timestamp, '!expiry-value');

            // params.expiry cant be after default expiry of market and trigger orders
            uint256 ttl = params.expiry - block.timestamp;
            if (params.orderType == 0) require(ttl <= orderStore.maxMarketOrderTTL(), '!max-expiry');
            else require(ttl <= orderStore.maxTriggerOrderTTL(), '!max-expiry');
        }

        // cant cancel an order of another user
        if (params.cancelOrderId > 0) {
            require(orderStore.isUserOrder(params.cancelOrderId, params.user), '!user-oco');
        }

        params.fee = (params.size * market.fee) / BPS_DIVIDER;
        uint256 valueConsumed;

        if (params.isReduceOnly) {
            params.margin = 0;
            // Existing position is checked on execution so TP/SL can be submitted as reduce-only alongside a non-executed order
            // In this case, valueConsumed is zero as margin is zero and fee is taken from the order's margin when position is executed
        } else {
            require(!market.isReduceOnly, '!market-reduce-only');
            require(params.margin > 0, '!margin');

            uint256 leverage = (UNIT * params.size) / params.margin;
            require(leverage >= UNIT, '!min-leverage');
            require(leverage <= market.maxLeverage * UNIT, '!max-leverage');

            // Check against max OI if it's not reduce-only. this is not completely fail safe as user can place many
            // consecutive market orders of smaller size and get past the max OI limit here, because OI is not updated until
            // keeper picks up the order. That is why maxOI is checked on processing as well, which is fail safe.
            // This check is more of preemptive for user to not submit an order
            riskStore.checkMaxOI(params.asset, params.market, params.size);

            // Transfer fee and margin to store
            valueConsumed = params.margin + params.fee;

            if (params.asset == address(0)) {
                fundStore.transferIn{value: valueConsumed}(params.asset, params.user, valueConsumed);
            } else {
                fundStore.transferIn(params.asset, params.user, valueConsumed);
            }
        }

        // Add order to store and emit event
        params.orderId = orderStore.add(params);

        emit OrderCreated(
            params.orderId,
            params.user,
            params.asset,
            params.market,
            params.margin,
            params.size,
            params.price,
            params.fee,
            params.isLong,
            params.orderType,
            params.isReduceOnly,
            params.expiry,
            params.cancelOrderId
        );

        return (params.orderId, valueConsumed);
    }

    /// @notice Cancels order
    /// @param orderId Order to cancel
    function cancelOrder(uint256 orderId) external ifNotPaused {
        OrderStore.Order memory order = orderStore.get(orderId);
        require(order.size > 0, '!order');
        require(order.user == msg.sender, '!user');
        _cancelOrder(orderId, 'by-user');
    }

    /// @notice Cancel several orders
    /// @param orderIds Array of orderIds to cancel
    function cancelOrders(uint256[] calldata orderIds) external ifNotPaused {
        for (uint256 i = 0; i < orderIds.length; i++) {
            OrderStore.Order memory order = orderStore.get(orderIds[i]);
            if (order.size > 0 && order.user == msg.sender) {
                _cancelOrder(orderIds[i], 'by-user');
            }
        }
    }

    /// @notice Cancels order
    /// @dev Only callable by other protocol contracts
    /// @param orderId Order to cancel
    /// @param reason Cancellation reason
    function cancelOrder(uint256 orderId, string calldata reason) external onlyContract {
        _cancelOrder(orderId, reason);
    }

    /// @notice Cancel several orders
    /// @dev Only callable by other protocol contracts
    /// @param orderIds Order ids to cancel
    /// @param reasons Cancellation reasons
    function cancelOrders(uint256[] calldata orderIds, string[] calldata reasons) external onlyContract {
        for (uint256 i = 0; i < orderIds.length; i++) {
            _cancelOrder(orderIds[i], reasons[i]);
        }
    }

    /// @notice Cancels order
    /// @dev Internal function without access restriction
    /// @param orderId Order to cancel
    /// @param reason Cancellation reason
    function _cancelOrder(uint256 orderId, string memory reason) internal {
        OrderStore.Order memory order = orderStore.get(orderId);
        if (order.size == 0) return;

        orderStore.remove(orderId);

        if (!order.isReduceOnly) {
            fundStore.transferOut(order.asset, order.user, order.margin + order.fee);
        }

        emit OrderCancelled(orderId, order.user, reason);
    }
}
