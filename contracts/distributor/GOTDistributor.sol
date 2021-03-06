// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IDistributor.sol';
import '../interfaces/IRewardDistribution.sol';


contract InitialGOTDistributor is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 cashAmount);
    /// @notice 只能运行一次
    bool public once = true;

    /// @notice GOT地址
    IERC20 public GOT;
    /// @notice HTHUSDLPPool 矿池地址
    IRewardDistribution public HTHUSDLPPool;
    /// @notice HTHUSD 初始奖励
    uint256 public HTHUSDInitialBalance;

    /**
    * @dev 构造函数
    * @param _GOT GOT地址
    * @param _HTHUSDLPPool HTHUSDLPPool 矿池地址
    * @param _HTHUSDInitialBalance HTHUSD 初始奖励
     */
    constructor(
        IERC20 _GOT,
        IRewardDistribution _HTHUSDLPPool,
        uint256 _HTHUSDInitialBalance
    ) public {
        GOT = _GOT;
        HTHUSDLPPool = _HTHUSDLPPool;
        HTHUSDInitialBalance = _HTHUSDInitialBalance;
    }

    /**
    * @dev 分发奖励
     */
    function distribute() public override {
        require(
            once,
            'InitialGOTDistributor: you cannot run this function twice'
        );
        // 将奖励的GOT发送给HTHUSDLPPool 矿池地址
        GOT.transfer(address(HTHUSDLPPool), HTHUSDInitialBalance);
        // 通知奖励
        HTHUSDLPPool.notifyRewardAmount(HTHUSDInitialBalance);
        // 触发分发事件
        emit Distributed(address(HTHUSDLPPool), HTHUSDInitialBalance);

        once = false;
    }
}
