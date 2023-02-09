import { expect } from "chai";


import { Contract } from "ethers"
import { ethers } from "hardhat";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromUsdc, fromBtc, waitDays, waitSeconds } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";

import { deployMockContract } from "ethereum-waffle"

import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import pool_abi from "./abi/pool.json"


describe("MeanReversionV1", function () {

	async function deployPoolContract() {

        const [ deployer ] = await ethers.getSigners();

        // Deploy Mocks
        const usdcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const wbtcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const poolMock = await deployMockContract(deployer, pool_abi);

        // Depoly Strategy
        const MeanReversionV1 = await ethers.getContractFactory("MeanReversionV1")

        const strategy = await MeanReversionV1.deploy(
            poolMock.address,
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
            addresses.polygon.usdc, // 6 decimals
            addresses.polygon.wbtc, // 8 decimals

            350,      // moving average period (movingAveragePeriod)
            25423 * (10 ** 8) ,  // initial MV value (initialMeanValue)
            20,       // minAllocationPerc
            66,       // targetPricePercUp
            33,       // targetPricePercDown
            5,        // tokensToSwapPerc
        ); 
        await strategy.deployed()

        await strategy.setUpkeepInterval(5 * 86400) // run every 5 days

		const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)
		const wbtc = new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)
     
        // prepare mocks
        await usdcAggregatorMock.mock.latestRoundData.returns( 0, 100000000, 1801686057, 1801686057, 0 ); 
        await usdcAggregatorMock.mock.decimals.returns( 8 ); 

        await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 2000000000000, 1801686057, 1801686057, 0 ); 
        await wbtcAggregatorMock.mock.decimals.returns( 8 ); 

		return { strategy, usdc, wbtc, usdcAggregatorMock, wbtcAggregatorMock, poolMock };
	}


	describe("exec()", async function () {

        it("Should rebalance to 80%/20% when the pool has 100%/0% allocation", async () => {
           
			const { strategy, poolMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(0);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);
    
            const [action, minAmountOut] = await strategy.callStatic.exec();
            expect( action ).to.equal( enums.ActionType.BUY ); // BUY $200 of BTC
            expect( fromUsdc(minAmountOut) ).to.be.equal( 200 );
        })

   
        it("Should rebalance to 20%/80% when pool has 0%/100% allocation", async () => {
			const { strategy, poolMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(1000 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(0);
    
            const [action, minAmountOut] = await strategy.callStatic.exec();
            const expectedAmount = 200 / 20_000

            expect( action ).to.equal( enums.ActionType.SELL ); // SELL $200 of BTC
            expect( fromBtc(minAmountOut) ).to.be.equal( expectedAmount );
        })
   

        it("Should SELL when price moves up more than 66% from the mean", async () => {
            const { strategy, poolMock, wbtc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(500 * 10 ** 6);

            const ma = await strategy.movingAverage()
            const targetPricePercUp = (await strategy.targetPricePercUp()).toNumber() / 100
            const sellLevel = Math.round( ma.toNumber() * (1 + targetPricePercUp)) + 1

            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, sellLevel, 1801686057, 1801686057, 0 ); 

            const [action, minAmountOut] = await strategy.callStatic.exec();

            expect( action ).to.equal( enums.ActionType.SELL );

            const expectedAmountSold = 0.05 * 500 * 10 ** 8 / sellLevel
            expect( fromBtc(minAmountOut) ).to.be.approximately( expectedAmountSold, 0.00000001 );

            const valueSold = fromBtc(minAmountOut) * sellLevel / 10 ** 8
            const expectedValueSold = 0.05 * 500
            expect( valueSold ).to.be.approximately( expectedValueSold, 0.1 );
        })

        it("Should BUY when price moves down more than 33% from the mean", async () => {
            const { strategy, poolMock, wbtc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);

            const ma = await strategy.movingAverage()
            const targetPricePercDown = (await strategy.targetPricePercDown()).toNumber() / 100
            const buyLevel = Math.round( ma.toNumber() * (1 - targetPricePercDown)) - 1

            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, buyLevel, 1801686057, 1801686057, 0 ); 

            const [action, minAmountOut] = await strategy.callStatic.exec();

            expect( action ).to.equal( enums.ActionType.BUY );

            const expectedAmountSold = 0.05 * 1000
            expect( fromUsdc(minAmountOut) ).to.be.approximately( expectedAmountSold, 0.00000001 );
        })


        it("Updates the lastEvalTimestamp when the strategy is executed", async () => {
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);

            const ma = await strategy.movingAverage()
            const targetPricePercDown = (await strategy.targetPricePercDown()).toNumber() / 100
            const buyLevel = Math.round( ma.toNumber() * (1 - targetPricePercDown)) - 1

            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, buyLevel, 1801686057, 1801686057, 0 ); 

            const ts0 = await strategy.lastEvalTimestamp()
            await strategy.exec();

            const ts1 = await strategy.lastEvalTimestamp()
            expect( ts1 ).to.be.greaterThan( ts0 );
        })

        it("Updates the movingAverage when the strategy is executed", async () => {
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);

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
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);

            const ma0 = await strategy.movingAverage()
            const interval = await strategy.upkeepInterval()

            // increase price to ensure strategy would trade 
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0,  2 * Math.round( ma0.toNumber()) , 1801686057, 1801686057, 0 )

            // verify a trade is needed
            const [action, amountIn] = await strategy.callStatic.exec()
            expect (action).to.equal( enums.ActionType.SELL )
            expect (amountIn).to.be.greaterThan( 0 )

            // verify upkeep in not needed yet
            await waitSeconds( interval.toNumber() - 60 )
            expect( await strategy.shouldPerformUpkeep() ).to.be.false
        })


        it("Returns true after the upkeep interval elapses and no swap is needed", async () => {

            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);

            const ma0 = await strategy.movingAverage()

            // a price change that would not trigger a swap
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 1.1 * Math.round( ma0.toNumber() ) , 1801686057, 1801686057, 0 )

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
            expect( ma1 ).to.be.greaterThan( ma0 )

            await waitDays(5)

            // verify strategy should execute even if no swap is needed to update its moving average
            expect( await strategy.shouldPerformUpkeep() ).to.be.true
            await strategy.exec()
            expect( await strategy.movingAverage() ).to.be.greaterThan( ma1 )
        })


        it("Returns true after the upkeep interval elapses and a swap is needed", async () => {

            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1500 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);

            const ma0 = await strategy.movingAverage()

            // increase price
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round( 1.69 * ma0.toNumber()) , 1801686057, 1801686057, 0 )

            // verify strategy does execute after 5 days
            await waitDays(5)
            expect( await strategy.shouldPerformUpkeep() ).to.be.true

            await strategy.exec();
            const ma1 = await strategy.movingAverage() 
            expect( ma1 ).to.be.greaterThan( ma0 )

            // increase price
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, Math.round( 1.69 * ma1.toNumber()) , 1801686057, 1801686057, 0 )

            await waitDays(5)
            expect( await strategy.shouldPerformUpkeep() ).to.be.true

            await strategy.exec();
            expect( await strategy.movingAverage() ).to.be.greaterThan( ma1 )
        })


    });


});