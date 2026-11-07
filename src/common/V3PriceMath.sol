// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library V3PriceMath {
    /// @notice Quote at a raw token1/token0 sqrt price; supports the entire v3 tick range.
    function quote(uint256 amountIn, uint160 sqrtPriceX96, bool zeroForOne, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        uint256 ratio;
        uint256 scale;
        if (sqrtPriceX96 <= type(uint128).max) {
            ratio = uint256(sqrtPriceX96) * sqrtPriceX96;
            scale = 1 << 192;
        } else {
            // Round the ratio in the direction that makes a minimum-output requirement conservative.
            ratio = Math.mulDiv(
                sqrtPriceX96, sqrtPriceX96, 1 << 64, roundUp && zeroForOne ? Math.Rounding.Ceil : Math.Rounding.Floor
            );
            scale = 1 << 128;
        }
        return Math.mulDiv(
            amountIn,
            zeroForOne ? ratio : scale,
            zeroForOne ? scale : ratio,
            roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
    }
}
