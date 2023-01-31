// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;


import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./IPoolV4.sol";
import "./IDAOTokenFarm.sol";
import "./PoolLPToken.sol";
import "./TokenMaths.sol";

import "./strategies/IStrategy.sol";
import "./swaps/IUniswapV2Router.sol";
import "./swaps/ISwapRouter.sol";


/**
 * Owner of this contract should be DAOOperations
 */
contract PoolV4 is IPoolV4, ReentrancyGuard, KeeperCompatibleInterface, Ownable {
   
    using TokenMaths for uint;

   
    struct SwapInfo {
        uint timestamp;
        string side;
        uint feedPrice;
        uint bought;
        uint sold;
        uint depositTokenBalance;
        uint investTokenBalance;
    }

    enum  UserOperation { DEPOSIT, WITHDRAWAL }

    struct UserInfo {
        uint timestamp;
        UserOperation operation;
        uint amount;
    }

    uint8 public immutable feesPercDecimals = 4;
    uint public feesPerc;                    // using feePercDecimals precision (e.g 100 is 1%)

    IDAOTokenFarm public daoTokenFarm;

    // Pools tokens
    IERC20Metadata immutable public depositToken;
    IERC20Metadata public immutable investToken;
    PoolLPToken public immutable lpToken;


    event Deposited(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);
    event Swapped(string indexed swapType, uint spent, uint bought, uint slippage);


    uint public totalDeposited = 0;
    uint public totalWithdrawn = 0;

    mapping (address => uint) public deposits;
    mapping (address => uint) public withdrawals;
    mapping (address => UserInfo[]) public userInfos;

    address[] public users;
    mapping (address => bool) usersMap;

    // Chainlink pricefeed
    AggregatorV3Interface public priceFeed;

    // Uniswap V2/V3 routers
    IUniswapV2Router public immutable uniswapV2Router;
    ISwapRouter public immutable uniswapV3Router;

    IStrategy public strategy;


    uint public upkeepInterval;
    uint public lastUpkeepTimeStamp;

    uint public slippageThereshold = 500; // allow for 5% slippage on swaps (aka should receive at least 95% of the expected token amount)
    SwapInfo[] public swaps;


    constructor(
        address _uniswapV2RouterAddress,
        address _uniswapV3RouterAddress,
        address _priceFeedAddress,
        address _depositTokenAddress,
        address _investTokenAddress,
        address _lpTokenAddress,
        address _strategyAddress,
        uint _upkeepInterval,
        uint _feesPerc) {

            uniswapV2Router = IUniswapV2Router(_uniswapV2RouterAddress);
            uniswapV3Router = ISwapRouter(_uniswapV3RouterAddress);

            priceFeed = AggregatorV3Interface(_priceFeedAddress);
            investToken = IERC20Metadata(_investTokenAddress);
            depositToken = IERC20Metadata(_depositTokenAddress);
            lpToken = PoolLPToken(_lpTokenAddress);
            strategy = IStrategy(_strategyAddress);

            upkeepInterval = _upkeepInterval;
            lastUpkeepTimeStamp = block.timestamp;

            feesPerc = _feesPerc;
    }


    function getSwapsInfo() public view returns (SwapInfo[] memory) {
        return swaps;
    }


    function getUsers() public view returns (address[] memory) {
        return users;
    }

    function getUserInfos(address account) public view returns (UserInfo[] memory) {
        return userInfos[account];
    }


    /// View Functions

    function lpTokensValue (uint lpTokens) public view returns (uint) {
        return lpToken.totalSupply() > 0 ? this.totalValue() * lpTokens / lpToken.totalSupply() : 0;

    }

    function portfolioValue(address account) external view returns (uint) {
        // the value of the portfolio allocated to the user, espressed in deposit tokens
        uint precision = 10 ** uint(portfolioPercentageDecimals());
        return totalValue() * portfolioPercentage(account) / precision;
    }


    // Returns the % of the pool owned by _addr using 'priceFeed' decimals precision
    function portfolioPercentage(address _addr) public view returns (uint) {

        if (lpToken.totalSupply() == 0) return 0;

        return 10 ** uint(portfolioPercentageDecimals()) * lpToken.balanceOf(_addr) / lpToken.totalSupply();
    }


    // returns the portfolio value in depositTokens
    function totalValue() public override view returns(uint) {
        return stableAssetValue() + riskAssetValue();
    }


    //TODO return the value of the stable asset in USD
    function stableAssetValue() public override view returns(uint) {
        return depositToken.balanceOf(address(this));
    }



    //TODO optimize decimal conversion
    // @return the value of the risk asset according to the the latest pricefeed price
    function riskAssetValue() public override view returns(uint) {
        ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = priceFeed.latestRoundData();
        if (price <= 0) return 0;
        uint value = investToken.balanceOf( address(this) ).mul( uint(price),
                        investToken.decimals(), priceFeed.decimals(),
                        depositToken.decimals()
                    );

        return value;
    }

    function investTokenPercentage() internal view returns (uint)  {
        return (lpToken.totalSupply() == 0) ? 0 : 10 ** uint(portfolioPercentageDecimals()) * riskAssetValue() / totalValue(); 
    }

    function portfolioPercentageDecimals() public view returns (uint8) {
        return priceFeed.decimals();
    }

    
    /////  Deposit ///// 
   function deposit(uint amount) nonReentrant public override {

        //portfolio allocation before the deposit
        require(depositToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        
        if (amount == 0) return;
    
        // 1. Transfer deposit amount to the pool
        deposits[msg.sender] += amount;
        totalDeposited += amount;

        // record user and deposit infos
        if (!usersMap[msg.sender]) {
            usersMap[msg.sender] = true;
            users.push(msg.sender);
        }
        userInfos[msg.sender].push(
            UserInfo({
                timestamp: block.timestamp,
                operation: UserOperation.DEPOSIT,
                amount: amount
            })
        );

        depositToken.transferFrom(msg.sender, address(this), amount);

        // 2. Calculate LP tokens for this deposit that will be minted to the depositor
        // Important: calculate 'depositLPTokens' AFTER the deposit tokens have been transferred to he pool
        uint depositLPTokens = lpTokensForDeposit(amount);

        if (lpToken.totalSupply() == 0) {
            // if the pool was empty before this deposit => run the strategy and log the swap info.
            strategyEval();
        } else {
            // if the pool was not empty before this deposit => ensure the pool remains balanced with this deposit.
            // swap some of the deposit amount into investTokens to keep the pool balanced at current levels
            uint investTokenPerc = investTokenPercentage();
            uint precision = 10 ** uint(portfolioPercentageDecimals());
            uint rebalanceAmount = investTokenPerc * amount / precision;
            if (rebalanceAmount > 0) {
                swapIfNotExcessiveSlippage(StrategyAction.BUY, address(depositToken), address(investToken), rebalanceAmount, false);
            }
        }

        // 3. Mint LP tokens to the user
        lpToken.mint(msg.sender, depositLPTokens);

        emit Deposited(msg.sender, amount);
    }


    // calculate the LP tokens for a deposit of 'amount' tokens after the deposit tokens have been transferred into the pool
    function lpTokensForDeposit(uint amount) internal view returns (uint) {
        
        uint depositLPTokens;
         if (lpToken.totalSupply() == 0) {
             /// If pool is empty  => allocate the inital LP tokens amount to the user
            depositLPTokens = amount;
        } else {
            ///// if there are already LP tokens => calculate the additional LP tokens for this deposit
            // calculate portfolio % of the deposit (using lpPrecision digits precision)
            uint lpPrecision = 10 ** uint(lpToken.decimals());
            uint portFolioPercentage = lpPrecision * amount / totalValue();

            // calculate the amount of LP tokens for the deposit so that they represent 
            // a % of the existing LP tokens equivalent to the % value of this deposit to the whole portfolio value.
            // 
            // X := P * T / (1 - P)  
            //      X: additinal LP toleks to allocate to the user to account for this deposit
            //      P: Percentage of portfolio accounted by this deposit
            //      T: total LP tokens allocated before this deposit
    
            depositLPTokens = (portFolioPercentage * lpToken.totalSupply()) / ((1 * lpPrecision) - portFolioPercentage);
        }

        return depositLPTokens;
    }



    /////  Withdrawals ///// 

    function withdrawAll() nonReentrant external {
        _withdrawLP(lpToken.balanceOf(msg.sender));
    }

    /** 
    * @notice Withdraw 'amount' of LP tokens from the pool and receive the equivalent amoun of deposit tokens
    *         If fees are due, those are deducted from the LP amount before processing the withdraw.
    * 
    * @param amount the amount of LP tokent to withdraw
    */
    function withdrawLP(uint amount) nonReentrant external {
        uint fees = feesForWithdraw(amount, msg.sender);
        uint netAmount = amount - fees;

        // transfer fees to Pool by burning the and minting lptokens to the pool
        if (fees > 0) {
            lpToken.burn(msg.sender, fees);
            lpToken.mint(address(this), fees);
        }
       
        _withdrawLP(netAmount);
    }


    /** 
    *   @notice Burns the 'amount' of LP tokens and sends to the sender the equivalent value in deposit tokens.
    *   @param amount the amount of LP tokent being withdrawn.
    */
    function _withdrawLP(uint amount) internal {
        
        if(amount == 0) return;
        
        require(amount <= lpToken.balanceOf(msg.sender), "LP balance exceeded");

        uint precision = 10 ** uint(portfolioPercentageDecimals());
        uint withdrawPerc = precision * amount / lpToken.totalSupply();

        // 1. Calculate amount of depositTokens & investTokens to withdraw
        uint depositTokensBeforeSwap = depositToken.balanceOf(address(this));
        uint investTokensBeforeSwap = investToken.balanceOf(address(this));
        //  if these are the last LP being withdrawn ensure no leftovers tokens in the pool due to dounding errors
        bool isWithdrawingAll = (amount == lpToken.totalSupply());
        uint withdrawDepositTokensAmount = isWithdrawingAll ? depositTokensBeforeSwap : depositTokensBeforeSwap * withdrawPerc / precision;
        uint withdrawInvestTokensTokensAmount = isWithdrawingAll ? investTokensBeforeSwap : investTokensBeforeSwap * withdrawPerc / precision;

        // 2. burn the user's LP tokens
        lpToken.burn(msg.sender, amount);

        uint depositTokensSwapped = 0;
        // 3. swap some invest tokens back into deposit tokens
        if (withdrawInvestTokensTokensAmount > 0) {
            // swap some investTokens into depositTokens to be withdrawn
            uint256 amountMin = getAmountOutMin(address(investToken), address(depositToken), withdrawInvestTokensTokensAmount);
            swap(address(investToken), address(depositToken), withdrawInvestTokensTokensAmount, amountMin, address(this));
        
            // determine how much depositTokens were swapped
            uint depositTokensAfterSwap = depositToken.balanceOf(address(this));
            depositTokensSwapped = depositTokensAfterSwap - depositTokensBeforeSwap;
        }

        // 4. transfer depositTokens to the user
        uint amountToWithdraw = withdrawDepositTokensAmount + depositTokensSwapped;        

        withdrawals[msg.sender] += amountToWithdraw;
        totalWithdrawn += amountToWithdraw;
        userInfos[msg.sender].push(
            UserInfo({
                timestamp: block.timestamp,
                operation: UserOperation.WITHDRAWAL,
                amount: amountToWithdraw
            })
        );

        depositToken.transfer(msg.sender, amountToWithdraw);

        emit Withdrawn(msg.sender, amountToWithdraw);
    }



    //// Fees calculation ////


    /**
    * @notice The fees to withdraw are calcualted as percentage of the outstanding profit that the user is withdrawing
    * For example:
    *  given a 1% fees on profits,
    *  when a user having $1000 in outstaning profits is withdrawing 20% of his LP tokens
    *  then he will have to pay the LP equivalent of $2.00 in fees
    * 
    *     withdraw_value : = pool_value * lp_to_withdraw / lp_total_supply
    *     fees_value := fees_perc * gains_perc(account) * withdraw_value 
    *                := fees_perc * gains_perc(account) * pool_value * lp_to_withdraw / lp_total_supply
    *    
    *     fees_lp := fees_value * lp_total_supply / pool_value            <= fees_lp / lp_total_supply = fees_value / pool_value)
    *             := fees_perc * gains_perc(account) * pool_value * lp_to_withdraw / lp_total_supply * lp_total_supply / pool_value 
    *             := fees_perc * gains_perc(account) * lp_to_withdraw 
    *
    * @param lpToWithdraw the amount of LP tokens to withdraw
    * @param account the account withdrawing the LP tokens
    *
    * @return amount, in LP tokens, that 'account' would pay to withdraw 'lpToWithdraw' LP tokens.
    */

    function feesForWithdraw(uint lpToWithdraw, address account) public view returns (uint) {

        return feesPerc * gainsPerc(account) * lpToWithdraw / (10 ** (2 * uint(feesPercDecimals)));
    }


    /**
    * @param account used to determine the percentage of gains
    * @return the percentage percentage for the account provided using 'feesPercDecimals' decimals
    */
    function gainsPerc(address account) public view returns (uint) {
        
        // if the address has no deposits (e.g. LPs were transferred from original depositor)
        // then consider the entire LP value as gains.
        // This is to prevent tax avoidance by withdrawing the LPs to different addresses
        if (deposits[account] == 0) return 10 ** uint(feesPercDecimals); // 100% gains

        // take into account for staked LP when calculating the value held in the pool
        uint stakedLP = address(daoTokenFarm) != address(0) ? daoTokenFarm.getStakedBalance(account, address(lpToken)) : 0;
        uint valueInPool = lpTokensValue(lpToken.balanceOf(account) + stakedLP);

        // check if accounts is in profit
        bool hasGains = withdrawals[account] + valueInPool > deposits[account];

        // return the fees on the gains or 0 if there are no gains
        return hasGains ? 10 ** uint(feesPercDecimals) * ( withdrawals[account] + valueInPool - deposits[account] ) / deposits[account] : 0;
    }


    //// STRATEGY EXECUTION ////

    // KeeperCompatibleInterface implementation //
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
        //TODO ask strategy if should be avaluated
       return ((block.timestamp - lastUpkeepTimeStamp) >= upkeepInterval, "");
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        if ((block.timestamp - lastUpkeepTimeStamp) >= upkeepInterval ) {
            lastUpkeepTimeStamp = block.timestamp;
            strategyEval();
        }
    }

    function strategyEval() internal {

        // ask the strategy if a swap should happen 
        (StrategyAction action, uint amountIn) = strategy.evaluate();

        if (action == StrategyAction.NONE || amountIn == 0) {
            return;
        }

        address tokenIn;
        address tokenOut;

        if (action == StrategyAction.BUY) {
            tokenIn = address(depositToken);
            tokenOut = address(investToken);
        } else if (action == StrategyAction.SELL) {
            tokenIn = address(investToken);
            tokenOut = address(depositToken);
        }

        swapIfNotExcessiveSlippage(action, tokenIn, tokenOut, amountIn, true);
    }

    //// SWAP FUNCTIONALITY ////
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address to) internal {

    }


    function swapV2(
        address tokenIn, 
        address tokenOut, 
        uint amountIn,
        uint amountOutMin,
        address to
    ) internal returns (uint amountOut) {

        // allow the uniswapv2 router to spend the token we just sent to this contract
        IERC20(tokenIn).approve(address(uniswapV2Router), amountIn);

        // path is an array of addresses and we assume there is a direct pair btween the in and out tokens
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // the deadline is the latest time the trade is valid for
        // for the deadline we will pass in block.timestamp
        uint[] memory amounstOut = uniswapV2Router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            to,
            block.timestamp
        );

        amountOut = amounstOut[amounstOut.length-1];
    }


    function swapV3(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint amountIn,
        uint amountOutMin,
        address to
    ) internal returns (uint amountOut) {

        IERC20(tokenIn).approve(address(uniswapV3Router), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: to,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            });

// UNISWAP V3  (Polygon) 0xE592427A0AEce92De3Edee1F18E0157C05861564 
// USDC  0x2791bca1f2de4661ed88a30c99a7a9449aa84174  
// WBTC  0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6
// in   10000000 (6 decimals)
// out   (8 decimals)  43478 (0.00043478 BTC)
// ["0x2791bca1f2de4661ed88a30c99a7a9449aa84174", "0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6", 500, "0x209f4a997883Ac8e5f686ec59DD1DC47fccE4FAd", 1674844019, 10000000, 0, 0]

        amountOut = uniswapV3Router.exactInputSingle(params);
    }

    function swapIfNotExcessiveSlippage(StrategyAction action, address _tokenIn, address _tokenOut, uint256 _amountIn, bool log) internal {

        // ensure slippage is not too much (e.g. <= 500 for a 5% slippage)
        (uint amountMin, uint slippage) = slippagePercentage(_tokenIn, _tokenOut, _amountIn);

        require(slippage <= slippageThereshold, "Slippage exceeded");
        // if (slippage > slippageThereshold) {
        //     revert("Slippage exceeded");
        // }

        uint256 depositTokenBalanceBefore = depositToken.balanceOf(address(this));
        uint256 investTokenBalanceBefore = investToken.balanceOf(address(this));

        // perform swap required to rebalance the portfolio
       swap(_tokenIn, _tokenOut, _amountIn, amountMin, address(this));

        // balances after swap
        uint256 depositTokenBalanceAfter = depositToken.balanceOf(address(this));
        uint256 investTokenBalanceAfter = investToken.balanceOf(address(this));

        uint256 spent;
        uint256 bought;
        string memory swapType;
        
        if (action == StrategyAction.BUY) {
            swapType = "BUY";
            spent = depositTokenBalanceBefore - depositTokenBalanceAfter;
            bought = investTokenBalanceAfter - investTokenBalanceBefore;
        } else if (action == StrategyAction.SELL) {
            swapType = "SELL";
            spent = investTokenBalanceBefore - investTokenBalanceAfter;
            bought = depositTokenBalanceAfter - depositTokenBalanceBefore;
        }
        if (log) { 
            SwapInfo memory info = swapInfo(swapType, spent, bought);
            swaps.push(info);
        }

        emit Swapped(swapType, spent, bought, slippage);
    }


    /**
    * @return amountOut the minimum amount received from the V2 swap in
    */
    function getAmountOutMin(address _tokenIn, address _tokenOut, uint256 _amountIn) internal view returns (uint amountOut) {
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        uint256[] memory amountOutMins = uniswapV2Router.getAmountsOut(_amountIn, path);
        // require(amountOutMins.length >= path.length , "Invalid amountOutMins size");

        amountOut = amountOutMins[path.length - 1];
    }


    // Returns the min amount of tokens expected from the swap and the slippage calculated as a percentage from the feed price. 
    // The returned percentage is returned with 4 digits decimals
    // E.g: For a 5% slippage below the expected amount 500 is returned
    function slippagePercentage(address tokenIn, address tokenOut, uint amountIn) public view returns (uint amountMin, uint slippage) {
        ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");

        uint amountExpected;

        // swap USD => ETH
        if (tokenIn == address(depositToken) && tokenOut == address(investToken)) {
            amountExpected = amountIn.div( uint(price), 
                            depositToken.decimals(), priceFeed.decimals(),
                            investToken.decimals() ); // return value is in ETH (invest token decimals) 
        } 

        // swap ETH => USD
        if (tokenIn == address(investToken) && tokenOut == address(depositToken)) {
            amountExpected = amountIn.mul( uint(price), 
                            investToken.decimals(), priceFeed.decimals(),
                            depositToken.decimals());  // return value is in USD (deposit token decimals) 
        }

        amountMin = getAmountOutMin(tokenIn, tokenOut, amountIn);
        if (amountMin >= amountExpected) return (amountMin, 0);

        slippage = 10000 - (10000 * amountMin / amountExpected); // e.g 10000 - 9500 = 500  (5% slippage) - min slipage: 1 = 0.01%
    }


    function swapInfo(string memory swapType, uint amountIn, uint amountOut) internal view returns (SwapInfo memory) {

        (   /*uint80 roundID**/, int price, /*uint startedAt*/,
            /*uint timeStamp*/, /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");

        // Record swap info
        SwapInfo memory info = SwapInfo({
            timestamp: block.timestamp,
            side: swapType,
            feedPrice: uint(price),
            bought: amountOut,
            sold: amountIn,
            depositTokenBalance: depositToken.balanceOf(address(this)),
            investTokenBalance: investToken.balanceOf(address(this))
        });

        return info;
    }


    //////  OWNER FUNCTIONS  ////// 

    function setSlippageThereshold(uint slippage) public onlyOwner {
        slippageThereshold = slippage;
    }

    function setStrategy(address strategyAddress) public onlyOwner {
        strategy = IStrategy(strategyAddress);
    }

    function setUpkeepInterval(uint innterval) public onlyOwner {
        upkeepInterval = innterval;
    }

    function setFeesPerc(uint _feesPerc) public onlyOwner {
        feesPerc = _feesPerc;
    }

    function setFarmAddress(address farmAddress) public onlyOwner {
        daoTokenFarm = IDAOTokenFarm(farmAddress);
    }

    // Withdraw the given amount of LP token fees in deposit tokens
    function collectFees(uint amount) public onlyOwner {
        uint fees = amount == 0 ? lpToken.balanceOf(address(this)) : amount;
        if (fees > 0) {
            lpToken.transfer(msg.sender, fees);
            _withdrawLP(fees);
        }
    }

}