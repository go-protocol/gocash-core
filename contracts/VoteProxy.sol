pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/EnumerableSet.sol';

import './owner/Operator.sol';

contract VoteProxy is Operator {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    // Events
    event AddBoardroom(address indexed operator, address indexed Boardroom);
    event RemoveBoardroom(address indexed operator, address indexed Boardroom);
    event SetRate(
        address indexed operator,
        address indexed Boardroom,
        uint256 rate
    );

    /// @notice 董事会投票权重
    mapping(address => uint256) public rates;

    /// @dev 董事会数组
    EnumerableSet.AddressSet private _boardrooms;

    /**
     * @dev 构造函数
     * @param boardrooms 董事会地址数组
     */
    constructor(address[] memory boardrooms, uint256[] memory _rates) public {
        require(boardrooms.length == _rates.length, 'Array length!');
        for (uint256 i = 0; i < boardrooms.length; i++) {
            _boardrooms.add(boardrooms[i]);
            rates[boardrooms[i]] = _rates[i];
            emit AddBoardroom(msg.sender, boardrooms[i]);
        }
    }

    /**
     * @dev 添加董事会地址
     * @param boardroom 董事会地址
     */
    function addBoardroom(address boardroom) public onlyOperator {
        _boardrooms.add(boardroom);
        emit AddBoardroom(msg.sender, boardroom);
    }

    /**
     * @dev 移除董事会地址
     * @param boardroom 董事会地址
     */
    function removeBoardroom(address boardroom) public onlyOperator {
        _boardrooms.remove(boardroom);
        emit RemoveBoardroom(msg.sender, boardroom);
    }

    /**
     * @dev 设置权重
     * @param boardroom 董事会地址
     */
    function setRate(address boardroom, uint256 rate) public onlyOperator {
        rates[boardroom] = rate;
        emit SetRate(msg.sender, boardroom, rate);
    }

    /**
     * @dev 返回所有董事会地址
     * @return boardrooms 董事会地址
     */
    function allBoardrooms() public view returns (address[] memory boardrooms) {
        boardrooms = new address[](_boardrooms.length());
        for (uint256 i = 0; i < _boardrooms.length(); i++) {
            boardrooms[i] = _boardrooms.at(i);
        }
    }

    /**
     * @dev 精度
     */
    function decimals() external pure returns (uint8) {
        return uint8(18);
    }

    /**
     * @dev 名称
     */
    function name() external pure returns (string memory) {
        return 'GOS in Boardroom';
    }

    /**
     * @dev 符号
     */
    function symbol() external pure returns (string memory) {
        return 'sGOS';
    }

    /**
     * @dev 返回所有董事会的供应总量
     */
    function totalSupply()
        external
        view
        returns (uint256 boardroomTotalSupply)
    {
        for (uint256 i = 0; i < _boardrooms.length(); i++) {
            boardroomTotalSupply = boardroomTotalSupply.add(
                (IERC20(_boardrooms.at(i)).totalSupply()).mul(
                    rates[_boardrooms.at(i)]
                )
            );
        }
    }

    /**
     * @dev 返回用户在所有董事会的余额
     * @param _voter 用户地址
     */
    function balanceOf(address _voter) external view returns (uint256 balance) {
        for (uint256 i = 0; i < _boardrooms.length(); i++) {
            balance = balance.add(
                (IERC20(_boardrooms.at(i)).balanceOf(_voter)).mul(
                    rates[_boardrooms.at(i)]
                )
            );
        }
    }
}
