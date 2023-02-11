import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-etherscan";
import "hardhat-abi-exporter";
import "hardhat-contract-sizer";

require('dotenv').config()


const { RPC_URL_POLYGON_MAIN, RPC_URL_GOERLI, ETHERSCAN_API_KEY, POLYGONSCAN_API_KEY, MNEMONIC } = process.env;

const config : HardhatUserConfig = {
  
  defaultNetwork: "hardhat",

  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },

  abiExporter: {
    path: './build/abi',
    clear: true,
    flat: true,
    spacing: 2,
  },

  gasReporter: {
    enabled: true,
    outputFile: "gas-report.txt",
    noColors: true,
    showTimeSpent: true,
    currency: 'USD',
    gasPrice: 200
  },

  networks: {
    hardhat: {
      forking: {
        url: RPC_URL_POLYGON_MAIN || "",
        blockNumber: 38702537 // 38701099
      }
    },
    goerli: {
      url: RPC_URL_GOERLI,
      accounts: { mnemonic: MNEMONIC  },
    },
    polygon: {
      url: RPC_URL_POLYGON_MAIN,
      accounts: { mnemonic: MNEMONIC  },
      gasPrice:  120000000000,  // 120 Gwei
    },
  },

  etherscan: {
    apiKey: {
        mainnet: ETHERSCAN_API_KEY || "",
        polygon: POLYGONSCAN_API_KEY || "",
        goerli: '',
    }
  },
};

export default config;
