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
 * @notice The facet providing Fees functionality to a Pool
 * @author Carlo Pascoli
 */
contract FeesFacet {

    struct FeesArgs {
        uint256 feesPerc;
    }

    function init(FeesArgs memory args) public {
        LibDiamond.enforceIsContractOwner();
        LibFees.setFeesPerc(args.feesPerc);
    }


    // View functions

    function gainsPerc(address account) public view returns (uint256 perc) {
            perc = LibFees.gainsPerc(account);
    }

    /// @notice returns the fees, in percentage using 4 digit precision (e.g 100 is 1%)
    function feesPerc() external view returns(uint perc) {
        perc = LibFees.feesPerc();
    }


    /// @notice returns the fees, in shares, for the given account to withdraw the given amount of shares.
    function feesForWithdraw(uint shares, address account) external view returns (uint fees) {
        fees = LibFees.feesForWithdraw(shares, account);
    }


    //// Only Owner Functions ////

    function setFeesPerc(uint fee) external {
        LibDiamond.enforceIsContractOwner();
        LibFees.setFeesPerc(fee);
    }

    function collectFees(uint shares) external {
        LibDiamond.enforceIsContractOwner();
        uint256 lpAmount = shares == 0 ? LibERC20.erc20balanceOf(address(this)) : shares;
        LibPool.redeem(lpAmount, msg.sender, address(this));
    }

}

