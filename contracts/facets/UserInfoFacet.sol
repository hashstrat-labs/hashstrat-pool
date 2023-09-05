// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;


import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";
import { LibUserInfo } from "../libraries/LibUserInfo.sol";

/**
 * @notice The facet providing data about users' deposits and withdrawals.
 * @author Carlo Pascoli
 */
contract UserInfoFacet {

    function init() public {
        LibDiamond.enforceIsContractOwner();
    }


    function totalDeposited() external view returns(uint) {
        return LibUserInfo.totalDeposited();
    }

    function totalWithdrawn() external view returns(uint) {
        return LibUserInfo.totalWithdrawn();
    }

    function deposits(address account) external view returns (uint256) {
        return LibUserInfo.getDeposits(account);
    }
    
    function getDeposits(address account) external view returns (uint256) {
        return LibUserInfo.getDeposits(account);
    }

    function withdrawals(address account) external view returns (uint256) {
        return LibUserInfo.getWithdrawals(account);
    }

    function getWithdrawals(address account) external view returns (uint256) {
        return LibUserInfo.getWithdrawals(account);
    }

    function getUsers() external view returns (address[] memory) {
        return LibUserInfo.getUsers();
    }

    function getUserInfos(address account) external view returns (LibUserInfo.UserInfo[] memory) {
        return LibUserInfo.getUserInfos(account);
    }

    function portfolioPercentage(address account) external view returns (uint256) {
        return LibUserInfo.portfolioPercentage(account);
    }

}