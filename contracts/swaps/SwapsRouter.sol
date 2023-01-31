// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../TokenMaths.sol";

import "./IUniswapV2Router.sol";
import "./ISwapsRouter.sol";
import "./ISwapsV3.sol";


/**
 * Owner of this contract should be DAOOperations
 */
contract SwapsRouter is ISwapsRouter, ReentrancyGuard, Ownable {

    enum RouterVersion { V2, V3 }
    enum RouterType { Uniswap, QuickSwap }

    struct RouterInfo {
        address routerAddress;
        RouterVersion routerVersion;
        RouterType routerType;
    }

    IQuoter_Uniswap quoterUniswap;
    IQuoter_Quickswap quoterQuickswap;

    uint public activeRouterIdx = 0;
    RouterInfo[] public routers;


    constructor(address quoterUniswapAddress, address quoterQuickswapAddress) {
        quoterUniswap = IQuoter_Uniswap(quoterUniswapAddress);
        quoterQuickswap = IQuoter_Quickswap(quoterQuickswapAddress);
    }


    function getRouters() public view returns (RouterInfo[] memory) {
        return routers;
    }


    function activeRouter() public view returns (RouterInfo memory) {
        require (activeRouterIdx < routers.length, "SwapsRouter: Invalid router index");

        return routers[activeRouterIdx];
    }


    /**
     * Entry point for Pool swaps.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 feeV3
    ) external returns (uint amountOut) {

        // transfer the tokens to this contract and aprove spend from the AMM
        RouterInfo memory routerInfo = activeRouter();

        bool transferred = IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        bool approved = IERC20(tokenIn).approve(address(routerInfo.routerAddress), amountIn);
        assert (transferred && approved);

        if (routerInfo.routerVersion == RouterVersion.V3 && routerInfo.routerType == RouterType.Uniswap ) {
            ISwapRouter_Uniswap.ExactInputSingleParams memory params = ISwapRouter_Uniswap
                .ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: feeV3,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    sqrtPriceLimitX96: 0
                });

            ISwapRouter_Uniswap router = ISwapRouter_Uniswap(routerInfo.routerAddress);

            amountOut = router.exactInputSingle(params);

        } else if (routerInfo.routerVersion == RouterVersion.V3 && routerInfo.routerType == RouterType.QuickSwap ) {
            ISwapRouter_Quickswap.ExactInputSingleParams memory params = ISwapRouter_Quickswap
                .ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    recipient: recipient,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    limitSqrtPrice: 0
                });

            ISwapRouter_Quickswap router = ISwapRouter_Quickswap(routerInfo.routerAddress);
            amountOut = router.exactInputSingle(params);

        } else if (routerInfo.routerVersion == RouterVersion.V2) {
            // path is an array of addresses and we assume there is a direct pair btween the in and out tokens
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;

            // the deadline is the latest time the trade is valid for
            // for the deadline we will pass in block.timestamp
            IUniswapV2Router router = IUniswapV2Router(routerInfo.routerAddress);
            uint256[] memory amounstOut = router.swapExactTokensForTokens(
                amountIn,
                amountOutMin,
                path,
                recipient,
                block.timestamp
            );

            amountOut = amounstOut[amounstOut.length - 1];
        }

    }



    /**
    * @return amountOut the minimum amount of tokens expected from the V2 or v3 swap
    */
    function getAmountOutMin(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 feeV3
    ) external returns (uint amountOut) {

        RouterInfo memory routerInfo = activeRouter();

        if (routerInfo.routerVersion == RouterVersion.V3 && routerInfo.routerType == RouterType.Uniswap ) {
            amountOut = quoterUniswap.quoteExactInputSingle(tokenIn, tokenOut, feeV3, amountIn, 0);

        } else if (routerInfo.routerVersion == RouterVersion.V3 && routerInfo.routerType == RouterType.QuickSwap ) {
            (amountOut, ) = quoterQuickswap.quoteExactInputSingle(tokenIn, tokenOut, amountIn, 0);

        } else if (routerInfo.routerVersion == RouterVersion.V2) {
            IUniswapV2Router router = IUniswapV2Router(routerInfo.routerAddress);
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;

            uint256[] memory amountOutMins = router.getAmountsOut(amountIn, path);
            amountOut = amountOutMins[path.length - 1];
        }
    }



    // function swapV2(
    //     address tokenIn,
    //     address tokenOut,
    //     uint256 amountIn,
    //     uint256 amountOutMin,
    //     address recipient
    // ) internal returns (uint256 amountOut) {

    //     RouterInfo memory routerInfo = activeRouter();

    //     // allow the uniswapv2 router to spend the token we just sent to this contract
    //     IERC20(tokenIn).approve(address(routerInfo.routerAddress), amountIn);

    //     // path is an array of addresses and we assume there is a direct pair btween the in and out tokens
    //     address[] memory path = new address[](2);
    //     path[0] = tokenIn;
    //     path[1] = tokenOut;

    //     // the deadline is the latest time the trade is valid for
    //     // for the deadline we will pass in block.timestamp
    //     IUniswapV2Router uniswapV2Router = IUniswapV2Router(routerInfo.routerAddress);
    //     uint256[] memory amounstOut = uniswapV2Router.swapExactTokensForTokens(
    //         amountIn,
    //         amountOutMin,
    //         path,
    //         recipient,
    //         block.timestamp
    //     );

    //     amountOut = amounstOut[amounstOut.length - 1];
    // }




    //// ONLY OWNER ////

    function addRouter(address routerAddress,  RouterVersion routerVersion, RouterType routerType) public onlyOwner {
        RouterInfo memory info = RouterInfo({
            routerAddress: routerAddress,
            routerVersion: routerVersion,
            routerType: routerType
        });
        routers.push(info);
    }

    function setActiveRouter(uint routerIndex) public onlyOwner {
        activeRouterIdx = routerIndex;
    }
}
