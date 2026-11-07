// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";

/// @notice A locker shaped like the Infinity Universal Router: it settles the swapper's debt from the swapper's
///         ERC20 balance and takes every credit straight to the recipient. `mintOutput` instead keeps the credit as
///         an ERC6909 claim, which is what a malicious locker would try.
contract InfinityTestRouter is ILockCallback {
    using SafeERC20 for IERC20;

    IVault public immutable vault;
    ICLPoolManager public immutable manager;

    struct Call {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        address payer;
        address recipient;
        bool mintOutput;
        bool roundTrip;
    }

    error NotVault();

    constructor(IVault vault_, ICLPoolManager manager_) {
        vault = vault_;
        manager = manager_;
    }

    /// @dev Negative `amountSpecified` is exact input, positive is exact output, like the pool manager.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, address recipient)
        external
        returns (BalanceDelta delta)
    {
        return _run(Call(key, zeroForOne, amountSpecified, msg.sender, recipient, false, false));
    }

    /// @dev Sells `amount` of the input currency and immediately buys it back with the whole output inside one
    ///      lock, so most of the two swaps net out and little or nothing is settled as ERC20.
    function roundTrip(PoolKey memory key, bool zeroForOne, uint256 amount) external returns (BalanceDelta delta) {
        return _run(Call(key, zeroForOne, -int256(amount), msg.sender, msg.sender, false, true));
    }

    function swapMinting(PoolKey memory key, bool zeroForOne, int256 amountSpecified, address recipient)
        external
        returns (BalanceDelta delta)
    {
        return _run(Call(key, zeroForOne, amountSpecified, msg.sender, recipient, true, false));
    }

    function _run(Call memory c) private returns (BalanceDelta delta) {
        delta = abi.decode(vault.lock(abi.encode(c)), (BalanceDelta));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        Call memory c = abi.decode(data, (Call));
        BalanceDelta delta = manager.swap(
            c.key,
            ICLPoolManager.SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: c.amountSpecified,
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        if (c.roundTrip) {
            int128 out = c.zeroForOne ? delta.amount1() : delta.amount0();
            manager.swap(
                c.key,
                ICLPoolManager.SwapParams({
                    zeroForOne: !c.zeroForOne,
                    amountSpecified: -int256(out),
                    sqrtPriceLimitX96: !c.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                }),
                ""
            );
            _settle(c, c.key.currency0, int128(vault.currencyDelta(address(this), c.key.currency0)));
            _settle(c, c.key.currency1, int128(vault.currencyDelta(address(this), c.key.currency1)));
            return abi.encode(delta);
        }
        _settle(c, c.key.currency0, delta.amount0());
        _settle(c, c.key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Call memory c, Currency currency, int128 amount) private {
        if (amount < 0) {
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(c.payer, address(vault), uint256(uint128(-amount)));
            vault.settle();
        } else if (amount > 0) {
            if (c.mintOutput) vault.mint(c.recipient, currency, uint256(uint128(amount)));
            else vault.take(currency, c.recipient, uint256(uint128(amount)));
        }
    }
}

/// @notice A locker that hands the lock to its caller, so a test can issue arbitrary pool manager and vault calls
///         from its own address while the vault is locked.
contract LockRelay is ILockCallback {
    IVault public immutable vault;
    address private runner;

    error NotVault();

    constructor(IVault vault_) {
        vault = vault_;
    }

    function run(bytes calldata data) external returns (bytes memory result) {
        runner = msg.sender;
        result = vault.lock(data);
        runner = address(0);
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (bool ok, bytes memory result) = runner.call(abi.encodeWithSignature("onLock(bytes)", data));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}
