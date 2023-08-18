// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;


// https://eips.ethereum.org/EIPS/eip-2612
// function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external
// function nonces(address owner) external view returns (uint)
// function DOMAIN_SEPARATOR() external view returns (bytes32)

interface IERC2612 {

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    function nonces(address owner) external view returns (uint);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}