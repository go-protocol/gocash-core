// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IDistributor.sol';
import '../interfaces/IRewardDistribution.sol';


contract InitialGOTHUSDDistributor is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 cashAmount);
    /// @notice 只能运行一次
    bool public once = true;

    /// @notice GOT地址
    IERC20 public GOT;
    /// @notice GOTHUSDLPPool 矿池地址
    IRewardDistribution public GOTHUSDLPPool;
    /// @notice GOTHUSD 初始奖励
    uint256 public GOTHUSDInitialBalance;

    /**
    * @dev 构造函数
    * @param _GOTHUSDLPPool GOTHUSDLPPool 矿池地址
    * @param _GOTHUSDInitialBalance GOTHUSD 初始奖励
     */
    constructor(
        IRewardDistribution _GOTHUSDLPPool,
        uint256 _GOTHUSDInitialBalance
    ) public {
        GOT = IERC20(_GOTHUSDLPPool.GOT());
        GOTHUSDLPPool = _GOTHUSDLPPool;
        GOTHUSDInitialBalance = _GOTHUSDInitialBalance;
    }

    /**
    * @dev 分发奖励
     */
    function distribute() public override {
        require(
            once,
            'InitialGOTDistributor: you cannot run this function twice'
        );
        // 将奖励的GOT发送给GOTHUSDLPPool 矿池地址
        GOT.transfer(address(GOTHUSDLPPool), GOTHUSDInitialBalance);
        // 通知奖励
        GOTHUSDLPPool.notifyRewardAmount(GOTHUSDInitialBalance);
        // 触发分发事件
        emit Distributed(address(GOTHUSDLPPool), GOTHUSDInitialBalance);

        once = false;
    }
}
