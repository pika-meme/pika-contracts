// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaOrderManager } from "../../src/pika-market/infinity/PikaOrderManager.sol";
import { PikaAppRegistry } from "../../src/pika-apps/PikaAppRegistry.sol";
import { PikaAppBase } from "../../src/pika-apps/PikaAppBase.sol";
import { AppBinding, FeeSlot, IPikaApp } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice V1.4.1 project fees: the per-direction fee on top of the 0.30% platform fee, its split between app slots and
///         the creator's wallet, the registry's launch-time checks and the app notification with its fallback.
contract PikaProjectFeesTest is PikaInfinityFixture {
    using SafeERC20 for IERC20;

    function _apps2() internal pure returns (AppBinding[] memory apps) {
        apps = new AppBinding[](2);
        // The burn address is a direct receiver: it can only take buy shares, which are meme.
        apps[0] = AppBinding(BURN_ID, 3333, 0, "");
        apps[1] = AppBinding(APP_A_ID, 3333, 2500, abi.encode(uint256(1000)));
    }

    function _launch(uint16 buyBps, uint16 sellBps, AppBinding[] memory apps) internal returns (PikaToken token) {
        token = _createWithFees(address(usdt), true, buyBps, sellBps, apps);
    }

    function _expectLaunchRevert(uint16 buyBps, uint16 sellBps, AppBinding[] memory apps, bytes memory reason)
        internal
    {
        LaunchParams memory p = _params(address(usdt), true);
        p.buyFeeBps = buyBps;
        p.sellFeeBps = sellBps;
        p.apps = apps;
        _createReverts(CREATOR, p, reason);
    }

    function _share(uint256 value, uint256 bps) internal pure returns (uint256) {
        return value / 10_000 * bps + value % 10_000 * bps / 10_000;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Fee terms and launch checks
    // ---------------------------------------------------------------------------------------------------------

    function testFeeCapIsThirtyPercentPerDirection() public {
        PikaToken token = _launch(2970, 2970, new AppBinding[](0));
        assertEq(token.outputFeeBps(true), 2970);
        assertEq(token.outputFeeBps(false), 3000);
        assertEq(token.PLATFORM_FEE_BPS(), 30);
        bytes memory invalid = abi.encodeWithSelector(PikaToken.InvalidConfiguration.selector);
        _expectLaunchRevert(2971, 0, new AppBinding[](0), invalid);
        _expectLaunchRevert(0, 2971, new AppBinding[](0), invalid);
        // A zero project fee is allowed: the launch charges the platform fee only.
        token = _launch(0, 0, new AppBinding[](0));
        assertEq(token.outputFeeBps(true), 0);
        assertEq(token.feeSlots().length, 0);
    }

    function testRegistryRefusesInvalidAppChoices() public {
        AppBinding[] memory apps = new AppBinding[](4);
        apps[0] = AppBinding(BURN_ID, 100, 100, "");
        apps[1] = AppBinding(APP_A_ID, 100, 100, abi.encode(uint256(1)));
        apps[2] = AppBinding(APP_B_ID, 100, 100, abi.encode(uint256(1)));
        apps[3] = AppBinding(APP_C_ID, 100, 100, abi.encode(uint256(1)));
        _expectLaunchRevert(100, 100, apps, abi.encodeWithSelector(PikaAppRegistry.TooManyApps.selector));

        apps = new AppBinding[](1);
        apps[0] = AppBinding(9, 100, 100, "");
        _expectLaunchRevert(100, 100, apps, abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, 9));

        apps = new AppBinding[](2);
        apps[0] = AppBinding(BURN_ID, 100, 0, "");
        apps[1] = AppBinding(BURN_ID, 100, 0, "");
        _expectLaunchRevert(
            100, 100, apps, abi.encodeWithSelector(PikaAppRegistry.DuplicateTemplate.selector, BURN_ID)
        );

        apps[1] = AppBinding(APP_A_ID, 100, 10_001, abi.encode(uint256(1)));
        apps[0] = AppBinding(BURN_ID, 100, 0, "");
        _expectLaunchRevert(100, 100, apps, abi.encodeWithSelector(PikaAppRegistry.InvalidShares.selector));

        // A sell fee is quote: a direct receiver (the burn address) cannot take a share of it.
        apps = new AppBinding[](1);
        apps[0] = AppBinding(BURN_ID, 100, 100, "");
        _expectLaunchRevert(
            100, 100, apps, abi.encodeWithSelector(PikaAppRegistry.DirectReceiverSellShare.selector, BURN_ID)
        );

        // An app needs a direction where both the fee and its share are positive.
        apps = new AppBinding[](1);
        apps[0] = AppBinding(BURN_ID, 5000, 0, "");
        _expectLaunchRevert(0, 100, apps, abi.encodeWithSelector(PikaAppRegistry.NoFeeSource.selector, BURN_ID));
        // Direct receivers take no parameters; contract templates validate theirs.
        apps[0] = AppBinding(BURN_ID, 5000, 0, abi.encode(uint256(1)));
        _expectLaunchRevert(100, 0, apps, abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, BURN_ID));
        apps[0] = AppBinding(APP_A_ID, 5000, 0, abi.encode(uint256(0)));
        _expectLaunchRevert(100, 0, apps, abi.encodeWithSelector(PikaAppBase.InvalidParams.selector));
        apps[0] = AppBinding(APP_C_ID, 5000, 0, abi.encode(uint256(1), uint256(1)));
        _expectLaunchRevert(100, 0, apps, abi.encodeWithSelector(PikaAppBase.InvalidParams.selector));
        apps[0] = AppBinding(APP_B_ID, 5000, 0, abi.encode(uint256(1e9 + 1)));
        _expectLaunchRevert(100, 0, apps, abi.encodeWithSelector(PikaAppBase.InvalidParams.selector));

        // The fee wallet cannot be one of the bound apps.
        LaunchParams memory p = _params(address(usdt), true);
        p.buyFeeBps = 100;
        p.creatorFeeRecipient = BURN;
        p.apps = new AppBinding[](1);
        p.apps[0] = AppBinding(BURN_ID, 5000, 0, "");
        _createReverts(CREATOR, p, abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, BURN_ID));

        // Only allowed factories bind launches; templates register only through the registry.
        vm.expectRevert(PikaAppRegistry.UnauthorizedFactory.selector);
        registry.bindLaunch(address(1), CREATOR, 0, 0, new AppBinding[](0));
        vm.expectRevert(PikaAppBase.Unauthorized.selector);
        appA.register(address(1), abi.encode(uint256(1)));
    }

    /// @dev A new registry allows one chosen app per launch (product rule); the default sinks never count.
    function testNewRegistryAllowsOneChosenAppBesidesTheSinks() public {
        PikaAppRegistry fresh =
            PikaAppRegistry(_deploy("PikaAppRegistry", abi.encode(address(this), address(guard), address(this))));
        assertEq(fresh.maxApps(), 1);
        registry.setMaxApps(1);
        _expectLaunchRevert(100, 100, _apps2(), abi.encodeWithSelector(PikaAppRegistry.TooManyApps.selector));
        AppBinding[] memory apps = new AppBinding[](4);
        apps[0] = AppBinding(BURN_APP_ID, 1000, 1000, "");
        apps[1] = AppBinding(DIVIDEND_ID, 1000, 1000, abi.encode(uint256(0)));
        apps[2] = AppBinding(LIQUIDITY_ID, 1000, 1000, "");
        apps[3] = AppBinding(APP_A_ID, 1000, 1000, abi.encode(uint256(1)));
        PikaToken token = _launch(100, 100, apps);
        assertEq(token.feeSlots().length, 4);
        assertEq(lens.launchOptions(address(factory), address(usdt)).maxApps, 1);
    }

    function testTemplateAndMaxAppChangesOnlyAffectNewLaunches() public {
        PikaToken first = _launch(100, 100, _apps2());
        registry.setTemplateEnabled(APP_A_ID, false);
        _expectLaunchRevert(
            100, 100, _apps2(), abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, APP_A_ID)
        );
        // The launch that bound the template keeps it.
        assertEq(first.feeSlots()[1].target, address(appA));
        registry.setTemplateEnabled(APP_A_ID, true);

        vm.expectRevert(PikaAppRegistry.InvalidConfiguration.selector);
        registry.setMaxApps(7);
        registry.setMaxApps(6);
        registry.setMaxApps(4);
        AppBinding[] memory apps = new AppBinding[](4);
        apps[0] = AppBinding(BURN_ID, 100, 0, "");
        apps[1] = AppBinding(APP_A_ID, 100, 100, abi.encode(uint256(1)));
        apps[2] = AppBinding(APP_B_ID, 100, 100, abi.encode(uint256(1)));
        apps[3] = AppBinding(APP_C_ID, 100, 100, abi.encode(uint256(1)));
        PikaToken four = _launch(100, 100, apps);
        assertEq(four.feeSlots().length, 4);
        registry.setMaxApps(0);
        _expectLaunchRevert(100, 100, _apps2(), abi.encodeWithSelector(PikaAppRegistry.TooManyApps.selector));
        // Zero apps stays possible: the whole project fee goes to the wallet.
        _launch(100, 100, new AppBinding[](0));

        // Templates are listed by the timelocked owner only, and must answer to their key and version.
        vm.prank(ALICE);
        vm.expectRevert();
        registry.addTemplate(address(appA), PikaAppRegistry.Kind.Contract, "appA", 2, false);
        vm.expectRevert(PikaAppRegistry.InvalidConfiguration.selector);
        registry.addTemplate(address(appA), PikaAppRegistry.Kind.Contract, "appB", 2, false);
        vm.expectRevert(PikaAppRegistry.InvalidConfiguration.selector);
        registry.addTemplate(address(appA), PikaAppRegistry.Kind.Contract, "appA", 3, false);
        vm.expectRevert(PikaAppRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();
    }

    function testLaunchPublishesItsAppConfigAndHash() public {
        AppBinding[] memory apps = _apps2();
        LaunchParams memory p = _params(address(usdt), true);
        p.buyFeeBps = 150;
        p.sellFeeBps = 450;
        p.apps = apps;
        _mine(p);
        address predicted = _predict(CREATOR, p);
        vm.recordLogs();
        PikaToken token = _launchAs(CREATOR, p);
        assertEq(address(token), predicted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(registry) || logs[i].topics[0] != PikaAppRegistry.AppsBound.selector) {
                continue;
            }
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
            (
                bytes32 hash,
                address recipient,
                uint16 buyBps,
                uint16 sellBps,
                PikaAppRegistry.BoundApp[] memory bound
            ) = abi.decode(logs[i].data, (bytes32, address, uint16, uint16, PikaAppRegistry.BoundApp[]));
            assertEq(recipient, CREATOR);
            assertEq(buyBps, 150);
            assertEq(sellBps, 450);
            assertEq(bound.length, 2);
            assertEq(bound[1].target, address(appA));
            assertEq(bound[1].version, 2);
            assertEq(bound[1].params, apps[1].params);
            assertEq(hash, keccak256(abi.encode(block.chainid, address(token), CREATOR, buyBps, sellBps, bound)));
            found = true;
        }
        assertTrue(found);
        FeeSlot[] memory slots = token.feeSlots();
        assertEq(slots.length, 2);
        assertEq(slots[0].target, BURN);
        assertFalse(slots[0].notify);
        assertEq(slots[1].target, address(appA));
        assertTrue(slots[1].notify);
        assertEq(slots[1].sellShareBps, 2500);
        assertTrue(appA.registered(address(token)));
        assertEq(appA.param(address(token)), 1000 ether);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Split and notification
    // ---------------------------------------------------------------------------------------------------------

    struct Balances {
        /// @dev Takes the platform fee and the platform's cut of the project fee.
        uint256 treasury;
        uint256 burn;
        uint256 app;
        uint256 wallet;
    }

    /// @dev Balances of every fee receiver in `asset`: the token for buy fees, the quote for sell fees.
    function _balances(PikaToken token, address asset) internal view returns (Balances memory b) {
        IERC20 a = IERC20(asset);
        // The wallet's share accrues in the token until the wallet claims it.
        b = Balances(
            a.balanceOf(TREASURY),
            a.balanceOf(BURN),
            a.balanceOf(address(appA)),
            a.balanceOf(CREATOR) + token.creatorFees(asset)
        );
    }

    function _feeAsset(PikaToken token, bool buy) internal view returns (address) {
        return buy ? address(token) : address(usdt);
    }

    function _booked(address token, address asset) internal view returns (uint256) {
        return appA.booked(token, asset);
    }

    /// @dev Every party gets its share of the project fee, rounded down; the wallet takes the rest. A buy pays in
    ///      meme, a sell in quote, and the burn slot takes buy shares only.
    function _assertSplit(PikaToken token, Balances memory before, uint256 fee, bool buy) internal view {
        (uint256 platform, uint256 cut, uint256 project) = _feeParts(token, fee, buy);
        uint256 burned = buy ? _share(project, 3333) : 0;
        uint256 toApp = _share(project, buy ? 3333 : 2500);
        Balances memory a = _balances(token, _feeAsset(token, buy));
        assertEq(a.treasury - before.treasury, platform + cut, "platform fee plus the project fee cut");
        assertEq(a.burn - before.burn, burned, "burn slot");
        assertEq(a.app - before.app, toApp, "app slot");
        assertEq(a.wallet - before.wallet, project - burned - toApp, "wallet takes the rest");
    }

    function testTradesSplitTheProjectFeeAndNotifyApps() public {
        PikaToken token = _launch(150, 450, _apps2());
        _fill(token, address(usdt));
        // Graduation itself pays no fee to anybody.
        assertEq(token.balanceOf(BURN) + token.balanceOf(address(appA)) + token.balanceOf(CREATOR), 0);

        Balances memory before = _balances(token, address(token));
        uint256 vaultBefore = _vaultBalance(token);
        vm.recordLogs();
        (, uint256 out) = _swap(token, CAROL, false, 300 ether);
        uint256 gross = vaultBefore - _vaultBalance(token);
        uint256 fee = _tradeFee(token, gross, true);
        assertEq(out, gross - fee);
        _assertSplit(token, before, fee, true);
        _assertTradeFeesEvent(token, CAROL, true, gross, fee, _platformFee(300 ether));
        // The app booked what it received, at trade time.
        assertEq(_booked(address(token), address(token)), token.balanceOf(address(appA)));

        // A sell pays in quote: the same split, booked by the app under the quote asset.
        before = _balances(token, address(usdt));
        Balances memory memeBefore = _balances(token, address(token));
        vaultBefore = _vaultBalance(token);
        uint256 quoteVaultBefore = usdt.balanceOf(address(vault));
        vm.recordLogs();
        (uint256 spent, uint256 received) = _swap(token, ALICE, true, 1_000_000 ether);
        assertEq(_vaultBalance(token) - vaultBefore, spent);
        uint256 quoteGross = quoteVaultBefore - usdt.balanceOf(address(vault));
        fee = _tradeFee(token, quoteGross, false);
        assertEq(received, quoteGross - fee);
        _assertSplit(token, before, fee, false);
        _assertTradeFeesEvent(token, ALICE, false, quoteGross, fee, 0);
        assertEq(_booked(address(token), address(usdt)), usdt.balanceOf(address(appA)));
        Balances memory memeAfter = _balances(token, address(token));
        assertEq(memeAfter.treasury, memeBefore.treasury, "a sell moves no meme");
        assertEq(memeAfter.app, memeBefore.app);
        assertEq(memeAfter.wallet, memeBefore.wallet);
        // The token holds only the wallet's unclaimed share of the sell fees.
        assertEq(usdt.balanceOf(address(token)), token.creatorFees(address(usdt)));
    }

    /// @dev `fee` is the fee taken out of the gross output (a buy's project fee, a sell's whole fee);
    ///      `quotePlatform` a buy's platform fee out of its quote input (zero for a sell, whose platform fee is part of
    ///      `fee`).
    function _assertTradeFeesEvent(
        PikaToken token,
        address account,
        bool buy,
        uint256 value,
        uint256 fee,
        uint256 quotePlatform
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token) || logs[i].topics[0] != PikaToken.TradeFees.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), account);
            (bool isBuy, uint256 v, uint256 platform, uint256 cut, uint256 project) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
            assertEq(isBuy, buy);
            assertEq(v, value);
            (uint256 p, uint256 c,) = _feeParts(token, fee, buy);
            assertEq(cut + project, fee - p);
            assertEq(platform, buy ? quotePlatform : p);
            assertEq(cut, c);
            return;
        }
        fail();
    }

    function testOrderClaimsPayTheirDirectionsProjectFeeToApps() public {
        PikaToken token = _launch(150, 450, _apps2());
        _fill(token, address(usdt));
        PikaOrderManager orders = _orders(token);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        uint256 input = 2_000_000 ether;
        vm.startPrank(ALICE);
        token.approve(address(orders), input);
        uint256 id = orders.placeOrder(true, tick + 100, tick + 200, input);
        vm.stopPrank();
        _urSwap(token, ur, CAROL, false, 300 ether);
        // A filled sell order pays the sell fee in quote on the quote it bought, when claimed.
        Balances memory before = _balances(token, address(usdt));
        Balances memory memeBefore = _balances(token, address(token));
        vm.prank(ALICE);
        orders.claim(id, ALICE);
        token.pushFees();
        uint256 fee = _tradeFee(token, _order(orders, id).feeBasis, false);
        assertGt(fee, 0);
        _assertSplit(token, before, fee, false);
        assertEq(_booked(address(token), address(usdt)), usdt.balanceOf(address(appA)));
        assertEq(_balances(token, address(token)).app, memeBefore.app);
        assertEq(usdt.balanceOf(address(orders)), 0);
    }

    /// @dev Audit 2026-10-30: the transfer to an app and the app's booking stand or fall together. An app that
    ///      reverts reverts the push as a whole, and no app ever holds fees its books do not show. Trades only book
    ///      (2026-11-03), so a failing app never reaches them.
    function testANotificationFailureRevertsThePushAndNeverTheTrade() public {
        PikaToken token = _launch(150, 450, _apps2());
        _fill(token, address(usdt));
        vm.mockCallRevert(address(appA), abi.encodeWithSelector(IPikaApp.onProjectFee.selector), "down");
        uint256 appBefore = token.balanceOf(address(appA));
        uint256 unpaidBefore = _unpaidProject(token, address(token));
        // Long after the last push, a trade still only books.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        // The router swap alone (the fixture's `_swap` would push afterwards).
        vm.startPrank(CAROL);
        IERC20(address(usdt)).forceApprove(address(router), type(uint256).max);
        router.swap(_swapParams(token, false, 300 ether, CAROL));
        vm.stopPrank();
        assertEq(token.balanceOf(address(appA)), appBefore, "nothing reached the app");
        assertGt(_unpaidProject(token, address(token)), unpaidBefore, "the trade still booked its fee");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token)) {
                assertTrue(logs[i].topics[0] != PikaToken.AutoPushFailed.selector, "the trade attempted no push");
            }
        }
        // A manual push fails the same way, as a whole.
        vm.expectRevert(bytes("down"));
        token.pushFees();
        vm.clearMockedCalls();
        // Once the app answers again, one push pays and books everything.
        token.pushFees();
        assertGt(token.balanceOf(address(appA)), appBefore);
        assertEq(_booked(address(token), address(token)), token.balanceOf(address(appA)));
        assertEq(_booked(address(token), address(usdt)), usdt.balanceOf(address(appA)));
        // Only the launch token itself can notify.
        vm.expectRevert(PikaAppBase.UnknownLaunch.selector);
        appA.onProjectFee(address(token), true, 1);
    }

    /// @dev Trades only book their fees, so a tight gas limit cannot starve an app notification through a trade; a
    ///      push without the gas for every notification runs out and reverts as a whole instead of skipping one.
    function testAPushEitherNotifiesEveryAppOrReverts() public {
        PikaToken token = _launch(150, 450, _apps2());
        _fill(token, address(usdt));
        deal(address(usdt), address(this), 1_000_000 ether);
        usdt.approve(address(router), type(uint256).max);
        router.swap(_swapParams(token, false, 10 ether, address(this)));
        bool sawRevert;
        bool succeeded;
        for (uint256 gas = 60_000; gas < 1_200_000 && !succeeded; gas += 10_000) {
            try token.pushFees{ gas: gas }() {
                succeeded = true;
            } catch {
                sawRevert = true;
                assertEq(_booked(address(token), address(token)), token.balanceOf(address(appA)), "partial push");
            }
        }
        assertTrue(sawRevert, "no gas-starved revert");
        assertTrue(succeeded, "never succeeded");
        assertGt(token.balanceOf(address(appA)), 0);
        assertEq(_booked(address(token), address(token)), token.balanceOf(address(appA)));
    }

    function _unpaidProject(PikaToken token, address asset) internal view returns (uint256) {
        (,, uint256 project) = token.unpaid(asset);
        return project;
    }

    function _contains(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}
