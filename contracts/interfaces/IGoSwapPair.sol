// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

interface IGoSwapPair {
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function isGLP() external pure returns (bool);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external pure returns (address);

    function token0() external pure returns (address);

    function token1() external pure returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function fee() external view returns (uint8);

    function feeTo() external view returns (address);

    function getFeeTo() external view returns (address);

    function creator() external view returns (address);

    function birthday() external view returns (uint256);

    function rootKmul() external view returns (uint8);

    function initialize(address, address) external;

    function setFeeTo(address) external;

    function setrootKmul(uint8) external;

    function setFee(uint8) external;

    function getDeposited()
        external
        view
        returns (uint256 _deposited0, uint256 _deposited1);

    function getDummy()
        external
        view
        returns (uint256 _dummy0, uint256 _dummy1);

    function balanceOfIndex(uint256 tokenIndex)
        external
        view
        returns (uint256 balance);
}
