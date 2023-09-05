import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";


import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { deployPoolDiamondContractWithMocks } from './utils/diamond'
import { toUsdc, toWbtc, transferFunds, waitDays } from "./helpers"

import enums from "../conf/enums.json";


describe("PoolV5", function () {

    describe("checkUpkeep()", function () {

        it("returns true when the min eval interval has elapsed and strategy needs to BUY or SELL", async function () {

            const { pool, wbtcAggregatorMock, strategy } = await loadFixture(deployPoolDiamondContractWithMocks);

            const [_, user] = await ethers.getSigners();

            // Configure mock router with price and some liquidity
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);

            await transferFunds(toUsdc('20000'), pool.address, "usdc")
            await transferFunds(toWbtc('1'), pool.address, "btc")

            expect((await strategy.lastEvalTimestamp()).toNumber()).is.equal(0)

            // check if need to exec strategy
            const [upkeepNedded1] = await pool.checkUpkeep(new Int8Array())

            console.log("upkeepNedded1: ", upkeepNedded1)
            expect(upkeepNedded1).is.true

            // exec strategy
            await pool.connect(user).performUpkeep(new Int8Array())

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

            const { pool, wbtcAggregatorMock, strategy } = await loadFixture(deployPoolDiamondContractWithMocks);
            const [_, user] = await ethers.getSigners();

            // Configure mock router with price and some liquidity
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);

            await transferFunds(toUsdc('20000'), pool.address, "usdc")
            await transferFunds(toWbtc('1'), pool.address, "btc")

            // exec strategy
            await pool.connect(user).performUpkeep(new Int8Array())

            // unbalance the pool
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 4000000000000, 1801686057, 1801686057, 0);

            const [upkeepNedded3] = await pool.checkUpkeep(new Int8Array())
            expect(upkeepNedded3).is.false

            // verify pool is unbalanced
            const [action, amountIn] = await strategy.eval()
            expect(action).is.equal(enums.ActionType.SELL)

            const lastEvalTimestamp0 = await strategy.lastEvalTimestamp()

            // exec strategy
            await pool.connect(user).performUpkeep(new Int8Array())

            // verity the strategy was not exec because the min eval interval had not elapsed
            const [action1] = await strategy.eval()
            expect(action1).is.equal(enums.ActionType.SELL)

            // verify the strategy lastEvalTimestamp wasn't updated
            const lastEvalTimestamp1 = await strategy.lastEvalTimestamp()
            expect(lastEvalTimestamp0).is.equal(lastEvalTimestamp1)

            await waitDays(1)

            // exec the strategy after the min eval interval elapses
            await pool.connect(user).performUpkeep(new Int8Array())

            // verify the pool has been rebalanced and the lastEvalTimestamp updated
            const [action2] = await strategy.eval()
            expect(action2).is.equal(enums.ActionType.NONE)

            const lastEvalTimestamp2 = await strategy.lastEvalTimestamp()
            expect(lastEvalTimestamp2).is.greaterThan(lastEvalTimestamp1)

        });

    });

});