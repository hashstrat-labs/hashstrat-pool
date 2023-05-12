import { Contract, BigNumber } from "ethers";
import { ethers, network } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import addresses from "../conf/addresses.json"


import { impersonateAccount } from "@nomicfoundation/hardhat-network-helpers";

import erc20_abi from "../scripts/abis/erc20.json";


export const round = (n : number, d=2) => {
    return Math.round(n * (10**d)) / (10**d)
}


export const fromWei = (value : BigNumber, d=18) : Number => {
    if (d==18) return Number(ethers.utils.formatUnits(value, 'ether'))
    if (d==9) return Number(ethers.utils.formatUnits(value, 'gwei'))
    if (d==6) return Number(ethers.utils.formatUnits(value, 'mwei'))

    throw Error(`not supported decimal: ${d}`)
}


export const toWei = (value : string, d=18) => {
    if (d==18) return ethers.utils.parseUnits(value, 'ether')
    if (d==9) return ethers.utils.parseUnits(value, 'gwei')
    if (d==6) return ethers.utils.parseUnits(value, 'mwei')

    throw Error(`not supported decimal: ${d}`)
}


export const fromUsdc = (v: BigNumber) => {
    return  fromUnits(v, 6, 10)
}

export const fromBtc = (v: BigNumber) => {
    return fromUnits(v, 8, 10)
}

export const toUsdc = (value: string | number) => {
    return ethers.utils.parseUnits(value.toString(), 'mwei')
}

export const toWbtc = (value: string | number) => {
    return toUnits(value, 8)
}


export async function waitSeconds(secs: number) {
	const ts = (await time.latest()) + secs
	await time.increaseTo(ts)
}

export async function waitDays(days: number) {
	const DAYS_IN_SECS =  days * 24 * 60 * 60;
	const daysInSecs = (await time.latest()) + DAYS_IN_SECS
	await time.increaseTo(daysInSecs)
}

export async function mineBlocks(blocks: number) {
    await network.provider.send("hardhat_mine", ['0x' + blocks.toString(16) ] );
}


export async function transferFunds(amount: number | BigNumber, recipient: string, token : "usdc" | "btc" = "usdc") {

	// 48,354,222.149244   100.000000
	const tokenContract = token === 'usdc' ? new Contract(addresses.polygon.usdc, erc20_abi, ethers.provider) :
                                             new Contract(addresses.polygon.wbtc, erc20_abi, ethers.provider)
                
	await impersonateAccount(token === 'usdc' ? addresses.polygon.usd_holder : addresses.polygon.btc_holder);
	const signer = await ethers.getSigner( token === 'usdc' ? addresses.polygon.usd_holder : addresses.polygon.btc_holder );

	// const signer = await ethers.getSigner(usdcSource);
	await tokenContract.connect(signer).transfer(recipient, amount)
}

export const fromUnits = (amount: BigNumber, decimals: Number, precision: Number) => {

    const decimalsFactor =  BigNumber.from('10').pow( BigNumber.from(decimals) ); 
    const precisionFactor =  BigNumber.from('10').pow(BigNumber.from(precision)); 
    const number = BigNumber.from(amount).mul(precisionFactor).div(decimalsFactor)

    const decimal = (number.toString().length > 15) ? 
        number.div(precisionFactor).toNumber()   :
        number.toNumber() / precisionFactor.toNumber()

    return decimal
}

export const toUnits = (amount: string | number, decimals: number = 18) => {
    const formatted = ethers.utils.parseUnits(amount.toString(), decimals)
    return formatted
}

export const delay = (ms: number) => {
    return new Promise( resolve => setTimeout(resolve, ms) );
}
