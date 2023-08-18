/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { TokenMaths } from "./TokenMaths.sol";


/**
 * @notice The library files supporting the Pool Facet of the Diamond.
 * @author Carlo Pascoli
 */
library LibPool {

    using TokenMaths for uint256;

    /** ==================================================================
                            Pool Storage Space
    =====================================================================*/
    // each facet gets their own struct to store state into
    bytes32 constant POOL_STORAGE_POSITION = keccak256("facet.pool.diamond.storage");

    /**
     * @notice ERC20 storage for the ERC20 facet
     */
    struct Storage {
        address _riskAsset;
        address _stableAsset;
        address _riskAssetFeed;
        address _stableAssetFeed;
        mapping(address => uint256) _balances;
    }
    
    // access erc20 storage via:
    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = POOL_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }


    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function setRiskAsset(address asset) internal {
        require(asset != address(0), "POOL: invalid address");

        Storage storage ds = getStorage();
        ds._riskAsset = asset;
    }

    function seStableAsset(address asset) internal {
        require(asset != address(0), "POOL: invalid address");

        Storage storage ds = getStorage();
        ds._stableAsset = asset;
    }

    function setRiskAssetFeed(address feed) internal {
        require(feed != address(0), "POOL: invalid address");

        Storage storage ds = getStorage();
        ds._riskAssetFeed = feed;
    }

    function setStableAssetFeed(address feed) internal {
        require(feed != address(0), "POOL: invalid address");

        Storage storage ds = getStorage();
        ds._stableAssetFeed = feed;
    }



    function riskAsset() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._riskAsset;
    }

    function stableAsset() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._stableAsset;
    }

    function riskAssetFeed() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._riskAssetFeed;
    }

    function stableAssetFeed() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._stableAssetFeed;
    }


    /// @return the value of the risk assets in the pool in USD.
    /// @dev the value returned has the number of decimals of the stable asset token.
    function riskAssetsValue() internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(LibPool.riskAssetFeed());
        ( , int256 price, , , ) = priceFeed.latestRoundData();
        assert(price > 0);

        IERC20Metadata riskAssetMeta = IERC20Metadata(riskAsset());

        return riskAssetMeta.balanceOf(address(this)).mul(uint256(price), 
            riskAssetMeta.decimals(),
            priceFeed.decimals(), 
            IERC20Metadata(stableAsset()).decimals()
        );
    }


    /// @return the value of the stable assets in the pool in USD.
    /// @dev the value returned has the number of decimals of the stable asset token.
    function stableAssetsValue() internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(LibPool.stableAssetFeed());
        ( , int256 price, , , ) = priceFeed.latestRoundData();
        assert(price > 0);

        IERC20Metadata stableAssetMeta = IERC20Metadata(stableAsset());
        uint8 stableAssetDecs = stableAssetMeta.decimals();

        return stableAssetMeta.balanceOf(address(this)).mul(uint256(price), 
            stableAssetDecs,
            priceFeed.decimals(), 
            stableAssetDecs
        );
    }

    
    

}