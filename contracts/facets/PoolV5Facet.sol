// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { IPoolV5Facet } from "../interfaces/IPoolV5Facet.sol";
import { IPoolV5 } from "../interfaces/IPoolV5.sol";
import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";
import { LibPool } from "../libraries/LibPool.sol";
import { LibFees } from "../libraries/LibFees.sol";
import { LibERC20 } from "../libraries/LibERC20.sol";
import { LibSwaps } from "../libraries/LibSwaps.sol";
import { LibStrategy } from "../libraries/LibStrategy.sol";


/**
 * @notice The facet providing PoolV5 functions and legacy funcitons to interact with the Pool.
 * @dev It is initialized with the Pool stable and risk tokens' addresses and data feeds.
 * @author Carlo Pascoli
 */
contract PoolV5Facet is IPoolV5Facet {

    function init(IPoolV5Facet.PoolArgs memory args) public {
        LibDiamond.enforceIsContractOwner();

        LibPool.setStableAsset(args.stableAssetAddress);
        LibPool.setRiskAsset(args.riskAssetAddress);
        LibPool.setStableAssetFeed(args.stableAssetFeedAddress);
        LibPool.setRiskAssetFeed(args.riskAssetFeedAddress);
        LibPool.setDaoTokenFarm(args.daoTokenFarmAddress);
    }


    // View functions

    function lpToken() external view returns (address) {
        return address(this);
    }

    function totalValue() external view returns(uint) {
        return LibPool.riskAssetsValue() + LibPool.stableAssetsValue();
    }

    function riskAssetValue() external view returns(uint) {
        return LibPool.riskAssetsValue();
    }

    function stableAssetValue() external view returns(uint) {
        return LibPool.stableAssetsValue();
    }

    function lpTokensValue (uint shares) public view returns (uint value) {
        value = LibPool.lpTokensValue(shares);
    }

    function portfolioValue(address addr) external view returns (uint) {

        return lpTokensValue(LibERC20.erc20balanceOf(addr));
    }


    function riskAssetFeed() external view returns (address) {
        return LibPool.riskAssetFeed();
    }

    function stableAssetFeed() external view returns (address) {
        return LibPool.stableAssetFeed();
    }

    function daoTokenFarm() external view returns (address) {
        return LibPool.daoTokenFarm();
    }



    //// Transactional functions ////

    function deposit(uint assets) external {
        LibPool.deposit(assets, msg.sender);
    }

    function withdrawLP(uint shares) external {
        LibPool.redeem(shares, msg.sender, msg.sender);
    }

    function withdrawAll() external {
        LibPool.redeem(LibERC20.erc20balanceOf(msg.sender), msg.sender, msg.sender);
    }
    


    //// OnlyOwner functions ////

    function setFarmAddress(address farmAddress) external {
        LibDiamond.enforceIsContractOwner();
        LibPool.setDaoTokenFarm(farmAddress);
    }


}

