// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;


import { LibSwaps } from "../libraries/LibSwaps.sol";
import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";

/**
 * @notice The facet providing the swaps functionality via SwapRouter.
 * @author Carlo Pascoli
 */
contract SwapsFacet {

    struct SwapsArgs {
        uint256 swapInterval;
        uint256 maxSlippage;
        uint256 swapMaxValue;
        address swapRouter;
        uint24 feeV3;
    }

    function init(SwapsArgs memory args) external {
        LibDiamond.enforceIsContractOwner();

        LibSwaps.setTwapSwapInterval(args.swapInterval);
        LibSwaps.setMaxSlippage(args.maxSlippage);
        LibSwaps.setSwapMaxValue(args.swapMaxValue);
        LibSwaps.setSwapRouter(args.swapRouter);
        LibSwaps.setFeeV3(args.feeV3);
    }



    function feeV3() external view returns (uint256) {
        return LibSwaps.feeV3();
    }


    function getSwapsInfo() external view returns (LibSwaps.SwapInfo[] memory) {
        return LibSwaps.getSwapsInfo();
    }

    function slippageThereshold() external view returns(uint256) {
        return LibSwaps.maxSlippage();
    }

    function swapMaxValue() external view returns(uint256) {
        return LibSwaps.swapMaxValue();
    }

    function twapSwapInterval() external view returns(uint256) {
        return LibSwaps.twapSwapInterval();
    }

    function swapRouter() external view returns(address) {
        return LibSwaps.swapRouter();
    }


    //// Only Owner functions ////


    function twapSwaps() external view returns (LibSwaps.TWAPSwap memory) {
        return LibSwaps.twapSwaps();
    }

    function setTwapSwapInterval(uint interval) external {
        LibDiamond.enforceIsContractOwner();
        LibSwaps.setTwapSwapInterval(interval);
    }

     function setSwapRouter(address router) external {
        LibDiamond.enforceIsContractOwner();
        LibSwaps.setSwapRouter(router);
    }

    function setSlippageThereshold(uint256 slippage) external {
        LibDiamond.enforceIsContractOwner();
        LibSwaps.setMaxSlippage(slippage);
    }

    function setFeeV3(uint24 feeV3) external {
        LibDiamond.enforceIsContractOwner();
        LibSwaps.setFeeV3(feeV3);
    }

    function setSwapMaxValue(uint256 maxValue) external {
        LibDiamond.enforceIsContractOwner();
        LibSwaps.setSwapMaxValue(maxValue);
    }


}