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
        liquidity = LiquidityAmounts.getLiquidityForAmounts(price, r.lowerPrice, r.upperPrice, max0, max1);
        if (liquidity == 0) revert NotMinted();
        positionId = _mintBurned(positionManager, key, r, liquidity, max0, max1);
        (uint256 used0, uint256 used1) =
            LiquidityAmounts.getAmountsForLiquidity(price, r.lowerPrice, r.upperPrice, liquidity);
        (memeUsed, quoteUsed) = memeIs0 ? (used0, used1) : (used1, used0);
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
