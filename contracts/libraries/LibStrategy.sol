/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { IStrategy, StrategyAction } from "../strategies/IStrategy.sol";
import { LibSwaps } from "./LibSwaps.sol";
import { LibPool } from "./LibPool.sol";

// import "hardhat/console.sol";


/**
 * @notice The library supporting the Automation functionality of the Diamond.
 */
library LibStrategy {
    
    bytes32 constant STRATEGY_STORAGE_POSITION = keccak256("facet.strategy.diamond.storage");

    /**
     * @notice ERC20 storage for the ERC20 facet
     */
    struct Storage {
        address _strategy;
        uint256 _upkeepInterval;
    }
    
    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = STRATEGY_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }


    //// View functions //// 
    function strategy() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._strategy;
    }

    function upkeepInterval() internal view returns(uint256) {
        Storage storage ds = getStorage();
        return ds._upkeepInterval;
    }


    //// Setter functions //// 

    function setUpkeepInterval(uint256 innterval) internal {
        Storage storage ds = getStorage();
        ds._upkeepInterval = innterval;
    }

    function setStrategy(address strategyAddress) internal {
        Storage storage ds = getStorage();
        ds._strategy = strategyAddress;
    }

    function shouldPerformUpkeep() internal view returns(bool) {
        return IStrategy(strategy()).shouldPerformUpkeep();
    }



     function strategyExec() internal {

        (StrategyAction action, uint256 amountIn) = IStrategy(strategy()).exec();

        // console.log(">>> strategyExec - action:", 
        //     action == StrategyAction.NONE ? "NONE" : 
        //     action == StrategyAction.BUY ? "BUY" : 
        //      action == StrategyAction.SELL ? "SELL" :  "n/a"
        // );
        // console.log(">>> strategyExec: amountIn:", amountIn);

        if (action != StrategyAction.NONE && amountIn > 0) {
            address tokenIn;
            address tokenOut;
            address priceFeed;

            if (action == StrategyAction.BUY) {
                tokenIn = LibPool.stableAsset(); // address(depositToken);
                tokenOut = LibPool.riskAsset(); // address(investToken);
                priceFeed =  LibPool.stableAssetFeed(); // stableAssetFeed;
            } else if (action == StrategyAction.SELL) {
                tokenIn = LibPool.riskAsset();
                tokenOut = LibPool.stableAsset();
                priceFeed = LibPool.riskAssetFeed(); // riskAssetFeed;
            }

            // set and process the new TWAP swap 
            LibSwaps.setTwapSwap(
                action,
                tokenIn,
                tokenOut,
                amountIn,
                priceFeed
            );
            LibSwaps.handleTwapSwap();
        }
    }


}

