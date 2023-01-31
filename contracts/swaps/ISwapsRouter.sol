// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;


/**
*  Pool's functionality required by DAOOperations and DAOFarm
*/

interface ISwapsRouter {

    function getAmountOutMin(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 feeV3
    ) external returns (uint amountOut);

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 feeV3
    ) external returns (uint amountOut);
}