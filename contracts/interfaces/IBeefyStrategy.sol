// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IBeefyStrategy {
    function vault() external view returns (address);
    function want() external view returns (address);
    function unirouter() external view returns (address);
    function lpToken0() external view returns (address);
    function lpToken1() external view returns (address);
    function outputToLp0() external view returns (address[] memory);
    function outputToLp1() external view returns (address[] memory);
}
