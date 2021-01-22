// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import '../interfaces/IGoSwapPair.sol';
import './FixedPoint.sol';

// library with helper methods for oracles that are concerned with computing average prices
/**
 * @title 带有与计算平均价格有关的oracle的帮助程序方法的库
 */
library GoSwapOracleLibrary {
    using FixedPoint for *;

    /**
     * @dev 辅助函数，该函数返回uint32范围内的当前块时间戳，即[0，2 ** 32-1]
     */
    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    /**
     * @dev 使用反事实来产生累计价格，以节省燃料并避免调用同步。
     * @param pair 配对合约地址
     * @return price0Cumulative Token0累计价格
     * @return price1Cumulative Token1累计价格
     * @return blockTimestamp 时间戳
     */
    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(address pair)
        internal
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        )
    {
        // 时间戳 = 32位的当前时间
        blockTimestamp = currentBlockTimestamp();
        // 从配对合约获取Token0,1累计价格
        price0Cumulative = IGoSwapPair(pair).price0CumulativeLast();
        price1Cumulative = IGoSwapPair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        // 如果自该交易对上次更新以来已过去了一段时间，请模拟累积的价格值
        // 获取储备量0,1和上次更新的时间戳
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IGoSwapPair(pair).getReserves();
        // 如果上次更新储备量的时间 != 当前时间
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            // 时间流逝 = 当前时间 - 上次更新储备量的时间 (需要减法溢出)
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // 需要加法溢出
            // counterfactual
            // 价格0累计价格 +=  储备量1 / 储备量0 * 时间流逝
            price0Cumulative += uint256(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            // 价格1累计价格 +=  储备量0 / 储备量1 * 时间流逝
            price1Cumulative += uint256(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}
