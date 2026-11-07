// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The one way every Pika component computes an outer fee, so the hook, the token, the order manager, the
///         LP manager and the lens agree to the wei.
library PikaFeeMath {
    uint256 internal constant BPS = 10_000;
    /// @dev The outer platform fee, both directions, always in quote (`PikaToken.PLATFORM_FEE_BPS`).
    uint256 internal constant PLATFORM_FEE_BPS = 30;
    /// @dev The cap on platform plus project fee per direction (`PikaToken.MAX_TOTAL_FEE_BPS`); the hub and the token
    ///      module check launches against it too.
    uint256 internal constant MAX_TOTAL_FEE_BPS = 1000;

    /// @dev The fee inside a gross amount: `floor(gross × bps / 10000)`.
    function feeAt(uint256 gross, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(gross, bps, BPS);
    }

    /// @dev The fee on top of a net amount, so that the gross carries the rate: `ceil(net × 10000 / (10000 − bps)) − net`.
    function feeOnNet(uint256 net, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(net, BPS, BPS - bps, Math.Rounding.Ceil) - net;
    }

    /// @dev What to set aside from a budget so that the rest, once all of it converts, can pay its fee on top:
    ///      `ceil(budget × bps / 10000)`, never less than `feeOnNet(budget − reserve, bps)`.
    function reserve(uint256 budget, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(budget, bps, BPS, Math.Rounding.Ceil);
    }
}
