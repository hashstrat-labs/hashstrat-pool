// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;


/**
 * @title Roles
 * @dev Library for managing addresses assigned to a Role.
 */
library TokenMaths {

    /**
     * @notice addition between 2 amounts with different decimals. Assumes decimals1 <= 18 and decimals2 <= 18
     */
    // function add(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
    //     return fromWei(toWei(amount1, decimals1) + toWei(amount2, decimals2),  decimalsOut);
    // }


    /**
     * @notice division between 2 amounts with different decimals. Assumes decimals1 <= 18 and decimals2 <= 18
     */
    function div(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
        return (10 ** decimalsOut * toWei(amount1, decimals1) / toWei(amount2, decimals2));
    }

    /**
     * @notice multiplication between 2 amounts with different decimals. Assumes decimals1 <= 18 and decimals2 <= 18
     */
    function mul(uint amount1, uint amount2, uint8 decimals1, uint8 decimals2, uint8 decimalsOut) internal pure returns (uint) {
       return 10 ** decimalsOut * amount1 * amount2 / 10 ** (decimals1 + decimals2);
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

