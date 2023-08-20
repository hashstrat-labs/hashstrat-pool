/* global ethers */
import { Contract } from "ethers"
import { ethers  } from "hardhat";

import erc20_abi from "../../scripts/abis/erc20.json";
import addresses from "../../conf/addresses.json";


export const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 }


class SelectorArray extends Array<string> {
    
    contract: Contract;

    constructor(contract: Contract) {
        super();
        this.contract = contract
    }

    // used with getSelectors to get selectors from an array of selectors
    // functionNames argument is an array of function signatures
    get (functionNames: string[]) {

        const selectors = this.filter((v) => {
            for (const functionName of functionNames) {
                if (v === this.contract.interface.getSighash(functionName)) {
                    return true
                }
            }
            return false
        })
        return selectors
    }

    // used to remove some selectors from the contract
    // functionNames is an array of function signatures identifying the functions to be removed 
    remove(functionNames: string[]) {
        const selectors = this.filter((v) => {
        for (const functionName of functionNames) {
              if (v === this.contract.interface.getSighash(functionName)) {
                return false
              }
            }
            return true
        })

        return selectors;
    }
}



// get function selectors from ABI
export function getSelectors (contract: Contract) {
  const signatures = Object.keys(contract.interface.functions)

  const selectors = signatures.reduce((acc, val) => {
    if (val !== 'init(bytes)') {
        acc.push(contract.interface.getSighash(val))
    }
    return acc
  }, new SelectorArray(contract))

//   selectors.contract = contract
//   selectors.remove = remove
//   selectors.get = get
  return selectors
}

// get function selector from function signature
export function getSelector (func: string) {
  const abiInterface = new ethers.utils.Interface([func])
  return abiInterface.getSighash(ethers.utils.Fragment.from(func))
}



// used with getSelectors to get selectors from an array of selectors
// functionNames argument is an array of function signatures
// function get (functionNames) {
//   const selectors = this.filter((v) => {
//     for (const functionName of functionNames) {
//       if (v === this.contract.interface.getSighash(functionName)) {
//         return true
//       }
//     }
//     return false
//   })
//   selectors.contract = this.contract
//   selectors.remove = this.remove
//   selectors.get = this.get
//   return selectors
// }

// remove selectors using an array of signatures
// function removeSelectors (selectors, signatures) {
//   const iface = new ethers.utils.Interface(signatures.map(v => 'function ' + v))
//   const removeSelectors = signatures.map(v => iface.getSighash(v))
//   selectors = selectors.filter(v => !removeSelectors.includes(v))
//   return selectors
// }

// find a particular address position in the return value of diamondLoupeFacet.facets()
// function findAddressPositionInFacets (facetAddress, facets) {
//   for (let i = 0; i < facets.length; i++) {
//     if (facets[i].facetAddress === facetAddress) {
//       return i
//     }
//   }
// }


// exports.removeSelectors = removeSelectors
// exports.findAddressPositionInFacets = findAddressPositionInFacets


// exports.getSelectors = getSelectors
// exports.getSelector = getSelector
// exports.FacetCutAction = FacetCutAction



// exports.remove = remove
// exports.removeSelectors = removeSelectors
// exports.findAddressPositionInFacets = findAddressPositionInFacets




export async function deployPoolDiamondContract() {

    const [contractOwner] = await ethers.getSigners();

    // deploy DiamondCut facet
    const DiamondCutFacet = await ethers.getContractFactory('DiamondCutFacet')
    const diamondCutFacet = await DiamondCutFacet.deploy()

    // deploy Pool Diamond
    const PoolV5Diamond = await ethers.getContractFactory('PoolV5Diamond')
    const pool = await PoolV5Diamond.deploy(contractOwner.address, diamondCutFacet.address)
    await pool.deployed()
    console.log('PoolV5Diamond deployed at ', pool.address, "owner:", contractOwner.address)


    const [diamondLoupeFacet, ownershipFacet] = await initializeDiamondWithFacets(pool, [
        'DiamondLoupeFacet',
        'OwnershipFacet'
    ]);

    // deploy ERC20 facet
    const erc20Facet = await performDiamondCut(pool, 'ERC20Facet',  {
        symbol: "HSBTCTF01",
        name: "HashStrat TrendFollowing 01",
        decimals: 18,
    });

    // deploy PoolV5 facet
    const poolV5Facet = await performDiamondCut(pool, 'PoolV5Facet', {
        stableAssetAddress: addresses.polygon.usdc,
        riskAssetAddress: addresses.polygon.wbtc,
        stableAssetFeedAddress: addresses.polygon.usdc_usd_aggregator,
        riskAssetFeedAddress: addresses.polygon.wbtc_usd_aggregator,
        poolFees: 100,      // 1% fee
        uniswapV3Fee: 3000,
    });

    const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)

    return { pool, diamondCutFacet, diamondLoupeFacet, erc20Facet, poolV5Facet, usdc };
}


export async function initializeDiamondWithFacets(pool: Contract, FacetNames: string[]) {

    console.log('Initialize diamond with facets: ', FacetNames)
    // deploy DiamondInit
    // DiamondInit provides a function that is called when the diamond is upgraded to initialize state variables
    // Read about how the diamondCut function works here: https://eips.ethereum.org/EIPS/eip-2535#addingreplacingremoving-functions
    const DiamondInit = await ethers.getContractFactory('DiamondInit')
    const diamondInit = await DiamondInit.deploy()
    await diamondInit.deployed()
    console.log('DiamondInit deployed:', diamondInit.address)

    let deployedFacets = []

    const cut = []
    for (const FacetName of FacetNames) {
        const Facet = await ethers.getContractFactory(FacetName)
        const facet = await Facet.deploy()
        await facet.deployed()
        console.log(`${FacetName} deployed: ${facet.address}`)

        cut.push({
            facetAddress: facet.address,
            action: FacetCutAction.Add,
            functionSelectors: getSelectors(facet)
        })

        deployedFacets.push(facet);
    }

    // upgrade diamond with facets
    // console.log('Diamond Cut:', cut)

    // Get interface of IDiamondCut for the Diamond deploed at the Pool address
    const diamondCut = await ethers.getContractAt('IDiamondCut', pool.address)
    let functionCall = diamondInit.interface.encodeFunctionData('init')

    const tx = await diamondCut.diamondCut(cut, diamondInit.address, functionCall)
    console.log('Diamond cut tx: ', tx.hash)
    
    const receipt = await tx.wait()
    if (!receipt.status) {
        throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    console.log('Completed diamond init')

    return deployedFacets;
}


export async function performDiamondCut(
        pool: Contract, 
        FacetName: string,
        args? : any | undefined,
    ) {

    console.log('Deploying facet: ', FacetName)
    const cut = []

    const Facet = await ethers.getContractFactory(FacetName)
    const facet = await Facet.deploy()
    await facet.deployed()
    console.log(`Facet ${FacetName} deployed at ${facet.address}`)
    cut.push({
        facetAddress: facet.address,
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(facet)
    })
 
     // upgrade diamond with facet
    //  console.log('Diamond Cut:', cut)

    // Get interface of IDiamondCut for the Diamond deploed at the Pool address
    const diamondCut = await ethers.getContractAt('IDiamondCut', pool.address)
    
    // call to init function

    let functionCallInit = args === undefined ? 
        facet.interface.encodeFunctionData('init') : 
        facet.interface.encodeFunctionData('init', [args]);

    const initContractAddr = args !== undefined ? facet.address : ethers.constants.AddressZero 

    // console.log(">>> init - functionCall: ", functionCallInit, "init address: ", initContractAddr)

    const tx = await diamondCut.diamondCut(cut, initContractAddr, functionCallInit)
    console.log('Diamond cut tx: ', tx.hash)
    
    const receipt = await tx.wait()
    if (!receipt.status) {
        throw Error(`Diamond upgrade failed: ${tx.hash}`)
    }
    console.log('Completed diamond cut - receipt status: ', receipt.status)

    return facet;
}
