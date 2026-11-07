// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { CLPoolParametersHelper } from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaOrderManager } from "../../src/pika-market/infinity/PikaOrderManager.sol";
import { PikaTradeLens } from "../../src/pika-launch/PikaTradeLens.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice End-to-end behaviour of a launch on a local Infinity deployment: graduation, both routers, fees, the
///         orders and the lens.
contract PikaInfinityFlowTest is PikaInfinityFixture {
    using CLPoolParametersHelper for bytes32;
    using stdStorage for StdStorage;

    function testUsdtGraduationLocksLiquidityAndTradesBothWays() public {
        _roundTrip(address(usdt), true);
    }

    function testUsdtGraduationWithReversedTokenOrder() public {
        _roundTrip(address(usdt), false);
    }

    function testNativeGraduationWrapsAndTradesNative() public {
        PikaToken token = _create(address(0), true);
        _fill(token, address(0));
        // The pool opened with 98% of the raise.
        assertApproxEqAbs(wbnb.balanceOf(address(vault)), 17.64 ether, 1e9);
        uint256 aliceMeme = token.balanceOf(ALICE);
        uint256 nativeBefore = ALICE.balance;
        vm.startPrank(ALICE);
        token.approve(address(router), aliceMeme);
        PikaRouter.SwapParams memory p = _swapParams(token, true, aliceMeme / 100, ALICE);
        p.nativeQuote = true;
        (uint256 spent, uint256 out) = router.swap(p);
        assertGt(out, 0);
        assertEq(ALICE.balance - nativeBefore, out);
        assertEq(token.balanceOf(ALICE), aliceMeme - spent);
        p = _swapParams(token, false, 1 ether, ALICE);
        p.nativeQuote = true;
        (spent, out) = router.swap{ value: 1 ether }(p);
        vm.stopPrank();
        assertEq(spent, 1 ether);
        assertGt(out, 0);
        assertEq(address(router).balance, 0);
        assertEq(wbnb.balanceOf(address(router)), 0);
    }

    function _roundTrip(address quote, bool baseIs0) internal {
        // A project fee of 1% on buys and 3% on sells, all to the creator's wallet (no apps).
        PikaToken token = _createWithFees(quote, baseIs0, 100, 300, new AppBinding[](0));
        assertEq(token.memeIsCurrency0(), baseIs0);
        _assertGraduated(token, quote);
        uint256 out = _assertRouterSell(token, quote);
        _assertRouterBuy(token, quote, out / 2);
    }

    /// @dev The buy that sells the curve out graduates it: the pool's tokens and 98% of the raise are locked at the
    ///      curve's last price and no trading fee is paid.
    function _assertGraduated(PikaToken token, address quote) internal {
        // The launch pool opens at graduation.
        assertEq(_poolPrice(token), 0);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        uint256 creatorBefore = _walletTotal(token, address(token), CREATOR);
        uint256 creatorQuoteBefore = IERC20(quote).balanceOf(CREATOR);
        uint256 treasuryOwedBefore = locker.pendingTreasuryQuote(quote);
        _fill(token, quote);
        uint128 liquidity = _poolLiquidity(token);
        assertGt(liquidity, 0);
        PikaLaunchFactory.Launch memory l = _info(address(token));
        assertEq(uint256(l.phase), uint256(PikaLaunchFactory.Phase.External));
        assertTrue(token.tradingStarted());
        assertEq(token.tradingStartedAt(), block.timestamp);
        assertEq(token.lpManager(), address(lpManager));
        assertGt(_poolPrice(token), 0);
        assertEq(_poolLiquidity(token), liquidity);
        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        assertEq(_walletTotal(token, address(token), CREATOR), creatorBefore);
        assertEq(locker.positions(address(token)), liquidity);
        // The pool opened with 98% of the raise; 1% is credited to the creator's wallet (claimed from the token), 1%
        // is owed to the treasury.
        assertApproxEqAbs(IERC20(quote).balanceOf(address(vault)), 11_760 ether, 1e9);
        assertEq(IERC20(quote).balanceOf(CREATOR), creatorQuoteBefore);
        assertApproxEqAbs(token.creatorFees(quote), 120 ether, 1e9);
        assertApproxEqAbs(locker.pendingTreasuryQuote(quote) - treasuryOwedBefore, 120 ether, 1e9);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(IERC20(quote).balanceOf(address(factory)), 0);
    }

    /// @dev Balances before a trade: the fee receivers in both assets, the trader's meme and the vault's reserves.
    struct Snapshot {
        uint256 treasury;
        uint256 creator;
        uint256 alice;
        uint256 vaultMeme;
        uint256 quoteVault;
        uint256 quoteTreasury;
        uint256 quoteCreator;
    }

    function _snapshot(PikaToken token, address quote) internal view returns (Snapshot memory b) {
        b.treasury = token.balanceOf(TREASURY);
        b.creator = _walletTotal(token, address(token), CREATOR);
        b.alice = token.balanceOf(ALICE);
        b.vaultMeme = _vaultBalance(token);
        b.quoteVault = IERC20(quote).balanceOf(address(vault));
        b.quoteTreasury = IERC20(quote).balanceOf(TREASURY);
        b.quoteCreator = _walletTotal(token, quote, CREATOR);
    }

    /// @dev Sell through our router: the whole amountIn goes to the pool; the fee comes out of the quote it gives.
    function _assertRouterSell(PikaToken token, address quote) internal returns (uint256 out) {
        uint256 sellIn = 1_000_000 ether;
        Snapshot memory b = _snapshot(token, quote);
        uint256 spent;
        (spent, out) = _swap(token, ALICE, true, sellIn);
        assertEq(spent, sellIn);
        assertGt(out, 0);
        uint256 quoteGross = b.quoteVault - IERC20(quote).balanceOf(address(vault));
        uint256 fee = quoteGross * 330 / 10_000;
        assertEq(fee, _tradeFee(token, quoteGross, false));
        assertEq(out, quoteGross - fee);
        assertEq(b.alice - token.balanceOf(ALICE), sellIn);
        assertEq(IERC20(quote).balanceOf(TREASURY) - b.quoteTreasury, _treasuryPart(token, fee, false));
        assertEq(_walletTotal(token, quote, CREATOR) - b.quoteCreator, _walletPart(token, fee, false));
        assertEq(token.balanceOf(TREASURY), b.treasury, "a sell pays no meme");
        assertEq(_walletTotal(token, address(token), CREATOR), b.creator);
        assertEq(_vaultBalance(token) - b.vaultMeme, sellIn); // the pool received the whole amount
    }

    /// @dev Buy through our router: the project fee comes out of the pool's meme outflow, the platform fee out of
    ///      the quote input.
    function _assertRouterBuy(PikaToken token, address quote, uint256 quoteIn) internal {
        Snapshot memory b = _snapshot(token, quote);
        (uint256 spent, uint256 out) = _swap(token, ALICE, false, quoteIn);
        assertEq(spent, quoteIn);
        uint256 gross = b.vaultMeme - _vaultBalance(token);
        uint256 fee = gross / 10_000 * 100 + gross % 10_000 * 100 / 10_000;
        assertEq(out, gross - fee);
        assertEq(IERC20(quote).balanceOf(address(vault)) - b.quoteVault, quoteIn - _platformFee(quoteIn));
        assertEq(IERC20(quote).balanceOf(TREASURY) - b.quoteTreasury, _platformFee(quoteIn), "platform fee in quote");
        assertEq(token.balanceOf(ALICE) - b.alice, out);
        assertEq(token.balanceOf(TREASURY) - b.treasury, _treasuryPart(token, fee, true));
        assertEq(_walletTotal(token, address(token), CREATOR) - b.creator, _walletPart(token, fee, true));
        assertEq(router.trader(), address(0));
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(IERC20(quote).balanceOf(address(router)), 0);
    }

    function testUniversalRouterShapedLockerCanSellEverythingAndBuy() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        // CAROL holds a modest bag, then sells every last wei of it.
        vm.prank(ALICE);
        token.transfer(CAROL, 2_000_000 ether);
        uint256 all = token.balanceOf(CAROL);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        uint256 creatorBefore = _walletTotal(token, address(token), CREATOR);
        uint256 usdtBefore = usdt.balanceOf(CAROL);
        uint256 usdtVaultBefore = usdt.balanceOf(address(vault));
        uint256 usdtTreasuryBefore = usdt.balanceOf(TREASURY);
        uint256 vaultMemeBefore = _vaultBalance(token);
        PoolKey memory key = token.poolKey();
        // Exact approval of the whole balance: nothing is charged on top of the amount sold.
        vm.startPrank(CAROL);
        token.approve(address(ur), all);
        ur.swap(key, true, -int256(all), CAROL);
        vm.stopPrank();
        token.pushFees();
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(_vaultBalance(token) - vaultMemeBefore, all);
        uint256 quoteGross = usdtVaultBefore - usdt.balanceOf(address(vault));
        uint256 sellFee = _tradeFee(token, quoteGross, false);
        assertEq(usdt.balanceOf(CAROL) - usdtBefore, quoteGross - sellFee);
        // Without a project fee the whole fee is the platform's, in quote.
        assertEq(usdt.balanceOf(TREASURY) - usdtTreasuryBefore, sellFee);
        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        assertEq(_walletTotal(token, address(token), CREATOR), creatorBefore);
        assertEq(token.balanceOf(address(ur)), 0);
        assertEq(usdt.balanceOf(address(ur)), 0);
        _assertUrBuyCarvesOutTheFee(token);
    }

    /// @dev Buying keeps the net output as a delta until the locker takes it; the fees are carved out inside the
    ///      swap: without a project fee the whole meme output is the buyer's and the platform fee is quote.
    function _assertUrBuyCarvesOutTheFee(PikaToken token) internal {
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        uint256 usdtTreasuryBefore = usdt.balanceOf(TREASURY);
        uint256 vaultBefore = _vaultBalance(token);
        BalanceDelta delta = _urSwap(token, ur, CAROL, false, 100 ether);
        uint256 gross = vaultBefore - _vaultBalance(token);
        uint256 fee = _tradeFee(token, gross, true);
        assertEq(fee, 0, "no project fee: nothing comes out of the meme");
        assertEq(uint256(uint128(delta.amount0())), gross);
        assertEq(uint256(uint128(-delta.amount1())), 100 ether, "the locker pays the whole input");
        assertEq(token.balanceOf(CAROL), gross);
        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        assertEq(usdt.balanceOf(TREASURY) - usdtTreasuryBefore, _platformFee(100 ether), "platform fee in quote");
        // Exact-output buys work for any locker.
        PoolKey memory key = token.poolKey();
        vm.prank(CAROL);
        ur.swap(key, false, int256(1 ether), CAROL);
        assertGt(token.balanceOf(CAROL), gross - fee);
    }

    function testPoolIsSealedBeforeGraduation() public {
        PikaToken token = _create(address(usdt), true);
        PoolKey memory key = token.poolKey();
        _buy(token, address(usdt), ALICE, 100 ether, ALICE);
        // Nobody can swap, add liquidity or donate before trading opens.
        vm.startPrank(ALICE);
        usdt.approve(address(ur), type(uint256).max);
        token.approve(address(ur), type(uint256).max);
        vm.expectRevert();
        ur.swap(key, false, -int256(1 ether), ALICE);
        vm.stopPrank();
        pending = key;
        vm.expectRevert();
        relay.run(abi.encode(uint8(1)));
        vm.expectRevert();
        relay.run(abi.encode(uint8(2)));
        // The same key cannot be initialized twice.
        uint160 price = _poolPrice(token);
        vm.expectRevert();
        manager.initialize(key, price);
    }

    PoolKey private pending;

    /// @dev Called by the LockRelay with this contract as the pool manager caller.
    function onLock(bytes calldata data) external returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == 1) {
            manager.modifyLiquidity(
                pending,
                ICLPoolManager.ModifyLiquidityParams(TickMath.MIN_TICK, TickMath.MAX_TICK, 1e18, bytes32(0)),
                ""
            );
        } else if (action == 2) {
            manager.donate(pending, 1 ether, 0, "");
        }
        return "";
    }

    function _settleAll(PoolKey memory key) private {
        _settleOne(key.currency0);
        _settleOne(key.currency1);
    }

    function _settleOne(Currency currency) private {
        int256 delta = vault.currencyDelta(address(this), currency);
        if (delta < 0) {
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(vault), uint256(-delta));
            vault.settle();
        } else if (delta > 0) {
            vault.take(currency, address(this), uint256(delta));
        }
    }

    uint256 private _graduationVaultMeme;

    function testLensQuotesMatchRouterExecution() public {
        PikaToken token = _create(address(usdt), false);
        _fill(token, address(usdt));
        uint256 sellIn = 3_000_000 ether;
        PikaTradeLens.Quote memory q = lens.quote(address(token), true, sellIn, 0);
        assertEq(q.phase, lens.PHASE_EXTERNAL());
        assertEq(q.inputBudget, sellIn);
        uint256 usdtBefore = usdt.balanceOf(ALICE);
        (uint256 spent, uint256 out) = _swap(token, ALICE, true, sellIn);
        assertEq(spent, q.spent);
        assertEq(out, q.output);
        assertEq(usdt.balanceOf(ALICE) - usdtBefore, q.output);
        uint256 buyIn = out / 3;
        q = lens.quote(address(token), false, buyIn, 50);
        uint256 memeBefore = token.balanceOf(ALICE);
        (spent, out) = _swap(token, ALICE, false, buyIn);
        assertEq(spent, q.spent);
        assertEq(out, q.output);
        assertEq(token.balanceOf(ALICE) - memeBefore, q.output);
        assertEq(q.minimumOutput, q.output * 9950 / 10_000);
        // A sell of everything fills in full: there is no band to stop it.
        q = lens.quote(address(token), true, token.balanceOf(ALICE), 0);
        assertFalse(q.partialFill);
        (spent, out) = _swap(token, ALICE, true, token.balanceOf(ALICE));
        assertEq(spent, q.spent);
        assertEq(out, q.output);
    }

    function testOrdersOpenFillAndClaimWithDeferredFees() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        PikaOrderManager orders = _orders(token);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        // Sell order (meme is currency0 => zeroForOne) just above the price.
        int24 lowerTick = tick + 100;
        int24 upperTick = tick + 200;
        uint256 input = 2_000_000 ether;
        vm.startPrank(ALICE);
        token.approve(address(orders), input);
        uint256 id = orders.placeOrder(true, lowerTick, upperTick, input);
        vm.stopPrank();
        PikaOrderManager.Order memory b = _order(orders, id);
        assertEq(uint256(b.status), uint256(PikaOrderManager.Status.Active));
        assertGt(b.liquidity, 0);
        assertLe(b.inputUsed, input);
        assertEq(manager.getLiquidity(token.poolId(), address(orders), lowerTick, upperTick, bytes32(id)), b.liquidity);
        // Push the price through the range with buys from the other router.
        _urSwap(token, ur, CAROL, false, 300 ether);
        (, int24 tickAfter,,) = manager.getSlot0(token.poolId());
        assertGt(tickAfter, upperTick);
        _assertClaimPaysTheDeferredFee(token, orders, id, input);
    }

    /// @dev The deferred order fee is charged in quote on the quote the order bought; the unused meme comes back whole.
    function _assertClaimPaysTheDeferredFee(PikaToken token, PikaOrderManager orders, uint256 id, uint256 input)
        internal
    {
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        uint256 usdtTreasuryBefore = usdt.balanceOf(TREASURY);
        uint256 usdtBefore = usdt.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 amount0, uint256 amount1) = orders.claim(id, ALICE);
        token.pushFees();
        assertEq(usdt.balanceOf(ALICE) - usdtBefore, amount1);
        assertGt(amount1, 0);
        PikaOrderManager.Order memory b = _order(orders, id);
        assertEq(uint256(b.status), uint256(PikaOrderManager.Status.Settled));
        assertTrue(b.claimed);
        uint256 fee = _tradeFee(token, b.feeBasis, false);
        assertGt(fee, 0);
        assertEq(amount1, b.feeBasis - fee);
        assertEq(usdt.balanceOf(TREASURY) - usdtTreasuryBefore, fee);
        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        assertEq(amount0, input - b.inputUsed);
        assertEq(token.balanceOf(address(orders)), 0);
        assertEq(usdt.balanceOf(address(orders)), 0);
    }

    /// @dev A locker that sells and buys back inside one lock nets most of its meme delta; both legs still pay their
    ///      fees inside the swaps.
    function testRoundTripInsideOneLockPaysTheFees() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        PoolKey memory key = token.poolKey();
        uint256 amount = 1_000_000 ether;
        vm.prank(ALICE);
        token.transfer(address(this), 2 * amount);
        token.approve(address(ur), type(uint256).max);
        usdt.approve(address(ur), type(uint256).max);
        uint256 usdtTreasuryBefore = usdt.balanceOf(TREASURY);
        ur.roundTrip(key, true, amount);
        token.pushFees();
        // The sell fee is quote, taken inside the swap and booked at once, although no meme settled as ERC20.
        assertGt(usdt.balanceOf(TREASURY), usdtTreasuryBefore);
        assertEq(token.balanceOf(address(token)), 0, "the token never holds fees between transactions");
    }

    function testFundedOrderCanBeCancelled() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        PikaOrderManager orders = _orders(token);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        uint256 input = 1_000_000 ether;
        vm.startPrank(ALICE);
        token.approve(address(orders), input);
        // Below the price: a sell stays funded until the price crosses it.
        uint256 id = orders.placeOrder(true, tick - 200, tick - 100, input);
        assertEq(uint256(_order(orders, id).status), uint256(PikaOrderManager.Status.Funding));
        uint256 before = token.balanceOf(ALICE);
        orders.cancelFunding(id);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE) - before, input);
    }
}
