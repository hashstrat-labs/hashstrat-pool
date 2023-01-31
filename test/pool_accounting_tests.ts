import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";

import { deployMockContract } from "ethereum-waffle"
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromUsdc, toUsdc, toWbtc, transferFunds } from "./helpers"

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
        await usdcAggregatorMock.mock.latestRoundData.returns(0, 100000000, 1801686057, 1801686057, 0);
        await usdcAggregatorMock.mock.decimals.returns(8);

        await wbtcAggregatorMock.mock.latestRoundData.returns(0, 2000000000000, 1801686057, 1801686057, 0);
        await wbtcAggregatorMock.mock.decimals.returns(8);


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


    describe("Accounting", function () {

		it("When USDC tokens are depoisted should increase the deposit balance", async function () {
			const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);

            const [ _, addr1 ] = await ethers.getSigners();

          
            await transferFunds( toUsdc('1000'), addr1.address)

            const deposit1 = toUsdc('100') 
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const balance1 = await pool.deposits(addr1.address)
            expect( balance1 ).to.equal( deposit1 )

            const deposit2 = toUsdc('50') 
            await usdc.connect(addr1).approve(pool.address, deposit2)
            await pool.connect(addr1).deposit(deposit2)

            const balance2 = await pool.deposits(addr1.address)
            expect( balance2 ).to.equal( deposit1.add(deposit2) )
		});


        it("When USDC tokens are withdrawn should increase the withrawn balance", async function () {
			const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);

            const [ _, addr1 ] = await ethers.getSigners();
            await transferFunds( toUsdc('1000'), addr1.address)

            const deposit1 = toUsdc('100') 
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const balance1 = await pool.deposits(addr1.address)
            expect( balance1 ).to.equal( deposit1 )
            
            const lpBalance = await poolLPToken.balanceOf(addr1.address)
            const withdrawLP =  lpBalance.div(3)
            const withdrawValue = await pool.lpTokensValue(withdrawLP)

            await pool.connect(addr1).withdrawLP(withdrawLP)

            const withdrawalBalance = await pool.withdrawals(addr1.address)

            expect( fromUsdc(withdrawalBalance) ).to.be.approximately( fromUsdc(withdrawValue) , 0.1 )
		});


        it("attempting to withdraw more LP tokens than available in balance should throw", async () => {
			const { pool, poolLPToken, usdc } = await loadFixture(deployPoolContract);

            const [ _, addr1 ] = await ethers.getSigners();
            await transferFunds( toUsdc('100'), addr1.address)

            const deposit1 = toUsdc('100') 
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const lpBalance = await poolLPToken.balanceOf(addr1.address)
            const amount = lpBalance.add(1)

            await expect( pool.connect(addr1).withdrawLP(amount) ).to.be.reverted
        });

    });

});