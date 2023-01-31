// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

interface IDAOTokenFarm {

    function getStakedBalance(address account, address lpToken) external view returns (uint);
}