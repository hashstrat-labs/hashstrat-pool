import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromUsdc, toUsdc, transferFunds } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";


describe("PoolV4", function () {

	// const max_supply = ethers.utils.parseEther('1000000.0');   // 1M tokens

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
        const swapMaxValue = 10_000 * 10 ** 6

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
        await swapRouter.setActiveRouter(1)

		const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)
		const wbtc = new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)
     
		return { poolLPToken, swapRouter, strategy, pool, usdc, wbtc };
	}


	describe("Config", function () {
		it("Pool has the expected LP token", async function () {
			const { pool, poolLPToken  } = await loadFixture(deployPoolContract);
			expect(await pool.lpToken()).to.equal(poolLPToken.address);
		});

        it("Pool is the owner of its Strategy", async function () {
			const { pool, strategy  } = await loadFixture(deployPoolContract);
			expect(await strategy.owner()).to.equal(pool.address);
		});

        it("Pool has the expected SwapRouter", async function () {
			const { pool, swapRouter  } = await loadFixture(deployPoolContract);
			expect(await pool.swapRouter()).to.equal(swapRouter.address);
		});

        it("Router uses Uniswap V3", async function () {
			const { swapRouter  } = await loadFixture(deployPoolContract);
			expect( (await swapRouter.activeRouter()).routerAddress ).to.equal( addresses.polygon.quickswap_v3_router );
		});
	});


    describe("Deposit", function () {

		it("A first deposit allocates tokens in the Pool according to the strategy ", async function () {
			const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);

            const [ _, addr1 ] = await ethers.getSigners();

            const amount = toUsdc('1000') 
            await transferFunds(amount, addr1.address)
            await usdc.connect(addr1).approve(pool.address, amount)
            await pool.connect(addr1).deposit(amount)

            expect( fromUsdc(await usdc.balanceOf(pool.address)) ).to.approximately(400, 0.2);
            
			expect( fromUsdc(await pool.totalDeposited()) ).to.equal( 1000 );
            expect( fromUsdc(await pool.stableAssetValue()) ).to.approximately(400, 0.2);
            expect( fromUsdc(await pool.riskAssetValue()) ).to.be.approximately(600, 1);
            expect( fromUsdc(await pool.totalValue()) ).to.be.approximately(1000, 1);

            //user received LP tokens
            expect( fromUsdc(await poolLPToken.balanceOf(addr1.address)) ).to.be.approximately( 1000, 1 );
		});


        it("New deposits preserve the current pool allocations USDC/WBTC perc allocation", async () => {

            const { pool, usdc } = await loadFixture(deployPoolContract);

            const [ _, addr1, addr2 ] = await ethers.getSigners();

            const amount1 = toUsdc('1000') 
            await transferFunds(amount1, addr1.address)
            await usdc.connect(addr1).approve(pool.address, amount1)
            await pool.connect(addr1).deposit(amount1)

            expect( fromUsdc(await pool.totalDeposited()) ).to.equal( 1000 );
            expect( fromUsdc(await pool.stableAssetValue()) ).to.approximately(400, 0.2);
            expect( fromUsdc(await pool.riskAssetValue()) ).to.be.approximately(600, 1);
            expect( fromUsdc(await pool.totalValue()) ).to.be.approximately(1000, 1);

            const amount2 = toUsdc('2000') 
            await transferFunds(amount2, addr2.address)
            await usdc.connect(addr2).approve(pool.address, amount2)
            await pool.connect(addr2).deposit(amount2)

            expect( fromUsdc(await pool.totalDeposited()) ).to.equal( 3000 );
            expect( fromUsdc(await pool.stableAssetValue()) ).to.approximately(1200, 2);
            expect( fromUsdc(await pool.riskAssetValue()) ).to.be.approximately(1800, 4);
            expect( fromUsdc(await pool.totalValue()) ).to.be.approximately(3000, 3);

        });


        it("A first deposit into the Pool allocate the inital amount of LP tokens to the user", async () => {

            const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);
            const [ _, addr1, addr2 ] = await ethers.getSigners();

            const depositAmount = toUsdc('1000') 
            await transferFunds(depositAmount, addr1.address)
            await usdc.connect(addr1).approve(pool.address, depositAmount)
            await pool.connect(addr1).deposit(depositAmount)

            const portfolioValue = await pool.totalValue() 
            expect( fromUsdc(portfolioValue) ).to.be.approximately( fromUsdc(depositAmount), 1);

            // expect 100 initial portfolio allocation
            const lptokenBalance = await poolLPToken.balanceOf(addr1.address)
            expect( fromUsdc(lptokenBalance) ).to.be.approximately( fromUsdc(depositAmount), 1);

            // expect 100 total portfolio allocation 
            const totalPortfolioLP = await poolLPToken.totalSupply()
            expect( fromUsdc(totalPortfolioLP) ).to.be.approximately( fromUsdc(depositAmount), 1);
          
        });


        it("allocates LP tokens to multiple deposits from the same account", async () => {

            const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);
            const [ _, addr1 ] = await ethers.getSigners();

            let balanceBefore = await usdc.balanceOf(pool.address)
            expect( balanceBefore ).to.be.equal( 0 );

            // First deposit
            const firstDeposit = toUsdc('100') 
            await transferFunds(firstDeposit, addr1.address)
            await usdc.connect(addr1).approve(pool.address, firstDeposit)
            await pool.connect(addr1).deposit(firstDeposit)

    
            const portfolioValue1 = await pool.totalValue() 
            expect( fromUsdc(portfolioValue1) ).to.be.approximately( 100, 1 );

            // expect 100 LP tokens
            const lpBalance1 = await poolLPToken.balanceOf(addr1.address)
            expect(fromUsdc(lpBalance1)).to.be.approximately( 100, 0.1 )
    
            // Second deposit
            const secondDeposit = toUsdc('200') 
            await transferFunds(secondDeposit, addr1.address)
            await usdc.connect(addr1).approve(pool.address, secondDeposit)
            await pool.connect(addr1).deposit(secondDeposit)


            const portfolioValue2 = await pool.totalValue() 
            expect( fromUsdc(portfolioValue2) ).to.be.approximately( 300, 0.3 );
            
            // expect 300 LP tokens
            const lpBalance2 = await poolLPToken.balanceOf(addr1.address)
            expect( fromUsdc(lpBalance2) ).to.be.approximately( 300, 0.3 );

            // expect 300 total portfolio allocation 
            const totalLPSupply = await poolLPToken.totalSupply()
            expect( fromUsdc(totalLPSupply) ).to.be.approximately( 300, 0.3 );
    
            // expect 100% portfolio allocation
            const precision = 10 ** 8
            const portfolioPercentage = (await pool.portfolioPercentage(addr1.address)).toNumber() * 100 / precision
            expect( portfolioPercentage ).to.be.equal( 100 );

        })


        it("allocates LP tokens to deposits from multiple accounts", async () => {

            const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);
            const [ _, addr1, addr2 ] = await ethers.getSigners();

            let balanceBefore = await usdc.balanceOf(pool.address)
            expect( balanceBefore ).to.be.equal( 0 );

            // First deposit
            const firstDeposit = toUsdc('100') 
            await transferFunds(firstDeposit, addr1.address)
            await usdc.connect(addr1).approve(pool.address, firstDeposit)
            await pool.connect(addr1).deposit(firstDeposit)

    
            const portfolioValue1 = await pool.totalValue() 
            expect( fromUsdc(portfolioValue1) ).to.be.approximately( 100, 0.1 );

            // verify addr1 LP tokens
            const lpBalance1 = await poolLPToken.balanceOf(addr1.address)
            expect(fromUsdc(lpBalance1)).to.be.approximately( 100, 0.1 )
    
            // Second deposit
            const secondDeposit = toUsdc('200') 
            await transferFunds(secondDeposit, addr2.address)
            await usdc.connect(addr2).approve(pool.address, secondDeposit)
            await pool.connect(addr2).deposit(secondDeposit)

            // verify addr2 LP tokens
            const lpBalance2 = await poolLPToken.balanceOf(addr2.address)
            expect( fromUsdc(lpBalance2) ).to.be.approximately( 200, 0.2 );

            const portfolioValue2 = await pool.totalValue() 
            expect( fromUsdc(portfolioValue2) ).to.be.approximately( 300, 0.3 );
            
            // expect 300 total portfolio allocation 
            const totalLPSupply = await poolLPToken.totalSupply()
            expect( fromUsdc(totalLPSupply) ).to.be.approximately( 300, 0.3 );
    
            // expect 100% portfolio allocation
            const precision = 10 ** 8
            const portfolioPercentage1 = (await pool.portfolioPercentage(addr1.address)).toNumber() * 100 / precision
            expect( portfolioPercentage1 ).to.be.approximately( 33.33, 0.03 );

            const portfolioPercentage2 = (await pool.portfolioPercentage(addr2.address)).toNumber() * 100 / precision
            expect( portfolioPercentage2 ).to.be.approximately( 66.66, 0.03 );

        })




	});

});