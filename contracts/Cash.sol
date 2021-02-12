// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol';
import './lib/AdminRole.sol';

contract Cash is ERC20Burnable, AdminRole {
    /**
     * @notice Constructs the GoCash Cash ERC-20 contract.
     */
    constructor() public ERC20('GoCash Cash', 'GOC') {
        // Mints 1 GoCash Cash to contract creator for initial oracle deployment.
        _mint(msg.sender, 1 * 10**18);
    }

    /**
     * @notice GoCash Cash代币的铸造方法
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis bonds to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyAdmin returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    /**
     * @notice GoCash Cash代币的销毁方法，Admin有权限销毁
     */
    function burn(uint256 amount) public override onlyAdmin {
        super.burn(amount);
    }

    /**
     * @notice GoCash Cash代币的销毁方法，Admin有权限销毁，配合approve使用
     */
    function burnFrom(address account, uint256 amount) public override onlyAdmin {
        super.burnFrom(account, amount);
    }
}
