// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MinterRole.sol";

/**
 * The LP Token for the Pool representing the share of the value of the Pool held by ther owner.
 * When users deposit into the pool new LP tokens get minted.
 * When users withdraw their funds from the pool, they have to retun their LP tokens which get burt.
 * Only the Pool contract should be able to mint/burn its LP tokens.
 */

contract PoolLPToken is ERC20, MinterRole {

    uint8 immutable decs;

    constructor (string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        decs = _decimals;
    }

    function mint(address to, uint256 value) public onlyMinter returns (bool) {
        _mint(to, value);
        return true;
    }

    function burn(address to, uint256 value) public onlyMinter returns (bool) {
        _burn(to, value);
        return true;
    }

    function decimals() public view override returns (uint8) {
        return decs;
    }

}

