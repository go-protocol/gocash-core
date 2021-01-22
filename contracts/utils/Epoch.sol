// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '../lib/AdminRole.sol';
import "@openzeppelin/contracts/math/Math.sol";

/**
 * @title 周期合约
 */
contract Epoch is AdminRole {
    using SafeMath for uint256;
    /// @dev 周期时长
    uint256 private period;
    /// @dev 开始时间
    uint256 private startTime;
    /// @dev 最后执行时间
    uint256 private lastExecutedAt;

    /* ========== CONSTRUCTOR ========== */
    /**
     * @dev 构造函数
     * @param _period 周期时长 1 days
     * @param _startTime 开始时间
     * @param _startEpoch 0周期
     */
    constructor(
        uint256 _period,
        uint256 _startTime,
        uint256 _startEpoch
    ) public {
        require(_startTime > block.timestamp, 'Epoch: invalid start time');
        period = _period;
        startTime = _startTime;
        // 最后执行时间 = 开始时间 + 开始周期 * 周期时长
        lastExecutedAt = startTime.add(_startEpoch.mul(period));
    }

    /* ========== Modifier ========== */

    /**
     * @dev 检查开始时间
     */
    modifier checkStartTime {
        //确认现在大于开始时间
        require(now >= startTime, 'Epoch: not started yet');
        _;
    }

    /**
     * @dev 检查周期
     */
    modifier checkEpoch {
        //确认现在大于开始时间
        require(now > startTime, 'Epoch: not started yet');
        //确认当前周期 >= 下一个周期
        require(getCurrentEpoch() >= getNextEpoch(), 'Epoch: not allowed');

        _;
        // 最后执行时间 = 当前时间
        lastExecutedAt = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // epoch
    /**
     * @dev 获取最后一个周期
     */
    function getLastEpoch() public view returns (uint256) {
        // (最后执行时间 - 开始时间) / 周期时长
        return lastExecutedAt.sub(startTime).div(period);
    }

    /**
     * @dev 获取当前周期
     */
    function getCurrentEpoch() public view returns (uint256) {
        // (最大值(开始时间, 当前时间) - 开始时间) / 周期时长
        return Math.max(startTime, block.timestamp).sub(startTime).div(period);
    }

    /**
     * @dev 获取下一个周期
     */
    function getNextEpoch() public view returns (uint256) {
        // 如果开始时间 == 最后执行时间
        if (startTime == lastExecutedAt) {
            // 返回最后一个周期
            return getLastEpoch();
        }
        // 最后一个周期 + 1
        return getLastEpoch().add(1);
    }

    /**
     * @dev 获取下一个周期点
     */
    function nextEpochPoint() public view returns (uint256) {
        // 开始时间 + (下一个周期 * 周期时长)
        return startTime.add(getNextEpoch().mul(period));
    }

    // params
    /**
     * @dev 获取周期时长
     */
    function getPeriod() public view returns (uint256) {
        return period;
    }

    /**
     * @dev 获取开始时间
     */
    function getStartTime() public view returns (uint256) {
        return startTime;
    }

    /* ========== GOVERNANCE ========== */

    /**
     * @dev 设置周期时长
     * @param _period 周期时长
     */
    function setPeriod(uint256 _period) external onlyAdmin {
        period = _period;
    }
}
