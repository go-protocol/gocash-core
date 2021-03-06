// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IDistributor.sol';
import '../interfaces/IRewardDistribution.sol';

contract InitialshareDistributor is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 cashAmount);
    /// @notice 只能运行一次
    bool public once = true;

    /// @notice share地址
    IERC20 public share;
    /// @notice HUSDcashLPPool 矿池地址
    IRewardDistribution public HUSDcashLPPool;
    /// @notice HUSDcash 初始奖励
    uint256 public HUSDcashInitialBalance;
    /// @notice HUSDshareLPPool 矿池地址
    IRewardDistribution public HUSDshareLPPool;
    /// @notice HUSDshare 初始奖励
    uint256 public HUSDshareInitialBalance;

    /**
    * @dev 构造函数
    * @param _share share地址
    * @param _HUSDcashLPPool HUSDcashLPPool 矿池地址
    * @param _HUSDcashInitialBalance HUSDcash 初始奖励
    * @param _HUSDshareLPPool HUSDshareLPPool 矿池地址
    * @param _HUSDshareInitialBalance HUSDshare 初始奖励
     */
    constructor(
        IERC20 _share,
        IRewardDistribution _HUSDcashLPPool,
        uint256 _HUSDcashInitialBalance,
        IRewardDistribution _HUSDshareLPPool,
        uint256 _HUSDshareInitialBalance
    ) public {
        share = _share;
        HUSDcashLPPool = _HUSDcashLPPool;
        HUSDcashInitialBalance = _HUSDcashInitialBalance;
        HUSDshareLPPool = _HUSDshareLPPool;
        HUSDshareInitialBalance = _HUSDshareInitialBalance;
    }

    /**
    * @dev 分发奖励
     */
    function distribute() public override {
        require(
            once,
            'InitialshareDistributor: you cannot run this function twice'
        );
        // 将奖励的share发送给HUSDcashLPPool 矿池地址
        share.transfer(address(HUSDcashLPPool), HUSDcashInitialBalance);
        // 通知奖励
        HUSDcashLPPool.notifyRewardAmount(HUSDcashInitialBalance);
        // 触发分发事件
        emit Distributed(address(HUSDcashLPPool), HUSDcashInitialBalance);

        // 将奖励的share发送给HUSDshareLPPool 矿池地址
        share.transfer(address(HUSDshareLPPool), HUSDshareInitialBalance);
        // 通知奖励
        HUSDshareLPPool.notifyRewardAmount(HUSDshareInitialBalance);
        // 触发分发事件
        emit Distributed(address(HUSDshareLPPool), HUSDshareInitialBalance);

        once = false;
    }
}
