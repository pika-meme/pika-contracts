// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only 18-decimal quote token. Anyone may claim more tokens; it has no monetary value.
contract MockUSDT is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 100_000 ether;

    constructor(address recipient) ERC20("Mock USDT", "mUSDT") {
        _mint(recipient, 1_000_000 ether);
    }

    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
