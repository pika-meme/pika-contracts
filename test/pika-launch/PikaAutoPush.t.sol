// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice Trades only book fees; they never push, however long since the last push (2026-11-03: the automatic
///         push left trades). `pushFees`, open to anyone and sent by the keeper once the booked fees reach its
///         threshold, pays them; a payout that fails reverts only that push and never reaches a trade.
contract PikaAutoPushTest is PikaInfinityFixture {
    using SafeERC20 for IERC20;

    address constant EVE = address(0xe5e);

    /// @dev Burn and dividend sinks share 80% of the project fee; the creator keeps the rest.
    function _launch() internal returns (PikaToken token) {
        AppBinding[] memory apps = new AppBinding[](2);
        apps[0] = AppBinding(BURN_APP_ID, 4000, 4000, "");
        apps[1] = AppBinding(DIVIDEND_ID, 4000, 4000, abi.encode(uint256(0)));
        token = _createWithFees(address(usdt), true, 150, 450, apps);
        _fill(token, address(usdt));
    }

    /// @dev Booked and not yet pushed, all three parts.
    function _unpaid(PikaToken token, address asset) internal view returns (uint256) {
        (uint256 platform, uint256 cut, uint256 project) = token.unpaid(asset);
        return uint256(platform) + cut + project;
    }

    /// @dev A pool swap through our router that pushes nothing itself (unlike the fixture's `_swap`).
    function _directSwap(PikaToken token, address who, bool sell, uint256 input) internal {
        vm.startPrank(who);
        IERC20(sell ? address(token) : address(usdt)).forceApprove(address(router), type(uint256).max);
        router.swap(_swapParams(token, sell, input, who));
        vm.stopPrank();
    }

    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _hasLog(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    /// @dev A push that finds nothing booked pays nothing and leaves `lastPushAt` alone, so the keeper's "last paid"
    ///      age keeps counting (audit 2026-11-07, U-9).
    function testAnEmptyPushLeavesLastPushAtAlone() public {
        PikaToken token = _launch();
        uint64 opened = token.lastPushAt();
        _wait(2 days);
        vm.prank(EVE);
        token.pushFees();
        assertEq(token.lastPushAt(), opened, "nothing paid, nothing recorded");
        // The creator's claim pushes first; with nothing booked that push records nothing either.
        vm.prank(CREATOR);
        token.claimCreatorFees(CREATOR);
        assertEq(token.lastPushAt(), opened);
        _directSwap(token, CAROL, false, 300 ether);
        _wait(1 hours);
        token.pushFees();
        assertEq(token.lastPushAt(), vm.getBlockTimestamp(), "a paying push is recorded");
    }

    function testTradesOnlyBookAndAnyonePushes() public {
        PikaToken token = _launch();
        uint64 opened = token.lastPushAt();
        assertEq(opened, vm.getBlockTimestamp(), "the pool's opening");

        // Hours apart, trades keep booking and never push.
        _directSwap(token, CAROL, false, 300 ether);
        _wait(12 hours);
        vm.recordLogs();
        _directSwap(token, ALICE, true, 1_000_000 ether);
        _wait(3 days);
        _directSwap(token, CAROL, false, 300 ether);
        assertFalse(_hasLog(vm.getRecordedLogs(), address(token), PikaToken.FeesPushed.selector), "no trade pushed");
        assertEq(token.lastPushAt(), opened);
        assertGt(_unpaid(token, address(token)), 0);
        assertGt(_unpaid(token, address(usdt)), 0);
        // Nothing pushed yet: the creator's only claim is its graduation reward (1% of the raise, in quote).
        uint256 reward = _vaultOf(token).totalRaised() / 100;
        assertEq(token.creatorFees(address(token)), 0, "nothing pushed yet");
        assertEq(token.creatorFees(address(usdt)), reward, "nothing pushed yet");
        // Everything booked is still here.
        assertEq(token.balanceOf(address(token)), _unpaid(token, address(token)));
        assertEq(usdt.balanceOf(address(token)), _unpaid(token, address(usdt)) + reward);

        // Anyone pushes: the treasury, the sinks and the creator are paid in both assets.
        uint256 treasuryMeme = token.balanceOf(TREASURY);
        uint256 treasuryQuote = usdt.balanceOf(TREASURY);
        uint256 sinkMeme = token.balanceOf(address(burnApp));
        vm.prank(EVE);
        token.pushFees();
        assertEq(_unpaid(token, address(token)), 0, "meme pushed");
        assertEq(_unpaid(token, address(usdt)), 0, "quote pushed");
        assertEq(token.lastPushAt(), vm.getBlockTimestamp());
        assertGt(token.balanceOf(TREASURY), treasuryMeme, "platform meme fee paid");
        assertGt(usdt.balanceOf(TREASURY), treasuryQuote, "platform quote fee paid");
        assertGt(token.balanceOf(address(burnApp)), sinkMeme, "sink paid");
        assertGt(token.creatorFees(address(token)), 0, "creator's share pushed");
        assertGt(token.creatorFees(address(usdt)), 0, "creator's quote share pushed");
        // The token holds only the creator's share again.
        assertEq(token.balanceOf(address(token)), token.creatorFees(address(token)));
        assertEq(usdt.balanceOf(address(token)), token.creatorFees(address(usdt)));
    }

    /// @dev A push leaves each book part at its zero marker, not zero: the next trades book on warm nonzero slots
    ///      and report exactly their own fees.
    function testAPushLeavesTheBooksReadyForTheNextTrade() public {
        PikaToken token = _launch();
        _directSwap(token, CAROL, false, 300 ether);
        _directSwap(token, ALICE, true, 1_000_000 ether);
        token.pushFees();
        assertEq(_unpaid(token, address(token)), 0);
        assertEq(_unpaid(token, address(usdt)), 0);
        // Nothing left: another push pays nothing.
        vm.recordLogs();
        token.pushFees();
        assertFalse(_hasLog(vm.getRecordedLogs(), address(token), PikaToken.FeesPushed.selector), "empty push");

        // A buy books its platform fee in quote and its project fee in meme, exactly as it reports them.
        vm.recordLogs();
        _directSwap(token, CAROL, false, 300 ether);
        (uint256 platform, uint256 cut, uint256 project) = _tradeFees(vm.getRecordedLogs(), address(token));
        (uint256 p, uint256 c, uint256 r) = token.unpaid(address(token));
        assertEq(p, 0);
        assertEq(c, cut);
        assertEq(r, project);
        (p, c, r) = token.unpaid(address(usdt));
        assertEq(p, platform);
        assertEq(c + r, 0);
        // A sell adds its quote parts on top.
        vm.recordLogs();
        _directSwap(token, ALICE, true, 1_000_000 ether);
        (uint256 platform2, uint256 cut2, uint256 project2) = _tradeFees(vm.getRecordedLogs(), address(token));
        (p, c, r) = token.unpaid(address(usdt));
        assertEq(p, platform + platform2);
        assertEq(c, cut2);
        assertEq(r, project2);
        // The token holds exactly what it owes.
        assertEq(token.balanceOf(address(token)), _unpaid(token, address(token)) + token.creatorFees(address(token)));
        assertEq(usdt.balanceOf(address(token)), _unpaid(token, address(usdt)) + token.creatorFees(address(usdt)));
    }

    function _tradeFees(Vm.Log[] memory logs, address emitter)
        internal
        pure
        returns (uint256 platform, uint256 cut, uint256 project)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == PikaToken.TradeFees.selector) {
                (,, platform, cut, project) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
                return (platform, cut, project);
            }
        }
        revert("no TradeFees");
    }

    function testATradeNeedsNoGasForAPush() public {
        PikaToken token = _launch();
        _directSwap(token, CAROL, false, 300 ether);
        _wait(12 hours);
        uint256 unpaid = _unpaid(token, address(token));

        // A wallet-sized limit, long after the last push: the trade only books.
        vm.startPrank(CAROL);
        IERC20(address(usdt)).forceApprove(address(router), type(uint256).max);
        router.swap{ gas: 1_000_000 }(_swapParams(token, false, 300 ether, CAROL));
        vm.stopPrank();
        assertGt(_unpaid(token, address(token)), unpaid, "booked, not pushed");
    }

    function testAFailingPayoutOnlyFailsThePush() public {
        PikaToken token = _launch();
        _directSwap(token, CAROL, false, 300 ether);
        _directSwap(token, ALICE, true, 1_000_000 ether);
        _wait(1 days);
        uint256 treasuryMeme = token.balanceOf(TREASURY);
        uint256 treasuryQuote = usdt.balanceOf(TREASURY);
        assertGt(_unpaid(token, address(usdt)), 0, "quote fees booked");

        // The quote refuses the treasury: trades are untouched, since they never pay anyone out.
        vm.mockCallRevert(address(usdt), abi.encodeWithSelector(IERC20.transfer.selector, TREASURY), "down");
        vm.recordLogs();
        uint256 memeBefore = token.balanceOf(CAROL);
        _directSwap(token, CAROL, false, 300 ether);
        assertGt(token.balanceOf(CAROL), memeBefore, "the trade stood");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_hasLog(logs, address(token), PikaToken.AutoPushFailed.selector), "no push attempted");
        assertFalse(_hasLog(logs, address(token), PikaToken.FeesPushed.selector));

        // The push itself fails as a whole and keeps everything booked.
        uint256 memeUnpaid = _unpaid(token, address(token));
        uint256 quoteUnpaid = _unpaid(token, address(usdt));
        vm.expectRevert();
        token.pushFees();
        vm.clearMockedCalls();
        assertEq(_unpaid(token, address(token)), memeUnpaid);
        assertEq(_unpaid(token, address(usdt)), quoteUnpaid);
        assertEq(token.balanceOf(TREASURY), treasuryMeme, "the treasury's meme transfer was undone");
        assertEq(usdt.balanceOf(TREASURY), treasuryQuote);

        // Once the quote pays again, the next push goes through.
        vm.prank(EVE);
        token.pushFees();
        assertEq(_unpaid(token, address(token)), 0);
        assertEq(_unpaid(token, address(usdt)), 0);
        assertGt(token.balanceOf(TREASURY), treasuryMeme);
        assertGt(usdt.balanceOf(TREASURY), treasuryQuote);
    }
}
