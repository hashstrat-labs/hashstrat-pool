import { expect } from "chai";
import { BigNumber, Contract } from "ethers"
import { ethers } from "hardhat";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { deployMockContract } from "ethereum-waffle"

import { fromBtc, fromUsdc, toUsdc, toWbtc, transferFunds } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";

import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import quoter_uniswap_abi from "./abi/quoter_uniswap.json"

describe("PoolV4", function () {


	async function deployPoolContract() {

        const [ deployer, addr1, addr2 ] = await ethers.getSigners();

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
    
        // Configure mock router with price and some liquidity
        await transferFunds(toUsdc('100000'), uniswapV2RouterMock.address, "usdc")
        await transferFunds(toWbtc('10'), uniswapV2RouterMock.address, "btc")

        // empty addr1/addr2 usdc balance
        await usdc.connect(addr1).transfer( uniswapV2RouterMock.address, await usdc.balanceOf(addr1.address) )
        await usdc.connect(addr2).transfer( uniswapV2RouterMock.address, await usdc.balanceOf(addr2.address) )

        // prepare mocks
        await usdcAggregatorMock.mock.latestRoundData.returns( 0, 100000000, 1801686057, 1801686057, 0 ); 
        await usdcAggregatorMock.mock.decimals.returns( 8 ); 

        await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 2000000000000, 1801686057, 1801686057, 0 ); 
        await wbtcAggregatorMock.mock.decimals.returns( 8 ); 

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
        const poolFees = 100        // 1% fee
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
        await swapRouter.addRouter( uniswapV2RouterMock.address, enums.RouterVersion.V2, enums.RouterType.QuickSwap )
        await swapRouter.setActiveRouter(0)

	
		return { poolLPToken, swapRouter, strategy, pool, usdc, wbtc, 
            usdcAggregatorMock, wbtcAggregatorMock, quoterUniswapPMock, uniswapV2RouterMock 
        };
	}


    describe("Withdraw", function () {

        it("When an account is in profit it should pay whitdrawal fees ", async () => {
   
            const { pool, poolLPToken, usdc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ _, addr1 ] = await ethers.getSigners();

            const feesPerc = (await pool.feesPerc()).toNumber() / (10 ** await pool.feesPercDecimals())

            //  addr1 deposit
            const initialDeposit = 60
            const deposit1 = toUsdc(initialDeposit) 
            await transferFunds(deposit1, addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const lpblance = await poolLPToken.balanceOf(addr1.address)

            const lpToWithdraw = 40
            expect( fromUsdc(await pool.lpTokensValue( lpblance ))  ).to.equal( 60 )
            expect( fromUsdc(await pool.lpTokensValue( toUsdc(lpToWithdraw)  ))  ).to.equal( 40 )

            // btc price increase
            const btcPriceFactor = 2
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, btcPriceFactor * 2000000000000, 1801686057, 1801686057, 0 ); 
    
            const expectedLpValue = (40 * 0.4) + btcPriceFactor * (40 * 0.6)
            const currenInvestmentValue = (60 * 0.4) + btcPriceFactor * (60 * 0.6)

            expect( fromUsdc(await pool.lpTokensValue( toUsdc(lpToWithdraw)  ))  ).to.equal( expectedLpValue )
            expect( fromUsdc(await pool.lpTokensValue( await poolLPToken.balanceOf(addr1.address)  ))  ).to.equal( currenInvestmentValue )

            const expectedGainsPerc = (currenInvestmentValue - initialDeposit) / initialDeposit
            expect( (await pool.gainsPerc(addr1.address)).toNumber() / 10000 ).to.equal( expectedGainsPerc )

            const feesToWithdraw = fromUsdc(await pool.feesForWithdraw( toUsdc(lpToWithdraw) , addr1.address)) // 0.24 LP
            const expectedFeeAmount = 0.24  // LP = 0.6% * 40 LP * 0.01% = 0.24 LP (profit% * LP withdrawn * fees perc)
            expect( feesToWithdraw ).to.equal( expectedFeeAmount )

            // addr1 withdraw 40 LP
            await pool.connect(addr1).withdrawLP( toUsdc(lpToWithdraw) )
            const feeAmount = await poolLPToken.balanceOf(pool.address) //  0.24 LP
            const feeValue = await pool.lpTokensValue( feeAmount ) // $0.384004 
            const expectedFeeValue = expectedGainsPerc * expectedLpValue * feesPerc  // $0.384 (profit %  * value withdrawn * fees perc)

            // veridy value of fees collected by the pool
            expect( fromUsdc(feeValue) ).to.be.approximately( expectedFeeValue , 0.00001 )
        })


        it("When account withdraws some LP tokens and has no gains then no fees go to the pool", async () => {
   
            const { pool, poolLPToken, usdc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ _, addr1 ] = await ethers.getSigners();

            //  addr1 deposit
            const initialDeposit = 60
            const deposit1 = toUsdc(initialDeposit) 
            await transferFunds(deposit1, addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const account1LP = await poolLPToken.balanceOf(addr1.address)
            expect ( fromUsdc(account1LP) ).to.equal( 60 )

            // btc price decrease
            const btcPriceFactor = 0.999999999
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, btcPriceFactor * 2000000000000, 1801686057, 1801686057, 0 ); 

            const fees = await pool.feesForWithdraw( account1LP, addr1.address)
            expect ( fees ).to.equal( 0 )

            // verify withdraw fees are 0
            await pool.connect(addr1).withdrawAll()
            expect ( await poolLPToken.balanceOf(pool.address) ).to.equal( 0 )
        })


        it("When LP tokens are withdrawn by a different account, they pay the full fees", async () => {
   
            const { pool, poolLPToken, usdc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ _, addr1, addr2 ] = await ethers.getSigners();

            const feesPerc = (await pool.feesPerc()).toNumber() / (10 ** await pool.feesPercDecimals())

            // account1 deposit 60 usdc and gets 60 LPs
            //  addr1 deposit
            const initialDeposit = 60
            const deposit1 = toUsdc(initialDeposit) 
            await transferFunds(deposit1, addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            // btc price increase
            const btcPriceFactor = 2
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, btcPriceFactor * 2000000000000, 1801686057, 1801686057, 0 ); 
    
            // addr1 transfers 60 LP to addr2
            await poolLPToken.connect(addr1).transfer(addr2.address, await poolLPToken.balanceOf(addr1.address))
    
            expect ( fromUsdc(await poolLPToken.balanceOf(addr2.address)) ).to.equal( 60 )

            // verity 100% fee on profits applied
            const expectedGainsPerc = 1.0
            const lpToWithdraw = 60
            const expectedLpValue = (60 * 0.4) + btcPriceFactor * (60 * 0.6)
            const expectedFeeAmount = expectedGainsPerc * lpToWithdraw * feesPerc    // 0.6 LP (profit% * LP withdrawn * fees perc)
            const expectedFeeValue = expectedGainsPerc * expectedLpValue * feesPerc  // $0.96 (profit% * value withdrawn * fees perc)

            expect( (await pool.gainsPerc(addr2.address)).toNumber() / 10000 ).to.equal( 1 )

            const feesToWithdraw = await pool.feesForWithdraw( toUsdc(lpToWithdraw) , addr2.address)
            expect( fromUsdc(feesToWithdraw) ).to.be.equal( expectedFeeAmount )

            // addr2 withdraw 60 LP and is applied a 1% fee on the value withdrawn
            await pool.connect(addr2).withdrawLP( toUsdc(lpToWithdraw) )

            // verify fee amount
            const feeAmount = await poolLPToken.balanceOf(pool.address) //  0.6 LP  (fee)
            expect( fromUsdc(feeAmount) ).to.equal( 0.6 )

            const feeValue = await pool.lpTokensValue( feeAmount ) // $0.96

            // verify fee value
            expect( fromUsdc(feeValue) ).to.be.equal( expectedFeeValue )

        })


        it("When the owner collects all fees, all fees are transferred to the owner and no fees are left in the pool", async () => {
   
            const { pool, poolLPToken, usdc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ owner, addr1 ] = await ethers.getSigners();

            //  addr1 deposit
            const deposit1 = toUsdc(100) 
            await transferFunds(deposit1, addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            // btc price increase
            const btcPriceFactor = 2
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, btcPriceFactor * 2000000000000, 1801686057, 1801686057, 0 ); 
    
            await pool.connect(addr1).withdrawAll()

            const fees = await poolLPToken.balanceOf(pool.address) 
            expect( fees ).is.equal( toUsdc(0.6)  )  // 0.6 LP
    
            // only owner can collect all fees
            await pool.collectFees(0)

            expect( await poolLPToken.balanceOf(pool.address) ).is.equal( 0 )
            expect( await usdc.balanceOf(owner.address) ).is.equal( toUsdc(0.96) )  // 0.96 USDC
        })


        it("Reverts when a non awner tries to collect fees", async () => {
   
            const { pool, poolLPToken, usdc, wbtcAggregatorMock } = await loadFixture(deployPoolContract);
            const [ _, addr1 ] = await ethers.getSigners();

            //  addr1 deposit
            const deposit1 = toUsdc(100) 
            await transferFunds(deposit1, addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            // btc price increase
            const btcPriceFactor = 2
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, btcPriceFactor * 2000000000000, 1801686057, 1801686057, 0 ); 
    
            await pool.connect(addr1).withdrawAll()

            const fees = await poolLPToken.balanceOf(pool.address) 
            expect( fees ).is.equal( toUsdc(0.6)  )
    
            await expect ( pool.connect(addr1).collectFees(0) ).to.be.reverted
        })

	});

});