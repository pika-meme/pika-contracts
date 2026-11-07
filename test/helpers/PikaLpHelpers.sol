// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { LiquidityAmounts } from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import { IPikaPositionManager } from "../../src/pika-market/interfaces/IPikaMarket.sol";
import { PikaArtifacts } from "./PikaArtifacts.sol";

/// @notice The read side of Pancake's CL position manager the tests use.
interface IPositionReader {
    function positions(uint256 tokenId)
        external
        view
        returns (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            address subscriber
        );
}

/// @notice Third-party liquidity through Pancake's official position manager (the LP NFT), as any wallet would
///         provide it, and the burned positions the hub and the liquidity sink mint.
/// @dev The helpers fund the position manager first and let it pay the pool from its own balance (`SETTLE` with the
///      position manager as payer), then sweep the rest back: no Permit2 needed.
abstract contract PikaLpHelpers is PikaArtifacts {
    using SafeERC20 for IERC20;

    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Launch pools' tick spacing (PikaHook.TICK_SPACING) and their full range, the outermost usable ticks.
    int24 constant SPACING = 50;
    int24 constant FULL_LOWER = -887_250;
    int24 constant FULL_UPPER = 887_250;

    uint8 constant CL_INCREASE_LIQUIDITY = 0x00;
    uint8 constant CL_DECREASE_LIQUIDITY = 0x01;
    uint8 constant CL_MINT_POSITION = 0x02;
    uint8 constant SETTLE = 0x0b;
    uint8 constant TAKE_PAIR = 0x11;
    uint8 constant SWEEP = 0x14;

    /// @dev `who` mints a position on `key` in [`lower`, `upper`] with as much liquidity as the amounts fund at the
    ///      pool's price; the unused rest comes back to `who`.
    function _lpMint(
        IPikaPositionManager pm,
        PoolKey memory key,
        address who,
        int24 lower,
        int24 upper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 id, uint128 liquidity) {
        liquidity = _lpLiquidity(pm, key, lower, upper, amount0, amount1);
        id = pm.nextTokenId();
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(key, lower, upper, uint256(liquidity), uint128(amount0), uint128(amount1), who, "");
        _lpRun(pm, key, who, amount0, amount1, CL_MINT_POSITION, params);
    }

    /// @dev `who` adds to its position `id` with as much liquidity as the amounts fund.
    function _lpIncrease(IPikaPositionManager pm, uint256 id, address who, uint256 amount0, uint256 amount1)
        internal
        returns (uint128 liquidity)
    {
        (PoolKey memory key, int24 lower, int24 upper,,,,) = IPositionReader(address(pm)).positions(id);
        liquidity = _lpLiquidity(pm, key, lower, upper, amount0, amount1);
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(id, uint256(liquidity), uint128(amount0), uint128(amount1), "");
        _lpRun(pm, key, who, amount0, amount1, CL_INCREASE_LIQUIDITY, params);
    }

    function _lpLiquidity(
        IPikaPositionManager pm,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint128) {
        (uint160 price,,,) = ICLPoolManager(address(pm.clPoolManager())).getSlot0(key.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), amount0, amount1
        );
    }

    function _lpRun(
        IPikaPositionManager pm,
        PoolKey memory key,
        address who,
        uint256 amount0,
        uint256 amount1,
        uint8 action,
        bytes[] memory params
    ) private {
        params[1] = abi.encode(key.currency0, uint256(0), false);
        params[2] = abi.encode(key.currency1, uint256(0), false);
        params[3] = abi.encode(key.currency0, who);
        params[4] = abi.encode(key.currency1, who);
        vm.startPrank(who);
        if (amount0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(pm), amount0);
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(pm), amount1);
        pm.modifyLiquidities(abi.encode(abi.encodePacked(action, SETTLE, SETTLE, SWEEP, SWEEP), params), block.timestamp);
        vm.stopPrank();
    }

    /// @dev `who` takes `liquidity` out of its position `id`; the assets go to `to`.
    function _lpDecrease(IPikaPositionManager pm, uint256 id, address who, uint128 liquidity, address to) internal {
        (PoolKey memory key,,,,,,) = IPositionReader(address(pm)).positions(id);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(liquidity), uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, to);
        vm.prank(who);
        pm.modifyLiquidities(abi.encode(abi.encodePacked(CL_DECREASE_LIQUIDITY, TAKE_PAIR), params), block.timestamp);
    }

    function _lpPosition(IPikaPositionManager pm, uint256 id)
        internal
        view
        returns (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
    {
        (key, lower, upper, liquidity,,,) = IPositionReader(address(pm)).positions(id);
    }

    /// @dev The full-range positions on the pool `id` that the burn address owns among the NFTs from `from` on: how
    ///      many and their liquidity.
    function _burned(IPikaPositionManager pm, PoolId id, uint256 from)
        internal
        view
        returns (uint128 liquidity, uint256 count)
    {
        uint256 next = pm.nextTokenId();
        for (uint256 i = from; i < next; ++i) {
            (PoolKey memory key, int24 lower, int24 upper, uint128 l,,,) = IPositionReader(address(pm)).positions(i);
            if (PoolId.unwrap(key.toId()) != PoolId.unwrap(id) || pm.ownerOf(i) != BURN_ADDRESS) continue;
            if (lower != FULL_LOWER || upper != FULL_UPPER) continue;
            liquidity += l;
            ++count;
        }
    }

    /// @dev The first full-range position on the pool `id` owned by the burn address among the NFTs from `from` on:
    ///      the graduation position. Zero if there is none.
    function _graduationPositionId(IPikaPositionManager pm, PoolId id, uint256 from) internal view returns (uint256) {
        uint256 next = pm.nextTokenId();
        for (uint256 i = from; i < next; ++i) {
            (PoolKey memory key, int24 lower, int24 upper,,,,) = IPositionReader(address(pm)).positions(i);
            if (PoolId.unwrap(key.toId()) != PoolId.unwrap(id) || pm.ownerOf(i) != BURN_ADDRESS) continue;
            if (lower == FULL_LOWER && upper == FULL_UPPER) return i;
        }
        return 0;
    }

    /// @dev `tick` rounded down to the launch pools' spacing: a valid position bound at or below it.
    function _onSpacing(int24 tick) internal pure returns (int24) {
        int24 r = tick % SPACING;
        return r < 0 ? tick - r - SPACING : tick - r;
    }
}
