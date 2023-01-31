// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./IStrategy.sol";
import "../IPoolV4.sol";
import "../TokenMaths.sol";


/**
 * This strategy aims to follow the trend buying the risk asset when the price is above a predefined moving average
 * and selling into the stable asset when the price is below such moving average.
 * 
 * The strategy is configured with the following parameters:
 * - movingAveragePeriod: the period used to determine the average of the price.
 * - tokensToSwapPerc: the percentage of the risk/stable assets to BUY/SELL when the trade logic is triggered.
 * - minAllocationPerc: the minium percentage of the porfolio that should be allocated to both the stable and risk assets at all times.
 */


contract TrendFollowV1 is IStrategy, Ownable {

    using TokenMaths for uint;

    event StrategyEval(StrategyAction action, uint amountIn);


    IPoolV4 public pool;
    uint public upkeepInterval = 24 * 60 * 60;
    uint public lastEvalTimestamp; // last time the strategy was evaluated

    AggregatorV3Interface public stableAssetFeed;
    AggregatorV3Interface public riskAssetFeed;
    IERC20Metadata public depositToken;
    IERC20Metadata public investToken;


    uint public immutable movingAveragePeriod; // The period of the moving average, for example 350 period
    uint public movingAverage;      // The current value of the Moving Average. Needs to be initialized at deployment (uses pricefeed.decimals)
    // uint public lastEvalTime;       // the last time that the strategy was evaluated


    uint percentPrecision = 100 * 100;

    constructor(
        address poolAddress,
        address stableAssetFeedAddress,
        address riskAssetFeedAddress,

        address stableAssetAddress,
        address riskAssetAddress,

        uint _movingAveragePeriod,
        uint _initialMeanValue
    ) {
        pool = IPoolV4(poolAddress);
        stableAssetFeed = AggregatorV3Interface(stableAssetFeedAddress);
        riskAssetFeed = AggregatorV3Interface(riskAssetFeedAddress);

        depositToken = IERC20Metadata(stableAssetAddress);
        investToken = IERC20Metadata(riskAssetAddress);

        movingAveragePeriod = _movingAveragePeriod;
        movingAverage = _initialMeanValue;

        lastEvalTimestamp = block.timestamp;
    }

    //// IStrategy Interface //// 

    function name() external override pure returns(string memory) {
        return "TrendFollowV1";
    }

    function description() external override pure returns(string memory) {
        return "A trend following strategy based on a fast moving average";
    }


    /**
     * @return true when strategy needs to be executed because upkeepInterval has elapsed
     */
    function shouldPerformUpkeep() external view returns (bool) {
        return block.timestamp >= lastEvalTimestamp + upkeepInterval;
    }


    /**
     * @return action to inform the Pool on whether it should make a swap and the amount to swap.
     * note: this function should ony be called by its Pool
     */
    function exec() external override onlyOwner returns (StrategyAction action, uint amountIn) {
     
        // disregard negatice and old prices
        ( /*uint80 roundID**/,  int price, /*uint startedAt*/, uint priceTimestamp, /*uint80 answeredInRound*/ ) = riskAssetFeed.latestRoundData();
        if ( (price <= 0) || 
            ( (block.timestamp >= priceTimestamp) && ( block.timestamp - priceTimestamp > upkeepInterval)) ) {
            return (StrategyAction.NONE, 0);
        }

        // update the moving average
        uint ma = updatedMovingAverage(price);
        (action, amountIn) = eval(ma, price);

        movingAverage = ma;
        lastEvalTimestamp = block.timestamp;

        emit StrategyEval(action, amountIn);
    }



    function eval(uint ma, int price) internal view returns (StrategyAction action, uint amountIn) {

        if (pool.totalValue() == 0) {
            return (StrategyAction.NONE, 0);
        }

        int deltaPrice = int(percentPrecision) * (price - int(ma));
        uint investTokenBalance = investToken.balanceOf(address(pool));
        uint depositTokenBalance = depositToken.balanceOf(address(pool));

        bool shouldSell = deltaPrice < 0 && investTokenBalance > 0;

        if (shouldSell) {
            // SELL all invest tokens and buy deposit tokens
            action = StrategyAction.SELL;
            amountIn = investTokenBalance;
        }

        bool shouldBuy = deltaPrice > 0 && depositTokenBalance > 0;

        if (shouldBuy) {
            // BUY invest tokens spending all deposit tokens
            action = StrategyAction.BUY;
            amountIn = depositTokenBalance;
        }

        return (action, amountIn);
    }



    function updatedMovingAverage(int price) internal view returns (uint updatedMA) {
        // days elapsed since the moving average was updated
        uint daysSinceLastUpdate =  (block.timestamp - lastEvalTimestamp) / 86400; 
        if (daysSinceLastUpdate == 0) return movingAverage;

        if (daysSinceLastUpdate < movingAveragePeriod) {
            // update the moving average, using movingAverage price for 'movingAveragePeriod' - 'daysSinceLasUpdate' days 
            // and the current price for the last 'daysSinceLasUpdate' days
            uint oldPricesWeight = movingAverage * ( movingAveragePeriod - daysSinceLastUpdate);
            uint newPriceWeight = daysSinceLastUpdate * uint(price);
            updatedMA = (oldPricesWeight + newPriceWeight ) / movingAveragePeriod;
        } else {
            updatedMA = uint(price);
        }
    }



    //// ONLY OWNER ////
    function setPool(address _poolAddress) external onlyOwner {
        pool = IPoolV4(_poolAddress);
    }

    function setUpkeepInterval(uint interval) external onlyOwner {
        upkeepInterval = interval;
    }

}