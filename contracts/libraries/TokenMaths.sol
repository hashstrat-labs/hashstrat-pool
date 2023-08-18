// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;


/**
 * @title TokenMaths
 * @dev Library for simple arithmetics operations between tokens of different decimals, up to 18 decimals.
 */
library TokenMaths {

    /**
     * @notice division between 2 token amounts with different decimals. Assumes decimals1 <= 18 and decimals2 <= 18.
     * The returns value is provided with decimalsOut decimals.
     */
    function div(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
        return (10 ** decimalsOut * toWei(amount1, decimals1) / toWei(amount2, decimals2));
    }


    /**
     * @notice multiplication between 2 token amounts with different decimals. Assumes decimals1 <= 18 and decimals2 <= 18.
     * The returns value is provided with decimalsOut decimals.
     */
    function mul(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
       return 10 ** decimalsOut * amount1 * amount2 / 10 ** (decimals1 + decimals2);
    }


    /**
     * @notice converts an amount, having less than 18 decimals, to to a value with 18 decimals.
     * Otherwise returns the provided amount unchanged.
     */
    function toWei(uint amount, uint8 decimals) internal pure returns (uint) {

        if (decimals >= 18) return amount;

        return amount * 10 ** (18 - decimals);
    }


    /**
     * @notice converts an amount, having 18 decimals, to to a value with less than 18 decimals.
     * Otherwise returns the provided amount unchanged.
     */
    function fromWei(uint amount, uint8 decimals) internal pure returns (uint) {

        if (decimals >= 18) return amount;

        return amount / 10 ** (18 - decimals);
    }

}

