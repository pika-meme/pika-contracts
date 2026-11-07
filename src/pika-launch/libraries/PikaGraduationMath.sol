// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PikaGraduationMath
 * @notice Graduation math: the bonding curve's sizing (OpenFour's standard curve) and the
 * sqrtPriceX96 needed to seed a brand-new concentrated-liquidity pool with a single full-range
 * position from two known token amounts. In the
 * full-range limit (tickLower/tickUpper at the usable min/max ticks), a
 * position's amount0 and amount1 approach `liquidity / sqrtPrice` and
 * `liquidity * sqrtPrice`, so `amount1 / amount0` converges to the pool
 * price. This is exact enough for seeding a graduation pool, since both
 * amounts here are the sold-out curve's non-extreme pool amounts.
 */
library PikaGraduationMath {
    /// @notice The share of the raised quote OpenFour's bonding curve (`module.curve.bonding`) leaves for the
    ///         graduation pool, in bps: its final price is this share of the target against the tokens it keeps.
    uint256 internal constant POOL_QUOTE_BPS = 9800;

    error ZeroAmount();
    error UnsupportedPrice();
    error UnsupportedSizing();

    /**
     * @notice The virtual reserves OpenFour's bonding curve (`module.curve.bonding`, closed source) sets up for a
     *         launch, mirrored from its observed behaviour (BSC mainnet implementation
     *         `0xeAcb4085088a84f7dfC9AEBf8F0116A418f2600b`, 2026-11-06). Exact for Pika's 80/20 split.
     * @dev The curve is a constant product `virtualQuote · virtualTokens` over `virtualQuote + totalRaised` quote
     *      against `virtualTokens − sold` tokens, sized so that selling `saleAmount` raises `target` and ends at
     *      `POOL_QUOTE_BPS` of the target against the `supply − saleAmount` tokens left for the pool:
     *      q = target·9800/10000, virtualTokens = sale²·q / (sale·q − kept·target),
     *      virtualQuote = kept·target² / (sale·q − kept·target), each rounded down. Reverts when the split leaves
     *      no curve (the kept tokens' share of the sale must stay below 98%).
     */
    function bondingReserves(uint256 supply, uint256 saleAmount, uint256 target)
        internal
        pure
        returns (uint256 virtualQuote, uint256 virtualTokens)
    {
        if (saleAmount == 0 || saleAmount >= supply || target == 0) revert UnsupportedSizing();
        uint256 kept = supply - saleAmount;
        uint256 q = target * POOL_QUOTE_BPS / 10_000;
        uint256 sold = saleAmount * q;
        uint256 owed = kept * target;
        if (sold <= owed) revert UnsupportedSizing();
        virtualTokens = Math.mulDiv(saleAmount * saleAmount, q, sold - owed);
        virtualQuote = Math.mulDiv(owed, target, sold - owed);
        if (virtualQuote == 0) revert UnsupportedSizing();
    }

    /**
     * @notice Computes sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96.
     * @param amount0 Amount of the pool's currency0, must be nonzero.
     * @param amount1 Amount of the pool's currency1, must be nonzero.
     */
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        if (_fitsQ192(amount0, amount1)) {
            uint256 ratioX192 = Math.mulDiv(amount1, 1 << 192, amount0);
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(Math.sqrt(ratioX192));
        }

        // A Q128 ratio preserves the remaining valid CL price range without
        // requiring the intermediate Q192 quotient to fit in uint256.
        if (!_fitsQ128(amount0, amount1)) revert UnsupportedPrice();
        uint256 ratioX128 = Math.mulDiv(amount1, 1 << 128, amount0);
        uint256 sqrtPriceX64 = Math.sqrt(ratioX128);
        if (sqrtPriceX64 > type(uint128).max) revert UnsupportedPrice();

        // sqrt(amount1 / amount0 * 2^128) is Q64. Shift it into Q96.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPriceX64 << 32);
    }

    /**
     * @dev A Q192 quotient fits uint256 only when amount1 / amount0 is
     * strictly below 2^64. Avoiding the multiplication also avoids overflow.
     */
    function _fitsQ192(uint256 amount0, uint256 amount1) private pure returns (bool) {
        if (amount0 > type(uint192).max) return true;
        return amount1 < (amount0 << 64);
    }

    /**
     * @dev A Q128 quotient covers the remaining representable CL price range.
     */
    function _fitsQ128(uint256 amount0, uint256 amount1) private pure returns (bool) {
        if (amount0 > type(uint128).max) return true;
        return amount1 < (amount0 << 128);
    }
}
