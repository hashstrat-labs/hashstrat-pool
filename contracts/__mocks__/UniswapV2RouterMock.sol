// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../swaps/IUniswapV2Router.sol";
import "../libraries/TokenMaths.sol";

import "hardhat/console.sol";

/**
    Mock implementation of swap functionality and price feed via the interfaces:
    - UniswapV2Router to swap depositTokens into investTokens
    - AggregatorV3Interface to provide price for the  investTokens/depositTokens pair
 */
contract UniswapV2RouterMock is ReentrancyGuard, IUniswapV2Router {

    using TokenMaths for uint;

    IERC20Metadata internal depositToken;
    IERC20Metadata internal investToken;

    AggregatorV3Interface internal depositTokenFeed;
    AggregatorV3Interface internal investTokenFeed;

    uint public slippage = 0; // slippage percent using 4 decimals (e.g 2% slippage is 200)

    event Swapped(string direction, uint256 amountIn, uint256 amountOut, uint256 price, uint slippage);

    constructor(
         address depositTokenAddress,
         address investTokenAddress,
         address depositTokenAggregatorAaddress,
         address investTokenAggregatorAaddress
    ) {

        depositToken = IERC20Metadata(depositTokenAddress);
        investToken = IERC20Metadata(investTokenAddress);
        depositTokenFeed = AggregatorV3Interface(depositTokenAggregatorAaddress);
        investTokenFeed = AggregatorV3Interface(investTokenAggregatorAaddress);
    }


    function setSlippage(uint _slippage) external {
        slippage = _slippage;
    }



    //// UniswapV2Router interface implementation

    function WETH() external override view returns (address addr) {
        // assume the WETH intermediary token for token-to-token swaps is the investToken address
        return address(investToken);
    }

    function getPrice() public view returns (int price) {
        (   /*uint80 roundID**/, price, /*uint startedAt*/,
            /*uint timeStamp*/, /*uint80 answeredInRound*/
        ) = investTokenFeed.latestRoundData();
    }


    function getAmountsOut(uint amountIn, address[] calldata path) external override view returns (uint[] memory amounts) {
        
        uint price = uint(getPrice());
        uint[] memory amountOutMins = new uint[](path.length);
        uint amountOut = 0;

        if (path[0] == address(depositToken)) {
            amountOut = amountIn.div(price,
                depositToken.decimals(), investTokenFeed.decimals(), investToken.decimals()
            ) * (10000 - uint(slippage)) / 10000;

        } else if (path[0] == address(investToken)) {
            // swap ETH => USD
            amountOut = amountIn.mul(price,    // * price / pricePrecision * (10000 - uint(slippage)) / 10000;
                investToken.decimals(), depositTokenFeed.decimals(),  depositToken.decimals()
            ) * (10000 - uint(slippage)) / 10000;
        }

        amountOutMins[path.length-1] = amountOut;
        return amountOutMins;
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint /*amountOutMin*/,
        address[] calldata path,
        address to,
        uint /*deadline*/
    )  external nonReentrant override returns (uint[] memory amounts) {

        uint price = uint(getPrice());
        uint amountOut = 0;

        if (path[0] == address(depositToken)) {
            // swap USD => ETH
            depositToken.transferFrom(msg.sender, address(this), amountIn);

            amountOut = amountIn.div(price,
                depositToken.decimals(), investTokenFeed.decimals(), investToken.decimals()
            ) * (10000 - uint(slippage)) / 10000;

            require(investToken.balanceOf(address(this)) >= amountOut, "Mock UniswapV2: Not enough risk assets");
            investToken.transfer(to, amountOut);
            emit Swapped("BOUGHT", amountIn, amountOut, price, slippage);

        } else if (path[0] == address(investToken)) {
            // swap ETH => USD
            investToken.transferFrom(msg.sender, address(this), amountIn);

            amountOut = amountIn.mul(price,    // * price / pricePrecision * (10000 - uint(slippage)) / 10000;
                investToken.decimals(), depositTokenFeed.decimals(),  depositToken.decimals()
            ) * (10000 - uint(slippage)) / 10000;

            require(depositToken.balanceOf(address(this)) >= amountOut, "Mock UniswapV2: Not enough stable asset");
            depositToken.transfer(to, amountOut);
            emit Swapped("SOLD", amountIn, amountOut, price, slippage);
        }

        amounts = new uint[](2);
        amounts[0] = 0;
        amounts[1] = amountOut;
        return  amounts;
    }

}