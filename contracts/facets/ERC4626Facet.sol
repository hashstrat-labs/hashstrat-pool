// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { IERC4626 } from "../interfaces/IERC4626.sol";

import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";
import { LibPool } from "../libraries/LibPool.sol";
import { LibERC20 } from  "../libraries/LibERC20.sol";
import { TokenMaths } from "../libraries/TokenMaths.sol";

// import "hardhat/console.sol";

/**
 * @notice Facet that provides an ERC4626 interface (Tokenized Vault Standard) to a Pool.
 * @author Carlo Pascoli
 */
contract ERC4626Facet is IERC4626 {

    using TokenMaths for uint256;
    

    function init() external {
        LibDiamond.enforceIsContractOwner();
    }


    /// @notice The address of the underlying token used for the Vault for accounting, depositing, and withdrawing.
    function asseet() external view returns (address assetTokenAddress) {
        return LibPool.stableAsset(); // the quote asset
    }


    /// @notice Total amount of the underlying asset that is “managed” by Vault.
    function totalAssets() public view returns(uint256) {
        
        // price of 1 USDC in USD
        AggregatorV3Interface stableAssetFeed = AggregatorV3Interface(LibPool.stableAssetFeed());
        ( , int256 price, , , ) = stableAssetFeed.latestRoundData();
        assert(price > 0);

       
        IERC20Metadata stableAsset = IERC20Metadata(LibPool.stableAsset());
        uint8 stableTokenDecimals = stableAsset.decimals();

        // get the value of the risk assets in terms of stable assets (USDC)
        uint riskAssetsUSDValue = LibPool.riskAssetsValue();
        uint riskAssetsValueInDepositTokenAmount = riskAssetsUSDValue.div(uint256(price),
            stableTokenDecimals,
            stableAssetFeed.decimals(),
            stableTokenDecimals // return amount with number of decimals of the stable asset
        );

        return stableAsset.balanceOf(address(this)) + riskAssetsValueInDepositTokenAmount;
    }


    /// @notice The amount of shares that the Vault would exchange for the amount of assets provided, in an ideal scenario where all the conditions are met.
    function convertToShares(uint256 assets) external view returns(uint256 shares) {
        shares = LibERC20.erc20totalSupply() * assets / totalAssets();
    }


    /// @notice The amount of assets that the Vault would exchange for the amount of shares provided, in an ideal scenario where all the conditions are met.
    function convertToAssets(uint256 shares) external view returns(uint256 assets) {
        uint supply = LibERC20.erc20totalSupply();
        assets = supply > 0 ? totalAssets() * shares / supply : 0;
    }


    /// @notice Maximum amount of the underlying asset that can be deposited into the Vault for the receiver, through a deposit call.
    function maxDeposit(address receiver) external view returns(uint256 maxAssets) {
        maxAssets = type(uint256).max; // ~uint(0);
    }




    /// @notice Mints shares Vault shares to receiver by depositing exactly assets of underlying tokens.
    /// @dev stateMutability: nonpayable
    function deposit(uint256 assets, address receiver) external returns(uint256 shares) {
        return LibPool.deposit(assets, receiver);
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, given current on-chain conditions.
    function previewDeposit(uint256 assets) external view returns(uint256 shares) {
       shares = LibPool.sharesForDeposit(assets);
    }


    /// @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver.
    function redeem(uint256 shares, address receiver, address owner) external returns(uint256 assets) {
        assets = LibPool.redeem(shares, receiver, owner);
    }

    //////////  TODO  ////////// 

  

    /// @notice Maximum amount of shares that can be minted from the Vault for the receiver, through a mint call.
    function maxMint(address receiver) external view returns(uint256 maxShares) {
        return 0;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, given current on-chain conditions.
    function previewMint(address shares) external view returns(uint256 assets) {
        return 0;
    }

    /// @notice Mints exactly shares Vault shares to receiver by depositing assets of underlying tokens.
    function mint(uint256 shares, address receiver) external returns(uint256 assets) {
        return 0;
    }

    /// @notice Maximum amount of the underlying asset that can be withdrawn from the owner balance in the Vault, through a withdraw call.
    function maxWithdraw(address owner) external view returns(uint256 maxAssets) {
        return 0;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block, given current on-chain conditions.
    /// @return shares as close to and no fewer than the exact amount of Vault shares that would be burned in a withdraw call in the same transaction.
    ///         I.e. withdraw should return the same or fewer shares as previewWithdraw if called in the same transaction.
    function previewWithdraw(uint256 assets) external view returns(uint256 shares) {
        return 0;
    }

    /// @notice Burns shares from owner and sends exactly assets of underlying tokens to receiver.
    function withdraw(uint256 assets, address receiver, address owner) external returns(uint256 shares) {
        return 0;
    }
 
    /// @notice Maximum amount of Vault shares that can be redeemed from the owner balance in the Vault, through a redeem call.
    /// @return maxShares the maximum amount of shares that could be transferred from owner through redeem and not cause a revert,
    ///      which MUST NOT be higher than the actual maximum that would be accepted (it should underestimate if necessary).
    function maxRedeem(address receiver) external view returns(uint256 maxShares) {
         return 0;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their redeemption at the current block, given current on-chain conditions.
    /// @return assets as close to and no more than the exact amount of assets that would be withdrawn in a redeem call in the same transaction.
    ///         I.e. redeem should return the same or more assets as previewRedeem if called in the same transaction.
    function previewRedeem(uint256 shares) external view returns(uint256 assets) {
         return 0;
    }

 



}