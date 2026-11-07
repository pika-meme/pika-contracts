// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaOrderManager } from "../../src/pika-market/infinity/PikaOrderManager.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice 2026-10-29 (second) audit of the v10 gas batch: fee books against balances on every fee path, clone
///         arguments committed by the token address, single initialization, and the push's effect on dividends.
contract PikaAuditV10Test is PikaInfinityFixture {
    using SafeERC20 for IERC20;

    address constant EVE = address(0xe5e);

    function _apps() internal pure returns (AppBinding[] memory apps) {
        apps = new AppBinding[](2);
        apps[0] = AppBinding(BURN_ID, 3333, 0, "");
        apps[1] = AppBinding(APP_A_ID, 3333, 2500, abi.encode(uint256(1000)));
    }

    /// @dev Booked and not yet pushed, all three parts.
    function _unpaid(PikaToken token, address asset) internal view returns (uint256) {
        (uint256 platform, uint256 cut, uint256 project) = token.unpaid(asset);
        return uint256(platform) + cut + project;
    }

    /// @dev The token holds exactly what it has booked and not pushed plus the creator's claimable share, in both assets.
    function _assertBooksMatchBalances(PikaToken token) internal view {
        assertEq(
            token.balanceOf(address(token)), _unpaid(token, address(token)) + token.creatorFees(address(token)), "meme"
        );
        assertEq(
            usdt.balanceOf(address(token)), _unpaid(token, address(usdt)) + token.creatorFees(address(usdt)), "quote"
        );
    }

    function _directSwap(PikaToken token, address who, bool sell, uint256 input) internal {
        vm.startPrank(who);
        IERC20(sell ? address(token) : address(usdt)).forceApprove(address(router), type(uint256).max);
        router.swap(_swapParams(token, sell, input, who));
        vm.stopPrank();
    }

    function testFeeBooksMatchTheTokenBalancesOnEveryFeePath() public {
        PikaToken token = _createWithFees(address(usdt), true, 150, 450, _apps());
        _fill(token, address(usdt));
        _assertBooksMatchBalances(token);

        // Pool swaps through our router, nothing pushed yet: both assets are booked and held here.
        _directSwap(token, CAROL, false, 300 ether);
        _directSwap(token, ALICE, true, 1_000_000 ether);
        assertGt(_unpaid(token, address(token)), 0);
        assertGt(_unpaid(token, address(usdt)), 0);
        // Nothing pushed yet: the creator's only claim is its graduation reward (1% of the raise, in quote).
        assertEq(token.creatorFees(address(token)), 0, "nothing pushed yet");
        assertEq(token.creatorFees(address(usdt)), _vaultOf(token).totalRaised() / 100, "nothing pushed yet");
        _assertBooksMatchBalances(token);

        // A filled sell order claimed: the order manager pays the quote fee into the token by allowance.
        PikaOrderManager orders = _orders(token);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        tick = _onSpacing(tick);
        vm.startPrank(ALICE);
        token.approve(address(orders), 2_000_000 ether);
        uint256 id = orders.placeOrder(true, tick + 100, tick + 200, 2_000_000 ether);
        vm.stopPrank();
        _urSwap(token, ur, CAROL, false, 300 ether); // pushes
        uint256 quoteUnpaidBefore = _unpaid(token, address(usdt));
        vm.prank(ALICE);
        orders.claim(id, ALICE);
        assertGt(_unpaid(token, address(usdt)), quoteUnpaidBefore);
        _assertBooksMatchBalances(token);

        // A third-party full-range LP position (a Pancake LP NFT, anyone's) withdrawn books nothing: liquidity is
        // fee-free, only swaps pay.
        (uint256 positionId, uint128 liquidity) = _lpMintMeme(token, ALICE, FULL_LOWER, FULL_UPPER, 10_000 ether, 1 ether);
        _swap(token, CAROL, false, 300 ether); // pushes
        quoteUnpaidBefore = _unpaid(token, address(usdt));
        uint256 memeUnpaidBefore = _unpaid(token, address(token));
        _lpDecrease(positionManager, positionId, ALICE, liquidity, ALICE);
        assertEq(_unpaid(token, address(usdt)), quoteUnpaidBefore);
        assertEq(_unpaid(token, address(token)), memeUnpaidBefore);
        _assertBooksMatchBalances(token);

        // One push pays everything (a trade first, so there is something to pay); a second one moves nothing; the
        // creator's claim empties the token.
        _directSwap(token, CAROL, false, 100 ether);
        uint256 treasuryMeme = token.balanceOf(TREASURY);
        uint256 treasuryQuote = usdt.balanceOf(TREASURY);
        token.pushFees();
        assertEq(_unpaid(token, address(token)) + _unpaid(token, address(usdt)), 0);
        _assertBooksMatchBalances(token);
        assertGt(usdt.balanceOf(TREASURY), treasuryQuote);
        treasuryMeme = token.balanceOf(TREASURY);
        treasuryQuote = usdt.balanceOf(TREASURY);
        uint256 appMeme = token.balanceOf(address(appA));
        vm.prank(DAVE);
        token.pushFees();
        assertEq(token.balanceOf(TREASURY), treasuryMeme, "a second push pays nothing");
        assertEq(usdt.balanceOf(TREASURY), treasuryQuote);
        assertEq(token.balanceOf(address(appA)), appMeme);
        vm.prank(CREATOR);
        token.claimCreatorFees(CREATOR);
        assertEq(token.balanceOf(address(token)), 0, "nothing stays behind");
        assertEq(usdt.balanceOf(address(token)), 0);
    }



    /// @dev Audit 2026-10-29b L-1: fees reach the dividend sink in batches anyone may trigger, so a buyer must not
    ///      be able to buy, push, claim and sell for fees others earned. Dividends are released per second over
    ///      `RELEASE_WINDOW`: a buyer who pushes right after its buy earns only for the seconds it then holds.
    function testAFreshBuyerEarnsOnlyForTheSecondsItHolds() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(DIVIDEND_ID, 10_000, 10_000, abi.encode(uint256(0)));
        LaunchParams memory p = _params(address(usdt), true);
        p.buyFeeBps = 100;
        p.sellFeeBps = 100;
        p.apps = apps;
        _mine(p);
        PikaToken token = _launchAs(CREATOR, p);
        _fill(token, address(usdt));
        address t = address(token);
        // Fees accumulate unpushed: others trade.
        _directSwap(token, CAROL, false, 200 ether);
        _directSwap(token, ALICE, true, 1_000_000 ether);
        _directSwap(token, CAROL, false, 200 ether);
        assertGt(_unpaid(token, t), 0);
        // EVE buys and pushes in the same breath: nothing is shared in the push's own second.
        uint256 sinkBefore = token.balanceOf(address(dividendApp));
        deal(address(usdt), EVE, 1_000 ether);
        _directSwap(token, EVE, false, 500 ether);
        vm.prank(EVE);
        token.pushFees();
        uint256 income = token.balanceOf(address(dividendApp)) - sinkBefore;
        assertGt(income, 0);
        (uint256 eveDue,) = dividendApp.pending(t, EVE);
        assertEq(eveDue, 0, "nothing is shared at the push");
        assertEq(dividendApp.shares(t, EVE), token.balanceOf(EVE));
        (uint256 left,) = dividendApp.unreleased(t, t);
        assertEq(left, income);
        // A minute later she has earned a minute of the release by her share, not her share of the batch.
        uint256 window = dividendApp.RELEASE_WINDOW();
        vm.warp(vm.getBlockTimestamp() + 60);
        uint256 eveShares = dividendApp.shares(t, EVE);
        uint256 total = dividendApp.totalShares(t);
        (eveDue,) = dividendApp.pending(t, EVE);
        assertApproxEqAbs(eveDue, income * 60 / window * eveShares / total, 1e6);
        assertLt(eveDue, income * eveShares / total / 1000, "a minute is a small part of the window");
        // Selling stops her earning at once; what she earned stays claimable and the rest goes to those who hold.
        _directSwap(token, EVE, true, token.balanceOf(EVE));
        assertEq(dividendApp.shares(t, EVE), 0);
        (uint256 earned,) = dividendApp.pending(t, EVE);
        (uint256 aliceBefore,) = dividendApp.pending(t, ALICE);
        _releaseDividends();
        (eveDue,) = dividendApp.pending(t, EVE);
        assertEq(eveDue, earned, "nothing more after selling");
        (uint256 aliceAfter,) = dividendApp.pending(t, ALICE);
        assertGt(aliceAfter, aliceBefore);
    }
}
