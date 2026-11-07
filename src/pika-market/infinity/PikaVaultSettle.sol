// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";

/// @notice How the Pika position holders (locker, order manager, LP manager) settle one side of a position delta
///         inside a vault lock, always as plain ERC20: a negative amount is owed to the vault and paid by `payer`
///         (from this contract's own balance when `payer` is this contract), a positive one is taken here. Nothing
///         is ever kept as a vault delta or minted as a claim.
library PikaVaultSettle {
    using SafeERC20 for IERC20;

    function settleOrTake(IVault vault, Currency currency, int128 amount, address payer) internal {
        if (amount < 0) {
            vault.sync(currency);
            IERC20 asset = IERC20(Currency.unwrap(currency));
            uint256 owed = negative(amount);
            if (payer == address(this)) asset.safeTransfer(address(vault), owed);
            else asset.safeTransferFrom(payer, address(vault), owed);
            vault.settle();
        } else if (amount > 0) {
            vault.take(currency, address(this), positive(amount));
        }
    }

    /// @dev The magnitude of a positive delta; zero otherwise. A positive int128 always fits.
    function positive(int128 amount) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }

    /// @dev The magnitude of a negative delta; zero otherwise. int128 magnitudes always fit in uint128.
    function negative(int128 amount) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return amount < 0 ? uint256(uint128(-amount)) : 0;
    }
}
