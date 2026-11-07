// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { LiquidityAmounts } from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import { PikaToken } from "../../pika-launch/PikaToken.sol";
import { PikaFactoryBound } from "../PikaFactoryBound.sol";
import { PikaVaultSettle } from "./PikaVaultSettle.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";

/// @notice Pika permanent LP lock, shared by every launch: each launch's full-range graduation position and its
///         excess supply cannot leave. The liquidity sink adds project fees to the same position.
/// @dev The locker owns the pool position directly in the pool manager (it is the locker that modifies it), so no
///      NFT or third party can ever move it. There is no liquidity-decrease entry point and, since launch pools
///      charge no LP fee, nothing to harvest. Creators are paid through project fees, never from the locked LP.
contract PikaLocker is PikaFactoryBound, ReentrancyGuardTransient, ILockCallback {
    using SafeERC20 for IERC20;

    /// @notice A launch's locked graduation position: always the full tick range. The tokens beyond the pool's
    ///         (the curve's unsold remainder, donations) stay here for good; `PositionLocked` reports them.
    struct Position {
        uint128 liquidity;
    }

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    address public immutable treasury;
    mapping(address token => Position) public positions;
    /// @notice The liquidity sink templates, the only accounts that may add to a locked position. A set, not one
    ///         address: a launch keeps the template it bound at creation, so naming a newer template must not cut
    ///         the older one off from the position its launches' fees are meant for (audit 2026-10-31b, L-4).
    mapping(address app => bool allowed) public liquidityApps;
    /// @notice Unused graduation quote owed to the treasury, tracked by asset across launches. It is separate
    ///         from locked meme and from unsolicited balances; a later graduation never sweeps an earlier debt.
    mapping(address asset => uint256 amount) public pendingTreasuryQuote;

    error InvalidConfiguration();
    error PriceOutOfRange(uint160 price, uint160 lower, uint160 upper);
    error NotVault();

    event PositionLocked(
        address indexed token, uint128 liquidity, uint256 memeUsed, uint256 quoteUsed, uint256 excessTokens
    );
    event PositionIncreased(address indexed token, uint128 liquidity, uint256 memeUsed, uint256 quoteUsed);
    event LiquidityAppUpdated(address indexed app, bool allowed);
    event TreasuryQuoteAccrued(address indexed token, address indexed asset, uint256 amount);
    event TreasuryQuoteClaimed(address indexed asset, address indexed treasury, uint256 amount);

    constructor(IVault vault_, ICLPoolManager poolManager_, address treasury_) {
        if (
            address(vault_).code.length == 0 || address(poolManager_).code.length == 0
                || address(poolManager_.vault()) != address(vault_) || treasury_ == address(0)
        ) revert InvalidConfiguration();
        vault = vault_;
        poolManager = poolManager_;
        treasury = treasury_;
    }

    /// @notice Seed and lock the full-range graduation position from the meme and quote the factory moved here.
    ///         Whatever meme is not needed stays locked here; unused quote is owed to the treasury and claimed
    ///         separately, so a treasury payment cannot block graduation.
    /// @dev Called by the factory inside graduation, before trading opens. The hook admits this position only then.
    function lockPosition(address token, uint256 memeAmount, uint256 quoteAmount)
        external
        nonReentrant
        returns (uint128 liquidity, uint256 memeUsed, uint256 quoteUsed)
    {
        _requireFactory();
        Position storage p = positions[token];
        if (p.liquidity != 0 || memeAmount == 0 || quoteAmount == 0) revert InvalidConfiguration();
        PikaToken t = PikaToken(token);
        PoolKey memory key = t.poolKey();
        bool memeIs0 = t.memeIsCurrency0();
        (uint256 amount0, uint256 amount1) = memeIs0 ? (memeAmount, quoteAmount) : (quoteAmount, memeAmount);
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO, amount0, amount1
        );
        if (liquidity == 0) revert InvalidConfiguration();
        (memeUsed, quoteUsed) = _modify(key, memeIs0, liquidity, address(this));
        if (memeUsed == 0 || quoteUsed == 0 || memeUsed > memeAmount || quoteUsed > quoteAmount) {
            revert InvalidConfiguration();
        }
        p.liquidity = liquidity;
        uint256 excess = t.balanceOf(address(this));
        _accrueTreasuryQuote(token, Currency.unwrap(memeIs0 ? key.currency1 : key.currency0), quoteAmount - quoteUsed);
        emit PositionLocked(token, liquidity, memeUsed, quoteUsed, excess);
    }

    function _accrueTreasuryQuote(address token, address quote, uint256 amount) private {
        if (amount == 0) return;
        pendingTreasuryQuote[quote] += amount;
        emit TreasuryQuoteAccrued(token, quote, amount);
    }

    /// @notice Anyone may pay the recorded graduation remainder of one quote asset to the fixed treasury. Clear
    ///         before paying; a failed transfer restores the debt for retry. Never sweeps locked or donated funds.
    function claimTreasuryQuote(address asset) external nonReentrant returns (uint256 amount) {
        amount = pendingTreasuryQuote[asset];
        if (amount == 0) return 0;
        pendingTreasuryQuote[asset] = 0;
        IERC20(asset).safeTransfer(treasury, amount);
        emit TreasuryQuoteClaimed(asset, treasury, amount);
    }

    /// @notice Only the factory's timelocked owner names or removes a liquidity sink. Removing one strands the fees
    ///         its launches have pending until it is named again, so it is an owner decision in both directions.
    function setLiquidityApp(address app, bool allowed) external {
        if (msg.sender != Ownable(factory).owner()) revert Unauthorized();
        if (app.code.length == 0) revert InvalidConfiguration();
        liquidityApps[app] = allowed;
        emit LiquidityAppUpdated(app, allowed);
    }

    /// @notice Add to a launch's locked graduation position from the caller's balances (by allowance): as much
    ///         liquidity as `memeMax` and `quoteMax` fund at the current price, which must sit inside
    ///         [`sqrtPriceMinX96`, `sqrtPriceMaxX96`] so a sandwiched dispatch cannot add at a pushed price. Only a
    ///         named liquidity sink calls it, once the pool trades; what is added can never leave either.
    function addToPosition(
        address token,
        uint256 memeMax,
        uint256 quoteMax,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96
    ) external nonReentrant returns (uint128 liquidity, uint256 memeUsed, uint256 quoteUsed) {
        if (!liquidityApps[msg.sender]) revert Unauthorized();
        Position storage p = positions[token];
        if (p.liquidity == 0) revert InvalidConfiguration();
        PikaToken t = PikaToken(token);
        PoolKey memory key = t.poolKey();
        bool memeIs0 = t.memeIsCurrency0();
        (uint256 amount0, uint256 amount1) = memeIs0 ? (memeMax, quoteMax) : (quoteMax, memeMax);
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price < sqrtPriceMinX96 || price > sqrtPriceMaxX96) {
            revert PriceOutOfRange(price, sqrtPriceMinX96, sqrtPriceMaxX96);
        }
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO, amount0, amount1
        );
        if (liquidity == 0) revert InvalidConfiguration();
        (memeUsed, quoteUsed) = _modify(key, memeIs0, liquidity, msg.sender);
        if (memeUsed > memeMax || quoteUsed > quoteMax) revert InvalidConfiguration();
        p.liquidity += liquidity;
        emit PositionIncreased(token, liquidity, memeUsed, quoteUsed);
    }

    /// @dev Adds `liquidity` to the full-range position inside a vault lock, paid by `payer`.
    function _modify(PoolKey memory key, bool memeIs0, uint128 liquidity, address payer)
        private
        returns (uint256 memeUsed, uint256 quoteUsed)
    {
        BalanceDelta delta = abi.decode(vault.lock(abi.encode(key, liquidity, payer)), (BalanceDelta));
        uint256 used0 = PikaVaultSettle.negative(delta.amount0());
        uint256 used1 = PikaVaultSettle.negative(delta.amount1());
        (memeUsed, quoteUsed) = memeIs0 ? (used0, used1) : (used1, used0);
    }

    /// @dev Position changes run inside the vault lock and settle what the position needs from the payer: this
    ///      contract's balances when seeding, the liquidity sink's when adding.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (PoolKey memory key, uint128 liquidity, address payer) = abi.decode(data, (PoolKey, uint128, address));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        // Adding liquidity only ever owes the vault.
        if (delta.amount0() > 0 || delta.amount1() > 0) revert InvalidConfiguration();
        PikaVaultSettle.settleOrTake(vault, key.currency0, delta.amount0(), payer);
        PikaVaultSettle.settleOrTake(vault, key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }
}
