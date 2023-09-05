import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";

import { deployMockContract } from "@ethereum-waffle/mock-contract"
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromBtc, fromUsdc, toUsdc, toWbtc, transferFunds, waitDays, waitSeconds } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";


import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import quoter_uniswap_abi from "./abi/quoter_uniswap.json"

describe("PoolV4", function () {

	// const max_supply = ethers.utils.parseEther('1000000.0');   // 1M tokens

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
            wbtcAggregatorMock.address
        )

        await uniswapV2RouterMock.deployed()

        await transferFunds(toUsdc('100000'), uniswapV2RouterMock.address, "usdc")
        await transferFunds(toWbtc('5'), uniswapV2RouterMock.address, "btc")

        // prepare mocks
        await usdcAggregatorMock.mock.decimals.returns(8);
        await wbtcAggregatorMock.mock.decimals.returns(8);

        // 1. Deploy Pool LP token
        const PoolLPToken = await ethers.getContractFactory("PoolLPToken")
        const poolLPToken = await PoolLPToken.deploy("Pool LP Token", "PoolLP", 6)
        await poolLPToken.deployed()

        // 2. Depoly Strategy
        const TrendFollowV1 = await ethers.getContractFactory("TrendFollowV1")

        const strategy = await TrendFollowV1.deploy(
            '0x0000000000000000000000000000000000000000',
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
            usdc.address, // 6 decimals
            wbtc.address, // 8 decimals

            40,      // moving average period (movingAveragePeriod)
            19952 * (10 ** 8) ,  // initial 50D SMA value (initialMeanValue)
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


    describe("TWAP", function () {

		it("Large swaps are executed in chunks of the expected max size", async function () {
			const { pool, usdc, wbtc, usdcAggregatorMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            // BTC at $20k 
            await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);
            
            const [ _, addr1 ] = await ethers.getSigners();

            // $1000 max swap value
            const maxSwapSize = toUsdc(100) 
            await pool.setSwapMaxValue( maxSwapSize )

            const deposit1 = toUsdc(3000) 
            await transferFunds( deposit1, addr1.address)

            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const balance1 = await pool.deposits(addr1.address)
            expect( balance1 ).to.equal( deposit1 )

            const poolUsdc = await usdc.balanceOf(pool.address)
            const poolBtc = await wbtc.balanceOf(pool.address)
            

            expect( await pool.riskAssetValue() ).to.be.lessThanOrEqual( maxSwapSize )
            expect( await pool.riskAssetValue() ).to.be.greaterThan( maxSwapSize.div(2) )
            expect( await pool.totalValue() ).to.be.approximately(deposit1, 1)

		});
        

        it.only("Process the TWAP swap, chunk by chunk, to the max of 256 swaps", async function () {
			const { pool, strategy,usdcAggregatorMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ _, user ] = await ethers.getSigners();

            const twapInterval = (await pool.twapSwapInterval()).toNumber()

            // BTC at $20k 
            await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);
            
            // set a very small max swap value of $10
            const maxSwapSize = toUsdc(10) 
            await pool.setSwapMaxValue( maxSwapSize )

            // send 10k USDC to the pool that will need to be swapped for WBTC
            const poolUsdc = toUsdc(10_000)
            await transferFunds(poolUsdc, pool.address, "usdc")
    
            await waitSeconds( 5 * 24 * 60 * 60 )

            expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true
            expect( await strategy.shouldPerformUpkeep() ).is.true

            // expeced size of twap swap processed is 1/256 of the original size 10_000
            const expectedTwapChunk = poolUsdc.div(256) 
            // expectwd amount of BTC bought ar evey iteration
            const expectedBought = expectedTwapChunk.mul(10 ** 2).div(20_000)

            for (let i=1; i <= 255; i++) {
                // execute twap swap and verify that a twap chunk was swapped
                await waitSeconds(twapInterval)
                expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true
                
                // await pool.connect(user).performUpkeep(new Int8Array())
                const tx = await pool.connect(user).performUpkeep(new Int8Array())
                const gasUsed = (await tx.wait()).gasUsed
                const swapInfo = await pool.twapSwaps()
                console.log(i, ">> performUpkeep - gasUsed gas:", gasUsed.toString(), ", sold:" , swapInfo.sold.toString() ) 

                expect( swapInfo.side ).is.equal(enums.ActionType.BUY)
                expect( swapInfo.total ).is.equal( poolUsdc )
                expect( swapInfo.size ).is.equal( expectedTwapChunk )
                if (i < 255) {
                    expect( swapInfo.sold ).is.equal( expectedTwapChunk.mul(i) )
                    expect( swapInfo.bought ).is.equal( expectedBought.mul(i) )
                }
            }

            // execute last twap swap and verity the whole swap was completed 
            await pool.connect(user).performUpkeep(new Int8Array())
            const swapInfo = await pool.twapSwaps()
            const expectedBtcBought = poolUsdc.mul(100).div(20_000)

            expect( swapInfo.size ).is.equal( expectedTwapChunk )
            expect( swapInfo.sold ).is.equal( poolUsdc )
            expect( swapInfo.sold ).is.equal( swapInfo.total )
            expect( fromBtc(swapInfo.bought) ).is.approximately(fromBtc( expectedBtcBought ), 0.00001)
		});



        it("Exec next TWAP swaps after the min time has elapsed", async function () {

            const { pool, usdc, usdcAggregatorMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ _, addr1, addr2 ] = await ethers.getSigners();

            // BTC at $20k 
            await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
            await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);

            // limit swap size to $100
            await pool.setSwapMaxValue(100 * 10 ** 6)
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

            swapInfo = await pool.twapSwaps()
            const ts1 = swapInfo.lastSwapTimestamp
            const bought1 = swapInfo.bought
            const sold1 = swapInfo.sold

            expect( ts1 ).is.greaterThan( 0 )
            expect( bought1 ).is.greaterThan( 0 )
            expect( sold1 ).is.greaterThan( 0 )

            // can't process the twap before the twap interval elapses 
            expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.false

            // wait twap interval and verity that performUpkeep can run to process the twap
            await waitSeconds( twapInterval )
            expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true

            // perform upkeep
            await pool.connect(addr2).performUpkeep(new Int8Array())
            swapInfo = await pool.twapSwaps()
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