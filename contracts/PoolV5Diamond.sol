// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.14;

import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

import { LibDiamond } from "./diamond/libraries/LibDiamond.sol";
import { IDiamondCut } from "./diamond/interfaces/IDiamondCut.sol";
import { LibAutomation } from "./libraries/LibAutomation.sol";


/**
 * The contract of the HashStrat Pool. A pool is a digital valult that holds:
 * - A risk asset (e.g WETH or WBTC), also called invest token.
 * - A stable asset (e.g USDC), also called depoist token.
 * Each pool is configured with:
 * - Chainlink price feeds for the risk and stable assets of the pool.
 * - A Strategy, that represent the rules about how to trade between the risk asset and the stable asset in the pool.
 * - A SwapsRouter, that will route the swaps performed by the strategy to the appropriate AMM.
 * - Addresses of the tokens used by the pool: the pool LP token, a deposit and a risk tokens.
 *
 * Users who deposit funds into a pool receive an amount LP tokens proportional to the value they provided.
 * Users withdraw their funds by returning their LP tokens to the pool, that get burnt.
 * A Pool can charge a fee to the profits withdrawn from the pool in the form of percentage of LP tokens that
 * will remain in the pool at the time when users withdraws their funds.
 * A pool automates the execution of its strategy and the executon of swaps using ChainLink Automation.
 * Large swaps are broken into up to 256 smaller chunks and executed over a period of time to reduce slippage.
 */

contract PoolV5Diamond is AutomationCompatibleInterface {    

    constructor(address _contractOwner, address _diamondCutFacet) payable {        
        LibDiamond.setContractOwner(_contractOwner);

        // Add the diamondCut external function from the diamondCutFacet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet, 
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectors
        });
        LibDiamond.diamondCut(cut, address(0), "");        
    }


    //// implement the AutomationCompatibleInterface ////

    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = LibAutomation.checkUpkeep();
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        LibAutomation.performUpkeep();
    }


    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = address(bytes20(ds.facets[msg.sig]));
        require(facet != address(0), "Diamond: Function does not exist");
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
                case 0 {
                    revert(0, returndatasize())
                }
                default {
                    return(0, returndatasize())
                }
        }
    }

    receive() external payable {}
}
