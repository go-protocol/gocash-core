// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol';
import './lib/AdminRole.sol';

contract GoSwapBond is ERC20Burnable, AdminRole {
    /**
     * @notice 发行GoSwap Bond代币
     */
    constructor() public ERC20('GoSwap Bond', 'GOB') {}

    /**
     * @notice GoSwap Bond代币的铸造方法
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis bonds to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyAdmin returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        //仅Admin有权限铸造
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    /**
     * @notice GoSwap Bond代币的销毁方法，Admin有权限销毁
     */
    function burn(uint256 amount) public override onlyAdmin {
        super.burn(amount);
    }

    /**
     * @notice GoSwap Bond代币的销毁方法，Admin有权限销毁，配合approve使用
     */
    function burnFrom(address account, uint256 amount) public override onlyAdmin {
        super.burnFrom(account, amount);
    }
}
