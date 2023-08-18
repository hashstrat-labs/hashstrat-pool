import { expect } from "chai";


import { Contract } from "ethers"
import { ethers } from "hardhat";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromUsdc, fromBtc  } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";

import { deployMockContract } from "@ethereum-waffle/mock-contract"

import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import pool_abi from "./abi/pool.json"


describe("RebalancingStrategyV1", function () {

	async function deployPoolContract() {

        const [ deployer ] = await ethers.getSigners();

        // Deploy Mocks
        const usdcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const wbtcAggregatorMock = await deployMockContract(deployer, price_feed_aggreagator_abi);
        const poolMock = await deployMockContract(deployer, pool_abi);

        // Depoly Strategy
        const RebalancingStrategyV1 = await ethers.getContractFactory("RebalancingStrategyV1")

        const strategy = await RebalancingStrategyV1.deploy(
            poolMock.address,
            usdcAggregatorMock.address,
            wbtcAggregatorMock.address,
            addresses.polygon.usdc, // 6 decimals
            addresses.polygon.wbtc, // 8 decimals
            60,   // target portfolio 60% WBTC / 40% USDC
            10,   // 10% seems a good rebalancing band that requires price to double or halve to rebalance
        ); 
        await strategy.deployed()

		const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)
		const wbtc = new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)
     
        // prepare mocks
        await usdcAggregatorMock.mock.latestRoundData.returns( 0, 99996253, 1801686057, 1801686057, 0 ); 
        await usdcAggregatorMock.mock.decimals.returns( 8 ); 

        await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 2323439777008, 1801686057, 1801686057, 0 ); 
        await wbtcAggregatorMock.mock.decimals.returns( 8 ); 

		return { strategy, usdc, wbtc, usdcAggregatorMock, wbtcAggregatorMock, poolMock };
	}


	describe("exec()", async function () {

        it("Rebalance a pool at 0%/100% to 60%/40%", async () => {
           
			const { strategy, poolMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(0);
            await poolMock.mock.stableAssetValue.returns(1000 * 10 ** 6);
    
            const [action, minAmountOut] = await strategy.callStatic.exec();

            expect( action ).to.equal( enums.ActionType.BUY ); // BUY $600 of BTC
            expect( fromUsdc(minAmountOut) ).to.be.approximately( 600, 0.1);
        })

   
        it("Does not rebalance a pool at 60%/40%", async () => {
        
                const { strategy, poolMock } = await loadFixture(deployPoolContract);

                await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
                await poolMock.mock.riskAssetValue.returns(600 * 10 ** 6);
                await poolMock.mock.stableAssetValue.returns(400 * 10 ** 6);
        
                const resp = await strategy.eval();

                expect( resp[0] ).to.equal( enums.ActionType.NONE );
                expect( fromUsdc(resp[1]) ).to.be.equal( 0 );
        })
        
        
        it("Rebalance a pool at 20%/80% to 60%/40%", async () => {
        
            const { strategy, poolMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(200 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(800 * 10 ** 6);

            const resp = await strategy.eval();

            expect( resp[0] ).to.equal( enums.ActionType.BUY  );  // BUY $400 of BTC
            expect( fromUsdc(resp[1]) ).to.be.approximately( 400, 0.1 );
        })
        
        it("Rebalance a pool at 50%/50% to 60%/40%", async () => {
        
            const { strategy, poolMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(500 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(500 * 10 ** 6);

            const resp = await strategy.eval();

            expect( resp[0] ).to.equal( enums.ActionType.BUY );  // BUY $100 of BTC
            expect( fromUsdc(resp[1]) ).to.be.approximately( 100, 0.1 );
        })
        

        it("Rebalance a pool at 80%/20% to 60%/40%", async () => {
        
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(800 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(200 * 10 ** 6);

            const resp = await strategy.eval();
            const [ _, btcPrice ] = await wbtcAggregatorMock.latestRoundData(); 

            const expectedAmount = 200 / Number(btcPrice.toString()) * 10 ** 8

            expect( resp[0] ).to.equal( enums.ActionType.SELL );  // SELL $200 of BTC
            expect( fromBtc(resp[1]) ).to.be.approximately( expectedAmount, 0.001 );
        })


        it("Rebalance a pool at 70%/30% to 60%/40%", async () => {
        
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(700 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(300 * 10 ** 6);

            const resp = await strategy.eval();
            const [ _, btcPrice ] = await wbtcAggregatorMock.latestRoundData(); 

            const expectedSoldAmount = 100 / Number(btcPrice.toString()) * 10 ** 8

            expect( resp[0] ).to.equal( enums.ActionType.SELL );  // SELL $100 of BTC
            expect( fromBtc(resp[1]) ).to.be.approximately( expectedSoldAmount, 0.001 );
        })
        
        
        it("Does not rebalance a pool withing the upper 10% rebalancing threshold", async () => {
            
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(699 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(301 * 10 ** 6);

            const [ action, amountIn ] = await strategy.eval();
            expect( action ).to.equal( enums.ActionType.NONE ); 
            expect( fromBtc(amountIn) ).to.equal( 0 );
        })
    
        
        it("Does not rebalance a pool withing the lower 10% rebalancing threshold", async () => {
            const { strategy, poolMock, wbtcAggregatorMock } = await loadFixture(deployPoolContract);

            await poolMock.mock.totalValue.returns(1000 * 10 ** 6); 
            await poolMock.mock.riskAssetValue.returns(501 * 10 ** 6);
            await poolMock.mock.stableAssetValue.returns(499 * 10 ** 6);

            const resp = await strategy.eval();
            const [ _, btcPrice ] = await wbtcAggregatorMock.latestRoundData(); 

            expect( resp[0] ).to.equal( enums.ActionType.NONE ); 
            expect( resp[1].toNumber() ).to.equal( 0 );
        })

    });


});