// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface IGoSwapCompany {
    function factory() external pure returns (address);
    function pairForFactory(address tokenA, address tokenB) external pure returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}
