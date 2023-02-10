// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./IStrategy.sol";
import "../IPoolV4.sol";
import "../TokenMaths.sol";

/**
 * A simple rebalancing strategy for a 2 asset Pool.
 *
 * When the value of one of the assets in the Pool grows above (targetInvestPerc + rebalancingThreshold)
 * or drops below (targetInvestPerc - rebalancingThreshold) then the strategy returns the amount
 * of tokens to BUY or SELL in order to rebalance the Pool.
 *
 * Example:
 * Given an ETH/USD Pool with a 60%/40% target allocation and a 10% rebalancing thereshold,
 * when the value of all ETH in the Pool grows above 70%, or drops below 50%,
 * some ETH is sold/bought to restore the target 60%/40% asset  allocation.
 *
 * Owner: This contract shoukd be owned by the Pool configured with this Strategy.
 **/

contract RebalancingStrategyV1 is IStrategy, Ownable {

    using TokenMaths for uint;

    event StrategyEval(StrategyAction action, uint amountIn);

    uint immutable public targetInvestPerc;  // [0-100] interval
    uint immutable public rebalancingThreshold; // [0-100] interval

    IPoolV4 public pool;
    uint public upkeepInterval = 24 * 60 * 60;
    uint public lastEvalTimestamp; // last time the strategy was evaluated

    AggregatorV3Interface public riskAssetFeed;
    AggregatorV3Interface public stableAssetFeed;
    IERC20Metadata public depositToken;
    IERC20Metadata public investToken;


    constructor(
        address poolAddress,
        address stableAssetFeedAddress,
        address riskAssetFeedAddress,
        address stableAssetAddress,
        address riskAssetAddress,
        uint rebTargetPerc,
        uint rebThreshold
    ) {
        pool = IPoolV4(poolAddress);
        // feed = AggregatorV3Interface(_pricefeedAddress);

        riskAssetFeed = AggregatorV3Interface(riskAssetFeedAddress);
        stableAssetFeed = AggregatorV3Interface(stableAssetFeedAddress);

        depositToken = IERC20Metadata(stableAssetAddress);
        investToken = IERC20Metadata(riskAssetAddress);
        targetInvestPerc = rebTargetPerc;
        rebalancingThreshold = rebThreshold;
    }

    //// IStrategy Interface //// 

    function name() public override pure returns(string memory) {
        return "RebalancingStrategyV1";
    }

    function description() public override pure returns(string memory) {
        return "A rebalancing strategy for a 2 asset portfolio";
    }


    /**
     * Run strategy when the pool requires to be rebalanced AND upkeepInterval time has elapsed.
     */
    function shouldPerformUpkeep() external view returns (bool) {
        (StrategyAction action, uint amountIn) = eval();
        bool minTimeElapsed = (block.timestamp - lastEvalTimestamp) > upkeepInterval;

        return minTimeElapsed && action != StrategyAction.NONE && amountIn > 0;
    }


    // Evaluate stategy should be called only by its Pool
    function exec() public override onlyOwner returns (StrategyAction, uint) {
        
        // remoember when the strategy was last executed to avoid rebalancing too often.
        lastEvalTimestamp = block.timestamp;
        
        (StrategyAction action, uint amountIn) = eval();
        
        emit StrategyEval(action, amountIn);

        return (action, amountIn);
    }


    function eval() public view returns(StrategyAction, uint) {

        // If the pool is empty than do nothing
        uint poolValue = pool.totalValue();
        if (poolValue == 0) {
            return (StrategyAction.NONE, 0);
        }

        
        ( /*uint80 roundID**/, int price0, /*uint startedAt*/, uint priceTimestamp0, /*uint80 answeredInRound*/ ) = stableAssetFeed.latestRoundData();
        ( /*uint80 roundID**/, int price1, /*uint startedAt*/, uint priceTimestamp1, /*uint80 answeredInRound*/ ) = riskAssetFeed.latestRoundData();
      
        // disregard negarive prices
        if (price0 <= 0 || price1 <= 0) {
            return (StrategyAction.NONE, 0);
        }

        // disregard old prices
        if ((priceTimestamp0 < block.timestamp && (block.timestamp - priceTimestamp0 > upkeepInterval) ) ||
              (priceTimestamp1 < block.timestamp && (block.timestamp - priceTimestamp1 > upkeepInterval) ))  {
            return (StrategyAction.NONE, 0);
        }

        StrategyAction action = StrategyAction.NONE;
        uint amountIn;
        
        uint investTokenValue = pool.riskAssetValue();
        uint percPrecision = 1000;

        uint investPerc = percPrecision * 100 * investTokenValue / poolValue; // the % of invest tokens in the pool

        if (investPerc >= percPrecision * (targetInvestPerc + rebalancingThreshold)) {
            // Rebalance requires to SELL some investment tokens => amountIn as the amount of investment to spend
            action = StrategyAction.SELL;
            uint targetInvestTokenValue = poolValue * targetInvestPerc / 100;
    
            amountIn = (investTokenValue - targetInvestTokenValue).div(uint(price1),
                depositToken.decimals(), riskAssetFeed.decimals(), investToken.decimals()
            );
        }

        if (investPerc <= percPrecision * (targetInvestPerc - rebalancingThreshold)) {
            // Rebalance requires to BUY some investment tokens => amountIn is the amount of depositToken to spend
            action = StrategyAction.BUY;
          
            uint targetDepositPerc = 100 - targetInvestPerc;
            uint targetDepositValue = poolValue * targetDepositPerc / 100;
            uint depositTokenValue = pool.stableAssetValue();

            amountIn = (depositTokenValue - targetDepositValue).div(uint(price0),
                depositToken.decimals(), stableAssetFeed.decimals(), depositToken.decimals()
            );
        }

        return (action, amountIn);
    }


    //// ONLY OWNER ////

    function setPool(address _poolAddress) public onlyOwner {
        pool = IPoolV4(_poolAddress);
    }

    function setUpkeepInterval(uint interval) public onlyOwner {
        upkeepInterval = interval;
    }
}