# HashStrat - Pools and Strategies

This repo contains the suite of Solidity smart contracts for HashStrat Pools and Strategies.

HashStrat Pools hold a risk asset (e.g WETH or WBTC) and a stable asset (e.g USDC or DAI).  
Each Pool is configured with a Strategy that is able to trade between the risk asset and the stable asset held in the Pool.  
Users can deposit stable assets into a Pool and let the strategies take care of the rest.

Strategies use [Chainlink data feeds](https://docs.chain.link/docs/matic-addresses/) to assist their trading logic.
[Chainlink Automation](https://docs.chain.link/chainlink-automation/introduction/) are used automate the strategy execution.

So far there are 3 strategies:
- MeanReversionV1: DCA in and out the risk asset when its price deviates significantly from a long term moving average.
- RebalancingV1: Ensures to rebalance the assets in the Pool when their value moves above or below predetermined levels of the overall value of the Pool.
- TrendFollowV1: Allocates to the risk asset when its price moves above a short term moving average and sells into the stable asset when it moves below.
 

# Associated Repos 

- [Indexes](https://github.com/hashstrat-labs/hashstrat-indexes) - Smart contracts for HashStrat Indexes
- [DAO](https://github.com/hashstrat-labs/hashstrat-dao) - Smart contracts for the HashStrat DAO Token (HST), HST Farming Pool, etc.


# Instructions

### Requirements

1. Install NodeJS (MacOS with brew) 

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

Kovan:
```bash
npm run verify:kovan  
```

Polygon:
```bash
npm run verify:matic
```


## HowTo use the Pool Contract (Polygon)

1. Approve Pool contract to spend USDC 
- call `approve` function on [USDC contract](https://polygonscan.com/token/0x2791bca1f2de4661ed88a30c99a7a9449aa84174#writeProxyContract) providing the Pool address.

2. Deposit funds:
- call `deposit` function on Pool contract and pass the amount of USDC tokens to deposit. 
- The account receives an amount LP tokens proportional to the percentage of the pool value deposited into the Pool.

3. Withdraw funds:
- call `withdrawLP` function on Pool contract providing the amount of LP tokens to withdraw.
- call `withdrawAll` function on Pool contract to withdraw all LP tokens.
- Burns the LP tokens withrawn and sends the correspective value in USDC to the account.

4. Execute strategy:
Call the `performUpkeep` function on the Pool contract. This will trigger the execution of the Pool's strategy provided the `checkUpkeep` function returns true.
Alternatively wait for [Chainlink Automation](https://automation.chain.link/polygon) to trigger a strategy execution.
