// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';

import './lib/FixedPoint.sol';
import './lib/GoSwapLibrary.sol';
import './lib/GoSwapOracleLibrary.sol';
import './utils/Epoch.sol';
import './interfaces/IGoSwapPair.sol';

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract GoSwapOracle is Epoch {
    using FixedPoint for *;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // uniswap
    /// @notice token0地址
    address public token0;
    /// @notice token1地址
    address public token1;
    /// @notice 配对合约地址
    IGoSwapPair public pair;

    // oracle
    /// @notice 最后一次时间戳
    uint32 public blockTimestampLast;
    /// @notice 最后累计价格0
    uint256 public price0CumulativeLast;
    /// @notice 最后累计价格1
    uint256 public price1CumulativeLast;
    /// @notice 价格0平均值
    FixedPoint.uq112x112 public price0Average;
    /// @notice 价格1平均值
    FixedPoint.uq112x112 public price1Average;

    /* ========== CONSTRUCTOR ========== */
    /**
     * @dev 构造函数
     * @param _company 公司合约地址
     * @param _tokenA TokenA地址
     * @param _tokenB TokenB地址
     * @param _startTime 开始时间
     */
    constructor(
        address _company,
        address _tokenA,
        address _tokenB,
        uint256 _startTime
    ) public Epoch(12 hours, _startTime, 0) {
        // 从公司合约获取配对合约地址
        IGoSwapPair _pair = IGoSwapPair(GoSwapLibrary.pairFor(_company, _tokenA, _tokenB));
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
        // 最后累计价格0,1
        price0CumulativeLast = _pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        // 储备量0,1
        uint112 reserve0;
        uint112 reserve1;
        // 获取储备量0,1
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, 'Oracle: NO_RESERVES'); // ensure that there's liquidity in the pair
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /**
     * @dev Updates 1-day EMA price from GoCash.
     * @dev 更新价格
     */
    function update() external checkEpoch {
        // 使用反事实来产生累计价格，以节省燃料并避免调用同步。
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) =
            GoSwapOracleLibrary.currentCumulativePrices(address(pair));
        // 时间流逝 = 当前时间 - 上次更新储备量的时间 (需要减法溢出)
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 如果时间流逝 = 0 返回
        if (timeElapsed == 0) {
            // prevent divided by zero
            return;
        }

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        // 累计价格以（uq112x112价格*秒）单位表示，因此我们只需要在经过时间划分后将其包装即可
        // 平均价格0 = (最新的累计价格 - 上一次记录的累计价格) / 时间流逝
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        // 平均价格1 = (最新的累计价格 - 上一次记录的累计价格) / 时间流逝
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));
        // 记录最新累计价格
        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        // 记录最新时间戳
        blockTimestampLast = blockTimestamp;
        // 更新价格
        emit Updated(price0Cumulative, price1Cumulative);
    }

    /**
     * @dev 查询价格
     * @param token token地址
     * @param amountIn 输入数量
     * @return amountOut 输出数量
     * @notice 请注意，在首次成功调用更新之前，它将始终返回0。
     */
    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address token, uint256 amountIn) external view returns (uint144 amountOut) {
        // 如果token为token0
        if (token == token0) {
            // 输出数量 = 平均价格0 * 输入数量 / 2**112
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            // 确认token为token1
            require(token == token1, 'Oracle: INVALID_TOKEN');
            // 输出数量 = 平均价格1 * 输入数量 / 2**112
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }

    /**
     * @dev 查询价格
     * @param token token地址
     * @param amountIn 输入数量
     * @return amountOut 输出数量
     * @notice 请注意，在首次成功调用更新之前，它将始终返回0。
     */
    // collaboration of update / consult
    function expectedPrice(address token, uint256 amountIn)
        external
        view
        returns (uint224 amountOut)
    {
        // 使用反事实来产生累计价格，以节省燃料并避免调用同步。
        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        ) = GoSwapOracleLibrary.currentCumulativePrices(address(pair));
        // 时间流逝 = 当前时间 - 上次更新储备量的时间 (需要减法溢出)
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // 平均价格0 = (最新的累计价格 - 上一次记录的累计价格) / 时间流逝
        FixedPoint.uq112x112 memory avg0 =
            FixedPoint.uq112x112(
                uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)
            );
        // 平均价格1 = (最新的累计价格 - 上一次记录的累计价格) / 时间流逝
        FixedPoint.uq112x112 memory avg1 =
            FixedPoint.uq112x112(
                uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)
            );

        if (token == token0) {
            // 输出数量 = 平均价格0 * 输入数量 / 2**112
            amountOut = avg0.mul(amountIn).decode144();
        } else {
            require(token == token1, 'Oracle: INVALID_TOKEN');
            // 输出数量 = 平均价格1 * 输入数量 / 2**112
            amountOut = avg1.mul(amountIn).decode144();
        }
        return amountOut;
    }

    /**
     * @dev 寻找配对合约地址
     * @param company 公司合约地址
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @return lpt lp Token地址
     */
    function pairFor(
        address company,
        address tokenA,
        address tokenB
    ) external pure returns (address lpt) {
        // 通过公司合约返回tokenA tokenB配对合约地址
        return GoSwapLibrary.pairFor(company, tokenA, tokenB);
    }

    /**
     * @dev 事件:更新
     * @param price0CumulativeLast 累计价格0
     * @param price1CumulativeLast 累计价格1
     */
    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);
}
