// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;


/**
 * @title Roles
 * @dev Library for managing addresses assigned to a Role.
 */
library TokenMaths {

    /**
     * @dev give an account access to this role
     */
    function add(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {

        return fromWei(toWei(amount1, decimals1) + toWei(amount2, decimals2),  decimalsOut);

        // if (investTokensDecimals >= depositTokenDecimals) {
        //     // invest token has more decimals than deposit token, have to divide the invest token value by the difference
        //     uint decimalsConversionFactor = 10 ** (investTokensDecimals - depositTokenDecimals);
        //     value = investTokens * uint(price) / decimalsConversionFactor / priceFeedPrecision;
        // } else {
        //     // invest token has less decimals tham deposit token, have to multiply invest token value by the difference
        //     uint decimalsConversionFactor = 10 ** (depositTokenDecimals - investTokensDecimals);
        //     value = investTokens * uint(price) * decimalsConversionFactor / priceFeedPrecision;
        // }
     
    }





    /**
     * @dev remove an account's access to this role
     */
    function sub(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
        return fromWei(toWei(amount1, decimals1) - toWei(amount2, decimals2),  decimalsOut);
    }

    /**
     * @dev check if an account has this role
     * @return bool
     */
    function div(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
        return fromWei(toWei(amount1, decimals1) / toWei(amount2, decimals2),  decimalsOut);
    }


    function mul(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
        return fromWei(toWei(amount1, decimals1) * toWei(amount2, decimals2),  decimalsOut);
    }


    function toWei(uint amount, uint8 decimals) internal pure returns (uint) {

        if (decimals >= 18) return amount;

        return amount * 10 ** (18 - decimals);
    }

    function fromWei(uint amount, uint8 decimals) internal pure returns (uint) {

        if (decimals >= 18) return amount;

        return amount / 10 ** (18 - decimals);
    }


}

