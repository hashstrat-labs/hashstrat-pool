/* global ethers */
import { Contract } from "ethers"
import { ethers  } from "hardhat";
import { deployMockContract } from "@ethereum-waffle/mock-contract"

import { fromUsdc, toUsdc, toWbtc, transferFunds } from "../helpers"

import erc20_abi from "../../scripts/abis/erc20.json";
import addresses from "../../conf/addresses.json";

import enums from "../../conf/enums.json";


import price_feed_aggreagator_abi from "../abi/price_feed_aggreagator.json"
import quoter_uniswap_abi from "../abi/quoter_uniswap.json"
import poolv5_abi from "../abi/poolV5.json"


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




export async function deployPoolDiamondContract() {

    const [deployer] = await ethers.getSigners();

    const usdc = new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider)
    const wbtc = new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)
	const wbtcFeed = new Contract(addresses.polygon.wbtc_usd_aggregator, price_feed_aggreagator_abi, ethers.provider)
 

    // Deploy Router
    const SwapsRouter = await ethers.getContractFactory("SwapsRouter")
    const swapRouter = await SwapsRouter.deploy(
        addresses.polygon.uniswap_v3_quoter,
        addresses.polygon.quickswap_v3_quoter
    )
    await swapRouter.deployed(); 

    // Configure Router
    await swapRouter.addRouter( addresses.polygon.uniswap_v3_router, enums.RouterVersion.V3, enums.RouterType.Uniswap )
    await swapRouter.addRouter( addresses.polygon.quickswap_v3_router, enums.RouterVersion.V3, enums.RouterType.QuickSwap )
    await swapRouter.addRouter( addresses.polygon.quickswap_v2_router, enums.RouterVersion.V2, enums.RouterType.QuickSwap )
    await swapRouter.setActiveRouter(0)

    // deploy DiamondCut facet
    const DiamondCutFacet = await ethers.getContractFactory('DiamondCutFacet')
    const diamondCutFacet = await DiamondCutFacet.deploy()

    // deploy Pool Diamond
    const PoolV5Diamond = await ethers.getContractFactory('PoolV5Diamond')
    const diamond = await PoolV5Diamond.deploy(deployer.address, diamondCutFacet.address)
    await diamond.deployed()
    console.log('PoolV5Diamond deployed at ', diamond.address, "owner:", deployer.address)


    const [diamondLoupeFacet, _] = await initializeDiamondWithFacets(diamond, [
        'DiamondLoupeFacet',
        'OwnershipFacet'
    ]);

    // deploy ERC20 facet
    const decimals = await usdc.decimals();
    const erc20Facet = await performDiamondCut(diamond, 'ERC20Facet',  {
        symbol: "HSBTCTF01",
        name: "HashStrat TrendFollowing 01",
        decimals: decimals,
    });

    const poolV5Facet = await performDiamondCut(diamond, 'PoolV5Facet', {
        stableAssetAddress: addresses.polygon.usdc,
        riskAssetAddress: addresses.polygon.wbtc,
        stableAssetFeedAddress: addresses.polygon.usdc_usd_aggregator,
        riskAssetFeedAddress: addresses.polygon.wbtc_usd_aggregator,
        daoTokenFarmAddress: ethers.constants.AddressZero
    });


    const feesFacet = await performDiamondCut(diamond, 'FeesFacet', {
        feesPerc: 100 // 1% fee
    });

    const swapsFacet = await performDiamondCut(diamond, 'SwapsFacet', {
        swapInterval: 5 * 60,
        maxSlippage: 100,
        swapMaxValue: 10_000 * 10 ** 6,  // 10k per swap
        swapRouter: swapRouter.address,
        feeV3: 3000
    });

    const userInfoFacet = await performDiamondCut(diamond, 'UserInfoFacet');


    // Depoly Strategy
    const RebalancingStrategyV1 = await ethers.getContractFactory("RebalancingStrategyV1")

    const strategy = await RebalancingStrategyV1.deploy(
        diamond.address,
        addresses.polygon.usdc_usd_aggregator,
        addresses.polygon.wbtc_usd_aggregator,
        addresses.polygon.usdc, 
        addresses.polygon.wbtc, 
        60,   // target portfolio 60% WBTC / 40% USDC
        10,   // 10% seems a good rebalancing band that requires price to double or halve to rebalance
    ); 
    await strategy.deployed()

    // Transfer strategy ownership to the Pool
    await strategy.transferOwnership(diamond.address)

 
    const strategyFacet = await performDiamondCut(diamond, 'StrategyFacet', {
        strategyAddress: strategy.address,
        upkeepInterval: 24 * 60 * 60
    });
    

    const pool = new Contract(diamond.address, poolv5_abi, ethers.provider)
 
    return { pool, strategy, swapRouter,  usdc, wbtc, wbtcFeed,
        diamondCutFacet, 
        diamondLoupeFacet, 
        erc20Facet, 
        poolV5Facet, 
        strategyFacet, 
        feesFacet,
        swapsFacet, 
        userInfoFacet,
    };
}



export async function deployPoolDiamondContractWithMocks() {

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
        wbtcAggregatorMock.address,
    )
    
    await uniswapV2RouterMock.deployed()

    await transferFunds(toUsdc('100000'), uniswapV2RouterMock.address, "usdc")
    await transferFunds(toWbtc('5'), uniswapV2RouterMock.address, "btc")

    // prepare mocks
    await usdcAggregatorMock.mock.latestRoundData.returns( 0, 100000000, 1801686057, 1801686057, 0 ); 
    await usdcAggregatorMock.mock.decimals.returns( 8 ); 

    await wbtcAggregatorMock.mock.latestRoundData.returns( 0, 2000000000000, 1801686057, 1801686057, 0 ); 
    await wbtcAggregatorMock.mock.decimals.returns( 8 ); 

    // Deploy Router
    const SwapsRouter = await ethers.getContractFactory("SwapsRouter")
    const swapRouter = await SwapsRouter.deploy(
        quoterUniswapPMock.address,
        addresses.polygon.quickswap_v3_quoter
    )
    await swapRouter.deployed();
 

    // Depoly Diamond
    const DiamondCutFacet = await ethers.getContractFactory('DiamondCutFacet')
    const diamondCutFacet = await DiamondCutFacet.deploy()

    const PoolV5Diamond = await ethers.getContractFactory('PoolV5Diamond')
    const diamond = await PoolV5Diamond.deploy(deployer.address, diamondCutFacet.address)
    await diamond.deployed()
    console.log('PoolV5Diamond deployed at ', diamond.address, "owner:", deployer.address)

    const [diamondLoupeFacet, _] = await initializeDiamondWithFacets(diamond, [
        'DiamondLoupeFacet',
        'OwnershipFacet'
    ]);


    // Depoly Strategy
    const RebalancingStrategyV1 = await ethers.getContractFactory("RebalancingStrategyV1")

    const strategy = await RebalancingStrategyV1.deploy(
        diamond.address,
        usdcAggregatorMock.address,
        wbtcAggregatorMock.address,
        addresses.polygon.usdc,
        addresses.polygon.wbtc,
        60,   // target portfolio 60% WBTC / 40% USDC
        10,   // 10% seems a good rebalancing band that requires price to double or halve to rebalance
    ); 
    await strategy.deployed()
    
    // Transfer strategy ownership to the Pool
    await strategy.transferOwnership(diamond.address)


    // deploy Facets
    const decimals = await usdc.decimals();
    const erc20Facet = await performDiamondCut(diamond, 'ERC20Facet',  {
        symbol: "HSBTCTF01",
        name: "HashStrat TrendFollowing 01",
        decimals: decimals,
    });


    const poolV5Facet = await performDiamondCut(diamond, 'PoolV5Facet', {
        stableAssetAddress: addresses.polygon.usdc,
        riskAssetAddress: addresses.polygon.wbtc,
        stableAssetFeedAddress: usdcAggregatorMock.address,
        riskAssetFeedAddress: wbtcAggregatorMock.address,
        daoTokenFarmAddress: ethers.constants.AddressZero
    });

    const feesFacet = await performDiamondCut(diamond, 'FeesFacet', {
        feesPerc: 100 // 1% fee
    });

    const swapsFacet = await performDiamondCut(diamond, 'SwapsFacet', {
        swapInterval: 5 * 60,
        maxSlippage: 100,
        swapMaxValue: 10_000 * 10 ** 6,  // 10k per swap
        swapRouter: swapRouter.address,
        feeV3: 3000
    });

    const userInfoFacet = await performDiamondCut(diamond, 'UserInfoFacet');

    const strategyFacet = await performDiamondCut(diamond, 'StrategyFacet', {
        strategyAddress: strategy.address,
        upkeepInterval: 24 * 60 * 60
    });
    

    // Wrap the Diamond into the PoolV5 abi
    const pool = new Contract(diamond.address, poolv5_abi, ethers.provider)

    // Configure SwapRouter
    await swapRouter.addRouter(uniswapV2RouterMock.address, enums.RouterVersion.V2, enums.RouterType.QuickSwap)
    await swapRouter.setActiveRouter(0)

    return {
        swapRouter, strategy, pool, usdc, wbtc,
        usdcAggregatorMock, wbtcAggregatorMock, quoterUniswapPMock, uniswapV2RouterMock
    };
}

export async function initializeDiamondWithFacets(pool: Contract, FacetNames: string[]) {

    console.log('Initialize diamond with facets: ', FacetNames)
    // deploy DiamondInit
    // DiamondInit provides a function that is called when the diamond is upgraded to initialize state variables
    // Read about how the diamondCut function works here: https://eips.ethereum.org/EIPS/eip-2535#addingreplacingremoving-functions
    const DiamondInit = await ethers.getContractFactory('DiamondInit')
    const diamondInit = await DiamondInit.deploy()
    await diamondInit.deployed()

    const receipt0 = await diamondInit.deployTransaction.wait();
    if (!receipt0.status) {
        throw Error(`DiamondInit failed: ${diamondInit.deployTransaction.hash}`)
    }

    if (receipt0.gasUsed) {
        console.log(`DiamondInit deployment - address: ${diamondInit.address} - gasUsed: `, receipt0.gasUsed.toString(), "tx: ", receipt0.transactionHash)
    }

    let deployedFacets = []

    const cut = []
    for (const FacetName of FacetNames) {
        const Facet = await ethers.getContractFactory(FacetName)
        const facet = await Facet.deploy()
        await facet.deployed()
        const receipt = await facet.deployTransaction.wait();
        if (receipt.gasUsed) {
            console.log(`${FacetName} deployment - address: ${facet.address} - gasUsed: `, receipt.gasUsed.toString(), "tx: ", receipt.transactionHash)
        }

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
    const receipt = await tx.wait()
    if (!receipt.status) {
        throw Error(`Diamond cut ${FacetNames} failed: ${tx.hash}`)
    }

    if (receipt.gasUsed) {
        console.log(`Diamond cut ${FacetNames} - gasUsed: `, receipt.gasUsed.toString(), "tx: ", tx.hash)
    }

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


    const txReceipt = await facet.deployTransaction.wait();
    console.log(`${FacetName} deployment - address: ${facet.address} - gasUsed: ${txReceipt.gasUsed.toString()} tx: ${txReceipt.transactionHash}`);
 
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

    console.log(`Completed diamond cut ${FacetName} - receipt status: `, receipt.status, " gas used: ", receipt.gasUsed.toString())

    return facet;
}
