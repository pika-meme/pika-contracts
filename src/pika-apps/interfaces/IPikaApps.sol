// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice One receiver of a launch's project fee, fixed at creation. The creator's fee wallet is implicit: it takes
///         whatever the slots leave of each fee, rounding included.
struct FeeSlot {
    address target;
    uint16 buyShareBps;
    uint16 sellShareBps;
    /// @dev Contract templates are told about every amount they receive; direct receivers (such as the burn
    ///      address) are not, and they only take buy shares, since a sell fee is quote.
    bool notify;
    /// @dev The holder book (the dividend template): the token also tells it every holder balance change. At most
    ///      one slot of a launch.
    bool holders;
}

/// @notice A creator's choice of one app template for a launch.
struct AppBinding {
    uint32 templateId;
    uint16 buyShareBps;
    uint16 sellShareBps;
    /// @dev The template's own parameters, validated by the template. Direct receivers take none.
    bytes params;
}

/// @notice A contract app template: one proxy serves every launch that binds it; the registry upgrades it.
interface IPikaApp {
    function templateKey() external view returns (bytes32);
    function version() external view returns (uint16);
    /// @notice Only the app registry calls this, inside the launch's creation. Reverts on invalid parameters.
    function register(address token, bytes calldata params) external;
    /// @notice Only a registered launch token calls this, right after transferring `amount` of `asset` to the app:
    ///         the launch token itself for a buy, the launch's quote asset for a sell.
    /// @dev Runs inside the token's fee push, which reverts with it: constant work, no transfers, no external calls.
    function onProjectFee(address asset, bool buy, uint256 amount) external;
}

/// @notice The holder book of a launch: a template the token tells about every balance change, so it can share
///         fees among plain holders. Every rule about who earns is the book's (2026-11-03): it excludes the launch's
///         platform accounts (`IPikaAppToken.isPlatformAccount`), holders below the launch's minimum and the
///         accounts its owner lists.
interface IPikaHolderBook {
    /// @notice Only a registered launch token calls this, right after a transfer: the two parties and their
    ///         balances after it. The book decides what shares those balances are worth.
    /// @dev Constant work plus at most two reads of the token (`isPlatformAccount`), no transfers: it runs inside
    ///      every transfer of the launch, with the transaction's available gas, and the transfer requires it to
    ///      succeed: any failure reverts the balance change too.
    function setShares(address from, uint256 fromBalance, address to, uint256 toBalance) external;
    /// @notice Reread `holder`'s balance from `token` and apply every rule to it. The token calls it for an account
    ///         that becomes one of its platform accounts after the supply exists (the order manager at graduation).
    function refresh(address token, address holder) external;
}

/// @notice What app templates read from a launch token.
interface IPikaAppToken {
    /// @notice The launch factory, fixed in the token's code; readable before the token is initialized.
    function factory() external view returns (address);
    /// @notice The pool's other asset; sell fees arrive in it.
    function quoteAsset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    /// @notice The launch's platform accounts, data for the holder book's default exclusion: the zero and burn
    ///         addresses, the vault, the launch's components and its app slots.
    function isPlatformAccount(address account) external view returns (bool);
}

/// @notice What app templates read from a launch factory.
interface IPikaAppFactory {
    /// @notice The supply of every launch the factory creates; a launch binds its apps in the same call that
    ///         fixes its supply to this value.
    function defaultSupply() external view returns (uint256);
}

/// @notice What the app templates read from the registry.
interface IPikaAppRegistry {
    /// @notice The registry's owner (the timelock), which also governs the dividend sink's exclusion list.
    function owner() external view returns (address);
    /// @notice Accounts allowed to run the sink entries that trade (buyback, liquidity rebalancing).
    function keepers(address account) external view returns (bool);
    /// @notice Whether the template at `target` is paused (the guardian's emergency stop): the sinks' trading entries
    ///         refuse; dividend claims and what the token calls inside trades and transfers never do.
    function appPaused(address target) external view returns (bool);
}

/// @notice What the hub calls on the registry while it validates and registers a launch (`PikaAppRegistry`).
interface IPikaLaunchAppRegistry {
    function holderBookOf(AppBinding[] calldata apps) external view returns (address book);
    function bindLaunch(
        address token,
        address creatorFeeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        AppBinding[] calldata apps
    ) external returns (FeeSlot[] memory slots);
}

/// @notice The launch router, as the sink templates use it: one swap on the launch's venue with a net minimum.
interface IPikaSwapRouter {
    struct SwapParams {
        address token;
        bool sellMeme;
        uint256 amountIn;
        uint256 minOutput;
        address recipient;
        uint256 deadline;
        bool nativeQuote;
    }

    function swap(SwapParams calldata p) external payable returns (uint256 spent, uint256 output);
}

/// @notice What the liquidity template calls on a launch's locker: add to the permanently locked graduation
///         position from the caller's balances (by allowance), returning what was taken.
interface IPikaLiquidityLocker {
    function addToPosition(
        address token,
        uint256 memeMax,
        uint256 quoteMax,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96
    ) external returns (uint128 liquidity, uint256 memeUsed, uint256 quoteUsed);
}
