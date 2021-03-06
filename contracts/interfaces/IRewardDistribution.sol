pragma solidity ^0.6.0;

interface IRewardDistribution {
    function notifyRewardAmount(uint256 reward) external;
    function GOT() external view returns(address);
}