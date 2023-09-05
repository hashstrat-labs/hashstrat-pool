


import {  BigNumber } from "ethers"
import { ethers } from "hardhat";
import { expect } from "chai";

import { fromBtc, fromUsdc, waitSeconds, transferFunds, waitDays, toUsdc } from "./helpers";
import { deployPoolDiamondContract } from './utils/diamond'

import enums from "../conf/enums.json";

const usdc_decimals = 6


describe("TWAP ingtegration", function () {

	it("Consumes the expected average gas amount per swap", async function () {

		const { pool, usdc } = await deployPoolDiamondContract()
		const [ owner, addr1, addr2 ] = await ethers.getSigners();
		const twapInterval = (await pool.twapSwapInterval()).toNumber()

		// set high slippage to avoid hitting max slippage
		await pool.connect(owner).setSlippageThereshold(25 * 100) 

		await transferFunds(100_000 * 10 ** usdc_decimals, addr1.address)

		console.log("addr1 balance: ",  fromUsdc( await usdc.balanceOf(addr1.address) ))
	
		const balance = await usdc.balanceOf(addr1.address)
		await usdc.connect(addr1).approve(pool.address, balance)
		await pool.connect(addr1).deposit(balance)

		const iterations = 100
		let totalGasUsed = BigNumber.from(0)

		for (let i=0; i<iterations; i++) {
			await waitSeconds(twapInterval)

            const [upkeepNedded1] = await pool.checkUpkeep(new Int8Array())

			console.log(">>> upkeepNeeded: ", upkeepNedded1);

			expect( upkeepNedded1 ).is.true

			// exec strategy
			const tx = await pool.connect(addr2).performUpkeep(new Int8Array())
			const gasUsed = (await tx.wait()).gasUsed;
			totalGasUsed = totalGasUsed.add(gasUsed)

			console.log("i: ", i, "gasUsed", gasUsed.toString())
		}

		const avgGasUsed = totalGasUsed.div(iterations).toNumber()
		console.log("avgGasUsed: ", avgGasUsed.toString(), "totalGasUsed", totalGasUsed.toString())

		expect( avgGasUsed ).to.lessThan( 550_000 )
		
	}).timeout(120_000);


	it("Exec extremely large TWAP swaps until slippage is exceeded", async function () {

		const { pool, usdc } = await deployPoolDiamondContract()
		const [ owner, addr1, addr2 ] = await ethers.getSigners();

		// set high slippage
		await pool.connect(owner).setSlippageThereshold(1 * 100) 

		const maxVal = (await pool.swapMaxValue()).toNumber()
		await pool.connect(owner).setSwapMaxValue(10 * 10**6)
		const maxVal2 = (await pool.swapMaxValue()).toNumber()
		console.log("!!! maxVal:", maxVal.toString() , "maxVal2: ", maxVal2.toString() )
		
		const MAX_SLIPPAGE = (await pool.slippageThereshold()).toNumber()
		const twapInterval = (await pool.twapSwapInterval()).toNumber()
		console.log("MAX_SLIPPAGE:", MAX_SLIPPAGE, "twapInterval: ", twapInterval)


		await transferFunds(100_000 * 10 ** usdc_decimals, addr1.address)

		/// deposit $1000 with max swap size of $100
		const deposit = toUsdc(10_000)
		console.log("!!! depositing ", fromUsdc(deposit))
		await usdc.connect(addr1).approve(pool.address, deposit)
		await pool.connect(addr1).deposit(deposit)
	
		let i=0;
		let swapErrorEvent = undefined
		let priorSwapTimestamp = 0
		let swapProcessing = true

		do {

			console.log("===== ", i, "=====")
			await waitSeconds(twapInterval)

			const [ upkeepNedded ] = await pool.checkUpkeep(new Int8Array())
			expect( upkeepNedded ).is.true

			// process swap
			const tx = await pool.connect(addr2).performUpkeep(new Int8Array())
			const receipt = await tx.wait()

			const events = receipt.events;
			// console.log("events: ", events)
			console.log("events ", events.map( (e : any) => e.event) )

			const swapEvents = events?.filter((x: any) => { return x.event === "Swapped" })

			const [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()

			// "function twapSwaps() view returns (tuple(uint8,address,address,uint256,uint256,uint256,uint256,uint256))"

			expect( side ).is.equal(enums.ActionType.BUY)
			expect( lastSwapTimestamp ).is.greaterThan( priorSwapTimestamp )

			//    event Swapped(string side, uint256 sold, uint256 bought, uint256 slippage);
			const swapEvent = swapEvents && swapEvents![swapEvents.length-1]
			const soldE = swapEvent?.args?.[1]?.toNumber() ?? 0
			const boughtE = swapEvent?.args?.[2]?.toNumber() ?? 0
			const slipageE = swapEvent?.args?.[3]?.toNumber() ?? 0

			// const twapSwaps = await pool.twapSwaps()

			if (boughtE == 0) {
				swapErrorEvent = events?.filter((x: any) => { return x.event === "SwapError" }).find( (e: any) => true)
				// console.log(i, "swapErrorEvent", swapErrorEvent)
			}
			
			const remaining = total.sub(sold)
			const soldCum = fromUsdc(sold)
			console.log(++i, lastSwapTimestamp.toNumber(), "sold: ", soldCum ,`(+${fromUsdc(soldE)})`, "bought: ", fromBtc(boughtE), " remaining: ", fromUsdc(remaining), "slipage: ",slipageE )

			await waitSeconds( 10 * 60 )

			priorSwapTimestamp = lastSwapTimestamp.toNumber()

			swapProcessing = fromUsdc(remaining) > 0
			console.log(i, "swapProcessing", swapProcessing)

		} while (swapErrorEvent == undefined && swapProcessing)
		// } while (true)

		console.log("swap error reason: ", swapErrorEvent?.args?.[0])

		// Teansfer failed
		expect( swapErrorEvent?.args?.[0] ).is.equal( 'TF' )


	}).timeout(120_000);

	
	it.only("Exec TWAP swaps until the full size is executed", async function () {

		const { pool, usdc, wbtc } = await deployPoolDiamondContract()
		const [ owner, addr1, addr2 ] = await ethers.getSigners();

		const twapInterval = (await pool.twapSwapInterval()).toNumber()

		// limit swap size to $100
		await pool.connect(owner).setSwapMaxValue(100 * 10 ** 6)

		// deposit 
		const deposit = 400 * 10 ** usdc_decimals
		await transferFunds(deposit, addr1.address)
		await usdc.connect(addr1).approve(pool.address, deposit)
		await pool.connect(addr1).deposit(deposit)

		
		let remaining;
		let i=0;
		
		do {
			await waitSeconds(twapInterval)

			const [ upkeepNedded ] = await pool.checkUpkeep(new Int8Array())
			expect( upkeepNedded ).is.true

			
			// exec strategy
			const tx = await pool.connect(addr2).performUpkeep(new Int8Array())
			const gasUsed = (await tx.wait()).gasUsed;
			const events = (await tx.wait()).events;
			
			const [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()

			expect( side ).is.equal(enums.ActionType.BUY)
			
			const swapEvents = events?.filter((x) => { return x.event === "Swapped" })
			const swapEvent = swapEvents && swapEvents![swapEvents.length-1]
	

			const soldE = swapEvent?.args?.[1]?.toNumber() ?? 0
			const boughtE = swapEvent?.args?.[2]?.toNumber() ?? 0

			// const twapSwaps = await pool.twapSwaps()
		
			remaining = total.sub(sold)
			
			expect ( soldE ).to.not.be.undefined
			expect ( boughtE ).to.not.be.undefined

			expect ( soldE ).to.be.greaterThan( 0 )
			expect ( boughtE ).to.be.greaterThan( 0 )

			console.log(++i, "swap ---- gas used : ", gasUsed.toString(), "sold: ", fromUsdc(sold), "bought: ", fromBtc(bought), " remaining: ", fromUsdc(remaining) )

			await waitSeconds( 10 * 60 )

		} while (remaining.toNumber() > 0)

		const [side, tokenIn, tokenOut, total, size, sold, bought, lastSwapTimestamp] = await pool.twapSwaps()


		console.log(">>> TOTAL - sold: ", fromUsdc( sold ), "of", fromUsdc( total ), "==>",  Math.round (100 * sold.toNumber() / total.toNumber()), "%" )
		console.log("pool usdc balance: ", fromUsdc( await usdc.balanceOf(pool.address)))
		console.log("pool btc balance: ", fromBtc( await wbtc.balanceOf(pool.address)))
		console.log("pool value: ", fromUsdc( await pool.totalValue()))
		console.log("pool risk asset: ", fromUsdc( await pool.riskAssetValue()))
		console.log("pool stable asset: ", fromUsdc( await pool.stableAssetValue()))

		// verify swap has been fully processed
		expect (total.sub(sold).toNumber() ).to.be.equal( 0 )
		
		// verify upkeep is not needed
		const [upkpeedNeeded] = await pool.checkUpkeep(new Int8Array()) 
		expect( upkpeedNeeded ).is.false
		 
	}).timeout(60_000);

});

