// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;


enum StrategyAction { NONE, BUY, SELL }

interface IStrategy {
    function name() external view returns(string memory);
    function description() external view returns(string memory);
    function exec() external returns(StrategyAction action, uint amount);
    function shouldPerformUpkeep() external view returns (bool);
    function setUpkeepInterval(uint innterval) external;
}