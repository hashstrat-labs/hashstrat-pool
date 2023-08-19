/* ==========================================================================================
Tests the PoolV5 diamond and facets.

@author: Carlo Pascoli
============================================================================================= */

import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { Contract } from "ethers"
import { ethers } from "hardhat";

import { getSelectors, FacetCutAction, deployPoolDiamondContract, performDiamondCut } from './utils/diamond'

import { transferFunds, toUsdc } from "./helpers"


import erc20_abi from "./abi/erc20.json"
import erc4626_abi from "../abi/ERC4626Facet.json"
import addresses from "../conf/addresses.json";

// // HELPER: get function selectors from a contract
// function getSelectors (contract: Contract) {
 
//   // get the function signatures from the ABI of the contract:
//   const signatures = Object.keys(contract.interface.functions)

//   console.log(">>> ERC20 Facet function signatures: ", signatures)
  
//   // convert from signature to selector:
//   const selectors = signatures.reduce((acc, val) => {
//     acc.push(contract.interface.getSighash(val))
//     return acc
//   }, [] as string[])
//   return selectors
// }




describe('Create a PoolV5 Diamond', async function () {

  it('should add the ERC20 facet', async () => {

    const { pool, diamondInit, usdc  } = await loadFixture(deployPoolDiamondContract);

    const [ deployer, user0, user1 ] = await ethers.getSigners();

  
    await transferFunds( toUsdc('1000'), user0.address)

    // deploy ERC20 facet

    // 'ERC4626Facet', 'PoolV5Facet' 
 
    await performDiamondCut(pool, 'ERC20Facet',  {
        symbol: "HSBTCTF01",
        name: "HashStrat TrendFollowing 01",
        decimals: 18,
    });


    // address stableAssetAddress;
   
    await performDiamondCut(pool, 'PoolV5Facet', {
        stableAssetAddress: addresses.polygon.usdc,
        riskAssetAddress: addresses.polygon.wbtc,
        stableAssetFeedAddress: addresses.polygon.usdc_usd_aggregator,
        riskAssetFeedAddress: addresses.polygon.wbtc_usd_aggregator,
        poolFees: 100,      // 1% fee
        uniswapV3Fee: 3000,
    });

    await performDiamondCut(pool, 'ERC4626Facet');


    // Now can interact with the Pool via its ERC20 interface
    const poolErc20Facet = new Contract(pool.address, erc20_abi, ethers.provider)
    console.log(">>> totalSupply:", await poolErc20Facet.totalSupply() )
    console.log(">>> LP balance of user0:", await poolErc20Facet.balanceOf(user0.address) )
    console.log(">>> UDSC balance of user0:", await usdc.balanceOf(user0.address) )
  
    // And it's ERC4626 Tokenized Vault Standard facet
    const poolErc4626Facet = new Contract(pool.address, erc4626_abi, ethers.provider)

    const deposit = toUsdc('200') 
    await usdc.connect(user0).approve(pool.address, deposit)
    await poolErc4626Facet.connect(user0).deposit(deposit, user0.address) 

    console.log(">>> totalSupply:", await poolErc20Facet.totalSupply() )
    console.log(">>> LP balance of user0:", await poolErc20Facet.balanceOf(user0.address) )
    console.log(">>> UDSC balance of user0:", await usdc.balanceOf(user0.address) )


  })

  // Now test general behavior and expect that the NFT and ERC20 features work
//   it('should mint the nft as expected and be able to transfer it', async () => {
//     const nftFacet = await ethers.getContractAt('NFTFacet', diamond.address)

//     await expect(nftFacet.ownerOf(0)).to.be.revertedWith("ERC721: invalid token ID")
//     await expect(nftFacet.ownerOf(1)).to.be.revertedWith("ERC721: invalid token ID")
//     expect(await nftFacet.balanceOf(alice.address)).to.equal(0)

//     tx = await nftFacet.mint(alice.address, 1)
//     await tx.wait()

//     // confirm that alice got the NFT
//     expect(await nftFacet.balanceOf(alice.address)).to.equal(1)
//     await expect(nftFacet.ownerOf(0)).to.be.revertedWith("ERC721: invalid token ID")
//     expect(await nftFacet.ownerOf(1)).to.equal(alice.address)

//     tx = await nftFacet.connect(alice).transfer(bob.address, 1)
//     await tx.wait()

//     expect(await nftFacet.balanceOf(alice.address)).to.equal(0)
//     expect(await nftFacet.balanceOf(bob.address)).to.equal(1)

//     // bob burns it
//     tx = await nftFacet.connect(bob).burn(1)
//     await tx.wait()

//     // it's gone:
//     expect(await nftFacet.balanceOf(alice.address)).to.equal(0)
//     expect(await nftFacet.balanceOf(bob.address)).to.equal(0)

//     // mint more
//     tx = await nftFacet.mint(alice.address, 0)
//     await tx.wait()
//     tx = await nftFacet.mint(bob.address, 1)
//     await tx.wait()
//     tx = await nftFacet.mint(bob.address, 2)
//     await tx.wait()

//     // make sure balances and ownership are correct
//     expect(await nftFacet.balanceOf(alice.address)).to.equal(1)
//     expect(await nftFacet.balanceOf(bob.address)).to.equal(2)
    
//     expect(await nftFacet.ownerOf(0)).to.equal(alice.address)
//     expect(await nftFacet.ownerOf(1)).to.equal(bob.address)
//     expect(await nftFacet.ownerOf(2)).to.equal(bob.address)
//   })


//   it('should add the ERC20 facet', async () => {
//     // we need to link the ERC20Facet to its Library function first:
//     // const ERC20lib = await ethers.getContractFactory('LibERC20')
//     // const erc20lib = await ERC20lib.deploy()
//     // await erc20lib.deployed()

//     const ERC20Facet = await ethers.getContractFactory('ERC20Facet')
//     const erc20Facet = await ERC20Facet.deploy()
//     await erc20Facet.deployed()
//     // now we have the NFT Facet deployed with its library dependency

//     // get all the function selectors covered by this facet - we need that during the cut below:
//     const selectors = getSelectors(erc20Facet)

//     // now make the diamond cut (register the facet) - cut the ERC20 Facet onto the diamond:
//     tx = await diamond.diamondCut(
//       {
//         facetAddress: erc20Facet.address, // the nft facet is deployed here
//         functionSelectors: selectors // these are the selectors of this facet (the functions that are supported)
//       }, { gasLimit: 800000 }
//     )
//     receipt = await tx.wait()
//     if (!receipt.status) {
//       throw Error(`Diamond upgrade failed: ${tx.hash}`)
//     }
//   })

 
})