/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import { LibSwaps } from "./LibSwaps.sol";
import { LibStrategy } from "./LibStrategy.sol";
import { LibSwaps } from "./LibSwaps.sol";
import { IStrategy } from "../strategies/IStrategy.sol";

import "hardhat/console.sol";

/**
 * @notice The library supporting the Automation functionality of the Diamond.
 */
library LibAutomation {

    function checkUpkeep() internal view returns (bool upkeepNeeded) {
        bool strategyUpkeep = IStrategy(LibStrategy.strategy()).shouldPerformUpkeep();
        bool shouldProcessSwap = LibSwaps.shouldProcessSwap();

        upkeepNeeded = shouldProcessSwap || strategyUpkeep;
    }

    /**
     *  Run the strategy if needed, otherwise process the TWAP swap if there is one in progress.
     *  Important: strategy exeution must take priority over an incompleted TWAP swap. 
     */
    function performUpkeep() internal  {
        if (LibStrategy.shouldPerformUpkeep()) {
             console.log("LibAutomation.strategyExec()");
            LibStrategy.strategyExec();

        } else if (LibSwaps.shouldProcessSwap()) {
            console.log("LibAutomation.handleTwapSwap()");
            LibSwaps.handleTwapSwap();
        }
    }
}

