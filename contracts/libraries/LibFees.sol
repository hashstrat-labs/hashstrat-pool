/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import { LibUserInfo } from "./LibUserInfo.sol";
import { LibPool } from "./LibPool.sol";


/**
 * @notice The library that implements the logic for Pool fees
 */
library LibFees {
    

    bytes32 constant FEES_STORAGE_POSITION = keccak256("facet.fees.diamond.storage");

    struct Storage {
        uint256 _feesPerc;
    }
    

    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = FEES_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }


    function feesPerc() internal view returns(uint256) {
        Storage storage ds = getStorage();
        return ds._feesPerc;
    }


    function setFeesPerc(uint256 fees) internal {
        Storage storage ds = getStorage();
        ds._feesPerc = fees;
    }

 
    function feesForWithdraw(uint256 lpToWithdraw, address account) internal view returns (uint256) {
        return
            (feesPerc() * gainsPerc(account) * lpToWithdraw) /
            (10**(2 * feesPercDecimals()));
    }


    /**
     * @param account used to determine the percentage of gains
     * @return the percentage percentage for the account provided using 'feesPercDecimals' decimals
     */
    function gainsPerc(address account) internal view returns (uint256) {

        uint deposits = LibUserInfo.getDeposits(account);
        uint withdrawals = LibUserInfo.getWithdrawals(account);

        // if the address has no deposits (e.g. LPs were transferred from original depositor)
        // then consider the entire LP value as gains.
        // This is to prevent fee avoidance by withdrawing the LPs to different addresses
        if (deposits == 0) return 10**feesPercDecimals(); // 100% of LP tokens are taxable

        // take into account for staked LP when calculating the value held in the pool
        uint256 shares = LibPool.sharesForAccount(account, true);
        uint256 valueInvested = LibPool.lpTokensValue(shares);

        // check if account is in profit
        bool hasGains = withdrawals + valueInvested > deposits;

        // return the fees on the gains or 0 if there are no gains
        return
            hasGains
                ? ( 10**feesPercDecimals() * (withdrawals + valueInvested - deposits) ) / deposits
                : 0;
    }

    function feesPercDecimals() pure internal returns(uint) {
        return 4;
    }

}

