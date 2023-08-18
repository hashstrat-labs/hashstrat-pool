// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LibERC20 } from  "../libraries/LibERC20.sol";
import { LibDiamond } from "../diamond/libraries/LibDiamond.sol";

// LibERC20

/**
 * @notice the ERC20 Token Facet contract which will be registered with the Diamond contract as its facet.
 * @author Jesper Kristensen
 */
contract ERC20Facet {

    function totalSupply() external view returns (uint256) {
        return LibERC20.erc20totalSupply();
    }


    function balanceOf(address account) external view returns (uint256) {
        return LibERC20.erc20balanceOf(account);
    }


    function allowance(address owner, address spender) external view returns (uint256) {
        return LibERC20._erc20allowance(owner, spender);
    }


    function approve(address spender, uint256 amount) external returns (bool) {
        address owner = _msgSender();
        return LibERC20.erc20approve(owner, spender, amount);
    }


    function transfer(address to, uint256 amount) external returns (bool) {
        return LibERC20.erc20transfer(to, amount);
    }


    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        address spender = _msgSender();
        return LibERC20.erc20transferFrom(spender, from, to, amount);
    }


    //// Mint and Buring buction for owner only ////
    //TODO implemnent enforceIsMinter based on MinterRole.onlyMinter
    function mint(address to, uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibERC20.erc20mint(to, amount);
    }

    function burn(address to, uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibERC20.erc20burn(to, amount);
    }

    function _msgSender() private view returns (address) {
        return msg.sender;
    }
}