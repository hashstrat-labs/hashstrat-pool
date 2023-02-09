import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";

import { BigNumber, Contract } from "ethers"
import { ethers } from "hardhat";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { deployMockContract } from "ethereum-waffle"

import { fromBtc, fromUsdc, fromWei, toUsdc, toWbtc, transferFunds } from "./helpers"

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
    
        // Configure mock router with price and liquidity (leave 1 USDC to the usd_holder account to transfer to users)
        await transferFunds( (await usdc.balanceOf(addresses.polygon.usd_holder)).sub( toUsdc(1_000_000) )  , uniswapV2RouterMock.address, "usdc")
        await transferFunds( await wbtc.balanceOf(addresses.polygon.btc_holder), uniswapV2RouterMock.address, "btc")

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
        const poolFees = 0        // 1% fee
        const uniswapV3Fee = 3000

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
            uniswapV3Fee
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

        it("withdraw of inital deposit", async () => {

			const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);
            const [ _, addr1, addr2 ] = await ethers.getSigners();

            const deposit1 = toUsdc('60') 
            await transferFunds(toUsdc('1000'), addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const deposit2 = toUsdc('100') 
            await transferFunds(toUsdc('1000'), addr2.address)
            await usdc.connect(addr2).approve(pool.address, deposit2)
            await pool.connect(addr2).deposit(deposit2)

            expect (fromUsdc(await usdc.balanceOf(addr1.address))).to.be.approximately( 940, 0.1 )
            expect (fromUsdc(await usdc.balanceOf(addr2.address))).to.be.approximately( 900, 0.1 )

            const lpBalance1 = await poolLPToken.balanceOf(addr1.address)
            const lpBalance2 = await poolLPToken.balanceOf(addr2.address)

            expect (fromUsdc(lpBalance1)).to.be.approximately( 60, 0.1 )
            expect (fromUsdc(lpBalance2)).to.be.approximately( 100, 0.1 )
            
            expect (fromUsdc(await pool.portfolioValue(addr1.address)) ).to.be.approximately( 60, 0.1 )
            expect (fromUsdc(await pool.portfolioValue(addr2.address)) ).to.be.approximately( 100, 0.1 )
            expect (fromUsdc(await pool.totalValue()) ).to.be.approximately( 160, 0.1 )
    
            let withraw1 = Math.floor(lpBalance1.toNumber() / 3)
            await pool.connect(addr1).withdrawLP(withraw1)

            expect (fromUsdc(await usdc.balanceOf(addr1.address))).to.be.approximately( 960, 0.1 )
            expect (fromUsdc(await usdc.balanceOf(addr2.address))).to.be.approximately( 900, 0.1 )

		});


        it("withdraw after price increase", async () => {

            const { pool, poolLPToken, usdc, wbtcAggregatorMock, quoterUniswapPMock, uniswapV2RouterMock } = await loadFixture(deployPoolContract);
            const [ _, addr1, addr2 ] = await ethers.getSigners();

            const deposit1 = toUsdc('60') 
            await transferFunds(toUsdc('60'), addr1.address)
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            expect (fromUsdc(await pool.totalValue())).to.be.equal( 60 )

            await quoterUniswapPMock.mock.quoteExactInputSingle.returns(500000) // 0.005 BTC

            const deposit2 = toUsdc('100') 
            await transferFunds(toUsdc('100'), addr2.address)
            await usdc.connect(addr2).approve(pool.address, deposit2)
            await pool.connect(addr2).deposit(deposit2)

            
            expect (fromUsdc(await usdc.balanceOf(addr1.address))).to.be.approximately( 0, 0.1 )
            expect (fromUsdc(await usdc.balanceOf(addr2.address))).to.be.approximately( 0, 0.1 )
            expect (fromUsdc(await pool.totalValue())).to.be.equal( 160 )

            expect (fromUsdc(await pool.riskAssetValue())).to.be.equal( 96 )   // 60% total value
            expect (fromUsdc(await pool.stableAssetValue())).to.be.equal( 64 ) // 40% total value
  
            // BTC prices up 50%
            await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 3000000000000, 1801686057, 1801686057, 0 ); 


            expect (fromUsdc(await pool.riskAssetValue())).to.be.equal( 144 )   // 60% total value (69.23%)
            expect (fromUsdc(await pool.stableAssetValue())).to.be.equal( 64 )  // 40% total value (30.77%)
            expect (fromUsdc(await pool.totalValue())).to.be.equal( 208 )

            // withdraw 20/160 = 12.5% of the pool value
            const withdraw = BigNumber.from( Math.round( (await poolLPToken.balanceOf(addr1.address)).toNumber() / 3) )
            // addr1 withdraws 1/3 of LP
            await pool.connect(addr1).withdrawLP(withdraw)

            expect (fromUsdc(await usdc.balanceOf(addr1.address))).to.be.approximately( 26, 0.1 )
            expect (fromUsdc(await pool.totalValue())).to.be.approximately( 182, 0.1 )

            // addr1, addr2 withdraws all their LP
            await pool.connect(addr1).withdrawAll()
            await pool.connect(addr2).withdrawAll()

            expect (fromUsdc(await usdc.balanceOf(addr1.address))).to.be.approximately( 78, 0.1 )
            expect (fromUsdc(await usdc.balanceOf(addr2.address))).to.be.approximately( 130, 0.1 )

            // Pool is empty
            expect (fromUsdc(await pool.totalValue())).to.be.equal( 0 )
        })

	});

});