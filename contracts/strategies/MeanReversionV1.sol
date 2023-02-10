// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./IStrategy.sol";
import "../IPoolV4.sol";
import "../TokenMaths.sol";

/**
 * This strategy aims to buy/sell when the price moves far in either directions from a slow moving average of the price.
 * If the price moves above 'targetPricePercUp' percent of the moving average the strategy should sell 'tokensToSwapPerc' percentage of the invest tokens.
 * If the price moves below 'targetPricePercDown' percent of the moving average the strategy should buy 'tokensToSwapPerc' percentage of the invest tokens.
 * 
 * The strategy also ensures to keep at least "minAllocationPerc' percent of the pool value in both tokens.
 * This is to ensure the strategy doesn't get too greedy investing or disinvesting.
 */

contract MeanReversionV1 is IStrategy, Ownable {

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


    // [0-100] intervals
    uint public immutable minAllocationPerc;   // the min percentage of pool value to hold in deposit and invest tokens (e.g 20%)
    uint public immutable targetPricePercUp;   // the percentage the price should move above the moving average to trigger a SELL of invest tokens (e.g 66%)
    uint public immutable targetPricePercDown; // the percentage the price shold move below the moving average to trigger a BUY of invest tokens (e.g 33%)
    uint public immutable tokensToSwapPerc;     // the percentage of deposit/invest tokens to BUY/SELL when the stategy trigger a BUY/SELL (e.g 5%)

    uint percentPrecision = 100 * 100;


    constructor(
        address poolAddress,
        address stableAssetFeedAddress,
        address riskAssetFeedAddress,
        address stableAssetAddress,
        address riskAssetAddress,

        uint _movingAveragePeriod,
        uint _initialMeanValue,

        uint _minAllocationPerc,
        uint _targetPricePercUp,
        uint _targetPricePercDown,
        uint _tokensToSwapPerc

    ) {
        pool = IPoolV4(poolAddress);
        stableAssetFeed = AggregatorV3Interface(stableAssetFeedAddress);
        riskAssetFeed = AggregatorV3Interface(riskAssetFeedAddress);

        depositToken = IERC20Metadata(stableAssetAddress);
        investToken = IERC20Metadata(riskAssetAddress);

        movingAveragePeriod = _movingAveragePeriod;
        movingAverage = _initialMeanValue;

        minAllocationPerc = _minAllocationPerc;
        targetPricePercUp = _targetPricePercUp;
        targetPricePercDown = _targetPricePercDown;
        tokensToSwapPerc = _tokensToSwapPerc;

        lastEvalTimestamp = block.timestamp;
    }

    //// IStrategy Interface //// 

    function name() public override pure returns(string memory) {
        return "MeanReversionV1";
    }

    function description() public override pure returns(string memory) {
        return "A mean reversion strategy for a 2 token portfolio";
    }


    /**
     * @return true when strategy needs to be executed because upkeepInterval has elapsed
     */
    function shouldPerformUpkeep() external view returns (bool) {

        return (block.timestamp >= lastEvalTimestamp) && (block.timestamp - lastEvalTimestamp >= upkeepInterval);
    }


    /**
     * @return action to inform the Pool on whether it should make a swap and the amount to swap.
     * note: this function should ony be called by its Pool
     */
    function exec() public override onlyOwner returns (StrategyAction action, uint amountIn) {
    
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



    function eval(uint ma, int price) public view returns (StrategyAction action, uint amountIn) {

        if (pool.totalValue() == 0) {
            return (StrategyAction.NONE, 0);
        }

        (action, amountIn) = evalDCA(ma, price);

        // Handle rebalancing situations when either token balance is too low
        uint depositTokensToSell = rebalanceDepositTokensAmount();
        if (depositTokensToSell > 0) {
            amountIn = (action == StrategyAction.BUY) && (amountIn > depositTokensToSell) ? amountIn : depositTokensToSell;
            return (StrategyAction.BUY, amountIn);
        }

        uint investTokensToSell = rebalanceInvestTokensAmount();
        if (investTokensToSell > 0) {
            amountIn = (action == StrategyAction.SELL) && (amountIn > investTokensToSell) ? amountIn : investTokensToSell;
            return (StrategyAction.SELL, amountIn);
        }

        return (action, amountIn);
    }



    function evalDCA(uint ma, int price) internal view returns (StrategyAction action, uint amountIn) {

        ( /*uint80 roundID**/, int price0, /*uint startedAt*/, /* uint priceTimestamp0 */, /*uint80 answeredInRound*/ ) = stableAssetFeed.latestRoundData();
        ( /*uint80 roundID**/, int price1, /*uint startedAt*/, /* uint priceTimestamp1 */, /*uint80 answeredInRound*/ ) = riskAssetFeed.latestRoundData();



        int deltaPricePerc = int(percentPrecision) * (price - int(ma)) / int(ma);
        uint investPerc = investPercent(); // the % of invest tokens in the pool with percentPrecision
        // uint depositPerc = percentPrecision - investPerc;    // with percentPrecision
        uint minAllocationPercent = minAllocationPerc * percentPrecision / 100;
        
        uint targetPricePercUpPercent = targetPricePercUp * percentPrecision / 100;
        bool shouldSell = deltaPricePerc > 0 &&
                          uint(deltaPricePerc) >= targetPricePercUpPercent &&
                          investPerc > minAllocationPercent;

        if (shouldSell) {
            // need to SELL invest tokens buying deposit tokens
            action = StrategyAction.SELL;
            amountIn = (pool.riskAssetValue() * tokensToSwapPerc ).div(uint(price1),
                depositToken.decimals(), riskAssetFeed.decimals(), investToken.decimals()
            ) / 100;
        }

        uint targetPricePercDownPercent = targetPricePercDown * percentPrecision / 100;
        bool shouldBuy = deltaPricePerc < 0 &&
                        deltaPricePerc <= -1 * int(targetPricePercDownPercent) &&
                        (percentPrecision - investPerc) > minAllocationPercent;

        if (shouldBuy) {
            // need to BUY invest tokens spending depositTokens
            action = StrategyAction.BUY;
            amountIn = (pool.stableAssetValue() * tokensToSwapPerc).div(uint(price0),
                depositToken.decimals(), stableAssetFeed.decimals(), depositToken.decimals()
            ) / 100;
        }

        return (action, amountIn);
    }




    // Returns the % of invest tokens with percentPrecision precision
    // Assumes pool.totalPortfolioValue > 0 or returns 0
    function investPercent() internal view returns (uint investPerc) {

        uint riskAssetValue = pool.riskAssetValue();
        uint poolValue = pool.totalValue();
        if (poolValue == 0) return 0;

        investPerc = (percentPrecision * riskAssetValue / poolValue); // the % of risk asset in the pool
    }


    // determine the amount of stable asset to SELL to have minAllocationPerc % invest tokens
    function rebalanceDepositTokensAmount() internal view returns (uint) {

        uint investPerc = investPercent(); // with percentPrecision digits
        uint targetInvestPerc = minAllocationPerc * percentPrecision / 100;
        uint amountIn = 0;

        if (investPerc < targetInvestPerc) {
            (   /*uint80 roundID**/, int price, /*uint startedAt*/,
            /*uint timeStamp*/, /*uint80 answeredInRound*/
            ) = stableAssetFeed.latestRoundData();

            uint depositTokenValue = pool.stableAssetValue();
            uint targetDepositPerc =  percentPrecision - targetInvestPerc; //  1 - investt_token % (e.g. 80%)
            uint targetDepositTokenValue = pool.totalValue() * targetDepositPerc / percentPrecision;

            // ensure we have deposit tokens to SELL
            assert(depositTokenValue >= targetDepositTokenValue);
            
            // calculate amount of stable tokens to SELL
            amountIn = (depositTokenValue - targetDepositTokenValue).div( uint(price), 
                depositToken.decimals(), stableAssetFeed.decimals(), depositToken.decimals());
        }

        return amountIn;
    }

    // determine the amount of invest tokens to SELL to have minAllocationPerc % deposit tokens
    function rebalanceInvestTokensAmount() internal view returns (uint) {

        uint investPerc = investPercent(); // with percentPrecision digits
        uint depositPerc = percentPrecision - investPerc; //  1 - invest_token %

        uint targetDepositPerc = minAllocationPerc * percentPrecision / 100;
        uint amountIn = 0;
     
        if (depositPerc < targetDepositPerc) {

            (   /*uint80 roundID**/, int price, /*uint startedAt*/,
                /*uint timeStamp*/, /*uint80 answeredInRound*/
            ) = riskAssetFeed.latestRoundData();

            // calculate amount of invest tokens to sell (to BUY deposit tokens)
            uint investTokenValue = pool.riskAssetValue();
            uint targetInvestPerc = percentPrecision - targetDepositPerc;  //  1 - deposit_token % (e.g. 80%)
            uint targetInvestTokenValue = pool.totalValue() * targetInvestPerc / percentPrecision;

            // ensure we have invest tokens to sell
            assert(investTokenValue >= targetInvestTokenValue);

            // calculate amount of investment tokens to SELL
            amountIn = (investTokenValue - targetInvestTokenValue).div( uint(price), 
                depositToken.decimals(), riskAssetFeed.decimals(), investToken.decimals());
        }

        return amountIn;
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
    function setPool(address _poolAddress) public onlyOwner {
        pool = IPoolV4(_poolAddress);
    }

    function setUpkeepInterval(uint interval) public onlyOwner {
        upkeepInterval = interval;
    }

}