// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { TransientSlot } from "@openzeppelin/contracts/utils/TransientSlot.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { PikaToken } from "./PikaToken.sol";
import { PikaPermit, IWBNB, IPikaHub } from "./interfaces/IPikaLaunch.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { PikaFactoryBound } from "../pika-market/PikaFactoryBound.sol";

/// @notice One shared entry for every graduated launch's pool swaps. Curve trades before graduation go through
///         OpenFour Core. Wallets approve a quote asset once for all launches; BNB launches trade native BNB.
/// @dev Serves only launches of the factory it is bound to: `swap` refuses any other `token`, so a contract that
///      merely imitates a launch's getters cannot have the router act on it. Holds no trade funds between
///      transactions; unsolicited balances are never counted as a trade's funds or refund.
///      Swap context lives in transient storage; launch tokens read the trader from it when the hook hands them a
///      fee. A pool swap settles straight between the trader and the Infinity vault inside the lock: the input the
///      pool took (and, on a buy, the platform fee the hook reserved out of it) is pulled from the trader into the
///      vault, the output is taken from the vault to the recipient, so nothing passes through this contract and no
///      balance is read (2026-11-01). The hook takes the fees inside the swap: a buy's
///      platform fee out of the quote input and its project fee out of the meme output, a sell's whole fee out of
///      the quote output; `minOutput` measures the net output. Without price limits and with the locked full-range
///      position always in the pool, a router swap fills in full; one that would not (the price limit at the
///      protocol's edge) reverts instead of refunding.
contract PikaRouter is PikaFactoryBound, ReentrancyGuardTransient, ILockCallback {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @notice Interface generation required by the current component release.
    uint32 public constant FEE_PROTOCOL_VERSION = 4;

    struct SwapParams {
        address token;
        bool sellMeme;
        uint256 amountIn;
        uint256 minOutput;
        address recipient;
        uint256 deadline;
        /// @dev Pay or receive native BNB instead of WBNB on a graduated BNB launch.
        bool nativeQuote;
    }

    IWBNB public immutable wrappedNative;
    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;

    bytes32 private constant TRADER_SLOT = keccak256("pika.router.trader");

    error NativeTransferFailed();
    error InvalidTrade();
    error NotVault();

    event Swap(
        address indexed token,
        address indexed user,
        address indexed recipient,
        bool sellMeme,
        uint256 spent,
        uint256 received
    );

    constructor(address wrappedNative_, IVault vault_, ICLPoolManager poolManager_) {
        if (
            wrappedNative_.code.length == 0 || address(vault_).code.length == 0
                || address(poolManager_).code.length == 0 || address(poolManager_.vault()) != address(vault_)
        ) revert InvalidTrade();
        wrappedNative = IWBNB(wrappedNative_);
        vault = vault_;
        poolManager = poolManager_;
    }

    /// @notice Native BNB arrives only as an unwrap.
    receive() external payable {
        if (msg.sender != address(wrappedNative)) revert InvalidTrade();
    }

    /// @notice The trader of the pool swap in progress; zero outside a swap.
    function trader() external view returns (address) {
        return TRADER_SLOT.asAddress().tload();
    }

    function swap(SwapParams calldata p) external payable nonReentrant returns (uint256 spent, uint256 output) {
        return _swap(p);
    }

    /// @notice Sell meme with an EIP-2612 signature for this router over `amountIn`, in one transaction.
    /// @dev A front-run permit only consumes the signature; the allowance it set is then used as usual.
    function swapWithPermit(SwapParams calldata p, PikaPermit calldata permit)
        external
        nonReentrant
        returns (uint256 spent, uint256 output)
    {
        if (!p.sellMeme) revert InvalidTrade();
        try IERC20Permit(p.token)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) { }
            catch { }
        return _swap(p);
    }

    function _swap(SwapParams calldata p) private returns (uint256 spent, uint256 output) {
        if (
            p.amountIn == 0 || p.amountIn > uint256(uint128(type(int128).max)) || p.deadline < block.timestamp
                || p.recipient == address(0) || p.recipient == address(this)
        ) revert InvalidTrade();
        // Only a launch of the bound factory is trusted for its pool and quote getters.
        if (!IPikaHub(factory).isLaunch(p.token)) revert InvalidTrade();
        PikaToken t = PikaToken(p.token);
        PikaToken.RouterContext memory c = t.routerContext();
        // Before graduation the launch trades on its OpenFour curve, through OpenFour Core.
        if (!c.tradingStarted) revert InvalidTrade();
        return _poolSwap(t, c, p);
    }

    /// @dev What the lock callback needs: the pool, the direction, the input offered, the price limit, who pays and
    ///      who receives, and whether the input arrives as native BNB (wrapped inside the lock) or the output leaves
    ///      as native BNB (taken here first and unwrapped after the lock).
    struct PoolContext {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 limit;
        address trader;
        address recipient;
        bool nativeIn;
        bool nativeOut;
    }

    function _poolSwap(PikaToken t, PikaToken.RouterContext memory c, SwapParams calldata p)
        private
        returns (uint256 spent, uint256 output)
    {
        if (c.router != address(this)) revert InvalidTrade();
        if (p.nativeQuote && c.quoteAsset != address(wrappedNative)) revert InvalidTrade();
        bool nativeIn = p.nativeQuote && !p.sellMeme;
        if (nativeIn ? msg.value != p.amountIn : msg.value != 0) revert InvalidTrade();
        bool zeroForOne = p.sellMeme == c.memeIsCurrency0;
        TRADER_SLOT.asAddress().tstore(msg.sender);
        bytes memory result = vault.lock(
            abi.encode(
                PoolContext(
                    c.key,
                    zeroForOne,
                    p.amountIn,
                    zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                    msg.sender,
                    p.recipient,
                    nativeIn,
                    p.nativeQuote && p.sellMeme
                )
            )
        );
        TRADER_SLOT.asAddress().tstore(address(0));
        (spent, output) = abi.decode(result, (uint256, uint256));
        // A full fill owes exactly the input: on a buy the pool took the input less the hook's platform reservation.
        if (spent != p.amountIn || output == 0 || output < p.minOutput) revert InvalidTrade();
        if (p.nativeQuote && p.sellMeme) {
            wrappedNative.withdraw(output);
            _sendNative(p.recipient, output);
        }
        emit Swap(address(t), msg.sender, p.recipient, p.sellMeme, spent, output);
    }

    /// @dev Swaps, pulls exactly what the swap owes from the trader into the vault and takes the
    ///      output to the recipient. The swap's deltas already include the hook's: a buy owes the quote the pool took
    ///      plus the platform fee, and its meme output is net of the project fee.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        PoolContext memory c = abi.decode(data, (PoolContext));
        BalanceDelta delta = poolManager.swap(
            c.key,
            ICLPoolManager.SwapParams({
                zeroForOne: c.zeroForOne, amountSpecified: -int256(c.amountIn), sqrtPriceLimitX96: c.limit
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            c.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (inDelta >= 0 || outDelta <= 0) revert InvalidTrade();
        Currency inputCurrency = c.zeroForOne ? c.key.currency0 : c.key.currency1;
        Currency outputCurrency = c.zeroForOne ? c.key.currency1 : c.key.currency0;
        // int128 magnitudes always fit in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-inDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(uint128(outDelta));
        vault.sync(inputCurrency);
        if (c.nativeIn) {
            wrappedNative.deposit{ value: owed }();
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(vault), owed);
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(c.trader, address(vault), owed);
        }
        vault.settle();
        vault.take(outputCurrency, c.nativeOut ? address(this) : c.recipient, out);
        return abi.encode(owed, out);
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }
}
