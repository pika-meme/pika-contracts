// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { LiquidityAmounts } from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { PikaVaultSettle } from "./PikaVaultSettle.sol";
import { PikaFeeMath } from "../../common/libraries/PikaFeeMath.sol";
import { IPikaLaunchToken, IPikaHook } from "../interfaces/IPikaMarket.sol";

/// @notice The only way for third parties to provide liquidity to a graduated launch pool, shared by every launch.
/// @dev A single-sided range is a limit order, so liquidity cannot simply be fee-free: whoever turns meme into quote
///      (or back) through a position pays the launch's outer fee on the net turnover, like a filled order. Each
///      position remembers the meme and the quote put in and not yet settled (`memeBasis`, `quoteBasis`) and the
///      quote set aside for the platform fee of a net buy (`quoteReserve`: the platform fee on top of the quote put
///      in, pulled with it, so the position's quote can convert in full and still pay it; `quoteMax` bounds both).
///      Withdrawing a share of a position compares what comes back with that share of the bases: less meme is a net
///      sell, which pays both fees in quote on the quote gained; more meme is a net buy, which pays the project fee
///      in meme on the meme gained and the platform fee in quote, out of the reserve, on the quote the position
///      converted. The reserve's unused part comes back with the withdrawal. The manager is the vault locker of
///      every position it opens (salt = position id), so it owns them in the pool manager; it settles from and
///      takes to plain ERC20 balances and never mints vault claims. Launch pools charge no LP fee, so a position's
///      withdrawal is all principal. The manager is shared by every launch, so it trusts nothing a token says about
///      its pool: the hook is the authority on which pool belongs to which token, and only a token the hook
///      registered (and that names this manager) can hold positions.
contract PikaLpManager is ReentrancyGuardTransient, ILockCallback {
    using SafeERC20 for IERC20;
    using PikaVaultSettle for int128;

    /// @notice Interface generation required by the current component release.
    uint32 public constant FEE_PROTOCOL_VERSION = 4;

    /// @dev Four slots: the owner; the token and the range; the liquidity and the meme basis; the quote basis and
    ///      the reserve. The amounts are sums of pool deltas and of fees on them, far below 128 bits for any real
    ///      supply, and the additions are checked.
    struct Position {
        address owner;
        address token;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 memeBasis;
        uint128 quoteBasis;
        uint128 quoteReserve;
    }

    struct AddParams {
        address token;
        int24 tickLower;
        int24 tickUpper;
        uint256 memeMax;
        uint256 quoteMax;
        uint128 minLiquidity;
        uint256 deadline;
    }

    struct RemoveParams {
        uint256 positionId;
        uint128 liquidity;
        uint256 memeMin;
        uint256 quoteMin;
        address recipient;
        uint256 deadline;
    }

    /// @dev A withdrawal's outcome, kept in memory to stay within the stack limit.
    struct Withdrawal {
        uint256 meme;
        uint256 quote;
        uint256 memeBasis;
        uint256 quoteBasis;
        uint256 quoteReserve;
        uint256 quoteFee;
        uint256 memeFee;
    }

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    IPikaHook public immutable hook;
    uint256 public positionCount;
    mapping(uint256 positionId => Position) public positions;

    error InvalidPosition();
    error NotOwner();
    error Expired();
    error SlippageExceeded();
    error NotVault();
    error UnsupportedToken();

    event PositionOpened(
        uint256 indexed positionId, address indexed owner, address indexed token, int24 tickLower, int24 tickUpper
    );
    /// @dev `quoteReserve` is the quote pulled on top of `quoteAmount` for the platform fee of a later net buy.
    event LiquidityAdded(
        uint256 indexed positionId, uint128 liquidity, uint256 memeAmount, uint256 quoteAmount, uint256 quoteReserve
    );
    /// @dev The fees on the net turnover, already deducted from the amounts: `quoteFee` is a net sell's whole fee or
    ///      a net buy's platform fee (taken from the reserve, whose rest is in `quoteAmount`), `memeFee` a net buy's
    ///      project fee.
    event LiquidityRemoved(
        uint256 indexed positionId,
        address indexed recipient,
        uint128 liquidity,
        uint256 memeAmount,
        uint256 quoteAmount,
        uint256 quoteFee,
        uint256 memeFee
    );

    constructor(IVault vault_, ICLPoolManager poolManager_, IPikaHook hook_) {
        if (
            address(vault_).code.length == 0 || address(poolManager_).code.length == 0
                || address(poolManager_.vault()) != address(vault_) || address(hook_).code.length == 0
                || hook_.vault() != vault_ || hook_.poolManager() != poolManager_
        ) revert InvalidPosition();
        vault = vault_;
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Open a position at the current price from at most `memeMax` meme and `quoteMax` quote.
    function mint(AddParams calldata p) external nonReentrant returns (uint256 positionId, uint128 liquidity) {
        PoolKey memory key = _launchKey(p.token);
        // MIN_TICK and MAX_TICK belong to the locker's full-range position: a few wei there fill the tick's liquidity
        // cap and stop the locked position from growing (audit 2026-11-02, M-1).
        if (p.tickLower >= p.tickUpper || p.tickLower <= TickMath.MIN_TICK || p.tickUpper >= TickMath.MAX_TICK) {
            revert InvalidPosition();
        }
        positionId = ++positionCount;
        Position storage pos = positions[positionId];
        pos.owner = msg.sender;
        (pos.token, pos.tickLower, pos.tickUpper) = (p.token, p.tickLower, p.tickUpper);
        emit PositionOpened(positionId, msg.sender, p.token, p.tickLower, p.tickUpper);
        liquidity = _add(positionId, pos, key, p.memeMax, p.quoteMax, p.minLiquidity, p.deadline);
    }

    /// @dev The position's token passed `_launchKey` when it opened, and nothing it checks can change since: the
    ///      hook never unregisters a pool and a token's LP manager is fixed.
    function increase(uint256 positionId, uint256 memeMax, uint256 quoteMax, uint128 minLiquidity, uint256 deadline)
        external
        nonReentrant
        returns (uint128 liquidity)
    {
        Position storage pos = positions[positionId];
        if (pos.owner != msg.sender) revert NotOwner();
        liquidity = _add(positionId, pos, hook.poolKey(pos.token), memeMax, quoteMax, minLiquidity, deadline);
    }

    /// @notice Withdraw `liquidity` of a position, paying the fees on its net turnover; the unused share of the
    ///         platform reserve comes back with the quote. Anyone holding no position can never be charged; only the
    ///         owner can withdraw.
    function decrease(RemoveParams calldata p)
        external
        nonReentrant
        returns (uint256 memeAmount, uint256 quoteAmount, uint256 quoteFee, uint256 memeFee)
    {
        if (block.timestamp > p.deadline) revert Expired();
        Position storage pos = positions[p.positionId];
        if (pos.owner != msg.sender) revert NotOwner();
        if (
            p.liquidity == 0 || p.liquidity > pos.liquidity || p.recipient == address(0) || p.recipient == address(this)
        ) revert InvalidPosition();
        IPikaLaunchToken t = IPikaLaunchToken(pos.token);
        PoolKey memory key = hook.poolKey(pos.token);
        bool memeIs0 = Currency.unwrap(key.currency0) == pos.token;
        BalanceDelta delta = _modify(p.positionId, pos, key, -int256(uint256(p.liquidity)));
        Withdrawal memory w;
        (w.meme, w.quote) = memeIs0
            ? (delta.amount0().positive(), delta.amount1().positive())
            : (delta.amount1().positive(), delta.amount0().positive());
        // The share of both bases and of the reserve this withdrawal settles; a full withdrawal settles all of them.
        if (p.liquidity == pos.liquidity) {
            (w.memeBasis, w.quoteBasis, w.quoteReserve) = (pos.memeBasis, pos.quoteBasis, pos.quoteReserve);
        } else {
            w.memeBasis = Math.mulDiv(pos.memeBasis, p.liquidity, pos.liquidity);
            w.quoteBasis = Math.mulDiv(pos.quoteBasis, p.liquidity, pos.liquidity);
            w.quoteReserve = Math.mulDiv(pos.quoteReserve, p.liquidity, pos.liquidity);
        }
        // Each share is at most the stored 128-bit value it is taken from.
        // forge-lint: disable-next-line(unsafe-typecast)
        (pos.liquidity, pos.memeBasis) = (pos.liquidity - p.liquidity, uint128(pos.memeBasis - w.memeBasis));
        // forge-lint: disable-next-line(unsafe-typecast)
        (pos.quoteBasis, pos.quoteReserve) =
            (uint128(pos.quoteBasis - w.quoteBasis), uint128(pos.quoteReserve - w.quoteReserve));
        IERC20 quote = IERC20(Currency.unwrap(memeIs0 ? key.currency1 : key.currency0));
        if (w.meme < w.memeBasis) {
            // A net sell: the quote gained pays both fees in quote. Rounding can leave no gain, which pays nothing.
            // The token may take at most this withdrawal's quote. The whole reserve comes back.
            if (w.quote > w.quoteBasis) {
                quote.forceApprove(pos.token, w.quote);
                w.quoteFee = t.chargeSellFee(msg.sender, w.quote - w.quoteBasis, w.quote);
            }
            memeAmount = w.meme;
        } else if (w.meme > w.memeBasis) {
            // A net buy: the meme gained pays the project fee in meme; the quote the position converted pays the
            // platform fee out of the reserve, whose rest comes back.
            uint256 spent = w.quote < w.quoteBasis ? w.quoteBasis - w.quote : 0;
            quote.forceApprove(pos.token, w.quoteReserve);
            (w.quoteFee, w.memeFee) = t.chargeBuyFees(msg.sender, spent, w.meme - w.memeBasis, w.quoteReserve, w.meme);
            memeAmount = w.meme - w.memeFee;
        } else {
            memeAmount = w.meme;
        }
        quoteAmount = w.quote + w.quoteReserve - w.quoteFee;
        (quoteFee, memeFee) = (w.quoteFee, w.memeFee);
        if (memeAmount < p.memeMin || quoteAmount < p.quoteMin) revert SlippageExceeded();
        if (memeAmount != 0) IERC20(pos.token).safeTransfer(p.recipient, memeAmount);
        if (quoteAmount != 0) quote.safeTransfer(p.recipient, quoteAmount);
        emit LiquidityRemoved(p.positionId, p.recipient, p.liquidity, memeAmount, quoteAmount, quoteFee, memeFee);
    }

    function _add(
        uint256 positionId,
        Position storage pos,
        PoolKey memory key,
        uint256 memeMax,
        uint256 quoteMax,
        uint128 minLiquidity,
        uint256 deadline
    ) private returns (uint128 liquidity) {
        if (block.timestamp > deadline) revert Expired();
        bool memeIs0 = Currency.unwrap(key.currency0) == pos.token;
        liquidity = _liquidityFor(pos, key, memeIs0, memeMax, quoteMax);
        if (liquidity == 0 || liquidity < minLiquidity) revert SlippageExceeded();
        BalanceDelta delta = _modify(positionId, pos, key, int256(uint256(liquidity)));
        (uint256 meme, uint256 quote) = memeIs0
            ? (delta.amount0().negative(), delta.amount1().negative())
            : (delta.amount1().negative(), delta.amount0().negative());
        // The platform reserve on top of the quote put in, pulled with it; `quoteMax` bounds both.
        uint256 reserve = PikaFeeMath.feeOnNet(quote, IPikaLaunchToken(pos.token).platformFeeBps());
        if (meme > memeMax || quote + reserve > quoteMax) revert SlippageExceeded();
        if (reserve != 0) {
            IERC20(Currency.unwrap(memeIs0 ? key.currency1 : key.currency0))
                .safeTransferFrom(msg.sender, address(this), reserve);
        }
        (pos.liquidity, pos.memeBasis) = (pos.liquidity + liquidity, SafeCast.toUint128(pos.memeBasis + meme));
        (pos.quoteBasis, pos.quoteReserve) =
            (SafeCast.toUint128(pos.quoteBasis + quote), SafeCast.toUint128(pos.quoteReserve + reserve));
        emit LiquidityAdded(positionId, liquidity, meme, quote, reserve);
    }

    /// @dev The liquidity the budgets fund at the current price; the quote budget covers the quote put in and the
    ///      platform reserve on top of it.
    function _liquidityFor(Position storage pos, PoolKey memory key, bool memeIs0, uint256 memeMax, uint256 quoteMax)
        private
        view
        returns (uint128)
    {
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        uint256 quoteBudget = quoteMax - IPikaLaunchToken(pos.token).platformReserve(quoteMax);
        (uint256 max0, uint256 max1) = memeIs0 ? (memeMax, quoteBudget) : (quoteBudget, memeMax);
        return LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtRatioAtTick(pos.tickLower), TickMath.getSqrtRatioAtTick(pos.tickUpper), max0, max1
        );
    }

    /// @dev Runs one position change inside the vault lock for the position's owner. The pool key and the range go
    ///      along, so the callback reads nothing again.
    function _modify(uint256 positionId, Position storage pos, PoolKey memory key, int256 liquidityDelta)
        private
        returns (BalanceDelta)
    {
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(positionId)
        });
        return abi.decode(vault.lock(abi.encode(key, params, msg.sender)), (BalanceDelta));
    }

    /// @dev Adding pays straight from the owner's wallet into the vault; removing takes both assets here. Only the
    ///      vault calls it, inside a lock this contract opened, so the data is this contract's own.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (PoolKey memory key, ICLPoolManager.ModifyLiquidityParams memory params, address payer) =
            abi.decode(data, (PoolKey, ICLPoolManager.ModifyLiquidityParams, address));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        PikaVaultSettle.settleOrTake(vault, key.currency0, delta.amount0(), payer);
        PikaVaultSettle.settleOrTake(vault, key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    /// @dev Only a token whose pool the hook registered and that names this manager can hold positions; returns its
    ///      pool key. A contract that merely answers like a launch token cannot pass: the hook, not the token, says
    ///      which pool is the token's, and the hook registers a pool only for the factory, at graduation, which also
    ///      opens its trading.
    function _launchKey(address token) private view returns (PoolKey memory key) {
        if (token.code.length == 0) revert UnsupportedToken();
        try hook.poolKey(token) returns (PoolKey memory k) {
            key = k;
        } catch {
            revert UnsupportedToken();
        }
        if (IPikaLaunchToken(token).lpManager() != address(this)) revert UnsupportedToken();
    }
}
