// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import { IPoolV5Facet } from "../interfaces/IPoolV5Facet.sol";
import { IPoolV5 } from "../interfaces/IPoolV5.sol";
import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";
import { LibPool } from "../libraries/LibPool.sol";
import { LibERC4626 } from "../libraries/LibERC4626.sol";


// Remember to add the loupe functions from DiamondLoupeFacet to the diamond.
// The loupe functions are required by the EIP2535 Diamonds standard
//TODO implement IPoolV5
contract PoolV5Facet is IPoolV5Facet /*, IPoolV5 */ {

    function init(IPoolV5Facet.PoolArgs memory args) public {
        LibDiamond.enforceIsContractOwner();

        LibPool.setStableAsset(args.stableAssetAddress);
        LibPool.setRiskAsset(args.riskAssetAddress);
        LibPool.setStableAssetFeed(args.stableAssetFeedAddress);
        LibPool.setRiskAssetFeed(args.riskAssetFeedAddress);
    }



    // View functions
    function totalValue() external view returns(uint) {

    }

    function riskAssetValue() external view returns(uint) {
        return LibPool.riskAssetsValue();
    }

    function stableAssetValue() external view returns(uint) {
        return LibPool.stableAssetsValue();
    }


    function lpTokensValue (uint lpTokens) external view returns (uint) {

        return LibPool.stableAssetsValue();

    }

    function portfolioValue(address addr) external view returns (uint) {

    }

}