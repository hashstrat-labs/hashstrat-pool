// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
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
contract PoolV4 is IPoolV4, ReentrancyGuard, AutomationCompatibleInterface, Ownable {
   
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

    struct TWAPSwap {
        StrategyAction side;
        address tokenIn;
        address tokenOut;

        uint total;     // the total amount of the tokenIn to spend (e.g. the total size of this twap swap)
        uint size;      // the max size of each indivitual swap 
        uint sold;      // the cumulative amount of the tokenIn tokens spent
        uint bought;    // the cumulative amount of the tokenOut tokens bought

        uint lastSwapTimestamp; // timestamp of the last attempted/executed swap
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
    event Swapped(string side, uint spent, uint bought, uint slippage);
    event SwapError(string reason);
    event MaxSlippageExceeded(string side, uint amountIn, uint amountOutMin, uint slippage);


    uint public totalDeposited = 0;
    uint public totalWithdrawn = 0;

    mapping (address => uint) public deposits;
    mapping (address => uint) public withdrawals;
    mapping (address => UserInfo[]) public userInfos;

    address[] public users;
    mapping (address => bool) usersMap;

    // Chainlink price feeds
    AggregatorV3Interface public immutable riskAssetFeed;
    AggregatorV3Interface public immutable stableAssetFeed;
    
    ISwapsRouter public immutable swapRouter;
    IStrategy public strategy;


    // Swap data
    TWAPSwap public twapSwaps; // the pending swap
    SwapInfo[] public swaps; // logs of compteted swaps
    uint public slippageThereshold = 500; // allow for 5% slippage on swaps (aka should receive at least 95% of the expected token amount)


    uint24 public immutable feeV3;
    uint public swapMaxValue;

    constructor(
        address swapRouterAddress,
        address stableAssetFeedAddress,
        address riskAssetFeedAddress,
        address depositTokenAddress,
        address investTokenAddress,
        address lpTokenAddress,
        address strategyAddress,
        uint poolFees,
        uint24 uniswapV3Fee,
        uint swapValue
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

        swapMaxValue = swapValue;
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


    // Return the value of the given amount of LP tokens (in USD)
    function lpTokensValue (uint amount) public view returns (uint) {
        return lpToken.totalSupply() > 0 ? totalValue() * amount / lpToken.totalSupply() : 0;
    }

    // Return the value of the assets for the account (in USD)
    function portfolioValue(address account) external view returns (uint) {
        // the value of the portfolio allocated to the user, espressed in deposit tokens
        uint precision = 10 ** uint(portfolioPercentageDecimals());
        return totalValue() * portfolioPercentage(account) / precision;
    }


    // Return the % of the pool owned by 'account' with the precision of the risk asset price feed decimals
    function portfolioPercentage(address account) public view returns (uint) {

        if (lpToken.totalSupply() == 0) return 0;

        return 10 ** uint(portfolioPercentageDecimals()) * lpToken.balanceOf(account) / lpToken.totalSupply();
    }


    // Return the pool total value in USD
    function totalValue() public override view returns(uint) {
        return stableAssetValue() + riskAssetValue();
    }


    /** 
    * @return value of the stable assets in the pool (in USD)
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
    * @return value of the risk assets in the pool (in USD)
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
        bool transferred = depositToken.transferFrom(msg.sender, address(this), amount);
        assert(transferred);

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
            uint rebalanceAmountIn = investTokenPerc * amount / (10 ** uint(portfolioPercentageDecimals()));
            uint amountOutMin = swapRouter.getAmountOutMin(address(depositToken), address(investToken), rebalanceAmountIn, feeV3);
            swap(
                address(depositToken),
                address(investToken),
                rebalanceAmountIn,
                amountOutMin,
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
        uint amountOutMin = swapRouter.getAmountOutMin(address(investToken), address(depositToken), withdrawInvestTokensTokensAmount, feeV3);
        uint depositTokensReceived = swap(
            address(investToken), 
            address(depositToken), 
            withdrawInvestTokensTokensAmount, 
            amountOutMin, 
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

        bool transferred = depositToken.transfer(msg.sender, amountToWithdraw);
        assert(transferred);

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

    // AutomationCompatibleInterface  //
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
       return  ( (twapSwaps.sold < twapSwaps.total) || strategy.shouldPerformUpkeep(), "");
    }


    /**
      *  Handle the pending swap if there is one, othewise exec the strategy
     */
    function performUpkeep(bytes calldata /* performData */) external override {

        if (twapSwaps.sold < twapSwaps.total) {
            handleTwapSwap();
        } else if ( strategy.shouldPerformUpkeep() ) {
            strategyExec();
        }
    }

    function handleTwapSwap() internal {
        
        uint size = (twapSwaps.total > twapSwaps.sold + twapSwaps.size) ? twapSwaps.size : 
                    (twapSwaps.total > twapSwaps.sold) ? twapSwaps.total - twapSwaps.sold : 0;
        
        if (size > 0) {
            (uint sold, uint bought, uint slippage) = swapIfNotExcessiveSlippage(twapSwaps, size);

            twapSwaps.lastSwapTimestamp = block.timestamp;
            string memory side = (twapSwaps.side == StrategyAction.BUY) ? "BUY" : 
                        (twapSwaps.side == StrategyAction.SELL) ? "SELL" : "NONE";
            if (sold > 0 && bought > 0) {
                twapSwaps.sold += sold;
                twapSwaps.bought += bought;
                if (twapSwaps.sold == twapSwaps.total) { 
                    // log that the twap swap has been fully executed
                    SwapInfo memory info = swapInfo(side, twapSwaps.sold, twapSwaps.bought);
                    swaps.push(info);
                }
            }

            emit Swapped(side, sold, bought, slippage);
        }
    }
   


    /** 
     * Exec the trategy and set a swap if needed
     */
    function strategyExec() internal {

        // ask the strategy if a swap should happen 
        (StrategyAction action, uint amountIn) = strategy.exec();

        if (action != StrategyAction.NONE && amountIn > 0) {
            address tokenIn;
            address tokenOut;
            AggregatorV3Interface feed;

            if (action == StrategyAction.BUY) {
                tokenIn = address(depositToken);
                tokenOut = address(investToken);
                feed = stableAssetFeed;
            } else if (action == StrategyAction.SELL) {
                tokenIn = address(investToken);
                tokenOut = address(depositToken);
                feed = riskAssetFeed;
            }

            ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = feed.latestRoundData();
            require(price > 0, "PoolV4: negative price");
            twapSwaps = twapSwapsInfo(action, tokenIn, tokenOut, amountIn, uint(price), feed.decimals());
            
            handleTwapSwap();
        }
    }



    //// SWAP FUNCTIONALITY ////

    /**
     * @notice uses SwapsRouter to performa a single swap 'amountOutMin' of tokenIn into tokenOut.
     *          It does not check slippage and it's not expected to revert
     * @return amountOut the amount received from the swap
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipent) internal returns (uint amountOut) {
        
        if (amountIn > 0 && amountOutMin > 0) {
            IERC20Metadata token = tokenIn == address(depositToken) ?  depositToken : investToken;
            token.approve(address(swapRouter), amountIn);
            try swapRouter.swap(tokenIn, tokenOut, amountIn, amountOutMin, recipent, feeV3) returns (uint received) {
                amountOut = received;
            }  catch Error(string memory reason) {
                // log catch failing revert() and require()
                emit SwapError(reason);
            } catch (bytes memory reason) {
                // catch failing assert()
                emit SwapError(string(reason));
            }
        }
    }






    /** 
    * @return size of the TWAP swaps.
    * The TWAP size is determined by dividing the deised swap size (amountIn) by 2 up to 8 times
    * or until TWAP size is below swapMaxValue.
    * If, for example, swapMaxValue is set to $20k, it would take 256 TWAP swaps to process a $5m swap.
    * A $1m Swap would be processed in 64 TWAP swaps of $15,625 each.
    */
    function twapSwapsInfo(StrategyAction side, address tokenIn, address tokenOut, uint256 amountIn, uint price, uint8 feedDecimals) internal view returns (TWAPSwap memory) {

        IERC20Metadata token = tokenIn == address(depositToken) ? depositToken : investToken;

        uint swapValue = amountIn.mul( uint(price), 
            token.decimals(), feedDecimals, depositToken.decimals()
        );

        // if the value of the swap is less than swapMaxValue than we can swap in one go. 
        // otherwise break the swap into chunks.
        if (swapValue <= swapMaxValue) return TWAPSwap({
            side: side,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            total: amountIn,
            size: amountIn,
            sold: 0,
            bought: 0,
            lastSwapTimestamp: 0
        });

        // determine the size of each chunk
        uint size = amountIn;
        uint8 i=0;
        do {
            size /= 2;
            swapValue /= 2;
        } while( ++i < 8 && swapValue > swapMaxValue);

        return TWAPSwap({
            side: side,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            total: amountIn,
            size: size == 0 ? amountIn : size,
            sold: 0,
            bought: 0,
            lastSwapTimestamp: 0
        });
    }


    /**
     * Perform a swap as part of processing a potentially larger TWAP swap. 
     * if max slippage is exceeded the swap does not happen.
     * @param pendingSwap the info about the TWAP swap being processed. 
     * @param size the amount of tokens to sell. Expected to be > 0 
    */ 
    function swapIfNotExcessiveSlippage(TWAPSwap memory pendingSwap, uint size) internal returns (uint sold, uint bought, uint slppgg) {
       
        // ensure max slippage is not exceeded
        (uint amountOutMin, uint slippage) = slippagePercentage(pendingSwap.tokenIn, pendingSwap.tokenOut, size);
      
        if (slippage > slippageThereshold || amountOutMin == 0) {
            string memory side = (pendingSwap.side == StrategyAction.BUY) ? "BUY" : 
                                 (pendingSwap.side == StrategyAction.SELL) ? "SELL" : "NONE";
            emit MaxSlippageExceeded(side, size, amountOutMin, slippage);

            return (0, 0, slippage);
        }

        uint depositTokenBalanceBefore = depositToken.balanceOf(address(this));
        uint investTokenBalanceBefore = investToken.balanceOf(address(this));

        // perform swap required to rebalance the portfolio
        swap(pendingSwap.tokenIn, pendingSwap.tokenOut, size, amountOutMin, address(this));

        // token balances after swap
        uint depositTokenBalanceAfter = depositToken.balanceOf(address(this));
        uint investTokenBalanceAfter = investToken.balanceOf(address(this));

        if (pendingSwap.side == StrategyAction.BUY) {
            sold = depositTokenBalanceBefore - depositTokenBalanceAfter;
            bought = investTokenBalanceAfter - investTokenBalanceBefore;
        } else if (pendingSwap.side == StrategyAction.SELL) {
            sold = investTokenBalanceBefore - investTokenBalanceAfter;
            bought = depositTokenBalanceAfter - depositTokenBalanceBefore;
        }

        return (sold, bought, slippage);
    }


    /**
     * @return amountOutMin the amount of tokenOut received from the swap and slippage as a percentage with 4 digits decimals.
     */
    function slippagePercentage(address tokenIn, address tokenOut, uint amountIn) internal  returns (uint amountOutMin, uint slippage) {
        ( /*uint80 roundID**/, int price, /*uint startedAt*/, /*uint timeStamp*/, /*uint80 answeredInRound*/) = riskAssetFeed.latestRoundData();

        // if received a negative price the return amountOutMin = 0 to avoid swap 
        if (price < 0) return (0, 0);

        uint amountExpected = 0;

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

        uint minAmountAccepted = (10000 - slippageThereshold) * amountExpected / 10000;

        // receive from the swap an amount of tokens compatible with our max slippage
        amountOutMin = minAmountAccepted > amountOutMin ? minAmountAccepted : amountOutMin;
    }


    function swapInfo(string memory side, uint amountIn, uint amountOut) internal view returns (SwapInfo memory) {

        (   /*uint80 roundID**/, int price, /*uint startedAt*/,
            /*uint timeStamp*/, /*uint80 answeredInRound*/
        ) = riskAssetFeed.latestRoundData();

        // Record swap info
        SwapInfo memory info = SwapInfo({
            timestamp: block.timestamp,
            side: side,
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

    function setSwapMaxValue(uint value) public onlyOwner {
        swapMaxValue = value;
    }

    // Withdraw the given amount of LP token fees in deposit tokens
    function collectFees(uint amount) public onlyOwner {
        uint fees = amount == 0 ? lpToken.balanceOf(address(this)) : amount;
        if (fees > 0) {
            assert(lpToken.transfer(msg.sender, fees));
            _withdrawLP(fees);
        }
    }

}