// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { IPoolV5Facet } from "../interfaces/IPoolV5Facet.sol";
import { IPoolV5 } from "../interfaces/IPoolV5.sol";
import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";
import { LibPool } from "../libraries/LibPool.sol";
import { LibERC20 } from "../libraries/LibERC20.sol";
import { LibSwaps } from "../libraries/LibSwaps.sol";
import { LibStrategy } from "../libraries/LibStrategy.sol";


/**
 * @notice The facet providing PoolV5 functions and legacy funcitons to interact with the Pool.
 * @dev It is initialized with the Pool stable and risk tokens' addresses and data feeds.
 * @author Carlo Pascoli
 */
contract StrategyFacet {

   struct StrategyArgs {
        address strategyAddress;
        uint256 upkeepInterval;
    }

    function init(StrategyArgs memory args) public {
        LibDiamond.enforceIsContractOwner();

        LibStrategy.setStrategy(args.strategyAddress);
        LibStrategy.setUpkeepInterval(args.upkeepInterval);
    }


    function strategy() external view returns(address) {
        return LibStrategy.strategy();
    }

    function upkeepInterval() external view returns(uint256) {
        return LibStrategy.upkeepInterval();
    }
   

    //// Only Owner Functions ////

    function setStrategy(address strategyAddress) external {
        LibDiamond.enforceIsContractOwner();
        LibStrategy.setStrategy(strategyAddress);
    }

    function setUpkeepInterval(uint256 interval) external {
        LibDiamond.enforceIsContractOwner();
        LibStrategy.setUpkeepInterval(interval);
    }

}

