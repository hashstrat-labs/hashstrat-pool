// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "hardhat/console.sol";

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
import "./swaps/ISwapsRouter.sol";



/**
 * Owner of this contract should be DAOOperations
 */
contract PoolV4 is IPoolV4, ReentrancyGuard, KeeperCompatibleInterface, Ownable {
   
    using TokenMaths for uint;

    enum  UserOperation { DEPOSIT, WITHDRAWAL }
   
    struct SwapInfo {
        uint timestamp;
        string side;
        uint feedPrice;
        uint bought;
        uint sold;
        uint depositTokenBalance;
        uint investTokenBalance;
    }

    struct UserInfo {
        uint timestamp;
        UserOperation operation;
        uint amount;
    }

    uint8 public immutable feesPercDecimals = 4;
    uint public feesPerc; // using feePercDecimals precision (e.g 100 is 1%)

    IDAOTokenFarm public daoTokenFarm;

    // Pools tokens
    IERC20Metadata immutable public depositToken;
    IERC20Metadata public immutable investToken;
    PoolLPToken public immutable lpToken;


    event Deposited(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);
    event Swapped(string swapType, uint spent, uint bought, uint slippage);
    event MaxSlippageExceeded(string swapType, uint amountIn, uint amountOutMin, uint slippage);


    uint public totalDeposited = 0;
    uint public totalWithdrawn = 0;

    mapping (address => uint) public deposits;
    mapping (address => uint) public withdrawals;
    mapping (address => UserInfo[]) public userInfos;

    address[] public users;
    mapping (address => bool) usersMap;

    // Chainlink price feeds
    AggregatorV3Interface public riskAssetFeed;
    AggregatorV3Interface public stableAssetFeed;
    
    ISwapsRouter public swapRouter;
    IStrategy public strategy;


    uint public slippageThereshold = 500; // allow for 5% slippage on swaps (aka should receive at least 95% of the expected token amount)
    SwapInfo[] public swaps;

    uint24 public feeV3;

    constructor(
        address swapRouterAddress,
        address stableAssetFeedAddress,
        address riskAssetFeedAddress,
        address depositTokenAddress,
        address investTokenAddress,
        address lpTokenAddress,
        address strategyAddress,
        uint poolFees,
        uint24 uniswapV3Fee
    ) {
        swapRouter = ISwapsRouter(swapRouterAddress);

        stableAssetFeed = AggregatorV3Interface(stableAssetFeedAddress);
        riskAssetFeed = AggregatorV3Interface(riskAssetFeedAddress);

        depositToken = IERC20Metadata(depositTokenAddress);
        investToken = IERC20Metadata(investTokenAddress);

        lpToken = PoolLPToken(lpTokenAddress);
        strategy = IStrategy(strategyAddress);
        feesPerc = poolFees;
        feeV3 = uniswapV3Fee;
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


    /** 
    * @return value of the stable assets in the pool in USD
    */
    function stableAssetValue() public override view returns(uint) {
        ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = stableAssetFeed.latestRoundData();

        if (price <= 0) return 0;
        
        uint value = depositToken.balanceOf( address(this) ).mul( uint(price),
                depositToken.decimals(), stableAssetFeed.decimals(),
                depositToken.decimals()
        );

        return value;
    }


    /** 
    * @return value of the risk assets in the pool in USD
    */
    function riskAssetValue() public override view returns(uint) {
        ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = riskAssetFeed.latestRoundData();
        if (price <= 0) return 0;

        uint value = investToken.balanceOf( address(this) ).mul( uint(price),
                investToken.decimals(), riskAssetFeed.decimals(),
                depositToken.decimals()
            );

        return value;
    }


    function investTokenPercentage() internal view returns (uint)  {
        return (lpToken.totalSupply() == 0) ? 0 : 10 ** uint(portfolioPercentageDecimals()) * riskAssetValue() / totalValue(); 
    }

    function portfolioPercentageDecimals() internal view returns (uint8) {
        return riskAssetFeed.decimals();
    }

    
    /////  Deposit ///// 
   function deposit(uint amount) nonReentrant public override {

        require(depositToken.allowance(msg.sender, address(this)) >= amount, "PoolV4: Insufficient allowance");
        
        if (amount == 0) return;
    
        // portfolio allocation before the deposit
        uint investTokenPerc = investTokenPercentage();

        // 1. Transfer deposit amount to the pool
        depositToken.transferFrom(msg.sender, address(this), amount);
            
        deposits[msg.sender] += amount;
        totalDeposited += amount;

        // and record user address (if new user) and deposit infos
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
      
        // 2. Calculate LP tokens for this deposit that will be minted to the depositor
        // Important: calculate 'depositLPTokens' AFTER the deposit tokens have been transferred to he pool
        uint depositLPTokens = lpTokensForDeposit(amount);

        if (lpToken.totalSupply() == 0) {
            // if the pool was empty before this deposit => exec the strategy once to ensure the initial asset allocation
            strategyExec();

        } else {
            // if the pool was not empty before this deposit => ensure the pool remains balanced with this deposit.
            // swap some of the deposit amount into investTokens to keep the pool balanced at current levels
            // uint investTokenPerc = investTokenPercentage();
            uint rebalanceAmount = investTokenPerc * amount / (10 ** uint(portfolioPercentageDecimals()));

            swap(
                address(depositToken),
                address(investToken),
                rebalanceAmount,
                0,
                address(this)
            );
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
        collectFeeAndWithdraw(lpToken.balanceOf(msg.sender));
    }

    function withdrawLP(uint amount) nonReentrant external {
        collectFeeAndWithdraw(amount);
    }


    /** 
    * @notice Withdraw 'amount' of LP tokens from the pool and receive the equivalent amount of deposit tokens
    *         If fees are due, those are deducted from the LP amount before processing the withdraw.
    * 
    * @param amount the amount of LP tokent to withdraw
    */
    function collectFeeAndWithdraw(uint amount) internal {

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
    *           If withdrawal producesa a swap with excessive slippage the transaction will be reverted.
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

        // 3. swap some invest tokens back into deposit tokens
        uint depositTokensReceived = swap(
            address(investToken), 
            address(depositToken), 
            withdrawInvestTokensTokensAmount, 
            0, 
            address(this)
        );

        // 4. transfer depositTokens to the user
        uint amountToWithdraw = withdrawDepositTokensAmount + depositTokensReceived;        

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

    // KeeperCompatibleInterface  //
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
       return  ( strategy.shouldPerformUpkeep(), "");
    }


    function performUpkeep(bytes calldata /* performData */) external override {
        if ( strategy.shouldPerformUpkeep() ) {
            strategyExec();
        }
    }

    /**
     * @notice evaluate the strategy and execute a swap required by the strategy if max slippage is exceeed.  
     */
    function strategyExec() internal {

        // ask the strategy if a swap should happen 
        (StrategyAction action, uint amountIn) = strategy.exec();

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

    /**
     * @notice uses SwapsRouter to performa a single swap 'amountOutMin' of tokenIn into tokenOut.
     *          It does not check slippage and it's not expected to revert
     * @return amountOut the amount received from the swap
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipent) internal returns (uint amountOut) {
        
        if (amountIn > 0) {
            IERC20Metadata token = tokenIn == address(depositToken) ?  depositToken : investToken;
            token.approve(address(swapRouter), amountIn);
            amountOut = swapRouter.swap(tokenIn, tokenOut, amountIn, amountOutMin, recipent, feeV3);
        }
    }


   


    function swapIfNotExcessiveSlippage(
        StrategyAction action,
        address _tokenIn, 
        address _tokenOut, 
        uint256 _amountIn,
        bool log
    ) internal returns (uint spent, uint bought) {

        string memory swapType  = (action == StrategyAction.BUY) ? "BUY" : (action == StrategyAction.SELL) ? "SELL" : "n/a";

        // ensure max slippage is not exceeded
        (uint amountOutMin, uint slippage) = slippagePercentage(_tokenIn, _tokenOut, _amountIn);
        if (amountOutMin == 0) {
            return (0, 0);
        }
        if (slippage > slippageThereshold) {
            emit MaxSlippageExceeded(swapType, _amountIn, amountOutMin, slippage);
            return (0, 0);
        }

        uint depositTokenBalanceBefore = depositToken.balanceOf(address(this));
        uint investTokenBalanceBefore = investToken.balanceOf(address(this));

        // perform swap required to rebalance the portfolio
        // console.log("swapIfNotExcessiveSlippage() - BUY amountIn: ", _amountIn, amountOutMin);
        swap(_tokenIn, _tokenOut, _amountIn, amountOutMin, address(this));

        // balances after swap
        uint depositTokenBalanceAfter = depositToken.balanceOf(address(this));
        uint investTokenBalanceAfter = investToken.balanceOf(address(this));

        if (action == StrategyAction.BUY) {
            spent = depositTokenBalanceBefore - depositTokenBalanceAfter;
            bought = investTokenBalanceAfter - investTokenBalanceBefore;
        } else if (action == StrategyAction.SELL) {
            spent = investTokenBalanceBefore - investTokenBalanceAfter;
            bought = depositTokenBalanceAfter - depositTokenBalanceBefore;
        }
        if (log) { 
            SwapInfo memory info = swapInfo(swapType, spent, bought);
            swaps.push(info);
        }

        emit Swapped(swapType, spent, bought, slippage);

        return (spent, bought);
    }


    /**
     * @return amountOutMin the amount of tokenOut received from the swap and slippage as a percentage with 4 digits decimals.
     */
    function slippagePercentage(address tokenIn, address tokenOut, uint amountIn) internal  returns (uint amountOutMin, uint slippage) {
        ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = riskAssetFeed.latestRoundData();

        // if received a negative price the return amountOutMin = 0 to avoid swap 
        if (price < 0) return (0, 0);

        uint amountExpected;

        // swap USD => ETH
        if (tokenIn == address(depositToken) && tokenOut == address(investToken)) {
            amountExpected = amountIn.div( uint(price), 
                            depositToken.decimals(), riskAssetFeed.decimals(),
                            investToken.decimals() ); // return value is in ETH (invest token decimals) 
        } 

        // swap ETH => USD
        if (tokenIn == address(investToken) && tokenOut == address(depositToken)) {
            amountExpected = amountIn.mul( uint(price), 
                            investToken.decimals(), riskAssetFeed.decimals(),
                            depositToken.decimals());  // return value is in USD (deposit token decimals) 
        }

        amountOutMin = swapRouter.getAmountOutMin(tokenIn, tokenOut, amountIn, feeV3);

        if (amountOutMin >= amountExpected) return (amountOutMin, 0);

        slippage = 10000 - (10000 * amountOutMin / amountExpected); // e.g 10000 - 9500 = 500  (5% slippage) - min slipage: 1 = 0.01%

        // console.log(">>> Poolv4 - slippage", slippage);
    }


    function swapInfo(string memory swapType, uint amountIn, uint amountOut) internal view returns (SwapInfo memory) {

        (   /*uint80 roundID**/, int price, /*uint startedAt*/,
            /*uint timeStamp*/, /*uint80 answeredInRound*/
        ) = riskAssetFeed.latestRoundData();

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
        strategy.setUpkeepInterval(innterval);
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