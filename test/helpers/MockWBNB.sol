// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WBNB for local tests: deposit wraps msg.value, withdraw unwraps to the caller.
contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") { }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{ value: amount }("");
        require(ok, "WBNB: send failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
