// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '../interfaces/IGoSwapPair.sol';
import '../interfaces/IGoSwapFactory.sol';
import '../interfaces/IGoSwapCompany.sol';

/**
 * @title GoSwap库合约
 */
library GoSwapLibrary {
    using SafeMath for uint256;

    /**
     * @dev 排序token地址
     * @notice 返回排序的令牌地址，用于处理按此顺序排序的对中的返回值
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return token0  Token0
     * @return token1  Token1
     */
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        //确认tokenA不等于tokenB
        require(tokenA != tokenB, 'GoSwapLibrary: IDENTICAL_ADDRESSES');
        //排序token地址
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        //确认token地址不等于0地址
        require(token0 != address(0), 'GoSwapLibrary: ZERO_ADDRESS');
    }

    /**
     * @dev 获取pair合约地址
     * @notice 计算一对的CREATE2地址，而无需进行任何外部调用
     * @param company 配对寻找工厂地址
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return pair  pair合约地址
     */
    function pairFor(
        address company,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        // 通过配对寻找工厂合约
        address factory = IGoSwapCompany(company).pairForFactory(tokenA, tokenB);
        //排序token地址
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        // 获取pairCodeHash
        bytes32 pairCodeHash = IGoSwapFactory(factory).pairCodeHash();
        //根据排序的token地址计算create2的pair地址
        pair = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        factory,
                        keccak256(abi.encodePacked(token0, token1)),
                        pairCodeHash // init code hash
                    )
                )
            )
        );
    }

    /**
     * @dev 获取不含虚流动性的储备量
     * @notice 提取并排序一对的储备金
     * @param company 配对寻找工厂地址
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return reserveA  储备量A
     * @return reserveB  储备量B
     * @return fee  手续费
     */
    // fetches and sorts the reserves and fee for a pair
    function getReservesWithoutDummy(
        address company,
        address tokenA,
        address tokenB
    )
        internal
        view
        returns (
            uint256 reserveA,
            uint256 reserveB,
            uint8 fee
        )
    {
        //排序token地址
        (address token0, ) = sortTokens(tokenA, tokenB);
        // 实例化配对合约
        IGoSwapPair pair = IGoSwapPair(pairFor(company, tokenA, tokenB));
        // 获取储备量
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        // 获取虚流动性
        (uint256 dummy0, uint256 dummy1) = pair.getDummy();
        // 储备量0 - 虚流动性0
        reserve0 -= dummy0;
        // 储备量1 - 虚流动性1
        reserve1 -= dummy1;
        // 排序token
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        // 返回手续费
        fee = pair.fee();
    }

    /**
     * @dev 获取储备量
     * @notice 提取并排序一对的储备金
     * @param company 配对寻找工厂地址
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return reserveA  储备量A
     * @return reserveB  储备量B
     * @return fee  手续费
     */
    function getReserves(
        address company,
        address tokenA,
        address tokenB
    )
        internal
        view
        returns (
            uint256 reserveA,
            uint256 reserveB,
            uint8 fee
        )
    {
        //排序token地址
        (address token0, ) = sortTokens(tokenA, tokenB);
        //通过排序后的token地址和工厂合约地址获取到pair合约地址,并从pair合约中获取储备量0,1
        (uint256 reserve0, uint256 reserve1, ) = IGoSwapPair(pairFor(company, tokenA, tokenB)).getReserves();
        //根据输入的token顺序返回储备量
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        //获取配对合约中设置的手续费比例
        fee = IGoSwapPair(pairFor(company, tokenA, tokenB)).fee();
    }

    /**
     * @dev 对价计算
     * @notice 给定一定数量的资产和货币对储备金，则返回等值的其他资产
     * @param amountA 数额A
     * @param reserveA 储备量A
     * @param reserveB 储备量B
     * @return amountB  数额B
     */
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        //确认数额A>0
        require(amountA > 0, 'GoSwapLibrary: INSUFFICIENT_AMOUNT');
        //确认储备量A,B大于0
        require(reserveA > 0 && reserveB > 0, 'GoSwapLibrary: INSUFFICIENT_LIQUIDITY');
        //数额B = 数额A * 储备量B / 储备量A
        amountB = amountA.mul(reserveB) / reserveA;
    }

    /**
     * @dev 获取单个输出数额
     * @notice 给定一项资产的输入量和配对的储备，返回另一项资产的最大输出量
     * @param amountIn 输入数额
     * @param reserveIn 储备量In
     * @param reserveOut 储备量Out
     * @param fee 手续费比例
     * @return amountOut  输出数额
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint8 fee
    ) internal pure returns (uint256 amountOut) {
        //确认输入数额大于0
        require(amountIn > 0, 'GoSwapLibrary: INSUFFICIENT_INPUT_AMOUNT');
        //确认储备量In和储备量Out大于0
        require(reserveIn > 0 && reserveOut > 0, 'GoSwapLibrary: INSUFFICIENT_LIQUIDITY');
        //税后输入数额 = 输入数额 * (1000-fee)
        uint256 amountInWithFee = amountIn.mul(1000 - fee);
        //分子 = 税后输入数额 * 储备量Out
        uint256 numerator = amountInWithFee.mul(reserveOut);
        //分母 = 储备量In * 1000 + 税后输入数额
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        //输出数额 = 分子 / 分母
        amountOut = numerator / denominator;
    }

    /**
     * @dev 获取单个输出数额
     * @notice 给定一项资产的输出量和对储备，返回其他资产的所需输入量
     * @param amountOut 输出数额
     * @param reserveIn 储备量In
     * @param reserveOut 储备量Out
     * @param fee 手续费比例
     * @return amountIn  输入数额
     */
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint8 fee
    ) internal pure returns (uint256 amountIn) {
        //确认输出数额大于0
        require(amountOut > 0, 'GoSwapLibrary: INSUFFICIENT_OUTPUT_AMOUNT');
        //确认储备量In和储备量Out大于0
        require(reserveIn > 0 && reserveOut > 0, 'GoSwapLibrary: INSUFFICIENT_LIQUIDITY');
        //分子 = 储备量In * 储备量Out * 1000
        uint256 numerator = reserveIn.mul(amountOut).mul(1000);
        //分母 = 储备量Out - 输出数额 * (1000-fee)
        uint256 denominator = reserveOut.sub(amountOut).mul(1000 - fee);
        //输入数额 = (分子 / 分母) + 1
        amountIn = (numerator / denominator).add(1);
    }

    /**
     * @dev 获取输出数额
     * @notice 对任意数量的对执行链接的getAmountOut计算
     * @param company 配对寻找工厂合约地址
     * @param amountIn 输入数额
     * @param path 路径数组
     * @return amounts  数额数组
     */
    function getAmountsOut(
        address company,
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        //确认路径数组长度大于2
        require(path.length >= 2, 'GoSwapLibrary: INVALID_PATH');
        //初始化数额数组
        amounts = new uint256[](path.length);
        //数额数组[0] = 输入数额
        amounts[0] = amountIn;
        //遍历路径数组,path长度-1
        for (uint256 i; i < path.length - 1; i++) {
            //(储备量In,储备量Out,手续费比例) = 获取储备(当前路径地址,下一个路径地址)
            (uint256 reserveIn, uint256 reserveOut, uint8 fee) = getReserves(company, path[i], path[i + 1]);
            //下一个数额 = 获取输出数额(当前数额,储备量In,储备量Out)
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, fee);
        }
    }

    /**
     * @dev 获取输出数额
     * @notice 对任意数量的对执行链接的getAmountIn计算
     * @param company 公司合约地址
     * @param amountOut 输出数额
     * @param path 路径数组
     * @return amounts  数额数组
     */
    function getAmountsIn(
        address company,
        uint256 amountOut,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        //确认路径数组长度大于2
        require(path.length >= 2, 'GoSwapLibrary: INVALID_PATH');
        //初始化数额数组
        amounts = new uint256[](path.length);
        //数额数组最后一个元素 = 输出数额
        amounts[amounts.length - 1] = amountOut;
        //从倒数第二个元素倒叙遍历路径数组
        for (uint256 i = path.length - 1; i > 0; i--) {
            //(储备量In,储备量Out,手续费比例) = 获取储备(上一个路径地址,当前路径地址)
            (uint256 reserveIn, uint256 reserveOut, uint8 fee) = getReserves(company, path[i - 1], path[i]);
            //上一个数额 = 获取输入数额(当前数额,储备量In,储备量Out)
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, fee);
        }
    }
}
