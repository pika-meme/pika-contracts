// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";

/// @notice What the hook, order manager, LP manager and the sink templates read from a launch token.
interface IPikaLaunchToken {
    /// @notice What the hook's swap callbacks need, in one read: whether the pool trades and the three fee rates.
    struct SwapTerms {
        bool tradingStarted;
        uint16 platformFeeBps;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
    }

    function swapTerms() external view returns (SwapTerms memory);
    /// @notice The platform fee, in basis points; always paid in the quote asset.
    function platformFeeBps() external view returns (uint16);
    /// @notice The quote a component sets aside from a buy's quote budget for the platform fee.
    function platformReserve(uint256 quoteBudget) external view returns (uint256);
    function tradingStarted() external view returns (bool);
    function tradingRouter() external view returns (address);
    function orderManager() external view returns (address);
    function lpManager() external view returns (address);
    function locker() external view returns (address);
    /// @notice The pool's other asset: the quote token, or WBNB for a BNB launch.
    function quoteAsset() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function memeIsCurrency0() external view returns (bool);
    /// @notice The hook hands over the fees it took out of one swap: `platformFee` in quote (out of a buy's quote
    ///         input or a sell's quote output) and `projectFee` out of the gross output `value` (meme for a buy,
    ///         quote for a sell); `sender` is the locker.
    function notifyPoolFee(address sender, bool buy, uint256 platformFee, uint256 projectFee, uint256 value) external;
    /// @notice The order and LP managers pay a sell's fee (platform plus project) from the quote they hold, by
    ///         allowance, on `quoteBought`; at most `maxFee`.
    function chargeSellFee(address account, uint256 quoteBought, uint256 maxFee) external returns (uint256 fee);
    /// @notice The order and LP managers pay a buy's fees from what they hold: the platform fee in quote (by
    ///         allowance) on top of the `quoteSpent` the pool took, at most `maxPlatformFee` (the reserve), and the
    ///         project fee in meme out of the `memeBought`, at most `maxProjectFee`.
    function chargeBuyFees(
        address account,
        uint256 quoteSpent,
        uint256 memeBought,
        uint256 maxPlatformFee,
        uint256 maxProjectFee
    ) external returns (uint256 platformFee, uint256 projectFee);
}

/// @notice A launch's order manager, as the token checks it when the factory attaches it.
interface IPikaOrderBook {
    function token() external view returns (address);
}


/// @notice The shared pool hook, as seen by launch tokens and the factory.
interface IPikaHook {
    function vault() external view returns (IVault);
    function poolManager() external view returns (ICLPoolManager);
    function poolKey(address token) external view returns (PoolKey memory);
    function poolToken(PoolId id) external view returns (address);
    function buildPoolKey(address token, address quoteAsset) external view returns (PoolKey memory);
    /// @notice The pool parameters every launch pool of this hook uses.
    function poolParameters() external view returns (bytes32);
    function registerPool(address token, address quote) external returns (PoolKey memory key);
}

// The hub reaches the outer components only through the interfaces below, so it compiles with OpenFour's compiler
// settings (solc 0.8.24, paris) while the components keep theirs (solc 0.8.26, cancun, transient storage).

/// @notice A shared component bound to one launch factory (`PikaFactoryBound`).
interface IPikaFactoryBound {
    function factory() external view returns (address);
}

/// @notice The graduation locker, as the hub checks and calls it.
interface IPikaLocker {
    function vault() external view returns (IVault);
    function poolManager() external view returns (ICLPoolManager);
    function treasury() external view returns (address);
    function lockPosition(address token, uint256 memeAmount, uint256 quoteAmount)
        external
        returns (uint128 liquidity, uint256 memeUsed, uint256 quoteUsed);
}

/// @notice The LP manager, as the hub checks it when it publishes components.
interface IPikaLpManager {
    function vault() external view returns (IVault);
    function poolManager() external view returns (ICLPoolManager);
    function hook() external view returns (IPikaHook);
}

/// @notice The order-manager deployer, as the hub checks and calls it.
interface IPikaOrderDeployer {
    function hook() external view returns (address);
    /// @dev Returns the new order manager.
    function deploy(address token) external returns (address orders);
}
