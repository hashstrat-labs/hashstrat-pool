


import { Contract, BigNumber } from "ethers"
import { ethers } from "hardhat";

import { fromBtc, fromUsdc, waitSeconds, transferFunds, waitDays } from "./helpers";

import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";

import erc20_abi from "../scripts/abis/erc20.json";
import pricefeed_aggregator_abi from "./abi/price_feed_aggreagator.json"
import { expect } from "chai";

const usdc_decimals = 6


async function deployPoolContract() {

	// 1. Deploy Pool LP token
	const PoolLPToken = await ethers.getContractFactory("PoolLPToken")
	const poolLPToken = await PoolLPToken.deploy("Pool LP Token", "PoolLP", 6)
	await poolLPToken.deployed()

	// 2. Depoly Strategy
	const TrendFollowV1 = await ethers.getContractFactory("TrendFollowV1")

	const strategy = await TrendFollowV1.deploy(
		'0x0000000000000000000000000000000000000000',// pool address not known yet
		addresses.polygon.usdc_usd_aggregator,
		addresses.polygon.wbtc_usd_aggregator,
		addresses.polygon.usdc, 
		addresses.polygon.wbtc, 
		40,      // moving average period (movingAveragePeriod)
		19952 * (10 ** 8) ,  // initial 50D SMA value (initialMeanValue)
	); 
	await strategy.deployed()
	await strategy.setUpkeepInterval(5 * 86400) // run every 5 days


	// 3. Deploy Router
	const SwapsRouter = await ethers.getContractFactory("SwapsRouter")
	const swapRouter = await SwapsRouter.deploy(
		addresses.polygon.uniswap_v3_quoter,
		addresses.polygon.quickswap_v3_quoter
	)
	await swapRouter.deployed(); 

	// 4. Deploy Pool
	const poolFees = 100        // 1% fee
	const uniswapV3Fee = 3000
	const swapMaxValue = 10_000 * 10 ** 6  // 10k per swap

	const PoolV4 = await ethers.getContractFactory("PoolV4")
	const pool = await PoolV4.deploy(
		swapRouter.address,
		addresses.polygon.usdc_usd_aggregator,
		addresses.polygon.wbtc_usd_aggregator,
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

	// Configure Router
	await swapRouter.addRouter( addresses.polygon.uniswap_v3_router, enums.RouterVersion.V3, enums.RouterType.Uniswap )
	await swapRouter.addRouter( addresses.polygon.quickswap_v3_router, enums.RouterVersion.V3, enums.RouterType.QuickSwap )
	await swapRouter.addRouter( addresses.polygon.quickswap_v2_router, enums.RouterVersion.V2, enums.RouterType.QuickSwap )
	await swapRouter.setActiveRouter(0)

	const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)
	const wbtc = new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)
	const wbtcFeed = new Contract(addresses.polygon.wbtc_usd_aggregator, pricefeed_aggregator_abi, ethers.provider)
 
	return { poolLPToken, swapRouter, strategy, pool, usdc, wbtc, wbtcFeed };
}



describe("TWAP ingtegration", function () {

	it.skip("Consumes the expected average gas amount per swap", async function () {

		const { pool, usdc } = await deployPoolContract()
		const [ _, addr1 ] = await ethers.getSigners();
		const twapInterval = (await pool.twapSwapInterval()).toNumber()

		// set high slippage to avoid hitting max slippage
		await pool.setSlippageThereshold(25 * 100) 

		await transferFunds(1_000_000 * 10 ** usdc_decimals, addr1.address)

		console.log("addr1 balance: ",  fromUsdc( await usdc.balanceOf(addr1.address) ))
	
		const balance = await usdc.balanceOf(addr1.address)
		await usdc.connect(addr1).approve(pool.address, balance)
		await pool.connect(addr1).deposit(balance)

		const iterations = 100
		let totalGasUsed = BigNumber.from(0)

		for (let i=0; i<iterations; i++) {
			await waitSeconds(twapInterval)
			expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true

			// exec strategy
			const tx = await pool.performUpkeep(new Int8Array())
			const gasUsed = (await tx.wait()).gasUsed;
			totalGasUsed = totalGasUsed.add(gasUsed)

			console.log("i: ", i, "gasUsed", gasUsed.toString())
		}

		const avgGasUsed = totalGasUsed.div(iterations).toNumber()
		console.log("avgGasUsed: ", avgGasUsed.toString(), "totalGasUsed", totalGasUsed.toString())

		expect( avgGasUsed ).to.lessThan( 400_000 )
		
	}).timeout(60_000);


	it.skip("Exec extremely large TWAP swaps until slippage is exceeded", async function () {

		const { pool, usdc } = await deployPoolContract()
		const twapInterval = (await pool.twapSwapInterval()).toNumber()

		const [ _, addr1 ] = await ethers.getSigners();
		await transferFunds(1_000_000 * 10 ** usdc_decimals, addr1.address)
		const balance = await usdc.balanceOf(addr1.address)

		await usdc.connect(addr1).approve(pool.address, balance)
		await pool.connect(addr1).deposit(balance)

		const MAX_SLIPPAGE = (await pool.slippageThereshold()).toNumber()

		let slippage = undefined
		let i=0;
		do {
			await waitSeconds(twapInterval)
			expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true

			// exec strategy
			const tx = await pool.performUpkeep(new Int8Array())
			const events = (await tx.wait()).events;
			const swapInfo = await pool.twapSwaps()
			expect( swapInfo.side ).is.equal(enums.ActionType.BUY)
			
			const swapEvents = events?.filter((x) => { return x.event === "Swapped" })
			const swapEvent = swapEvents && swapEvents![swapEvents.length-1]
			const sold = swapEvent?.args?.['sold']?.toNumber()
			const bought = swapEvent?.args?.['bought']?.toNumber()

			const slippageExceededEvents = events?.filter((x) => { return x.event === "MaxSlippageExceeded" })
			const slippageExceededEvent = slippageExceededEvents && slippageExceededEvents![slippageExceededEvents.length-1]
			slippage = slippageExceededEvent?.args?.['slippage']?.toNumber()
			
			const twapSwaps = await pool.twapSwaps()
			const remaining = twapSwaps.total.sub(twapSwaps.sold)
			console.log("-----", ++i, "iteration ---- sold: ", fromUsdc(sold), "bought: ", fromBtc(bought), " remaining: ", fromUsdc(remaining) )

			await waitSeconds( 10 * 60 )

		} while (slippage === undefined)

		expect( slippage >= MAX_SLIPPAGE ).to.be.true

	}).timeout(60_000);

	
	it.skip("Exec TWAP swaps until the full size is executed", async function () {

		const { pool, usdc, wbtc } = await deployPoolContract()

		// limit swap size to $1000
		await pool.setSwapMaxValue(100 * 10 ** 6)
		const twapInterval = (await pool.twapSwapInterval()).toNumber()

		const [ _, addr1 ] = await ethers.getSigners();
		const deposit = 29123 * 10 ** usdc_decimals
		await transferFunds(deposit, addr1.address)
	
		await usdc.connect(addr1).approve(pool.address, deposit)
		await pool.connect(addr1).deposit(deposit)

		let remaining = 0
		let i=0;
		
		do {
			await waitSeconds(twapInterval)
			expect( (await pool.checkUpkeep(new Int8Array())).upkeepNeeded ).is.true

			// exec strategy
			const tx = await pool.performUpkeep(new Int8Array())
			const gasUsed = (await tx.wait()).gasUsed;
			const events = (await tx.wait()).events;
			const swapInfo = await pool.twapSwaps()
			expect( swapInfo.side ).is.equal(enums.ActionType.BUY)
			
			const swapEvents = events?.filter((x) => { return x.event === "Swapped" })
			const swapEvent = swapEvents && swapEvents![swapEvents.length-1]
			const sold = swapEvent?.args?.['sold']?.toNumber()
			const bought = swapEvent?.args?.['bought']?.toNumber()

			const twapSwaps = await pool.twapSwaps()
			remaining = twapSwaps.total.sub(twapSwaps.sold).toNumber()

			console.log("-----", ++i, "swap ---- gas used : ", gasUsed.toString(), "sold: ", fromUsdc(sold), "bought: ", fromBtc(bought), " remaining: ", fromUsdc(remaining) )

			await waitSeconds( 10 * 60 )

		} while (remaining > 0)

		const swapInfo = await pool.twapSwaps()
		console.log(">>> TOTAL - sold: ", fromUsdc( swapInfo.sold ), "of", fromUsdc( swapInfo.total ), "==>",  Math.round (100 * swapInfo.sold.toNumber() / swapInfo.total.toNumber()), "%" )
		console.log("pool usdc balance: ", fromUsdc( await usdc.balanceOf(pool.address)))
		console.log("pool btc balance: ", fromBtc( await wbtc.balanceOf(pool.address)))
		console.log("pool value: ", fromUsdc( await pool.totalValue()))
		console.log("pool risk asset: ", fromUsdc( await pool.riskAssetValue()))
		console.log("pool stable asset: ", fromUsdc( await pool.stableAssetValue()))

		// verify swap has been fully processed
		expect (swapInfo.total.sub(swapInfo.sold).toNumber() ).to.be.equal( 0 )
		
		// verify upkeep is not needed
		const [upkpeedNeeded] = await pool.checkUpkeep(new Int8Array()) 
		expect( upkpeedNeeded ).is.false
		 
	}).timeout(60_000);

});

