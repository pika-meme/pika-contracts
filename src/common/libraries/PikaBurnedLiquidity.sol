// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { CLPoolParametersHelper } from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import { SqrtPriceMath } from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import { IPikaPositionManager } from "../../pika-market/interfaces/IPikaMarket.sol";

/// @notice Permanently locked liquidity the standard way: a full-range position minted through Pancake's official CL
///         position manager straight to the burn address. Nobody holds the NFT's key, the position manager has no
///         owner and is not upgradeable, and only an NFT's owner or approved account may decrease or burn it, so the
///         liquidity can never leave the pool. Used by the hub at graduation and by the liquidity sink.
/// @dev The caller's meme and quote go to the position manager, which pays the pool from its own balance (`SETTLE`
///      with the payer being itself) and sweeps the rest back. The sweep returns whatever the position manager held of
///      the two currencies, a stranger's leftovers included, so the amounts used are derived from the liquidity, never
///      from balance changes a third party could skew. Launch pools charge no LP fee, so the position never earns.
library PikaBurnedLiquidity {
    using SafeERC20 for IERC20;
    using CLPoolParametersHelper for bytes32;

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    // Pancake Infinity periphery `Actions`.
    uint8 private constant CL_MINT_POSITION = 0x02;
    uint8 private constant SETTLE = 0x0b;
    uint8 private constant SWEEP = 0x14;
    /// @dev `ActionConstants.OPEN_DELTA`: settle the whole debt.
    uint256 private constant OPEN_DELTA = 0;

    error NotMinted();

    /// @dev The full range's ticks and their prices.
    struct Range {
        int24 lower;
        int24 upper;
        uint160 lowerPrice;
        uint160 upperPrice;
    }

    /// @notice Mints a full-range position (the outermost ticks on the pool's spacing) at the pool's current price from
    ///         at most `memeMax` meme and `quoteMax` quote held by the caller, owned by the burn address. What the
    ///         position does not take comes back to the caller. `memeUsed` and `quoteUsed` are what the liquidity is
    ///         worth at that price (rounded down; the pool may take one more unit of each).
    /// @dev The pool charges a mint rounded up (`CLPool.modifyLiquidity`), and currency0 twice over (once per
    ///      division by a sqrt price), so the liquidity `LiquidityAmounts` derives from an amount can cost one unit
    ///      more than that amount; the position manager then refuses the mint, and for the hub that would make a
    ///      sold-out launch impossible to graduate (audit 2026-11-08b, L-3). The liquidity is therefore checked
    ///      against the pool's own arithmetic (`_charge`) and, only when it would cost more than the maxima, derived
    ///      again from one unit less than each: a charge is at most one unit above the amount it was derived from, so
    ///      that second derivation always fits. Launches whose amounts round cleanly (every one tried) keep the exact
    ///      liquidity of before.
    function mint(
        IPikaPositionManager positionManager,
        ICLPoolManager poolManager,
        PoolKey memory key,
        bool memeIs0,
        uint256 memeMax,
        uint256 quoteMax
    ) internal returns (uint256 positionId, uint128 liquidity, uint256 memeUsed, uint256 quoteUsed) {
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        (uint256 max0, uint256 max1) = memeIs0 ? (memeMax, quoteMax) : (quoteMax, memeMax);
        Range memory r = _fullRange(key.parameters.getTickSpacing());
        liquidity = _liquidityWithin(price, r, max0, max1);
        positionId = _mintBurned(positionManager, key, r, liquidity, max0, max1);
        (uint256 used0, uint256 used1) =
            LiquidityAmounts.getAmountsForLiquidity(price, r.lowerPrice, r.upperPrice, liquidity);
        (memeUsed, quoteUsed) = memeIs0 ? (used0, used1) : (used1, used0);
    }

    /// @dev The liquidity `max0` and `max1` fund over `r` at `price`, which the pool is sure to charge no more than
    ///      `max0` and `max1` for (see the contract notes on the L-3 fallback).
    function _liquidityWithin(uint160 price, Range memory r, uint256 max0, uint256 max1)
        private
        pure
        returns (uint128 liquidity)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(price, r.lowerPrice, r.upperPrice, max0, max1);
        if (liquidity == 0) revert NotMinted();
        (uint256 charge0, uint256 charge1) = _charge(price, r, liquidity);
        if (charge0 > max0 || charge1 > max1) {
            // Both maxima are nonzero here: a zero one gives zero liquidity above.
            liquidity = LiquidityAmounts.getLiquidityForAmounts(price, r.lowerPrice, r.upperPrice, max0 - 1, max1 - 1);
            if (liquidity == 0) revert NotMinted();
        }
    }

    /// @dev What the pool charges for minting `liquidity` over `r` at `price`: `CLPool.modifyLiquidity`'s amounts,
    ///      rounded up, with the same branches on the price's position as `LiquidityAmounts`.
    function _charge(uint160 price, Range memory r, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (price <= r.lowerPrice) {
            amount0 = SqrtPriceMath.getAmount0Delta(r.lowerPrice, r.upperPrice, liquidity, true);
        } else if (price < r.upperPrice) {
            amount0 = SqrtPriceMath.getAmount0Delta(price, r.upperPrice, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(r.lowerPrice, price, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(r.lowerPrice, r.upperPrice, liquidity, true);
        }
    }

    function _fullRange(int24 spacing) private pure returns (Range memory r) {
        r.lower = TickMath.minUsableTick(spacing);
        r.upper = TickMath.maxUsableTick(spacing);
        r.lowerPrice = TickMath.getSqrtRatioAtTick(r.lower);
        r.upperPrice = TickMath.getSqrtRatioAtTick(r.upper);
    }

    /// @dev Hands the maxima to the position manager, which mints `liquidity` over `r` to the burn address, pays the
    ///      pool from what it holds and sweeps the rest back.
    function _mintBurned(
        IPikaPositionManager positionManager,
        PoolKey memory key,
        Range memory r,
        uint128 liquidity,
        uint256 max0,
        uint256 max1
    ) private returns (uint256 positionId) {
        if (max0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(positionManager), max0);
        if (max1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(positionManager), max1);
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            key,
            r.lower,
            r.upper,
            uint256(liquidity),
            SafeCast.toUint128(max0),
            SafeCast.toUint128(max1),
            BURN,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, OPEN_DELTA, false);
        params[2] = abi.encode(key.currency1, OPEN_DELTA, false);
        params[3] = abi.encode(key.currency0, address(this));
        params[4] = abi.encode(key.currency1, address(this));
        positionId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(CL_MINT_POSITION, SETTLE, SETTLE, SWEEP, SWEEP), params), block.timestamp
        );
        if (positionManager.ownerOf(positionId) != BURN) revert NotMinted();
    }
}
