/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { TokenMaths } from "./TokenMaths.sol";
import { LibERC20 } from "./LibERC20.sol";
import { LibStrategy } from "./LibStrategy.sol";
import { LibUserInfo } from "./LibUserInfo.sol";
import { LibSwaps } from "./LibSwaps.sol";
import { LibFees } from "./LibFees.sol";

import { StrategyAction } from "../strategies/IStrategy.sol";
import { IDAOTokenFarm } from "../interfaces/IDAOTokenFarm.sol";


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
     * @notice storage for the PoolV5 facet
     */
    struct Storage {
        address _riskAsset;
        address _stableAsset;
        address _riskAssetFeed;
        address _stableAssetFeed;
        address _daoTokenFarm;
    }
    
    // access pool storage via:
    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = POOL_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }


    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function setRiskAsset(address asset) internal {
        require(asset != address(0), "LibPool: invalid address");

        Storage storage ds = getStorage();
        ds._riskAsset = asset;
    }

    function setStableAsset(address asset) internal {
        require(asset != address(0), "LibPool: invalid address");

        Storage storage ds = getStorage();
        ds._stableAsset = asset;
    }

    function setRiskAssetFeed(address feed) internal {
        require(feed != address(0), "LibPool: invalid address");

        Storage storage ds = getStorage();
        ds._riskAssetFeed = feed;
    }

    function setStableAssetFeed(address feed) internal {
        require(feed != address(0), "LibPool: invalid address");

        Storage storage ds = getStorage();
        ds._stableAssetFeed = feed;
    }

    function setDaoTokenFarm(address farm) internal {
        Storage storage ds = getStorage();
        ds._daoTokenFarm = farm;
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

    function daoTokenFarm() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._daoTokenFarm;
    }



    /// @notice Total amount of the underlying asset that is “managed” by Vault.
    function totalAssets() public view returns(uint256) {
        
        // price of 1 USDC in USD
        AggregatorV3Interface stableAssetPriceFeed = AggregatorV3Interface(stableAssetFeed());
        ( , int256 price, , , ) = stableAssetPriceFeed.latestRoundData();
        assert(price > 0);

       
        IERC20Metadata stableAssetToken = IERC20Metadata(stableAsset());
        uint8 stableTokenDecimals = stableAssetToken.decimals();

        // get the value of the risk assets in terms of stable assets (USDC)
        uint riskAssetsUSDValue = riskAssetsValue();
        uint riskAssetsValueInDepositTokenAmount = riskAssetsUSDValue.div(uint256(price),
            stableTokenDecimals,
            stableAssetPriceFeed.decimals(),
            stableTokenDecimals // return amount with number of decimals of the stable asset
        );

        return stableAssetToken.balanceOf(address(this)) + riskAssetsValueInDepositTokenAmount;
    }


    /// @return the value of the risk assets in the pool in USD.
    /// @dev the value returned has the number of decimals of the stable asset token.
    function riskAssetsValue() internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(riskAssetFeed());
        ( , int256 price, , , ) = priceFeed.latestRoundData();
        assert(price > 0);

        IERC20Metadata riskAssetToken = IERC20Metadata(riskAsset());
        IERC20Metadata stableAssetToken = IERC20Metadata(stableAsset());

        return riskAssetToken.balanceOf(address(this)).mul(uint256(price), 
            riskAssetToken.decimals(),
            priceFeed.decimals(), 
            stableAssetToken.decimals()
        );
    }


    /// @return the value of the stable assets in the pool in USD.
    /// @dev the value returned has the number of decimals of the stable asset token.
    function stableAssetsValue() internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(stableAssetFeed());
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


    function lpTokensValue (uint shares) internal view returns (uint) {

        uint supply = LibERC20.erc20totalSupply();
        uint total = riskAssetsValue() + stableAssetsValue();

        return supply > 0 ? shares * total / supply : 0;
    }


    function sharesForAccount (address account, bool includesStaked) internal view returns (uint256 shares) {
        uint balance = LibERC20.erc20balanceOf(account);
        address farm = daoTokenFarm();

        uint256 stakedLP = farm != address(0)
            ? IDAOTokenFarm(farm).getStakedBalance(account, address(this))
            : 0;

        shares = includesStaked ? balance + stakedLP : balance;
    }




    /// @notice deposit an exact amount of stable assets and reveive shares in the pool
    /// @param assets the amount of the stable asset tokens deposited
    /// @param receiver the account of receiving the shares minted for this deposit
    /// @return shares the number of shares received for the deposit
    function deposit(uint256 assets, address receiver) internal returns(uint256 shares) {
    
        if (assets == 0) return 0;

        IERC20 depositToken = IERC20(stableAsset());
        require(depositToken.allowance(msg.sender, address(this)) >= assets, "PoolV5: Insufficient allowance");

        // 0. Get the total assets before receiving the deposit
        uint assetsBefore = totalAssets();
        uint256 investTokenPerc = investTokenPercentage();

        // 1. Transfer deposit amount to the pool
        depositToken.transferFrom(msg.sender, address(this), assets);

        // Log depoist into
        LibUserInfo.newDepositInfo(assets, msg.sender);

        // 2. Rebalance the pool to ensure the deposit does not alter the pool allocation
        if (LibERC20.erc20totalSupply() == 0) {
            // if the pool was empty before this deposit then exec the strategy once to establish the initial asset allocation
            // strategyExec();
            LibStrategy.strategyExec();
        } else {
            // if the pool was not empty before this deposit then ensure the pool remains balanced
            uint256 rebalanceAmountIn = (investTokenPerc * assets) / (10**uint256(portfolioPercentageDecimals()));
   
            if (rebalanceAmountIn > 0) {
                // performa a rebalance operation
                (bool success, , , ) = LibSwaps.swapAndCheckSlippage(
                    stableAsset(),
                    riskAsset(),
                    StrategyAction.BUY,
                    rebalanceAmountIn
                );

                require(success, "PoolV5: swap error");
            }
        }

        // 3. Calculate again the assets in the pool AFTER the swaps
        uint assetsAfter = totalAssets();

        shares = sharesForDeposit(assetsAfter - assetsBefore);

        // 4. Mint LP tokens to the user
        LibERC20.erc20mint(receiver, shares);

        // console.log(">>> deposit - lpToMint: ", shares);
        emit Deposited(msg.sender, assets);
    }


    /// @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver.
    function redeem(uint256 shares, address receiver, address owner) internal returns(uint256 assets) {

        // stableAsset
        if (shares == 0) return 0;
        require(shares <= LibERC20.erc20balanceOf(owner), "LibPool: LP balance exceeded");

        uint256 precision = 10**uint256(portfolioPercentageDecimals());
        uint256 sharesTotalSupply = LibERC20.erc20totalSupply();
        uint256 withdrawPerc = precision * shares / sharesTotalSupply;

        // 1. Calculate amount of depositTokens & investTokens to withdraw
        uint256 depositTokensBeforeSwap = IERC20(stableAsset()).balanceOf(address(this));
        uint256 investTokensBeforeSwap = IERC20(riskAsset()).balanceOf(address(this));
        
        // if these are the last LP being withdrawn ensure no dust tokens are left in the pool
        bool isWithdrawAll = (shares == sharesTotalSupply);
        uint256 withdrawDepositTokensAmount = isWithdrawAll ? depositTokensBeforeSwap : (depositTokensBeforeSwap * withdrawPerc) / precision;
        uint256 withdrawInvestTokensTokensAmount = isWithdrawAll ? investTokensBeforeSwap : (investTokensBeforeSwap * withdrawPerc) / precision;

        // 2. burn the owner's LP tokens
        LibERC20.erc20burn(owner, shares);

        // 3. swap some invest tokens back into deposit tokens
        uint256 depositTokensReceived = 0;

        //TODO avoid swapping very small amount of the risk asset (e.g. < $1 of value)
        // swapValue < 10 ** IERC20(stableAsset()).decimals()

        AggregatorV3Interface priceFeed = AggregatorV3Interface(riskAssetFeed());
        if (withdrawInvestTokensTokensAmount > 0) {
            (bool success, , uint bought, ) = LibSwaps.swapAndCheckSlippage(
                riskAsset(),
                stableAsset(),
                StrategyAction.SELL,
                withdrawInvestTokensTokensAmount
            );
            
            ( , int256 price, , , ) = priceFeed.latestRoundData();
            assert(price > 0);

            uint256 swapValue = withdrawInvestTokensTokensAmount.mul(uint256(price), 
                IERC20Metadata(riskAsset()).decimals(), 
                priceFeed.decimals(), 
                IERC20Metadata(stableAsset()).decimals()
            );

            // revert if swap failed or swap was above min value of $1
            // allow very small swaps that would otherwise fail due to slipppage
            require(success || swapValue < 10 ** IERC20Metadata(stableAsset()).decimals(), "PoolV4: swap error");

            depositTokensReceived = bought;
        }

        // 4. Log withdraw info
        assets = withdrawDepositTokensAmount + depositTokensReceived;
        LibUserInfo.newWithdrawal(assets, owner);

        // 5. transfer depositTokens to the user
        IERC20(stableAsset()).transfer(receiver, assets);

        emit Withdrawn(owner, assets);
    }



    function collectFeeAndWithdraw( uint256 amount, address receiver, address owner) internal {

        uint256 fees = LibFees.feesForWithdraw(amount, owner);
        uint256 netAmount = amount - fees;

        // transfer fees to Pool by burning the and minting lptokens to the pool
        if (fees > 0) {
            LibERC20.erc20burn(owner, fees);
            LibERC20.erc20mint(address(this), fees);
        }

        redeem(netAmount, receiver, owner);
    }
    
 

    function portfolioPercentageDecimals() internal view returns (uint8) {
        return  AggregatorV3Interface(riskAssetFeed()).decimals();
    }


    /// @notice calculate the shares for a the value of the deposit 'valueDeposited' tokens after the deposit tokens have been transferred into the pool
    /// @param assets the amount od stable assets to deposit.
    /// @return shares the amount of new LP tokens to mint for this deposit.
    function sharesForDeposit(uint256 assets) internal view returns (uint256 shares) {

        uint supply = LibERC20.erc20totalSupply();
        uint256 lpPrecision = 10**uint256(LibERC20.erc20decimals());

        IERC20Metadata stableAssetToken = IERC20Metadata(stableAsset());

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


    /// @return percentValue the % of risk assets in the pool in terms of the stable asset.
    /// @dev the percentage value returned has precision of 'portfolioPercentageDecimals' decimals.
    function investTokenPercentage() internal view returns (uint256 percentValue) {

        // price of 1 USDC in USD
        AggregatorV3Interface stableAssetTokenFeed = AggregatorV3Interface(stableAssetFeed());
        ( , int256 price, , , ) = stableAssetTokenFeed.latestRoundData();
        assert(price > 0);
       
        IERC20Metadata stableAssetToken = IERC20Metadata(stableAsset());
        uint8 stableTokenDecimals = stableAssetToken.decimals();

        // get the value of the risk assets in terms of stable assets (USDC)
        uint riskAssetsUSDValue = riskAssetsValue();
        uint riskAssetsValueInDepositTokenAmount = riskAssetsUSDValue.div(uint256(price),
            stableTokenDecimals,
            stableAssetTokenFeed.decimals(),
            stableTokenDecimals // return amount with number of decimals of the stable asset
        );

        uint total = stableAssetToken.balanceOf(address(this)) + riskAssetsValueInDepositTokenAmount;

        percentValue = (LibERC20.erc20totalSupply() == 0) ? 0 :
                10**uint256(portfolioPercentageDecimals()) * riskAssetsValueInDepositTokenAmount / total;
    }


}