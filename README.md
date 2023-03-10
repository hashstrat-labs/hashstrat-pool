# HashStrat - Pools and Strategies

This repo contains the suite of Solidity smart contracts for the HashStrat Pools and Strategies.

- HashStrat pools hold a risk asset (e.g WETH or WBTC) and a stable asset (e.g USDC).
- Each pool is configured with a Strategy that is able to trade between the risk asset and the stable asset held in the pool.
- Users can deposit USDC into a pool. The pool's strategy will determine the inital portfolio allocation (e.g. the split between risk and stable asset) and will automatically manage the allocation over time, with the goal to capture volatility in the risk asset and manage risk.

Strategies use [Chainlink data feeds](https://docs.chain.link/docs/matic-addresses/) to assist their trading logic.  
[Chainlink Automation](https://docs.chain.link/chainlink-automation/introduction/) is used automate the strategy execution.

So far there are 3 strategies. More will be added in the future:
1. MeanReversionV1: DCA in and out the risk asset when its price deviates significantly from a long term moving average.
2. RebalancingV1: Ensures to rebalance the assets in the pool when their value moves above or below predetermined levels of the overall value of the pool.
3. TrendFollowV1: Allocates to the risk asset when its price moves above a short term moving average and sells into the stable asset when it moves below.
 

# Associated Repos 

- [Indexes](https://github.com/hashstrat-labs/hashstrat-index) - Smart contracts for HashStrat Indexes
- [DAO](https://github.com/hashstrat-labs/hashstrat-dao) - Smart contracts for the HashStrat DAO Token (HST), HST Farming Pool, etc.


# Instructions

### Requirements

1. Install NodeJS  (MacOS with brew). Recommended version: v18.14.0 
```bash
brew install node 
```

2. Install hardhat

```bash
npm install --save-dev hardhat
```

3. Install dependencies:

```bash
npm install
```


### Customize Environment vars:

Edit vars in `.env` file:

```bash
MNEMONIC="<12 memonic words here>"
RPC_URL_POLYGON_MAIN=="https://kovan.infura.io/v3/<infura_project_id here>"
POLYGONSCAN_API_KEY=="<etherscan api key here"
```


### Run Tests

```bash
npx hardhat test
# OR 
npm run test
```


### Deploy Contracts

Polygon:
```bash
npm run deploy:polygon
```


### Verify Contracts

Polygon:
```bash
npm run verify:matic
```


## HowTo use the Pool Contract (Polygon)

1. Approve Pool contract to spend USDC 
- call `approve` function on [USDC contract](https://polygonscan.com/token/0x2791bca1f2de4661ed88a30c99a7a9449aa84174#writeProxyContract) providing the pool address.

2. Deposit funds:
- call `deposit` function on pool contract and pass the amount of USDC tokens to deposit. 
- The account receives an amount LP tokens proportional to the percentage of the pool value deposited into the pool.

3. Withdraw funds:
- call `withdrawLP` function on pool contract providing the amount of LP tokens to withdraw.
- call `withdrawAll` function on pool contract to withdraw all LP tokens.
- Burns the LP tokens withrawn and sends the correspective value in USDC to the account.

4. Execute strategy:
Call the `performUpkeep` function on the pool contract. This will trigger the execution of the pool's strategy provided the `checkUpkeep` function returns true.
Alternatively wait for [Chainlink Automation](https://automation.chain.link/polygon) to trigger a strategy execution.
