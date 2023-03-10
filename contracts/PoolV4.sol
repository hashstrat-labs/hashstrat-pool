// SPDX-License-Identifier: BUSL-1.1
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
 * The contract of the HashStrat Pool. A pool is a digital valult that holds:
 * - A risk asset (e.g WETH or WBTC), also called invest token.
 * - A stable asset (e.g USDC), also called depoist token.
 * Each pool is configured with:
 * - Chainlink price feeds for the risk and stable assets of the pool.
 * - A Strategy, that represent the rules about how to trade between the risk asset and the stable asset in the pool.
 * - A SwapsRouter, that will route the swaps performed by the strategy to the appropriate AMM.
 * - Addresses of the tokens used by the pool: the pool LP token, a deposit and a risk tokens.
 *
 * Users who deposit funds into a pool receive an amount LP tokens proportional to the value they provided.
 * Users withdraw their funds by returning their LP tokens to the pool, that get burnt.
 * A Pool can charge a fee to the profits withdrawn from the pool in the form of percentage of LP tokens that
 * will remain in the pool at the time when users withdraws their funds.
 * A pool automates the execution of its strategy and the executon of swaps using ChainLink Automation.
 * Large swaps are broken into up to 256 smaller chunks and executed over a period of time to reduce slippage.
 */

contract PoolV4 is
    IPoolV4,
    ReentrancyGuard,
    AutomationCompatibleInterface,
    Ownable
{
    using TokenMaths for uint256;

    enum UserOperation {
        DEPOSIT,
        WITHDRAWAL
    }

    struct SwapInfo {
        uint256 timestamp;
        string side;
        uint256 feedPrice;
        uint256 bought;
        uint256 sold;
        uint256 depositTokenBalance;
        uint256 investTokenBalance;
    }

    struct TWAPSwap {
        StrategyAction side;
        address tokenIn;
        address tokenOut;
        uint256 total; // the total amount of the tokenIn to spend (e.g. the total size of this twap swap)
        uint256 size; // the max size of each indivitual swap
        uint256 sold; // the cumulative amount of the tokenIn tokens spent
        uint256 bought; // the cumulative amount of the tokenOut tokens bought
        uint256 lastSwapTimestamp; // timestamp of the last attempted/executed swap
    }

    struct UserInfo {
        uint256 timestamp;
        UserOperation operation;
        uint256 amount;
    }

    uint256 public twapSwapInterval = 5 * 60; // 5 minutes between swaps
    uint8 public immutable feesPercDecimals = 4;
    uint256 public feesPerc; // using feePercDecimals precision (e.g 100 is 1%)

    IDAOTokenFarm public daoTokenFarm;

    // Pool tokens
    IERC20Metadata public immutable depositToken;
    IERC20Metadata public immutable investToken;
    PoolLPToken public immutable lpToken;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Swapped(string side, uint256 sold, uint256 bought, uint256 slippage);
    event SwapError(string reason);
    event InvalidAmount();
    event MaxSlippageExceeded(
        string side,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 slippage
    );

    uint256 public totalDeposited = 0;
    uint256 public totalWithdrawn = 0;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public withdrawals;
    mapping(address => UserInfo[]) public userInfos;

    address[] public users;
    mapping(address => bool) usersMap;

    // Chainlink price feeds
    AggregatorV3Interface public immutable riskAssetFeed;
    AggregatorV3Interface public immutable stableAssetFeed;

    ISwapsRouter public immutable swapRouter;
    IStrategy public strategy;

    // Swap data
    TWAPSwap public twapSwaps; // the pending swap
    SwapInfo[] public swaps; // logs of compteted swaps
    uint256 public slippageThereshold = 500; // allow for 5% slippage on swaps (aka should receive at least 95% of the expected token amount)

    uint24 public immutable feeV3;
    uint256 public swapMaxValue;

    constructor(
        address swapRouterAddress,
        address stableAssetFeedAddress,
        address riskAssetFeedAddress,
        address depositTokenAddress,
        address investTokenAddress,
        address lpTokenAddress,
        address strategyAddress,
        uint256 poolFees,
        uint24 uniswapV3Fee,
        uint256 swapValue
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

    //// External functions //// 

    function deposit(uint256 amount) external override nonReentrant {
        require(
            depositToken.allowance(msg.sender, address(this)) >= amount,
            "PoolV4: Insufficient allowance"
        );

        if (amount == 0) return;

        // portfolio allocation before the deposit
        uint256 investTokenPerc = investTokenPercentage();

        // 1. Transfer deposit amount to the pool
        bool transferred = depositToken.transferFrom(
            msg.sender,
            address(this),
            amount
        );
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
        uint256 depositLPTokens = lpTokensForDeposit(amount);

        if (lpToken.totalSupply() == 0) {
            // if the pool was empty before this deposit => exec the strategy once to ensure the initial asset allocation
            strategyExec();
        } else {
            // if the pool was not empty before this deposit => ensure the pool remains balanced with this deposit.
            // swap some of the deposit amount into investTokens to keep the pool balanced at current levels
            // uint investTokenPerc = investTokenPercentage();
            uint256 rebalanceAmountIn = (investTokenPerc * amount) /
                (10**uint256(portfolioPercentageDecimals()));
            uint256 amountOutMin = swapRouter.getAmountOutMin(
                address(depositToken),
                address(investToken),
                rebalanceAmountIn,
                feeV3
            );
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

    function withdrawAll() external nonReentrant {
        collectFeeAndWithdraw(lpToken.balanceOf(msg.sender));
    }

    function withdrawLP(uint256 amount) external nonReentrant {
        collectFeeAndWithdraw(amount);
    }

    // onlyOwner functions //

    function setSlippageThereshold(uint256 slippage) external onlyOwner {
        slippageThereshold = slippage;
    }

    function setStrategy(address strategyAddress) external onlyOwner {
        strategy = IStrategy(strategyAddress);
    }

    function setUpkeepInterval(uint256 innterval) external onlyOwner {
        strategy.setUpkeepInterval(innterval);
    }

    function setFeesPerc(uint256 _feesPerc) external onlyOwner {
        feesPerc = _feesPerc;
    }

    function setFarmAddress(address farmAddress) external onlyOwner {
        daoTokenFarm = IDAOTokenFarm(farmAddress);
    }

    function setSwapMaxValue(uint256 value) external onlyOwner {
        swapMaxValue = value;
    }

    function setTwapSwapInterval(uint256 interval) external onlyOwner {
        twapSwapInterval = interval;
    }

    // Withdraw the given amount of LP token fees in deposit tokens
    function collectFees(uint256 amount) external onlyOwner {
        uint256 fees = amount == 0 ? lpToken.balanceOf(address(this)) : amount;
        if (fees > 0) {
            assert(lpToken.transfer(msg.sender, fees));
            _withdrawLP(fees);
        }
    }

    /**
     *  Handle a pending swap, if there is one, othewise run the strategy.
     */
    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        if (
            twapSwaps.sold < twapSwaps.total &&
            (block.timestamp >= twapSwaps.lastSwapTimestamp + twapSwapInterval)
        ) {
            handleTwapSwap();
        } else if (strategy.shouldPerformUpkeep()) {
            strategyExec();
        }
    }


    // External view functions //

    /**
     * Perfor upkeep if:
     *  1. The current twap swap was fully executed AND enough time has elapsed since the last time the twap swap was processed
     *  2. The strategy should run
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        return (
            (twapSwaps.sold < twapSwaps.total &&
                (block.timestamp >=
                    twapSwaps.lastSwapTimestamp + twapSwapInterval)) ||
                strategy.shouldPerformUpkeep(),
            ""
        );
    }

    function getSwapsInfo() external view returns (SwapInfo[] memory) {
        return swaps;
    }

    function getUsers() external view returns (address[] memory) {
        return users;
    }

    function getUserInfos(address account)
        external
        view
        returns (UserInfo[] memory)
    {
        return userInfos[account];
    }


    // Return the value of the assets for the account (in USD)
    function portfolioValue(address account) external view returns (uint256) {
        // the value of the portfolio allocated to the user, espressed in deposit tokens
        uint256 precision = 10**uint256(portfolioPercentageDecimals());
        return (totalValue() * portfolioPercentage(account)) / precision;
    }


    //// Public view functions ////

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

    function feesForWithdraw(uint256 lpToWithdraw, address account)
        public
        view
        returns (uint256)
    {
        return
            (feesPerc * gainsPerc(account) * lpToWithdraw) /
            (10**(2 * uint256(feesPercDecimals)));
    }

    /**
     * @param account used to determine the percentage of gains
     * @return the percentage percentage for the account provided using 'feesPercDecimals' decimals
     */
    function gainsPerc(address account) public view returns (uint256) {
        // if the address has no deposits (e.g. LPs were transferred from original depositor)
        // then consider the entire LP value as gains.
        // This is to prevent tax avoidance by withdrawing the LPs to different addresses
        if (deposits[account] == 0) return 10**uint256(feesPercDecimals); // 100% gains

        // take into account for staked LP when calculating the value held in the pool
        uint256 stakedLP = address(daoTokenFarm) != address(0)
            ? daoTokenFarm.getStakedBalance(account, address(lpToken))
            : 0;
        uint256 valueInPool = lpTokensValue(
            lpToken.balanceOf(account) + stakedLP
        );

        // check if accounts is in profit
        bool hasGains = withdrawals[account] + valueInPool > deposits[account];

        // return the fees on the gains or 0 if there are no gains
        return
            hasGains
                ? (10**uint256(feesPercDecimals) *
                    (withdrawals[account] + valueInPool - deposits[account])) /
                    deposits[account]
                : 0;
    }

    // Return the value of the given amount of LP tokens (in USD)
    function lpTokensValue(uint256 amount) public view returns (uint256) {
        return
            lpToken.totalSupply() > 0
                ? (totalValue() * amount) / lpToken.totalSupply()
                : 0;
    }

    // Return the % of the pool owned by 'account' with the precision of the risk asset price feed decimals
    function portfolioPercentage(address account)
        public
        view
        returns (uint256)
    {
        if (lpToken.totalSupply() == 0) return 0;

        return
            (10**uint256(portfolioPercentageDecimals()) *
                lpToken.balanceOf(account)) / lpToken.totalSupply();
    }

    // Return the pool total value in USD
    function totalValue() public view override returns (uint256) {
        return stableAssetValue() + riskAssetValue();
    }

    /**
     * @return value of the stable assets in the pool (in USD)
     */
    function stableAssetValue() public view override returns (uint256) {
        (
            ,
            /*uint80 roundID**/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = stableAssetFeed.latestRoundData();

        if (price <= 0) return 0;

        uint256 value = depositToken.balanceOf(address(this)).mul(
            uint256(price),
            depositToken.decimals(),
            stableAssetFeed.decimals(),
            depositToken.decimals()
        );

        return value;
    }

    /**
     * @return value of the risk assets in the pool (in USD)
     */
    function riskAssetValue() public view override returns (uint256) {
        (
            ,
            /*uint80 roundID**/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = riskAssetFeed.latestRoundData();
        if (price <= 0) return 0;

        uint256 value = investToken.balanceOf(address(this)).mul(
            uint256(price),
            investToken.decimals(),
            riskAssetFeed.decimals(),
            depositToken.decimals()
        );

        return value;
    }


    //// Internal Functions //// 

    function investTokenPercentage() internal view returns (uint256) {
        return
            (lpToken.totalSupply() == 0)
                ? 0
                : (10**uint256(portfolioPercentageDecimals()) *
                    riskAssetValue()) / totalValue();
    }

    function portfolioPercentageDecimals() internal view returns (uint8) {
        return riskAssetFeed.decimals();
    }


    // calculate the LP tokens for a deposit of 'amount' tokens after the deposit tokens have been transferred into the pool
    function lpTokensForDeposit(uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint256 depositLPTokens;
        if (lpToken.totalSupply() == 0) {
            /// If pool is empty  => allocate the inital LP tokens amount to the user
            depositLPTokens = amount;
        } else {
            ///// if there are already LP tokens => calculate the additional LP tokens for this deposit
            // calculate portfolio % of the deposit (using lpPrecision digits precision)
            uint256 lpPrecision = 10**uint256(lpToken.decimals());
            uint256 portFolioPercentage = (lpPrecision * amount) / totalValue();

            // calculate the amount of LP tokens for the deposit so that they represent
            // a % of the existing LP tokens equivalent to the % value of this deposit to the whole portfolio value.
            //
            // X := P * T / (1 - P)
            //      X: additinal LP toleks to allocate to the user to account for this deposit
            //      P: Percentage of portfolio accounted by this deposit
            //      T: total LP tokens allocated before this deposit

            depositLPTokens =
                (portFolioPercentage * lpToken.totalSupply()) /
                ((1 * lpPrecision) - portFolioPercentage);
        }

        return depositLPTokens;
    }


    /**
     * @notice Withdraw 'amount' of LP tokens from the pool and receive the equivalent amount of deposit tokens
     *         If fees are due, those are deducted from the LP amount before processing the withdraw.
     *
     * @param amount the amount of LP tokent to withdraw
     */
    function collectFeeAndWithdraw(uint256 amount) internal {
        uint256 fees = feesForWithdraw(amount, msg.sender);
        uint256 netAmount = amount - fees;

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
    function _withdrawLP(uint256 amount) internal {
        if (amount == 0) return;

        require(amount <= lpToken.balanceOf(msg.sender), "LP balance exceeded");

        uint256 precision = 10**uint256(portfolioPercentageDecimals());
        uint256 withdrawPerc = (precision * amount) / lpToken.totalSupply();

        // 1. Calculate amount of depositTokens & investTokens to withdraw
        uint256 depositTokensBeforeSwap = depositToken.balanceOf(address(this));
        uint256 investTokensBeforeSwap = investToken.balanceOf(address(this));
        //  if these are the last LP being withdrawn ensure no leftovers tokens in the pool due to dounding errors
        bool isWithdrawingAll = (amount == lpToken.totalSupply());
        uint256 withdrawDepositTokensAmount = isWithdrawingAll
            ? depositTokensBeforeSwap
            : (depositTokensBeforeSwap * withdrawPerc) / precision;
        uint256 withdrawInvestTokensTokensAmount = isWithdrawingAll
            ? investTokensBeforeSwap
            : (investTokensBeforeSwap * withdrawPerc) / precision;

        // 2. burn the user's LP tokens
        lpToken.burn(msg.sender, amount);

        // 3. swap some invest tokens back into deposit tokens
        uint256 amountOutMin = swapRouter.getAmountOutMin(
            address(investToken),
            address(depositToken),
            withdrawInvestTokensTokensAmount,
            feeV3
        );
        uint256 depositTokensReceived = swap(
            address(investToken),
            address(depositToken),
            withdrawInvestTokensTokensAmount,
            amountOutMin,
            address(this)
        );

        // 4. transfer depositTokens to the user
        uint256 amountToWithdraw = withdrawDepositTokensAmount +
            depositTokensReceived;

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


    // STRATEGY EXECUTION //

    function handleTwapSwap() internal {
        // determine swap size avoiding very small change that would not be possible to swap
        uint256 size = (twapSwaps.total > twapSwaps.sold + (2 * twapSwaps.size))
            ? twapSwaps.size
            : (twapSwaps.total > twapSwaps.sold)
            ? twapSwaps.total - twapSwaps.sold
            : 0;

        if (size > 0) {
            (
                uint256 sold,
                uint256 bought,
                uint256 slippage
            ) = swapIfNotExcessiveSlippage(twapSwaps, size);

            twapSwaps.lastSwapTimestamp = block.timestamp;
            string memory side = (twapSwaps.side == StrategyAction.BUY)
                ? "BUY"
                : (twapSwaps.side == StrategyAction.SELL)
                ? "SELL"
                : "NONE";

            if (sold > 0 && bought > 0) {
                twapSwaps.sold += sold;
                twapSwaps.bought += bought;
                if (twapSwaps.sold == twapSwaps.total) {
                    // log that the twap swap has been fully executed
                    SwapInfo memory info = swapInfo(
                        side,
                        twapSwaps.sold,
                        twapSwaps.bought
                    );
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
        (StrategyAction action, uint256 amountIn) = strategy.exec();

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

            (
                ,
                /*uint80 roundID**/
                int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
                ,
                ,

            ) = feed.latestRoundData();
            require(price > 0, "PoolV4: negative price");
            twapSwaps = twapSwapsInfo(
                action,
                tokenIn,
                tokenOut,
                amountIn,
                uint256(price),
                feed.decimals()
            );

            handleTwapSwap();
        }
    }

    // Swap Execution //

    /**
     * @notice uses SwapsRouter to performa a single swap 'amountOutMin' of tokenIn into tokenOut.
     *          It does not check slippage and it's not expected to revert
     * @return amountOut the amount received from the swap
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipent
    ) internal returns (uint256 amountOut) {
        if (amountIn > 0 && amountOutMin > 0) {
            IERC20Metadata token = tokenIn == address(depositToken)
                ? depositToken
                : investToken;
            token.approve(address(swapRouter), amountIn);
            try
                swapRouter.swap(
                    tokenIn,
                    tokenOut,
                    amountIn,
                    amountOutMin,
                    recipent,
                    feeV3
                )
            returns (uint256 received) {
                amountOut = received;
            } catch Error(string memory reason) {
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
    function twapSwapsInfo(
        StrategyAction side,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 price,
        uint8 feedDecimals
    ) internal view returns (TWAPSwap memory) {
        IERC20Metadata token = tokenIn == address(depositToken)
            ? depositToken
            : investToken;

        uint256 swapValue = amountIn.mul(
            uint256(price),
            token.decimals(),
            feedDecimals,
            depositToken.decimals()
        );

        // if the value of the swap is less than swapMaxValue than we can swap in one go.
        // otherwise break the swap into chunks.
        if (swapValue <= swapMaxValue)
            return
                TWAPSwap({
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
        uint256 size = amountIn;
        uint8 i = 0;
        do {
            size /= 2;
            swapValue /= 2;
        } while (++i < 8 && swapValue > swapMaxValue);

        return
            TWAPSwap({
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
    function swapIfNotExcessiveSlippage(
        TWAPSwap memory pendingSwap,
        uint256 size
    )
        internal
        returns (
            uint256 sold,
            uint256 bought,
            uint256 slppgg
        )
    {
        // ensure max slippage is not exceeded
        (uint256 amountOutMin, uint256 slippage) = slippagePercentage(
            pendingSwap.tokenIn,
            pendingSwap.tokenOut,
            size
        );

        if (slippage > slippageThereshold) {
            string memory side = (pendingSwap.side == StrategyAction.BUY)
                ? "BUY"
                : (pendingSwap.side == StrategyAction.SELL)
                ? "SELL"
                : "NONE";
            emit MaxSlippageExceeded(side, size, amountOutMin, slippage);

            return (0, 0, slippage);
        }

        if (amountOutMin == 0) {
            emit InvalidAmount();
            return (0, 0, slippage);
        }

        uint256 depositTokenBalanceBefore = depositToken.balanceOf(
            address(this)
        );
        uint256 investTokenBalanceBefore = investToken.balanceOf(address(this));

        // perform swap required to rebalance the portfolio
        swap(
            pendingSwap.tokenIn,
            pendingSwap.tokenOut,
            size,
            amountOutMin,
            address(this)
        );

        // token balances after swap
        uint256 depositTokenBalanceAfter = depositToken.balanceOf(
            address(this)
        );
        uint256 investTokenBalanceAfter = investToken.balanceOf(address(this));

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
    function slippagePercentage(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOutMin, uint256 slippage) {
        (
            ,
            /*uint80 roundID**/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = riskAssetFeed.latestRoundData();

        // if received a negative price the return amountOutMin = 0 to avoid swap
        if (price < 0) return (0, 0);

        uint256 amountExpected = 0;

        // swap USD => ETH
        if (
            tokenIn == address(depositToken) && tokenOut == address(investToken)
        ) {
            amountExpected = amountIn.div(
                uint256(price),
                depositToken.decimals(),
                riskAssetFeed.decimals(),
                investToken.decimals()
            ); // return value is in ETH (invest token decimals)
        }

        // swap ETH => USD
        if (
            tokenIn == address(investToken) && tokenOut == address(depositToken)
        ) {
            amountExpected = amountIn.mul(
                uint256(price),
                investToken.decimals(),
                riskAssetFeed.decimals(),
                depositToken.decimals()
            ); // return value is in USD (deposit token decimals)
        }

        amountOutMin = swapRouter.getAmountOutMin(
            tokenIn,
            tokenOut,
            amountIn,
            feeV3
        );

        if (amountOutMin >= amountExpected) return (amountOutMin, 0);

        slippage = 10000 - ((10000 * amountOutMin) / amountExpected); // e.g 10000 - 9500 = 500  (5% slippage) - min slipage: 1 = 0.01%

        uint256 minAmountAccepted = ((10000 - slippageThereshold) *
            amountExpected) / 10000;

        // receive from the swap an amount of tokens compatible with our max slippage
        amountOutMin = minAmountAccepted > amountOutMin
            ? minAmountAccepted
            : amountOutMin;
    }

    function swapInfo(
        string memory side,
        uint256 amountIn,
        uint256 amountOut
    ) internal view returns (SwapInfo memory) {
        (
            ,
            /*uint80 roundID**/
            int256 price, /*uint startedAt*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = /*uint timeStamp*/
            riskAssetFeed.latestRoundData();

        // Record swap info
        SwapInfo memory info = SwapInfo({
            timestamp: block.timestamp,
            side: side,
            feedPrice: uint256(price),
            bought: amountOut,
            sold: amountIn,
            depositTokenBalance: depositToken.balanceOf(address(this)),
            investTokenBalance: investToken.balanceOf(address(this))
        });

        return info;
    }

}
