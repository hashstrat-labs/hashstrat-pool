/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import { IERC4626 } from "../interfaces/IERC4626.sol";

/**
 * @notice The lobrary files supporting the ERC4626 Facet of the Diamond.
 *
 */
library LibERC4626 {
    /***************************************************************************************
               Library to support the ERC4626 Facet (contracts/facets/ERC4626Facet.sol)
    ****************************************************************************************/
    
    /** ==================================================================
                            ERC4626 Storage Space
    =====================================================================*/
    // each facet gets their own struct to store state into
    bytes32 constant ERC4626_STORAGE_POSITION = keccak256("facet.erc4626.diamond.storage");

    /**
     * @notice ERC4626 storage for the ERC4626 facet
     */
    struct Storage {
        // uint256 _totalSupply;
        mapping(address => uint256) _balances;
        mapping(address => mapping(address => uint256)) _allowances;
    }
    
    // access erc4626 storage via:
    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = ERC4626_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    // event Approval(address indexed owner, address indexed spender, uint256 value);
    // event Transfer(address indexed from, address indexed to, uint256 value);



  
}