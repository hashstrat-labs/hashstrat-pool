// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { IERC4626 } from "../interfaces/IERC4626.sol";
import { LibERC4626 } from  "../libraries/LibERC4626.sol";
import { LibPool } from "../libraries/LibPool.sol";
import { LibERC20 } from  "../libraries/LibERC20.sol";
import { TokenMaths } from "../libraries/TokenMaths.sol";

import "hardhat/console.sol";

/**
 * @notice the ERC20 Token Facet contract which will be registered with the Diamond contract as its facet.
 * @author Jesper Kristensen
 */
contract ERC4626Facet is IERC4626 {

    using TokenMaths for uint256;
    

    function init() public {
        console.log(">>> ERC4626Facet.init");
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
        console.log(">>> deposit - assets:", assets, "receiver: ", receiver);
        return _deposit(assets, receiver);
    }


    /// @notice Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, given current on-chain conditions.
    function previewDeposit(uint256 assets) external view returns(uint256 shares) {
       shares = sharesForDeposit(assets);
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

    /// @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver.
    function redeem(uint256 shares, address receiver, address owner) external returns(uint256 assets) {
         return 0;
    }


    //////// INTERNAL



    function _deposit(uint256 assets, address receiver) internal returns(uint256 shares) {
    
        if (assets == 0) return 0;

        IERC20 depositToken = IERC20(LibPool.stableAsset());
        require(depositToken.allowance(msg.sender, address(this)) >= assets, "PoolV5: Insufficient allowance");


        // 0. Get the total assets before receiving the deposit
        uint assetsBefore = totalAssets();
        // uint256 investTokenPerc = investTokenPercentage();

        // 1. Transfer deposit amount to the pool
        depositToken.transferFrom(msg.sender, address(this), assets);

        // deposits[msg.sender] += assets;
        // totalDeposited += assets;

        // // and record user address (if new user) and deposit infos
        // if (!usersMap[msg.sender]) {
        //     usersMap[msg.sender] = true;
        //     users.push(msg.sender);
        // }

        // userInfos[msg.sender].push(
        //     UserInfo({
        //         timestamp: block.timestamp,
        //         operation: UserOperation.DEPOSIT,
        //         amount: assets
        //     })
        // );

        // 2. Rebalance the pool to ensure the deposit does not alter the pool allocation
        if (LibERC20.erc20totalSupply() == 0) {
            // if the pool was empty before this deposit => exec the strategy once to establish the initial asset allocation
            // strategyExec();
        } else {
            // if the pool was not empty before this deposit => ensure the pool remains balanced after this deposit.
            // uint256 rebalanceAmountIn = (investTokenPerc * assets) / (10**uint256(portfolioPercentageDecimals()));
   
            // if (rebalanceAmountIn > 0) {
            //     // performa a rebalance operation
            //     (bool success, , , ) = swapAndCheckSlippage(
            //         address(depositToken),
            //         address(investToken),
            //         StrategyAction.BUY,
            //         rebalanceAmountIn
            //     );

            //     require(success, "PoolV5: swap error");
            // }
        }

        // 3. Calculate again the assets in the pool AFTER the swaps
        uint assetsAfter = totalAssets();

        shares = sharesForDeposit(assetsAfter - assetsBefore);

        // 4. Mint LP tokens to the user
        LibERC20.erc20mint(receiver, shares);

        // console.log(">>> deposit - lpToMint: ", shares);

        emit LibPool.Deposited(msg.sender, assets);
    }


    /// @return percentValue the % of the value of risk assets in the pool.
    /// @dev the percentage value returned has precision of 'portfolioPercentageDecimals' decimals.
    function investTokenPercentage() internal view returns (uint256 percentValue) {

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

        uint total = stableAsset.balanceOf(address(this)) + riskAssetsValueInDepositTokenAmount;

        percentValue = (LibERC20.erc20totalSupply() == 0) ? 0 :
                10**uint256(portfolioPercentageDecimals()) * riskAssetsValueInDepositTokenAmount / total;
    }


    function portfolioPercentageDecimals() internal view returns (uint8) {
        return  AggregatorV3Interface(LibPool.riskAssetFeed()).decimals();
    }


    /// @notice calculate the shares for a the value of the deposit 'valueDeposited' tokens after the deposit tokens have been transferred into the pool
    /// @param assets the amount od stable assets to deposit.
    /// @return shares the amount of new LP tokens to mint for this deposit.
    function sharesForDeposit(uint256 assets) internal view returns (uint256 shares) {

        uint supply = LibERC20.erc20totalSupply();
        uint256 lpPrecision = 10**uint256(LibERC20.erc20decimals());

        IERC20Metadata stableAssetToken = IERC20Metadata(LibPool.stableAsset());

        if (supply == 0) {
            // If pool is empty => allocate the inital LP tokens amount to the user
            shares = lpPrecision * assets / 10**stableAssetToken.decimals();
        } else {
            // if there are already LP tokens => calculate the additional LP tokens for this deposit
            // calculate portfolio % of the deposit (using lpPrecision digits precision)
            uint256 depositPercentage = lpPrecision * assets / totalAssets();

            // calculate the amount of LP tokens for the deposit so that they represent
            // a % of the existing LP tokens equivalent to the % value of this deposit to the whole portfolio value.
            //
            // X := P * T / (1 - P)
            //      X: additinal LP tokens to allocate for this deposit
            //      P: Percentage of portfolio accounted by this deposit
            //      T: total LP tokens allocated before this deposit

            shares = (depositPercentage * supply) / ((1 * lpPrecision) - depositPercentage);

            // console.log(">>>> lpTokensForDeposit: ", depositLPTokens, depositPercentage);
        }

        return shares;
    }

}