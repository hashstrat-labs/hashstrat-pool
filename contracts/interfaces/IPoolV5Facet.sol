// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;



/**
 *  @title Pool's functionality required by DAOOperations and DAOFarm
 */

interface IPoolV5Facet {

   struct PoolArgs {
        address stableAssetAddress;
        address riskAssetAddress;
        address stableAssetFeedAddress;
        address riskAssetFeedAddress;
        uint256 poolFees;
        uint24 uniswapV3Fee;
    }

    function init(PoolArgs memory args) external;

}