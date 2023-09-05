/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { StrategyAction } from "../strategies/IStrategy.sol";
import { LibPool } from "./LibPool.sol";
import { TokenMaths } from "./TokenMaths.sol";
import { ISwapsRouter } from "../swaps/ISwapsRouter.sol";

import "hardhat/console.sol";


/**
 * @notice The library supporting the Automation functionality of the Diamond.
 */
library LibSwaps {
    
    using TokenMaths for uint256;

    bytes32 constant SWAP_STORAGE_POSITION = keccak256("facet.swaps.diamond.storage");

    event SwapError(string reason);
    event Swapped(string side, uint256 sold, uint256 bought, uint256 slippage);


    /**
     * @notice storage for the Swaps facet
     */
    struct Storage {
        uint24 _feeV3;
        uint256 _swapMaxValue;
        uint256 _maxSlippage; // the max percentage slippage between 0 (0%) and 10000 (100%)
        uint256 _twapSwapInterval; // 5 minutes between swaps

        address _swapRouter;

        TWAPSwap _swap; // the TWAP swap in progress
        SwapInfo[] _swaps; // logs of compteted swaps
    }

    struct SwapInfo {
        uint256 timestamp;
        string side;
        uint256 feedPrice;
        uint256 bought;
        uint256 sold;
        uint256 depositTokenBalance;
        uint256 investTokenBalance;
    }

    struct TWAPSwap {
        StrategyAction side;
        address tokenIn;
        address tokenOut;
        uint256 total; // the total amount of the tokenIn to spend (e.g. the total size of this twap swap)
        uint256 size; // the max size of each indivitual swap
        uint256 sold; // the cumulative amount of the tokenIn tokens spent
        uint256 bought; // the cumulative amount of the tokenOut tokens bought
        uint256 lastSwapTimestamp; // timestamp of the last attempted/executed swap
    }

    
    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = SWAP_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }


    //// View functions ////

    function feeV3() internal view returns(uint24) {
        Storage storage ds = getStorage();
        return ds._feeV3;
    }

    function twapSwapInterval() internal view returns(uint256) {
        Storage storage ds = getStorage();
        return ds._twapSwapInterval;
    }

    function twapSwaps() internal view returns(TWAPSwap memory) {
        Storage storage ds = getStorage();
        return ds._swap;
    }

    function maxSlippage() internal view returns(uint256) {
        Storage storage ds = getStorage();
        return ds._maxSlippage;
    }

    function swapMaxValue() internal view returns(uint256) {
        Storage storage ds = getStorage();
        return ds._swapMaxValue;
    }
    
    function swapRouter() internal view returns(address) {
        Storage storage ds = getStorage();
        return ds._swapRouter;
    }

    function getSwapsInfo() internal view returns (SwapInfo[] memory) {
        Storage storage ds = getStorage();
        return ds._swaps;
    }


    //// Setter functions ////

    function setSwapRouter(address router) internal {
        Storage storage ds = getStorage();
        ds._swapRouter = router;
    }

    function setMaxSlippage(uint256 slippage) internal {
        Storage storage ds = getStorage();
        ds._maxSlippage = slippage;
    }

    function setFeeV3(uint24 fee) internal {
        Storage storage ds = getStorage();
        ds._feeV3 = fee;
    }

    function setSwapMaxValue(uint256 maxValue) internal {
        Storage storage ds = getStorage();
        ds._swapMaxValue = maxValue;
    }

    function setTwapSwapInterval(uint256 interval) internal {
        Storage storage ds = getStorage();
        ds._twapSwapInterval = interval;
    }


    //// TWAP Swap processing ////

    /**
     * @notice Sets a new TWAP swap in storage.
     * @param priceFeed the price feed of the tokenIn. Used to calculate the value of the token being swapped.
     * @dev The TWAP size is determined by dividing the desired swap size (amountIn) by 2 up to 8 times or until TWAP size is below swapMaxValue.
     *      If, for example, swapMaxValue is set to $20k, it would take 256 TWAP swaps to process a $5m swap.
     *      A $1m Swap would be processed in 64 TWAP swaps of $15,625 each.
     */
    function setTwapSwap(
        StrategyAction side, 
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn,
        address priceFeed
    ) internal  {

        Storage storage ds = getStorage();

        address stableAsset = LibPool.stableAsset();
        // address riskAsset = LibPool.riskAsset();

        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);
        ( , int256 price, , , ) = feed.latestRoundData();
        assert(price > 0);

        // IERC20Metadata token = tokenIn == stableAsset ? IERC20Metadata(stableAsset) : IERC20Metadata(riskAsset);

        uint maxValue = swapMaxValue();
        uint256 swapValue = amountIn.mul(uint256(price), 
            IERC20Metadata(tokenIn).decimals(), 
            feed.decimals(), 
            IERC20Metadata(stableAsset).decimals()
        );

        // if the value of the swap is less than swapMaxValue than we can swap in one go.
        // otherwise break the swap into chunks.
        if (swapValue <= maxValue) {
            console.log("LibSwaps.setTwapSwap - wapValue <= maxValue, size: ", amountIn);

            ds._swap =
                TWAPSwap({
                    side: side,
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    total: amountIn,
                    size: amountIn,
                    sold: 0,
                    bought: 0,
                    lastSwapTimestamp: 0
                });
            return;
        }


        // determine the size of each chunk
        uint256 size = amountIn;
        uint8 i = 0;
        do {
            size /= 2;
            swapValue /= 2;
        } while (++i < 8 && swapValue > maxValue);

        console.log("LibSwaps.setTwapSwap >> total/size: ", amountIn, size);


        ds._swap =
            TWAPSwap({
                side: side,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                total: amountIn,
                size: size == 0 ? amountIn : size,
                sold: 0,
                bought: 0,
                lastSwapTimestamp: 0
            });
    }


    function handleTwapSwap() internal {

        console.log("LibSwaps.handleTwapSwap");

        Storage storage ds = getStorage();
        
        // update twap swap processing timestamp
        ds._swap.lastSwapTimestamp = block.timestamp;

        // determine swap size avoiding very small amounts that would not be possible to swap
        // end ensuring the whole total amount gets swapped
        uint256 size = (ds._swap.total > ds._swap.sold + (2 * ds._swap.size)) ? ds._swap.size :
                       (ds._swap.total > ds._swap.sold) ? ds._swap.total - ds._swap.sold : 0;
            
        bool canSwap = size > 0 && IERC20(ds._swap.tokenIn).balanceOf(address(this)) >= size;
        
        console.log("LibSwaps.handleTwapSwap - swap/size/total: ", ds._swap.size, size, ds._swap.total);

        if (canSwap) {
            // continue processing the TWAP swap
            (bool success, uint sold, uint bought, ) = swapAndCheckSlippage(
                ds._swap.tokenIn, 
                ds._swap.tokenOut, 
                ds._swap.side,
                size
            );
     
            if (success) {
                ds._swap.sold += sold;
                ds._swap.bought += bought;
            }

        } else {
            // end the TWAP swap if the pool does not have enough tokenIn tokens to continue (e.g. due to withdrawals)
            ds._swap.total = ds._swap.sold;
        }

        // store swap info when the swap is fully filled
        if (ds._swap.sold == ds._swap.total) {
            // log that the twap swap has been fully filled
            string memory swapSide = (ds._swap.side == StrategyAction.BUY) ? "BUY" : 
                        (ds._swap.side == StrategyAction.SELL) ? "SELL" : "NONE";
            SwapInfo memory info = swapInfo(
                swapSide,
                ds._swap.sold,
                ds._swap.bought
            );

            ds._swaps.push(info);
        }
    }



    function swapInfo(string memory side, uint256 amountIn, uint256 amountOut) internal view returns (SwapInfo memory) {

        ( , int256 price, , , ) = AggregatorV3Interface(LibPool.riskAssetFeed()).latestRoundData();
        assert(price > 0);

        // Record swap info
        SwapInfo memory info = SwapInfo({
            timestamp: block.timestamp,
            side: side,
            feedPrice: uint256(price),
            bought: amountOut,
            sold: amountIn,
            depositTokenBalance: IERC20(LibPool.stableAsset()).balanceOf(address(this)),
            investTokenBalance: IERC20(LibPool.riskAsset()).balanceOf(address(this))
        });

        return info;
    }



    /**
     * Perform a swap as part of processing a potentially larger TWAP swap.
     * returns success if the swap happened and the percent slippage of the swap was below the current slippageThereshold
     * If the success flag is returned 'false' the caller has the option to reveert the transaction.
     
     * @param tokenIn the token being sold
     * @param tokenOut the token being bought
     * @param side the side of the swap (e.g Buy or Sell)
     * @param amountIn the amount of tokens to sell. Expected to be > 0
     */
    function swapAndCheckSlippage(
        address tokenIn,
        address tokenOut,
        StrategyAction side,
        uint amountIn
    ) internal returns (
            bool success,
            uint sold,
            uint bought,
            uint slippagePerc
        )
    {
        IERC20 depositToken = IERC20(LibPool.stableAsset());
        IERC20 investToken = IERC20(LibPool.riskAsset());

        // ensure max slippage is not exceeded
        (uint amountOutMin, uint amountOutExpected) = amountOutForSwap(tokenIn, tokenOut, amountIn);

        console.log(">>> swapAndCheckSlippage - amountIn:", amountIn); 
        console.log(">>> swapAndCheckSlippage - amountOutMin:", amountOutMin); 
        console.log(">>> swapAndCheckSlippage - amountOutExpected:", amountOutExpected); 

        // ensure to receive some tokens back
        if (amountOutMin > 0 && amountOutExpected > 0) {

            uint depositTokenBalanceBefore = depositToken.balanceOf(address(this));
            uint investTokenBalanceBefore = investToken.balanceOf(address(this));

            swap(tokenIn, tokenOut, amountIn, amountOutMin, address(this));

            uint depositTokenBalanceAfter = depositToken.balanceOf(address(this));
            uint investTokenBalanceAfter = investToken.balanceOf(address(this));

            if (side == StrategyAction.BUY) {
                sold = depositTokenBalanceBefore - depositTokenBalanceAfter;
                bought = investTokenBalanceAfter - investTokenBalanceBefore;
            } else if (side == StrategyAction.SELL) {
                sold = investTokenBalanceBefore - investTokenBalanceAfter;
                bought = depositTokenBalanceAfter - depositTokenBalanceBefore;
            }

            slippagePerc = bought < amountOutExpected ? 10000 - ((10000 * bought) / amountOutExpected) : 0; // e.g 10000 - 9500 = 500  (5% slippage) - min slipage: 1 = 0.01%
            success = sold > 0 && bought > 0 && slippagePerc <= maxSlippage();

            console.log(">>> swapAndCheckSlippage - sold:", sold); 
            console.log(">>> swapAndCheckSlippage - bought:", bought); 
            console.log(">>> swapAndCheckSlippage - slippagePerc:", slippagePerc); 
            console.log(">>> swapAndCheckSlippage - success:", success); 

            if (success) {
                string memory swapSide = (side == StrategyAction.BUY) ? "BUY" : 
                                        (side == StrategyAction.SELL) ? "SELL" : "NONE";
                emit Swapped(swapSide, sold, bought, slippagePerc);
            }
        }
    }


    /**
     * @return amountOutMin the min amount of tokens to accept based on max slippage and current oracle price.
     *         amountOutExpected the amount of tokens expected to receive based on the current oracle prices.
     */
    function amountOutForSwap(address tokenIn, address tokenOut, uint amountIn) internal view returns (uint amountOutMin, uint amountOutExpected) {
        
        address stableAsset = LibPool.stableAsset();
        address riskAsset = LibPool.riskAsset();

        AggregatorV3Interface riskAssetFeed = AggregatorV3Interface(LibPool.riskAssetFeed());

        IERC20Metadata depositToken = IERC20Metadata(stableAsset);
        IERC20Metadata investToken = IERC20Metadata(riskAsset);
        
        /* uint startedAt, uint price, uint timeStamp, uint80 answeredInRound */
        ( , int256 price, , , ) = riskAssetFeed.latestRoundData();

        // if received a negative price the return amountOutMin = 0 to avoid swap
        if (price < 0) return (0, 0);

        // swap USD => ETH
        if (tokenIn == stableAsset && tokenOut == riskAsset) {
            amountOutExpected = amountIn.div(uint256(price), depositToken.decimals(), riskAssetFeed.decimals(), investToken.decimals());
        }

        // swap ETH => USD
        if (tokenIn == riskAsset && tokenOut == stableAsset) {
            amountOutExpected = amountIn.mul(uint256(price), investToken.decimals(), riskAssetFeed.decimals(), depositToken.decimals());
        }

        amountOutMin = ((10000 - maxSlippage()) * amountOutExpected) / 10000;
    }



    /**
     * @notice uses SwapsRouter to performa a single swap 'amountOutMin' of tokenIn into tokenOut.
     *          It does not check slippage and it's not expected to revert
     * @return amountOut the amount received from the swap
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipent) internal returns (uint256 amountOut) {
        
        require (IERC20(tokenIn).balanceOf(address(this)) >= amountIn, "LibSwaps: insufficient balance");

        Storage storage ds = getStorage();

        if (amountIn > 0 && amountOutMin > 0) {
            // allow the router to spend the tokens
            address router = swapRouter();
            IERC20(tokenIn).approve(router, amountIn);
            console.log(">>> LibSwaps.swap - router: ", router, tokenIn);

            try ISwapsRouter(router).swap(
                tokenIn, 
                tokenOut, 
                amountIn, 
                amountOutMin, 
                recipent, 
                ds._feeV3
            ) returns (uint256 received) {
                amountOut = received;
                console.log(">>> LibSwaps.swap - amountOut: ", amountOut);
            } catch Error(string memory reason) {
                // log catch failing revert() and require() 
                // e.g. 'Too little received' when slippage is exceeded
                console.log(">>> LibSwaps.swap - reason: ", reason);

                emit SwapError(reason);
            } catch (bytes memory reason) {
                 console.log(">>> LibSwaps.swap - error: ", string(reason));
                // catch failing assert()
                emit SwapError(string(reason));
            }
        }
    }


    function shouldProcessSwap() view internal returns(bool) {
        Storage storage ds = getStorage();

        bool swapNotFilled = ds._swap.sold < ds._swap.total;
        bool twapSwapIntervalElapsed = block.timestamp >= ds._swap.lastSwapTimestamp + ds._twapSwapInterval;
        
        return swapNotFilled && twapSwapIntervalElapsed;
    }

}

