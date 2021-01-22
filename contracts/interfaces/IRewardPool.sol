pragma solidity ^0.6.0;

interface IRewardPool {
    function notifyRewardAmount(uint256 reward) external;
}