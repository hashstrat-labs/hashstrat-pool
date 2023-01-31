import { ethers } from "hardhat";


const wallet_address = '0x4F888d90c31c97efA63f0Db088578BB6F9D1970C'

async function main() {
	const tx = await ethers.provider.getTransactionCount(wallet_address)
	console.log("TX count >>>", tx)  // 1116  --> 1124
}


// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});

