import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-etherscan";
import "hardhat-abi-exporter";
import "hardhat-contract-sizer";

require('dotenv').config()


const { RPC_URL_POLYGON_MAIN, RPC_URL_GOERLI, ETHERSCAN_API_KEY, POLYGONSCAN_API_KEY, MNEMONIC, DEPLOYER_PRIVATE_KEY } = process.env;

const config : HardhatUserConfig = {
  
  defaultNetwork: "hardhat",

  solidity: {
    version: "0.8.14",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  paths: {
    // sources: './contracts',
    // tests: './test',
    // cache: './cache',
    // artifacts: './artifacts',
  },

  mocha: {
    timeout: 60000
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

  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
    only: [':PoolV5$', ':PoolV5Diamond$'],
  },

  networks: {
    hardhat: {
      forking: {
        url: RPC_URL_POLYGON_MAIN || ",",
        blockNumber: 42817100  // 42449622// post V4 deploymet: 42449622 // 42001664 // 42293851      // hack start block: 42001665  - hack end block: 42003217 ,
      },
      accounts: {accountsBalance: "10000000000000000000000"}
    },
    goerli: {
      url: RPC_URL_GOERLI,
      // accounts: { mnemonic: MNEMONIC  },
      accounts: [DEPLOYER_PRIVATE_KEY ?? ""],
    },
    polygon: {
      url: RPC_URL_POLYGON_MAIN,
      // accounts: { mnemonic: MNEMONIC  },
      accounts: [DEPLOYER_PRIVATE_KEY ?? ""],
      gasPrice:  180000000000,  // 250 Gwei
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
