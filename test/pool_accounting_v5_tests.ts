import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";

import { deployMockContract } from "@ethereum-waffle/mock-contract"
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { fromUsdc, toUsdc, toWbtc, transferFunds } from "./helpers"

import erc20_abi from "../scripts/abis/erc20.json";
import addresses from "../conf/addresses.json";
import enums from "../conf/enums.json";


import price_feed_aggreagator_abi from "./abi/price_feed_aggreagator.json"
import quoter_uniswap_abi from "./abi/quoter_uniswap.json"

import { deployPoolDiamondContractWithMocks } from './utils/diamond'

describe("PoolV4", function () {


    describe("Accounting", function () {

		it("When USDC tokens are depoisted should increase the deposit balance", async function () {
			const { pool, usdc } = await loadFixture(deployPoolDiamondContractWithMocks);

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
			const { pool, usdc } = await loadFixture(deployPoolDiamondContractWithMocks);

            const [ _, addr1 ] = await ethers.getSigners();
            await transferFunds( toUsdc('1000'), addr1.address)

            const deposit1 = toUsdc('100') 
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const balance1 = await pool.deposits(addr1.address)
            expect( balance1 ).to.equal( deposit1 )
            
            const lpBalance = await pool.balanceOf(addr1.address)
            const withdrawLP =  lpBalance.div(3)
            const withdrawValue = await pool.lpTokensValue(withdrawLP)

            await pool.connect(addr1).withdrawLP(withdrawLP)

            const withdrawalBalance = await pool.withdrawals(addr1.address)

            expect( fromUsdc(withdrawalBalance) ).to.be.approximately( fromUsdc(withdrawValue) , 0.1 )
		});


        it("attempting to withdraw more LP tokens than available in balance should throw", async () => {
			const { pool, usdc } = await loadFixture(deployPoolDiamondContractWithMocks);

            const [ _, addr1 ] = await ethers.getSigners();
            await transferFunds( toUsdc('100'), addr1.address)

            const deposit1 = toUsdc('100') 
            await usdc.connect(addr1).approve(pool.address, deposit1)
            await pool.connect(addr1).deposit(deposit1)

            const lpBalance = await pool.balanceOf(addr1.address)
            const amount = lpBalance.add(1)

            await expect( pool.connect(addr1).withdrawLP(amount) ).to.be.reverted
        });

    });

});