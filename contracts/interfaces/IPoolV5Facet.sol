// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;



/**
 *  @title Pool's functionality required by DAOOperations and DAOFarm
 */

interface IPoolV5Facet {

    function initialize(
        address riskAsset
    ) external;


  
}