


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
	const RebalancingStrategyV1 = await ethers.getContractFactory("RebalancingStrategyV1")

	const strategy = await RebalancingStrategyV1.deploy(
		'0x0000000000000000000000000000000000000000',// pool address not known yet
		addresses.polygon.usdc_usd_aggregator,
		addresses.polygon.wbtc_usd_aggregator,
		addresses.polygon.usdc, 
		addresses.polygon.wbtc, 
		60,   // target portfolio 60% WBTC / 40% USDC
		10,   // 10% seems a good rebalancing band that requires price to double or halve to rebalance
	); 
	await strategy.deployed()


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


describe("Deposit/Withdrawals average gas", function () {

	it.skip("Deposits", async function () {

		const { pool, usdc, wbtc, wbtcFeed } = await deployPoolContract()

		const [ signer, addr1 ] = await ethers.getSigners();
		await transferFunds(100_000 * 10 ** usdc_decimals, addr1.address)
		await pool.setSlippageThereshold( 200 )

		const iterations = 100
		const balance = await usdc.balanceOf(addr1.address)
		const deposit = balance.div(iterations)

		let totalGasUsed = BigNumber.from(0)
		for (let i=0; i<iterations; i++) {
			await usdc.connect(addr1).approve(pool.address, deposit)
			const tx = await pool.connect(addr1).deposit(deposit)

			const gasUsed = (await tx.wait()).gasUsed;
			totalGasUsed = totalGasUsed.add(gasUsed)

			await waitSeconds( 10 * 60 )
		}

		const avgGasUsed = totalGasUsed.div(iterations).toNumber()
		console.log("deposits avgGasUsed: ", avgGasUsed.toString())
		
		expect( avgGasUsed ).to.lessThan( 515_000 )

	}).timeout(100_000);


	it.skip("Withdrawals", async function () {

		const { pool, poolLPToken, usdc, wbtc, wbtcFeed } = await deployPoolContract()

		const [ signer, addr1 ] = await ethers.getSigners();
		await transferFunds(100_000 * 10 ** usdc_decimals, addr1.address)
		await pool.setSlippageThereshold( 100 )
	
		// 1000 usdc deposit
		await usdc.connect(addr1).approve(pool.address, 1_000 * 10 ** usdc_decimals)
		await pool.connect(addr1).deposit(1_000 * 10 ** usdc_decimals)

		const lpbalance = await poolLPToken.balanceOf(addr1.address)
		const balanceBefore = await usdc.balanceOf(addr1.address)

		// very small withdrawals of 0.10 USDC
		const withdrawalAmount = lpbalance.div( 10_000 )
		const iterations = 100

		let totalGasUsed = BigNumber.from(0)
		for (let i=0; i<iterations; i++) {
			const balanceBefore = await usdc.balanceOf(addr1.address)
			const tx = await pool.connect(addr1).withdrawLP(withdrawalAmount)
			const gasUsed = (await tx.wait()).gasUsed;
			totalGasUsed = totalGasUsed.add(gasUsed)

			const balanceAfter = await usdc.balanceOf(addr1.address)

			await waitSeconds( 10 * 60 )
		}

		const balanceAfter = await usdc.balanceOf(addr1.address)
		console.log("Total withdrawn:", fromUsdc(balanceAfter.sub(balanceBefore)) )

		const avgGasUsed = totalGasUsed.div(iterations).toNumber()
		console.log("withdrawals avgGasUsed: ", avgGasUsed.toString())
		
		expect( avgGasUsed ).to.lessThan( 515_000 )

	}).timeout(100_000);

});



