


import { Contract, BigNumber } from "ethers"
import { ethers } from "hardhat";

import { fromBtc, fromUsdc, waitSeconds, transferFunds } from "./helpers";

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



describe("TWAP processing gas", function () {

	it.only("Exec TWAP swaps until untill slippage is exceeded or full size is executed", async function () {

		const { pool, usdc, wbtc, wbtcFeed } = await deployPoolContract()

		const [ owner, addr1 ] = await ethers.getSigners();
		await transferFunds(1_000_000 * 10 ** usdc_decimals, addr1.address)
	
		const balance = await usdc.balanceOf(addr1.address)
		console.log("addr1 balance: ", fromUsdc(balance))

		// $2m deposit 
		await usdc.connect(addr1).approve(pool.address, balance)
		const tx = await pool.connect(addr1).deposit(balance)
		const gasUsed = (await tx.wait()).gasUsed;
		console.log("deposit: ", fromUsdc(balance)), ", balance: ", fromUsdc( await usdc.balanceOf(addr1.address) )
		console.log("deposit gasUsed: ", gasUsed.toString())

		
		let totaGasUsed = BigNumber.from(0)
		let upkeepNedded5 = false
		let swapped = 0
		let i=0;
		do {
			[upkeepNedded5] = await pool.checkUpkeep(new Int8Array())
			console.log("checkUpkeep: ", upkeepNedded5)

			if (upkeepNedded5) {
				i++

				// exec strategy
				const tx = await pool.performUpkeep(new Int8Array())
				const gasUsed = (await tx.wait()).gasUsed;
				const events = (await tx.wait()).events;
				totaGasUsed = totaGasUsed.add(gasUsed)

				const swapInfo = await pool.twapSwaps()
				expect( swapInfo.side ).is.equal(enums.ActionType.BUY)
				const swapEvents = events?.filter((x) => { return x.event === "Swapped" })
				const swapError = events?.filter((x) => { return x.event === "SwapError" })

				const error = swapError && swapError.length > 0 ? swapError?.[0] : ''
				console.log("error: ",  error )

				const swapEvent = swapEvents && swapEvents![swapEvents.length-1]
				swapped = swapEvent?.args?.['spent']?.toNumber()

			

				console.log("-----", i, "iteration ---- gasUsed ", gasUsed.toString(), "swapped: ", swapped )
				console.log( "swap size: ", fromUsdc( swapInfo.size ), "USDC" ,"- processed: ", Math.round (10000 * swapInfo.sold.toNumber() / swapInfo.total.toNumber()) / 100, "%" )

				console.log("usdc balance: ", fromUsdc( await usdc.balanceOf(pool.address)))
				console.log("btc balance: ", fromBtc( await wbtc.balanceOf(pool.address)))
				console.log("pool value: ", fromUsdc( await pool.totalValue()))
				console.log("risk assets: ", fromUsdc( await pool.riskAssetValue()))
				console.log("stable assets: ", fromUsdc( await pool.stableAssetValue()))
			}

			await waitSeconds( 10 * 60 )

		} while (upkeepNedded5 && swapped > 0) 

		const swapInfo = await pool.twapSwaps()
		console.log(">>> SWAP - sold: ", fromUsdc( swapInfo.sold ), "of", fromUsdc( swapInfo.total ), "==>",  Math.round (100 * swapInfo.sold.toNumber() / swapInfo.total.toNumber()), "%" )

		const avgGasUsed = totaGasUsed.div(i).toNumber()
		console.log(">>> avg gas per swap: ", avgGasUsed)
		
		console.log("pool usdc balance: ", fromUsdc( await usdc.balanceOf(pool.address)))
		console.log("pool btc balance: ", fromBtc( await wbtc.balanceOf(pool.address)))
		console.log("pool value: ", fromUsdc( await pool.totalValue()))
		console.log("pool risk asset: ", fromUsdc( await pool.riskAssetValue()))
		console.log("pool stable asset: ", fromUsdc( await pool.stableAssetValue()))
	
		expect( avgGasUsed ).to.lessThan( 350_000 )

	}).timeout(60_000);

});



