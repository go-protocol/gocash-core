// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
/**
 *Submitted for verification at Etherscan.io on 2020-07-17
 */

/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: BASISCASHRewards.sol
*
* Docs: https://docs.synthetix.io/
*
*
* MIT License
* ===========
*
* Copyright (c) 2020 Synthetix
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

// File: @openzeppelin/contracts/math/Math.sol

import '@openzeppelin/contracts/math/Math.sol';

// File: @openzeppelin/contracts/math/SafeMath.sol

import '@openzeppelin/contracts/math/SafeMath.sol';

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

// File: @openzeppelin/contracts/utils/Address.sol

import '@openzeppelin/contracts/utils/Address.sol';

// File: @openzeppelin/contracts/token/ERC20/SafeERC20.sol

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

// File: contracts/IRewardDistributionRecipient.sol

import '../interfaces/IRewardDistributionRecipient.sol';

import '../token/LPTokenWrapper.sol';

/**
 * @title HUSD-cash的LP Token矿池合约
 * @notice 周期180天
 */
contract HUSDcashLPTokenSharePool is
    LPTokenWrapper,
    IRewardDistributionRecipient
{
    IERC20 public cash;
    /// @notice 时间周期 = 180天
    uint256 public DURATION = 180 days;
    /// @notice 开始时间
    uint256 public starttime; // starttime TBD
    /// @notice 结束时间
    uint256 public periodFinish = 0;
    /// @notice 每秒奖励数量
    uint256 public rewardRate = 0;
    /// @notice 最后更新时间
    uint256 public lastUpdateTime;
    /// @notice 储存奖励数量
    uint256 public rewardPerTokenStored;
    /// @notice 每个质押Token支付用户的奖励
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @notice 用户未发放的奖励数量
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    /**
     * @dev 构造函数
     * @param cash_ cash地址
     * @param lptoken_ LPtoken地址
     * @param starttime_ 开始时间
     */
    constructor(
        address cash_,
        address lptoken_,
        uint256 starttime_
    ) public {
        cash = IERC20(cash_);
        lpt = IERC20(lptoken_);
        starttime = starttime_;
    }

    /**
     * @dev 检查开始时间
     */
    modifier checkStart() {
        require(block.timestamp >= starttime, 'LPTokenSharePool: not start');
        _;
    }

    /**
     * @dev 更新奖励
     * @param account 用户地址
     */
    modifier updateReward(address account) {
        // 已奖励数量 = 每个质押Token的奖励
        rewardPerTokenStored = rewardPerToken();
        // 最后更新时间 = min(当前时间,最后时间)
        lastUpdateTime = lastTimeRewardApplicable();
        // 如果用户地址!=0地址
        if (account != address(0)) {
            // 用户未发放的奖励数量 = 赚取用户奖励
            rewards[account] = earned(account);
            // 每个质押Token支付用户的奖励 = 已奖励数量
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @dev 返回奖励的最后期限
     * @return 最后期限
     * @notice 如果没有到达结束时间,返回当前时间
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        // 最小值(当前时间,结束时间)
        return Math.min(block.timestamp, periodFinish);
    }

    /**
     * @dev 每个质押Token的奖励
     * @return 奖励数量
     */
    function rewardPerToken() public view returns (uint256) {
        // 返回0
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        // 已奖励数量 + (min(当前时间,最后时间) - 最后更新时间) * 每秒奖励 * 1e18 / 质押总量
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    /**
     * @dev 用户已奖励的数量
     * @param account 用户地址
     */
    function earned(address account) public view returns (uint256) {
        // 用户的质押数量 * (每个质押Token的奖励 - 每个质押Token支付用户的奖励) / 1e18 + 用户未发放的奖励数量
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    /**
     * @dev 质押指定数量的token
     * @param amount 质押数量
     */
    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkStart
    {
        // 确认数量>0
        require(amount > 0, 'HUSDGOCLPTokenSharePool: Cannot stake 0');
        // 上级质押
        super.stake(amount);
        // 触发质押事件
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev 提款指定数额的质押token
     * @param amount 质押数量
     */
    function withdraw(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkStart
    {
        // 确认数量>0
        require(amount > 0, 'HUSDGOCLPTokenSharePool: Cannot withdraw 0');
        // 上级提款
        super.withdraw(amount);
        // 触发提款事件
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev 退出
     */
    function exit() external {
        // 提走用户质押的全部数量
        withdraw(balanceOf(msg.sender));
        // 获取奖励
        getReward();
    }

    /**
     * @dev 获取奖励
     */
    function getReward() public updateReward(msg.sender) checkStart {
        // 奖励数量 = 用户已奖励的数量
        uint256 reward = earned(msg.sender);
        // 如果奖励数量>0
        if (reward > 0) {
            // 用户未发放的奖励数量 = 0
            rewards[msg.sender] = 0;
            // 发送奖励
            cash.safeTransfer(msg.sender, reward);
            // 触发支付奖励事件
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @dev 通知奖励数量
     * @param reward 奖励数量
     */
    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyRewardDistribution
        updateReward(address(0))
    {
        // 如果当前时间>开始时间
        if (block.timestamp > starttime) {
            // 如果当前时间 >= 结束时间
            if (block.timestamp >= periodFinish) {
                // 每秒奖励 = 奖励数量 / 180天
                rewardRate = reward.div(DURATION);
            } else {
                // 剩余时间 = 结束时间 - 当前时间
                uint256 remaining = periodFinish.sub(block.timestamp);
                // 剩余奖励数量 = 剩余时间 * 每秒奖励 (第一次执行为0)
                uint256 leftover = remaining.mul(rewardRate);
                // 每秒奖励 = (奖励数量 + 剩余奖励数量) / 180天
                rewardRate = reward.add(leftover).div(DURATION);
            }
            //最后更新时间 = 当前时间
            lastUpdateTime = block.timestamp;
            // 结束时间 = 当前时间 + 180天
            periodFinish = block.timestamp.add(DURATION);
            // 触发奖励增加事件
            emit RewardAdded(reward);
        } else {
            // 每秒奖励 = 奖励数量 / 180天
            rewardRate = reward.div(DURATION);
            // 最后更新时间 = 开始时间
            lastUpdateTime = starttime;
            // 结束时间 = 开始时间 + 180天
            periodFinish = starttime.add(DURATION);
            // 触发奖励增加事件
            emit RewardAdded(reward);
        }
    }
}
