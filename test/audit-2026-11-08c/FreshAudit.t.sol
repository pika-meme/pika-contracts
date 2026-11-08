// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { SqrtPriceMath } from "infinity-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaOrderManager } from "../../src/pika-market/infinity/PikaOrderManager.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice Independent contract audit 2026-11-08 (third pass, from source only): the proofs behind
///         docs/audit-2026-11-08c-fresh-audit.md.
///
///         R-1  The liquidity `LiquidityAmounts` derives from an amount never costs more than that amount when the
///              pool charges it rounded up, on either side and at any price: the L-3 fallback in
///              `PikaBurnedLiquidity._liquidityWithin` (derive again from one unit less) can never be reached, and a
///              token0-side limit order can never fail its activation on `used > totalInput`.
///         K-1  The sinks' trading entries accept any nonzero minimum output. A compromised or careless keeper can
///              therefore be sandwiched for almost the whole dispatch: the attacker pumps the pool, the keeper's
///              buyback executes at the pumped price, the attacker sells back into the sink's quote.
contract FreshAudit20261108cTest is PikaInfinityFixture {
    // ------------------------------------------------------------------------------------------------------- R-1

    /// @dev Any range on the spacing (narrow or full), any price inside it, any amounts: the liquidity derived from
    ///      the amounts never costs more than the amounts when charged rounded up, as `CLPool.modifyLiquidity` does.
    ///      Algebra: `L0 = floor(a0 * floor(sA*sB/Q96) / (sB-sA))` gives `L0*Q96*(sB-sA)/(sA*sB) <= a0`, and the two
    ///      ceilings of `getAmount0Delta` add less than `1/sA` to a value whose fractional part is either zero or at
    ///      least that; `L1 = floor(a1*Q96/(sB-sA))` gives `ceil(L1*(sB-sA)/Q96) <= a1` directly.
    /// forge-config: default.fuzz.runs = 50000
    /// forge-config: lite.fuzz.runs = 50000
    function testFuzz_R1_DerivedLiquidityNeverCostsMoreThanItsAmount(
        int24 lowerTick,
        uint24 widthSteps,
        uint256 priceSeed,
        uint256 m0,
        uint256 e0,
        uint256 m1,
        uint256 e1
    ) public pure {
        int24 minTick = TickMath.minUsableTick(50);
        int24 maxTick = TickMath.maxUsableTick(50);
        int24 lower = int24(bound(int256(lowerTick), int256(minTick), int256(maxTick) - 50));
        lower = (lower / 50) * 50;
        if (lower < minTick) lower = minTick;
        int24 upper = lower + int24(uint24(bound(widthSteps, 1, uint24((maxTick - lower) / 50)))) * 50;
        uint160 sA = TickMath.getSqrtRatioAtTick(lower);
        uint160 sB = TickMath.getSqrtRatioAtTick(upper);
        uint160 price = uint160(bound(priceSeed, uint256(sA) + 1, uint256(sB) - 1));
        uint256 a0 = bound(m0, 1, 1000) * 10 ** bound(e0, 0, 33);
        uint256 a1 = bound(m1, 1, 1000) * 10 ** bound(e1, 0, 33);
        // Only representable liquidity (what `SafeCast.toUint128` accepts), checked without overflowing: the
        // library's `a0 * intermediate / (sB - price)` fits 128 bits iff `a0 * intermediate < 2^128 * (sB - price)`.
        uint256 intermediate = Math.mulDiv(price, sB, 1 << 96);
        vm.assume(_fits128(a0, intermediate, sB - price));
        vm.assume(_fits128(a1, 1 << 96, price - sA));

        uint128 l0 = LiquidityAmounts.getLiquidityForAmount0(price, sB, a0);
        uint128 l1 = LiquidityAmounts.getLiquidityForAmount1(sA, price, a1);
        if (l0 != 0) assertLe(SqrtPriceMath.getAmount0Delta(price, sB, l0, true), a0, "currency0 costs more");
        if (l1 != 0) assertLe(SqrtPriceMath.getAmount1Delta(sA, price, l1, true), a1, "currency1 costs more");
        // The two-sided derivation is the minimum of both, and the charges are monotone in the liquidity.
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(price, sA, sB, a0, a1);
        if (l != 0) {
            assertLe(SqrtPriceMath.getAmount0Delta(price, sB, l, true), a0, "two-sided currency0 costs more");
            assertLe(SqrtPriceMath.getAmount1Delta(sA, price, l, true), a1, "two-sided currency1 costs more");
        }
    }

    /// @dev The order manager's own activation path on a 50-tick token0-side order: a position single-sided in
    ///      token0 is charged `getAmount0Delta(lower, upper, L, roundUp)` for `L = getLiquidityForAmount0(lower,
    ///      upper, input)`; it never exceeds the input, so `_activate`'s `used > totalInput` cannot fire by rounding.
    /// forge-config: default.fuzz.runs = 50000
    /// forge-config: lite.fuzz.runs = 50000
    function testFuzz_R1_Token0OrderActivationNeverOvershootsItsInput(int24 lowerTick, uint256 amount) public pure {
        int24 minTick = TickMath.minUsableTick(50);
        int24 maxTick = TickMath.maxUsableTick(50);
        int24 lower = int24(bound(int256(lowerTick), int256(minTick) + 50, int256(maxTick) - 100));
        lower = (lower / 50) * 50;
        uint160 sA = TickMath.getSqrtRatioAtTick(lower);
        uint160 sB = TickMath.getSqrtRatioAtTick(lower + 50);
        amount = bound(amount, 1, type(uint128).max);
        uint256 intermediate = Math.mulDiv(sA, sB, 1 << 96);
        vm.assume(_fits128(amount, intermediate, sB - sA));
        uint128 l = LiquidityAmounts.getLiquidityForAmount0(sA, sB, amount);
        vm.assume(l != 0);
        assertLe(SqrtPriceMath.getAmount0Delta(sA, sB, l, true), amount, "order would fail activation");
    }

    /// @dev Whether `a * b / d` fits 128 bits, without computing a 512-bit quotient: `a * b < d << 128`, compared
    ///      on the (high, low) words of both sides.
    function _fits128(uint256 a, uint256 b, uint256 d) private pure returns (bool) {
        uint256 lo;
        uint256 hi;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
        uint256 dHi = d >> 128;
        uint256 dLo = d << 128;
        return hi < dHi || (hi == dHi && lo < dLo);
    }

    // ------------------------------------------------------------------------------------------------------- K-1

    /// @dev A launch with the burn sink on its sell fee. A sell books quote for the sink. Carol pumps the pool with
    ///      a large buy, the keeper runs the buyback with the smallest minimum output the contract accepts (1), and
    ///      Carol sells back. The sink's quote bought a small fraction of the meme the same quote would have bought at
    ///      the price before the pump; the difference is Carol's.
    function test_K1_KeeperBuybackWithMinimalFloorIsSandwichable() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(BURN_APP_ID, 0, 10_000, "");
        PikaToken token = _createWithFees(address(usdt), true, 0, 500, apps);
        _fill(token, address(usdt));
        // Alice sells on the pool: the sell fee is quote and its project part lands in the burn sink.
        _swap(token, ALICE, true, 20_000_000 ether);
        uint256 booked = burnApp.pending(address(token), address(usdt));
        assertGt(booked, burnApp.MIN_DISPATCH_DIVISOR(), "sink holds quote fees");

        // What the booked quote buys at today's price.
        (uint256 fair,) = burnApp.previewSwap(address(token), false, booked);

        // Carol pumps the pool with 60,000 USDT, far more than its 11,760 USDT reserve.
        deal(address(usdt), CAROL, 60_000 ether);
        (, uint256 carolMeme) = _swap(token, CAROL, false, 60_000 ether);

        // The keeper's dispatch goes through at the pumped price: the only floor is "not zero".
        vm.prank(KEEPER);
        (uint256 spent, uint256 bought,) = burnApp.buyback(address(token), 1, block.timestamp);
        assertEq(spent, booked);

        // Carol sells everything back.
        (, uint256 carolQuote) = _swap(token, CAROL, true, carolMeme);

        emit log_named_uint("meme the sink would have bought before the pump", fair);
        emit log_named_uint("meme the sink actually bought", bought);
        emit log_named_uint("Carol's USDT in", 60_000 ether);
        emit log_named_uint("Carol's USDT out", carolQuote);
        assertLt(bought * 10, fair, "the sink got less than a tenth of the fair amount");
    }

    /// @dev The same floor on the limit-order side is not an issue: an order's price range is its own protection.
    ///      Kept here only to document that the comparison was made.
    function test_K1_OrdersCarryTheirOwnPriceProtection() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        PikaOrderManager orders = _orders(token);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        tick = _onSpacing(tick);
        vm.startPrank(ALICE);
        token.approve(address(orders), 1_000_000 ether);
        uint256 id = orders.placeOrder(true, tick + 100, tick + 150, 1_000_000 ether);
        vm.stopPrank();
        assertEq(uint256(_order(orders, id).status), uint256(PikaOrderManager.Status.Active));
    }
}
