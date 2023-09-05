/* ==========================================================================================
Tests the PoolV5 diamond and facets.

@author: Carlo Pascoli
============================================================================================= */


import { ethers } from "hardhat";
import { Contract } from "ethers"
import { expect } from "chai";

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

import { getSelectors, FacetCutAction, deployPoolDiamondContract, performDiamondCut } from './utils/diamond'
import { transferFunds, toUsdc, toWei } from "./helpers"
import erc20_abi from "./abi/erc20.json"
import erc4626_abi from "../abi/ERC4626Facet.json"
import addresses from "../conf/addresses.json";


describe('Create a PoolV5 Diamond', async function () {

    it('should have the ERC20 facet', async () => {
        const { pool, usdc } = await loadFixture(deployPoolDiamondContract);
        const [user0] = await ethers.getSigners();

        // Now can interact with the Pool via its ERC20 interface
        const poolErc20Facet = new Contract(pool.address, erc20_abi, ethers.provider)

        expect(await poolErc20Facet.totalSupply()).to.be.equal(0)

        console.log(">>> totalSupply:", await poolErc20Facet.totalSupply())
        console.log(">>> LP balance of user0:", await poolErc20Facet.balanceOf(user0.address))
        console.log(">>> UDSC balance of user0:", await usdc.balanceOf(user0.address))

        expect ( await poolErc20Facet.symbol() ).to.be.equal( "HSBTCTF01" )
        expect ( await poolErc20Facet.name() ).to.be.equal( "HashStrat TrendFollowing 01" )
        expect ( await poolErc20Facet.totalSupply() ).to.be.equal( 0 )
        expect ( await poolErc20Facet.balanceOf(user0.address) ).to.be.equal(0 )
        expect ( await poolErc20Facet.decimals() ).to.be.equal( 18 )
    })

    it('should add the ERC4626F facet', async () => {

        const { pool, usdc } = await loadFixture(deployPoolDiamondContract);
        const [user0] = await ethers.getSigners();

        await transferFunds(toUsdc('1000'), user0.address)

        // deploy ERC4626 facet
        await performDiamondCut(pool, 'ERC4626Facet');

        // Now can interact with the Pool via its ERC20 interface
        const poolErc20Facet = new Contract(pool.address, erc20_abi, ethers.provider)

        // And it's ERC4626 Tokenized Vault Standard facet
        const poolErc4626Facet = new Contract(pool.address, erc4626_abi, ethers.provider)

        const deposit = toUsdc('200')
        await usdc.connect(user0).approve(pool.address, deposit)
        await poolErc4626Facet.connect(user0).deposit(deposit, user0.address)

        // console.log(">>> LP balance of user0:", await poolErc20Facet.balanceOf(user0.address))
        // console.log(">>> UDSC balance of user0:", await usdc.balanceOf(user0.address))

        expect( await poolErc20Facet.totalSupply() ).to.be.equal(toWei('200'))

    })



    it('should remove some ERC20 functions', async () => {

        const { pool, diamondCutFacet, diamondLoupeFacet, erc20Facet } = await loadFixture(deployPoolDiamondContract);
        const [owner, user0] = await ethers.getSigners();

        // const erc20Facet = await ethers.getContractAt('ERC20Facet', pool.address)
        const diamond = await ethers.getContractAt('DiamondCutFacet', pool.address)
        const diamondLoupe = await ethers.getContractAt('DiamondLoupeFacet', pool.address)

        const poolErc20Facet = new Contract(pool.address, erc20_abi, ethers.provider)

        // console.log(">> all facetAddresses: ", await diamondLoupe.facetAddresses())
        // console.log(">> ERC20Facet facetSelectors0: ", await diamondLoupe.facetFunctionSelectors(erc20Facet.address))

        const functionsToKeep = ['name()', 'symbol()']
        const selectorsToRemove = getSelectors(erc20Facet).remove(functionsToKeep)
        // console.log(">> selectorsToRemove: ", selectorsToRemove)

        const tx = await diamond.connect(owner).diamondCut(
            [{
                facetAddress: ethers.constants.AddressZero,
                action: FacetCutAction.Remove,
                functionSelectors: selectorsToRemove
            }],
            ethers.constants.AddressZero, '0x', { gasLimit: 800000 }
        )

        const receipt = await tx.wait()
        if (!receipt.status) {
            throw Error(`Diamond upgrade failed: ${tx.hash}`)
        }

        const functionsLeft = await diamondLoupe.facetFunctionSelectors(erc20Facet.address)
        const expectedFunctionsLeft = await getSelectors(erc20Facet).get(functionsToKeep);

        expect( functionsLeft ).to.have.members( expectedFunctionsLeft )

        expect( await poolErc20Facet.symbol() ).to.be.equal( "HSBTCTF01" )
        await expect( poolErc20Facet.totalSupply() ).to.be.revertedWith('Diamond: Function does not exist')
    })



})