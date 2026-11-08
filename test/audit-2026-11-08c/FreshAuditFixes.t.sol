// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaGraduationMath } from "../../src/pika-launch/libraries/PikaGraduationMath.sol";
import { IOpenFourVault } from "../../src/openfour/interfaces/IOpenFourVault.sol";
import { AppBinding, IPikaApp } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice Regressions for the fixes of audit 2026-11-08c (docs/audit-2026-11-08c-fresh-audit.md), contracts
///         v12.12.0:
///         D-1  A vault whose quote balance fell below `totalRaised` still graduates, priced on what it holds
///              (before: `executeMigration` reverted and the launch could never leave the curve).
///         F-1  `pushPlatformFees` pays the platform's part while an app's `onProjectFee` reverts; the project part
///              waits for `pushFees`, nothing is paid twice, `lastPushAt` only moves on the full push.
///         O-1  Graduation and the liquidity sink still mint with the exact derived liquidity after the unreachable
///              fallback was removed (covered by the whole suite; the two fuzzes in FreshAudit.t.sol are the proof).
contract FreshAuditFixes20261108cTest is PikaInfinityFixture {
    // ------------------------------------------------------------------------------------------------------- D-1

    function test_D1_GraduationSurvivesAVaultQuoteShortfall() public {
        PikaToken token = _create(address(usdt), true);
        // Most of the curve, not all of it.
        _buyAs(token, ALICE, 9_000 ether, false);
        IOpenFourVault v = _vaultOf(token);
        assertFalse(v.isSoldOut());

        // Core is the only account that can move the vault's quote; it stands in here for any gap between the
        // vault's books and its balance (a Core upgrade, a fee-routing change, a misbehaving quote asset).
        uint256 shortfall = v.totalRaised() / 10;
        vm.prank(address(core));
        v.transferQuote(BOB, shortfall);
        assertLt(usdt.balanceOf(address(v)), v.totalRaised(), "the vault now holds less than its books say");

        // The crossing buy sells the curve out and graduates it in the same transaction. Before the fix the migrate
        // module reverted here (`quoteBalance < raised`), and since nothing could ever restore the balance the launch
        // would have stayed on a closed curve for good.
        uint256 hubQuoteBefore = usdt.balanceOf(address(factory)) - factory.pendingTreasuryQuote(address(usdt));
        _fill(token, address(usdt));
        uint256 raised = v.totalRaised();
        uint256 priced = raised - shortfall;

        // The pool opened at the price the vault's actual quote sets: 98% of it against the pool's tokens.
        uint256 supply = factory.defaultSupply();
        uint256 poolTokens = supply - supply * factory.SALE_BPS() / 10_000;
        uint160 expected = PikaGraduationMath.sqrtPriceX96FromAmounts(poolTokens, priced * 9800 / 10_000);
        assertEq(_poolPrice(token), expected, "pool priced on the quote that was actually there");
        // The creator's graduation share follows the same amount, and the treasury is owed the rest of it.
        assertEq(token.creatorFees(address(usdt)), priced * factory.CREATOR_GRADUATION_BPS() / 10_000);
        assertEq(hubQuoteBefore, 0);
        // The treasury is owed the rest of what the vault held: the 1% outside the pool and the creator's share,
        // plus whatever the position left of its 98% (the liquidity is floored; the hub requires at least 99.99%).
        uint256 poolQuote = priced * 9800 / 10_000;
        uint256 rest = priced - poolQuote - priced * factory.CREATOR_GRADUATION_BPS() / 10_000;
        uint256 owed = factory.pendingTreasuryQuote(address(usdt));
        assertGe(owed, rest, "at least the raise's remainder");
        assertLe(owed, rest + poolQuote / 10_000, "plus at most 0.01% of the pool's quote the position left");
        assertEq(usdt.balanceOf(address(v)), 0, "the vault handed over everything it had");
    }

    // ------------------------------------------------------------------------------------------------------- F-1

    struct Unpaid {
        uint256 platformQ;
        uint256 cutQ;
        uint256 projectQ;
        uint256 cutM;
        uint256 projectM;
    }

    struct Balances {
        uint256 treasuryQuote;
        uint256 treasuryMeme;
        uint256 appQuote;
        uint256 appMeme;
        uint256 creatorQuote;
        uint256 creatorMeme;
    }

    function _unpaid(PikaToken token) private view returns (Unpaid memory u) {
        (u.platformQ, u.cutQ, u.projectQ) = token.unpaid(address(usdt));
        uint256 platformM;
        (platformM, u.cutM, u.projectM) = token.unpaid(address(token));
        assertEq(platformM, 0, "the platform fee is always quote");
    }

    function _balances(PikaToken token, address app) private view returns (Balances memory b) {
        address treasury = token.treasury();
        b.treasuryQuote = usdt.balanceOf(treasury);
        b.treasuryMeme = token.balanceOf(treasury);
        b.appQuote = usdt.balanceOf(app);
        b.appMeme = token.balanceOf(app);
        b.creatorQuote = token.creatorFees(address(usdt));
        b.creatorMeme = token.creatorFees(address(token));
    }

    function _tradeWithoutPushing(PikaToken token) private {
        vm.startPrank(ALICE);
        usdt.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        router.swap(PikaRouter.SwapParams(address(token), false, 1_000 ether, 1, ALICE, block.timestamp, false));
        router.swap(PikaRouter.SwapParams(address(token), true, 5_000_000 ether, 1, ALICE, block.timestamp, false));
        vm.stopPrank();
    }

    function _assertNothingUnpaid(PikaToken token) private view {
        Unpaid memory u = _unpaid(token);
        assertEq(u.platformQ + u.cutQ + u.projectQ + u.cutM + u.projectM, 0, "everything paid");
    }

    function test_F1_PlatformFeesAreNotHostageToAnApp() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(DIVIDEND_ID, 10_000, 10_000, abi.encode(uint256(0)));
        PikaToken token = _createWithFees(address(usdt), true, 300, 300, apps);
        _fill(token, address(usdt));
        _tradeWithoutPushing(token);
        Unpaid memory u1 = _unpaid(token);
        assertGt(u1.platformQ, 0);
        assertGt(u1.cutQ, 0);
        assertGt(u1.projectQ, 0);
        assertGt(u1.cutM, 0);
        assertGt(u1.projectM, 0);
        Balances memory b0 = _balances(token, address(dividendApp));
        uint64 lastPush = token.lastPushAt();

        // The dividend template's booking reverts (an upgrade bug, say): the full push fails as a whole.
        vm.mockCallRevert(address(dividendApp), abi.encodeWithSelector(IPikaApp.onProjectFee.selector), "boom");
        vm.expectRevert(bytes("boom"));
        token.pushFees();

        // The platform's part does not wait for the template.
        token.pushPlatformFees();
        Balances memory b1 = _balances(token, address(dividendApp));
        assertEq(b1.treasuryQuote - b0.treasuryQuote, u1.platformQ + u1.cutQ, "platform fee and cut in quote");
        assertEq(b1.treasuryMeme - b0.treasuryMeme, u1.cutM, "cut in meme");
        assertEq(b1.appQuote, b0.appQuote, "the app got nothing");
        assertEq(token.lastPushAt(), lastPush, "project fees still wait: the keeper's clock does not move");
        Unpaid memory u2 = _unpaid(token);
        assertEq(u2.platformQ + u2.cutQ + u2.cutM, 0, "platform parts cleared");
        assertEq(u2.projectQ, u1.projectQ, "project part untouched");
        assertEq(u2.projectM, u1.projectM, "project part untouched");
        // Again: nothing to pay.
        token.pushPlatformFees();
        assertEq(_balances(token, address(dividendApp)).treasuryQuote, b1.treasuryQuote, "nothing paid twice");
        // New trades keep booking in the meantime.
        _tradeWithoutPushing(token);
        Unpaid memory u3 = _unpaid(token);
        assertGt(u3.platformQ, 0);
        assertGt(u3.projectQ, u1.projectQ);

        // Once the template works again, the full push pays exactly what is left: the new platform part and the
        // whole project part; the dividend sink takes its 100% share.
        vm.clearMockedCalls();
        vm.warp(vm.getBlockTimestamp() + 1);
        token.pushFees();
        Balances memory b2 = _balances(token, address(dividendApp));
        assertEq(b2.appQuote - b1.appQuote, u3.projectQ);
        assertEq(b2.appMeme - b1.appMeme, u3.projectM);
        assertEq(b2.treasuryQuote - b1.treasuryQuote, u3.platformQ + u3.cutQ);
        assertEq(b2.treasuryMeme - b1.treasuryMeme, u3.cutM);
        _assertNothingUnpaid(token);
        assertGt(token.lastPushAt(), lastPush, "the full push moves the clock");
    }

    /// @dev Without a broken app the two entries compose: a platform-only push followed by a full push pays the same
    ///      totals as one full push.
    function test_F1_PlatformPushThenFullPushPaysTheSameAsOneFullPush() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(BURN_APP_ID, 5_000, 5_000, "");
        PikaToken token = _createWithFees(address(usdt), true, 200, 200, apps);
        _fill(token, address(usdt));
        _tradeWithoutPushing(token);
        Unpaid memory u = _unpaid(token);
        Balances memory b0 = _balances(token, address(burnApp));

        token.pushPlatformFees();
        token.pushFees();

        Balances memory b1 = _balances(token, address(burnApp));
        assertEq(b1.treasuryQuote - b0.treasuryQuote, u.platformQ + u.cutQ);
        assertEq(b1.treasuryMeme - b0.treasuryMeme, u.cutM);
        assertEq(b1.appQuote - b0.appQuote, u.projectQ / 2);
        assertEq(b1.appMeme - b0.appMeme, u.projectM / 2);
        assertEq(b1.creatorQuote - b0.creatorQuote, u.projectQ - u.projectQ / 2);
        assertEq(b1.creatorMeme - b0.creatorMeme, u.projectM - u.projectM / 2);
        _assertNothingUnpaid(token);
    }
}
