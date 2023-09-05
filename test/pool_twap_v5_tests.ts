import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";

import { deployMockContract } from "@ethereum-waffle/mock-contract"
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromBtc, fromUsdc, toUsdc, toWbtc, transferFunds, waitDays, waitSeconds } from "./helpers"

import { deployPoolDiamondContractWithMocks } from './utils/diamond'

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";


import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import quoter_uniswap_abi from "./abi/quoter_uniswap.json"

describe("PoolV5", function () {

    describe("TWAP", function () {

		it("Large swaps are executed in chunks of the expected max size", async function () {
			const { pool, usdc, wbtc, usdcAggregatorMock, wbtcAggregatorMock } = await loadFixture(deployPoolDiamondContractWithMocks);
            const [ owner, addr1 ] = await ethers.getSigners();

            // BTC at $20k 
            await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);
            
            // $1000 max swap value
            const maxSwapSize = toUsdc(100) 
            await pool.connect(owner).setSwapMaxValue( maxSwapSize )

            const deposit1 = toUsdc(3000) 
            await transferFunds( deposit1, addr1.address)

            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const balance1 = await pool.deposits(addr1.address)
            expect( balance1 ).to.equal( deposit1 )


            expect( await pool.riskAssetValue() ).to.be.lessThanOrEqual( maxSwapSize )
            expect( await pool.riskAssetValue() ).to.be.greaterThan( maxSwapSize.div(2) )
            expect( await pool.totalValue() ).to.be.approximately(deposit1, 1)
		});
        

        it.only("Process the TWAP swap, chunk by chunk, to the max of 256 swaps", async function () {
			const { pool, strategy,usdcAggregatorMock, wbtcAggregatorMock } = await loadFixture(deployPoolDiamondContractWithMocks);
            const [ owner, user ] = await ethers.getSigners();

            const twapInterval = (await pool.twapSwapInterval()).toNumber()

            // BTC at $20k 
            await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);
            
            // set a very small max swap value of $10
            const maxSwapSize = toUsdc(10) 
            await pool.connect(owner).setSwapMaxValue( maxSwapSize )

            // send 10k USDC to the pool that will need to be swapped for WBTC
            const poolUsdc = toUsdc(10_000)
            await transferFunds(poolUsdc, pool.address, "usdc")
    
            await waitSeconds( 5 * 24 * 60 * 60)

            const [ upkeepNedded ] = await pool.checkUpkeep(new Int8Array())
			expect( upkeepNedded ).is.true

            expect( await strategy.shouldPerformUpkeep() ).is.true

            // expect total swap size to be $6000 (e.g. 60% of usdc in the pool)
            const amountToSell = poolUsdc.mul(60).div(100)

            // expect the full$ $6000 swap to be processed in 256 chunks of $23.4375
            const expectedTwapChunk = amountToSell.div(256) 

            // expectwd amount of BTC bought ar evey iteration
            const expectedBought = expectedTwapChunk.mul(10 ** 2).div(20_000)

            var prevSold = 0;

            for (let i=1; i <= 255; i++) {
                // execute twap swap and verify that a twap chunk was swapped
                await waitSeconds(twapInterval)

                const [ upkeepNedded ] = await pool.checkUpkeep(new Int8Array())
                expect( upkeepNedded ).is.true
                
                const tx = await pool.connect(user).performUpkeep(new Int8Array())
                const gasUsed = (await tx.wait()).gasUsed;
	            console.log(">> performUpkeep - gasUsed gas:", gasUsed.toString()) 

                // const swapInfo = await pool.twapSwaps()
                const [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()
     
                console.log(i, ">> swapped: ", sold.toString(), "/", total.toString() )

                expect( side ).is.equal(enums.ActionType.BUY)
                expect( total ).is.equal( amountToSell )
                expect( size ).is.equal( expectedTwapChunk )
                expect( prevSold ).is.lessThan( sold )

                prevSold = sold
                // expect( sold ).is.greaterThan( 0 )

                // if (i < 255) {
                //     console.log(">> ", i, "sold: ", sold.toString(), "expectedTwapChunk: ", expectedTwapChunk.toString() )
                //     expect( sold ).is.equal( expectedTwapChunk.mul(i) )
                //     expect( bought ).is.equal( expectedBought.mul(i) )
                // }
            }

            // execute last twap swap and verity the whole swap was completed 
            console.log(">> last swap... MATIC: ",  await ethers.provider.getBalance(owner.address) )

            await pool.connect(owner).performUpkeep(new Int8Array())
            // const swapInfo = await pool.twapSwaps()

            const [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()


            const boughtTotal = poolUsdc.mul(100).div(20_000)

            expect( size ).is.equal( expectedTwapChunk )
            expect( sold ).is.equal( amountToSell )
            expect( sold ).is.equal( total )
            expect( fromBtc(bought) ).is.approximately(fromBtc( boughtTotal ), 0.00001)
		}).timeout(600_000);



        it("Exec next TWAP swaps after the min time has elapsed", async function () {

            const { pool, usdc, usdcAggregatorMock, wbtcAggregatorMock } = await loadFixture(deployPoolDiamondContractWithMocks);
            const [ owner, addr1, addr2 ] = await ethers.getSigners();

            // BTC at $20k 
            await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);

            // limit swap size to $100
            await pool.connect(owner).setSwapMaxValue(100 * 10 ** 6)
            const twapInterval = (await pool.twapSwapInterval()).toNumber()
    
            // no twap ingfo before deposit
            let swapInfo = await pool.twapSwaps()
            const swapTs0 = swapInfo.lastSwapTimestamp
            expect( swapTs0 ).is.equal( 0 )

            // depoist should trigger the first twap swap
           
            const deposit = 10_000 * 10 ** 6
            await transferFunds(deposit, addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit)
            await pool.connect(addr1).deposit(deposit)

            var [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()
            // const ts1 = swapInfo.lastSwapTimestamp
            // const bought1 = swapInfo.bought
            // const sold1 = swapInfo.sold


            expect( lastSwapTimestamp ).is.greaterThan( 0 )
            expect( bought ).is.greaterThan( 0 )
            expect( sold ).is.greaterThan( 0 )

            // can't process the twap before the twap interval elapses 
            const [ upkeepNedded ] = await pool.checkUpkeep(new Int8Array())
            expect( upkeepNedded ).is.false


            // wait twap interval and verity that performUpkeep can run to process the twap
            await waitSeconds( twapInterval )
            expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true

            // perform upkeep
            await pool.connect(addr2).performUpkeep(new Int8Array())

            var [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()

            const ts2 = swapInfo.lastSwapTimestamp
            const bought2 = swapInfo.bought
            const sold2 = swapInfo.sold

            // verity twap info have been updated
            expect( ts2 ).is.greaterThan( ts1 )
            expect( bought2 ).is.greaterThan( bought1 )
            expect( bought2 ).is.greaterThan( bought1 )
            expect( sold2 ).is.greaterThan( sold1 )

            // verity twap can't execute yet
            await waitSeconds( twapInterval / 2 )
            expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.false

            // verity now can performUpkeep and process the twap
            await waitSeconds( twapInterval / 2 )
            expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true

            await pool.connect(user).performUpkeep(new Int8Array())
            swapInfo = await pool.twapSwaps()
            const ts3 = swapInfo.lastSwapTimestamp
            const bought3 = swapInfo.bought
            const sold3= swapInfo.sold

            // verity twap info have been updated
            expect( ts3 ).is.greaterThan( ts2 )
            expect( bought3 ).is.greaterThan( bought2 )
            expect( bought3 ).is.greaterThan( bought2 )
            expect( sold3 ).is.greaterThan( sold2 )
             
        })

    });

});