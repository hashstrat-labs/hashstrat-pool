import { expect } from "chai";


import { Contract } from "ethers"
import { ethers } from "hardhat";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromUsdc, fromBtc, waitDays, waitSeconds } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";

import { deployMockContract } from "@ethereum-waffle/mock-contract"

import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import pool_abi from "./abi/pool.json"


describe("TrendFollowV1", function () {

	async function deployPoolContract() {

        const [ deployer ] = await ethers.getSigners();

        // Deploy Mocks
        const usdcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const wbtcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const usdcMock = await deployMockContract(deployer, erc20_abi);
        const wbtcMock = await deployMockContract(deployer, erc20_abi);
        const poolMock = await deployMockContract(deployer, pool_abi);

        // Depoly Strategy
        const TrendFollowV1 = await ethers.getContractFactory("TrendFollowV1")

        const strategy = await TrendFollowV1.deploy(
            poolMock.address,
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
            usdcMock.address, // 6 decimals
            wbtcMock.address, // 8 decimals

            40,      // moving average period (movingAveragePeriod)
            19952 * (10 ** 8) ,  // initial 50D SMA value (initialMeanValue)
        ); 
        await strategy.deployed()

        await strategy.setUpkeepInterval(5 * 86400) // run every 5 days


        // prepare mocks
        await usdcAggregatorMock.mock.latestRoundData.returns( 0, 100000000, 1801686057, 1801686057, 0 ); 
        await usdcAggregatorMock.mock.decimals.returns( 8 ); 

        await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 2000000000000, 1801686057, 1801686057, 0 ); 
        await wbtcAggregatorMock.mock.decimals.returns( 8 ); 

		return { strategy, usdcMock, wbtcMock, usdcAggregatorMock, wbtcAggregatorMock, poolMock };
	}


	describe("exec()", async function () {

        it("Should SELL when price moves below the mean", async () => {
            const { strategy, poolMock, wbtcMock, usdcMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 2000000000000, 1801686057, 1801686057, 0 ); 

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns(1000 / 20_000 * 10 ** 8) // 0.05 BTC in the pool
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 ) // 0.05 BTC in the pool

            const ma = await strategy.movingAverage()
            const sellLevel = Math.round(0.95 * ma.toNumber())
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, sellLevel, 1801686057, 1801686057, 0 ); 

            const [action, minAmountOut] = await strategy.callStatic.exec();

            expect( action ).to.equal( enums.ActionType.SELL );
            expect( fromBtc(minAmountOut) ).to.equal( 0.05 );

        })

        it("Should BUY when price moves down more than 33% from the mean", async () => {
            const { strategy, poolMock, wbtcMock, usdcMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 1500 * 10 ** 6 ) // 1500 USDC in the pool
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 ) // 0.05 BTC in the pool

            const ma = await strategy.movingAverage()
            const buyLevel = Math.round(1.1 * ma.toNumber())

            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, buyLevel, 1801686057, 1801686057, 0 ); 
            const [action, minAmountOut] = await strategy.callStatic.exec();

            expect( action ).to.equal( enums.ActionType.BUY );
            expect( fromUsdc(minAmountOut) ).to.equal( 1500 );
        })


        it("Updates the lastEvalTimestamp when the strategy is executed", async () => {
            const { strategy, poolMock, usdcMock, wbtcMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns( 0 ); 
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 ) 
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 )

            const ts0 = await strategy.lastEvalTimestamp()
            await strategy.exec();

            expect( await strategy.lastEvalTimestamp() ).to.be.greaterThan( ts0 );
        })


        it("Updates the movingAverage when the strategy is executed", async () => {
            const { strategy, poolMock, wbtcAggregatorMock, usdcMock, wbtcMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns( 0 ); 
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 ) 
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 )

            // price decreaase
            const ma0 = await strategy.movingAverage()
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round(0.5 * ma0.toNumber()), 1801686057, 1801686057, 0 ); 

            await waitDays(5)
            await strategy.exec();

            expect( await strategy.movingAverage() ).to.be.lessThan( ma0 );
        })

    });


    describe("shouldPerformUpkeep()", async function () {

        it("Returns false before the upkeep interval elapses", async () => {
            const { strategy, poolMock, wbtcAggregatorMock, usdcMock, wbtcMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns( 1500 * 10 ** 6 ); 
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 1500 * 10 ** 6 ) 
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 )

            const ma0 = await strategy.movingAverage()
            const interval = await strategy.upkeepInterval()

            // increase price to ensure strategy would trade 
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round( 1.1 * ma0.toNumber()) , 1801686057, 1801686057, 0 )

            // verify a trade is needed
            const [action, amountIn] = await strategy.callStatic.exec()
            expect (action).to.equal( enums.ActionType.BUY )
            expect (amountIn).to.be.greaterThan( 0 )

            // verify upkeep in not triggered yet
            await waitSeconds( interval.toNumber() - 60 )
            expect( await strategy.shouldPerformUpkeep() ).to.be.false
        })


        it("Returns true after the upkeep interval elapses and no swap is needed", async () => {

            const { strategy, poolMock, wbtcAggregatorMock, usdcMock, wbtcMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns( 1500 * 10 ** 6 ); 
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 1500 * 10 ** 6 ) 
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 )

            const ma0 = await strategy.movingAverage()

            // a price change that would not trigger a swap
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round( 0.9 * ma0.toNumber() ) , 1801686057, 1801686057, 0 )

            // verify no swap is needed
            const [action, amountIn] = await strategy.callStatic.exec()
            expect (action).to.equal( enums.ActionType.NONE )
            expect (amountIn).to.be.equal( 0 )
            await strategy.exec()

            await waitDays(5)

            // verify strategy should execute even if no swap is needed to update its moving average
            expect( await strategy.shouldPerformUpkeep() ).to.be.true
            await strategy.exec()

            const ma1 = await strategy.movingAverage() 
            expect( ma1 ).to.be.lessThan( ma0 )

            await waitDays(5)

            // verify strategy should execute even if no swap is needed to update its moving average
            expect( await strategy.shouldPerformUpkeep() ).to.be.true
            await strategy.exec()
            expect( await strategy.movingAverage() ).to.be.lessThan( ma1 )
        })


        it("Returns true after the upkeep interval elapses and a swap is needed", async () => {
            
            const { strategy, poolMock, wbtcAggregatorMock, usdcMock, wbtcMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns( 1500 * 10 ** 6 ); 
            await usdcMock.mock.balanceOf.withArgs(poolMock.address).returns( 1500 * 10 ** 6 ) 
            await wbtcMock.mock.balanceOf.withArgs(poolMock.address).returns( 0 )

            const ma0 = await strategy.movingAverage()

            // increase price
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round( 1.1 * ma0.toNumber()) , 1801686057, 1801686057, 0 )

            const [action, amountIn] = await strategy.callStatic.exec()
            expect (action).to.equal( enums.ActionType.BUY )

            // verify strategy does execute after 5 days
            await waitDays(5)
            expect( await strategy.shouldPerformUpkeep() ).to.be.true

            await strategy.exec();
            const ma1 = await strategy.movingAverage() 
            expect( ma1 ).to.be.greaterThan( ma0 )

            // increase price
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round( 1.1 * ma1.toNumber()) , 1801686057, 1801686057, 0 )

            await waitDays(5)
            expect( await strategy.shouldPerformUpkeep() ).to.be.true

            await strategy.exec();
            expect( await strategy.movingAverage() ).to.be.greaterThan( ma1 )
        })


    });


});