// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title LP质押合约
 */
contract LPTokenWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    /// @notice GoSwap LP Token合约地址
    IERC20 public lpt;

    /// @dev 质押总量
    uint256 private _totalSupply;
    /// @dev 余额映射
    mapping(address => uint256) private _balances;

    /**
     * @dev 返回总量
     * @return 总量
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev 返回账户余额
     * @param account 账户地址
     * @return 余额
     */
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev 把GOT抵押到Boardroom
     * @param amount 质押数量
     */
    function stake(uint256 amount) public virtual {
        // 总量增加
        _totalSupply = _totalSupply.add(amount);
        // 余额映射增加
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        // 将LPToken发送到当前合约
        lpt.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev 赎回LPToken
     * @param amount 赎回数量
     */
    function withdraw(uint256 amount) public virtual {
        // 用户的总质押数量
        uint256 directorShare = _balances[msg.sender];
        // 确认总质押数量大于取款数额
        require(directorShare >= amount, 'withdraw request greater than staked amount');
        // 总量减少
        _totalSupply = _totalSupply.sub(amount);
        // 余额减少
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        // 将LPToken发送给用户
        lpt.safeTransfer(msg.sender, amount);
    }
}
