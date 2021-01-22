pragma solidity ^0.6.0;

interface ITreasury {
    function initialize(
        uint256 _accumulatedSeigniorage,
        uint256 _accumulatedDebt,
        uint256 _bondPriceOnONC,
        uint256 _oraclePriceOne
    ) external;
}