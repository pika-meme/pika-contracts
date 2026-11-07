// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PikaAppBase } from "./PikaAppBase.sol";
import { IPikaAppRegistry, IPikaSwapRouter } from "./interfaces/IPikaApps.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { IPikaLaunchToken } from "../pika-market/interfaces/IPikaMarket.sol";

/// @notice What the default sinks that trade on the pool share: fees accumulate per launch and asset until a keeper
///         dispatches them, and the dispatch swaps through the launch's router.
/// @dev A swap needs an honest minimum output, so the entries that swap are keeper-only (the registry's list). The
///      on-chain floor on a dispatch is one hundredth of a unit of the asset dispatched; the keeper's own threshold is
///      higher and lives in its configuration.
///
///      Batches: each sink also takes several launches in one call. The batch calls the single-launch entry on this
///      contract once per launch, inside `try`, so a launch that reverts (a moved price, nothing worth a dispatch) is
///      skipped with `DispatchSkipped` and the others still go through. Those inner calls come from this contract,
///      so the keeper check accepts it as the caller; nothing else makes this contract call itself, and the batch
///      checks the keeper (and the pause) first. The batch holds no reentrancy lock of its own: each inner call takes
///      it, as a direct call would.
abstract contract PikaSinkBase is PikaAppBase {
    using SafeERC20 for IERC20;

    /// @notice A dispatch moves at least one unit of the asset divided by this.
    uint256 public constant MIN_DISPATCH_DIVISOR = 100;

    /// @notice Fees received and not yet dispatched, per launch and asset (the launch token for buy fees, its quote
    ///         asset for sell fees).
    mapping(address token => mapping(address asset => uint256)) public pending;
    /// @dev Room for later fields shared by the sinks.
    uint256[49] private __sinkGap;

    error NotKeeper();
    error BelowThreshold();

    /// @dev `amount` is in the sink's own asset: the launch token for a buy, the quote asset for a sell.
    event Dispatched(address indexed token, bool sellMeme, uint256 amountIn, uint256 amountOut);
    /// @notice A batch skipped this launch: `reason` is the revert data of its single-launch entry.
    event DispatchSkipped(address indexed token, bytes reason);

    constructor(address registry_) PikaAppBase(registry_) { }

    /// @dev Default sinks take no parameters.
    function _register(address, bytes calldata params) internal virtual override {
        if (params.length != 0) revert InvalidParams();
    }

    function _book(address token, address asset, uint256 amount) internal override {
        pending[token][asset] += amount;
    }

    /// @notice The launch pool's current price and the side meme sits on, for keepers computing a minimum output.
    function poolPrice(address token) external view returns (uint160 sqrtPriceX96, bool memeIs0) {
        _requireRegistered(token);
        return _price(IPikaLaunchToken(token));
    }

    function _price(IPikaLaunchToken t) internal view returns (uint160 sqrtPriceX96, bool memeIs0) {
        memeIs0 = t.memeIsCurrency0();
        PoolKey memory key = t.poolKey();
        (sqrtPriceX96,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
    }

    /// @dev A keeper, or this contract running a keeper's batch (see the contract notes).
    function _requireKeeper() internal view {
        if (msg.sender != address(this) && !IPikaAppRegistry(registry).keepers(msg.sender)) revert NotKeeper();
    }

    /// @dev The smallest amount of `asset` worth a dispatch.
    function _minDispatch(address asset) internal view returns (uint256) {
        return 10 ** IERC20Metadata(asset).decimals() / MIN_DISPATCH_DIVISOR;
    }

    /// @dev One swap on the launch's pool through its router, from and to this contract. The router fills it in full
    ///      or reverts. The swap pays the outer fee like any trade; the token books it, and this sink's share
    ///      arrives with a later fee push.
    function _swap(address token, bool sellMeme, uint256 amountIn, uint256 minOut, uint256 deadline)
        internal
        returns (uint256 spent, uint256 out)
    {
        IPikaLaunchToken t = IPikaLaunchToken(token);
        if (!t.tradingStarted()) revert NotGraduated();
        address router = t.tradingRouter();
        IERC20 input = IERC20(sellMeme ? token : t.quoteAsset());
        input.forceApprove(router, amountIn);
        (spent, out) = IPikaSwapRouter(router)
            .swap(IPikaSwapRouter.SwapParams(token, sellMeme, amountIn, minOut, address(this), deadline, false));
        input.forceApprove(router, 0);
        emit Dispatched(token, sellMeme, spent, out);
    }
}
