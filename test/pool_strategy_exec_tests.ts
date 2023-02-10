import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";


import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { deployMockContract } from "ethereum-waffle"

import { fromBtc, fromUsdc, toUsdc, toWbtc, transferFunds, waitDays } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";

import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import quoter_uniswap_abi from "./abi/quoter_uniswap.json"


describe("PoolV4", function () {

    async function deployPoolContract() {

        const [deployer] = await ethers.getSigners();

        const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)
        const wbtc = new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)

        // Mocks
        const usdcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const wbtcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const quoterUniswapPMock = await deployMockContract(deployer, quoter_uniswap_abi);

        // Mock Router
        const UniswapV2RouterMock = await ethers.getContractFactory("UniswapV2RouterMock")
        const uniswapV2RouterMock = await UniswapV2RouterMock.deploy(
            addresses.polygon.usdc, 
            addresses.polygon.wbtc,
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
        )
        
        await uniswapV2RouterMock.deployed()

        await transferFunds(toUsdc('100000'), uniswapV2RouterMock.address, "usdc")
        await transferFunds(toWbtc('5'), uniswapV2RouterMock.address, "btc")

        // prepare mocks
        await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
        await usdcAggregatorMock.mock.decimals.returns(8);

        await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);
        await wbtcAggregatorMock.mock.decimals.returns(8);


        // 1. Deploy Pool LP token
        const PoolLPToken = await ethers.getContractFactory("PoolLPToken")
        const poolLPToken = await PoolLPToken.deploy("Pool LP Token", "PoolLP", 6)
        await poolLPToken.deployed()

        // 2. Depoly Strategy
        const RebalancingStrategyV1 = await ethers.getContractFactory("RebalancingStrategyV1")

        const strategy = await RebalancingStrategyV1.deploy(
            '0x0000000000000000000000000000000000000000',// pool address not known yet
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
            addresses.polygon.usdc,
            addresses.polygon.wbtc,
            60,   // target portfolio 60% WBTC / 40% USDC
            10,   // 10% seems a good rebalancing band that requires price to double or halve to rebalance
        );
        await strategy.deployed()


        // 3. Deploy Router
        const SwapsRouter = await ethers.getContractFactory("SwapsRouter")
        const swapRouter = await SwapsRouter.deploy(
            quoterUniswapPMock.address,
            addresses.polygon.quickswap_v3_quoter
        )
        await swapRouter.deployed();

        // 4. Deploy Pool
        const poolFees = 0        // 1% fee
        const uniswapV3Fee = 3000
        const swapMaxValue = 10_000 * 10 ** 6

        const PoolV4 = await ethers.getContractFactory("PoolV4")
        const pool = await PoolV4.deploy(
            swapRouter.address,
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
            addresses.polygon.usdc,
            addresses.polygon.wbtc,
            poolLPToken.address,
            strategy.address,
            poolFees,
            uniswapV3Fee,
            swapMaxValue
        )
        await pool.deployed()

        // Configure LP token
        await poolLPToken.addMinter(pool.address)

        // Configure strategy
        await strategy.setPool(pool.address)
        await strategy.transferOwnership(pool.address)

        // Configure SwapRouter
        await swapRouter.addRouter(uniswapV2RouterMock.address, enums.RouterVersion.V2, enums.RouterType.QuickSwap)
        await swapRouter.setActiveRouter(0)


        return {
            poolLPToken, swapRouter, strategy, pool, usdc, wbtc,
            usdcAggregatorMock, wbtcAggregatorMock, quoterUniswapPMock, uniswapV2RouterMock
        };
    }



    describe("checkUpkeep()", function () {

        it("returns true when the min eval interval has elapsed and strategy needs to BUY or SELL", async function () {

            const { pool, poolLPToken, usdc, wbtc, uniswapV2RouterMock, wbtcAggregatorMock, strategy } = await loadFixture(deployPoolContract);

            // Configure mock router with price and some liquidity
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);

            await transferFunds(toUsdc('20000'), pool.address, "usdc")
            await transferFunds(toWbtc('1'), pool.address, "btc")

            expect((await strategy.lastEvalTimestamp()).toNumber()).is.equal(0)

            // check if need to exec strategy
            const [upkeepNedded1] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded1).is.true

            // exec strategy
            await pool.performUpkeep(new Int8Array())

            const [upkeepNedded2] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded2).is.false

            // verify lastEvalTimestamp is updated 
            expect((await strategy.lastEvalTimestamp()).toNumber()).is.greaterThan(0)

            // unbalance the pool
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 4000000000000, 1801686057, 1801686057, 0);
            const [upkeepNedded3] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded3).is.false

            // verify pool is unbalanced
            const [action] = await strategy.eval()
            expect(action).is.equal(enums.ActionType.SELL)

            // verify no need to rebalance because the stratgy min eval inverval has not elapsed
            const [upkeepNedded4] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded4).is.false

            await waitDays(1)

            const [upkeepNedded5] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded5).is.true

        });

    });

    describe("performUpkeep()", function () {

        it("exec strategy when then min eval interval has elapsed and strategy needs to BUY or SELL", async function () {

            const { pool, uniswapV2RouterMock, wbtcAggregatorMock, strategy } = await loadFixture(deployPoolContract);

            // Configure mock router with price and some liquidity
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);

            await transferFunds(toUsdc('20000'), pool.address, "usdc")
            await transferFunds(toWbtc('1'), pool.address, "btc")

            // exec strategy
            await pool.performUpkeep(new Int8Array())

            // unbalance the pool
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 4000000000000, 1801686057, 1801686057, 0);

            const [upkeepNedded3] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded3).is.false

            // verify pool is unbalanced
            const [action, amountIn] = await strategy.eval()
            expect(action).is.equal(enums.ActionType.SELL)

            const lastEvalTimestamp0 = await strategy.lastEvalTimestamp()

            // exec strategy
            await pool.performUpkeep(new Int8Array())

            // verity the strategy was not exec because the min eval interval had not elapsed
            const [action1] = await strategy.eval()
            expect(action1).is.equal(enums.ActionType.SELL)

            // verify the strategy lastEvalTimestamp wasn't updated
            const lastEvalTimestamp1 = await strategy.lastEvalTimestamp()
            expect(lastEvalTimestamp0).is.equal(lastEvalTimestamp1)

            await waitDays(1)

            // exec the strategy after the min eval interval elapses
            await pool.performUpkeep(new Int8Array())

            // verify the pool has been rebalanced and the lastEvalTimestamp updated
            const [action2] = await strategy.eval()
            expect(action2).is.equal(enums.ActionType.NONE)

            const lastEvalTimestamp2 = await strategy.lastEvalTimestamp()
            expect(lastEvalTimestamp2).is.greaterThan(lastEvalTimestamp1)

        });

    });

});