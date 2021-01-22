// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import '@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol';
import './lib/AdminRole.sol';

/**
 * @dev GoSwap 平台币
 */
contract GoSwapToken is ERC20('GoSwap Token', 'GOT'), ERC20Burnable, AdminRole {
    /**
     * @notice Operator mints basis cash to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis cash to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyAdmin returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override onlyAdmin {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyAdmin {
        super.burnFrom(account, amount);
    }
}
