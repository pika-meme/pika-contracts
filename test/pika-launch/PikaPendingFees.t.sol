// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaAppBase } from "../../src/pika-apps/PikaAppBase.sol";
import { PikaAppRegistry } from "../../src/pika-apps/PikaAppRegistry.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @dev An app notification must observe the consumed snapshot as empty, before it runs any app logic.
contract PendingFeeObserver is PikaAppBase {
    mapping(address => uint256) public received;

    constructor(address registry_) PikaAppBase(registry_) { }

    function templateKey() external pure returns (bytes32) {
        return "pendingObserver";
    }

    function version() external pure returns (uint16) {
        return 1;
    }

    function _register(address, bytes calldata) internal override { }

    function _book(address token, address asset, uint256 amount) internal override {
        (uint256 platform, uint256 cut, uint256 project) = PikaToken(token).unpaid(asset);
        require(platform == 0 && cut == 0 && project == 0, "snapshot must be cleared before notification");
        received[asset] += amount;
    }
}

contract PikaPendingFeesTest is PikaInfinityFixture {
    PikaToken private token;

    function setUp() public override {
        super.setUp();
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(APP_A_ID, 5000, 5000, abi.encode(uint256(1000)));
        token = _createWithFees(address(usdt), true, 150, 450, apps);
        _fill(token, address(usdt));
    }

    function _tradeBoth(PikaToken t) private {
        vm.startPrank(CAROL);
        usdt.approve(address(router), type(uint256).max);
        router.swap(_swapParams(t, false, 300 ether, CAROL));
        vm.stopPrank();
        vm.startPrank(ALICE);
        t.approve(address(router), type(uint256).max);
        router.swap(_swapParams(t, true, 1_000_000 ether, ALICE));
        vm.stopPrank();
    }

    function _pending(PikaToken t, address asset) private view returns (uint256) {
        (uint256 platform, uint256 cut, uint256 project) = t.unpaid(asset);
        return platform + cut + project;
    }

    function testSuccessfulPushClearsBothBooksAndPreservesCreatorClaims() public {
        _tradeBoth(token);
        (uint256 platform, uint256 cut, uint256 project) = token.unpaid(address(usdt));
        assertGt(platform, 0);
        assertGt(cut, 0);
        assertGt(project, 0);
        assertGt(_pending(token, address(token)), 0);
        token.pushFees();
        assertEq(_pending(token, address(token)), 0);
        assertEq(_pending(token, address(usdt)), 0);
        uint256 creatorMeme = token.creatorFees(address(token));
        uint256 creatorQuote = token.creatorFees(address(usdt));
        assertGt(creatorMeme, 0);
        assertGt(creatorQuote, 0);
        assertEq(token.balanceOf(address(token)), creatorMeme);
        assertEq(usdt.balanceOf(address(token)), creatorQuote);
        vm.prank(CREATOR);
        (uint256 meme, uint256 quote) = token.claimCreatorFees(DAVE);
        assertEq(meme, creatorMeme);
        assertEq(quote, creatorQuote);
        assertEq(token.balanceOf(DAVE), meme);
        assertEq(usdt.balanceOf(DAVE), quote);
    }

    function testRepeatedPushDoesNotPayTwiceAndNextBatchStartsEmpty() public {
        _tradeBoth(token);
        token.pushFees();
        uint256 creatorMeme = token.creatorFees(address(token));
        uint256 creatorQuote = token.creatorFees(address(usdt));
        uint256 treasuryMeme = token.balanceOf(TREASURY);
        uint256 treasuryQuote = usdt.balanceOf(TREASURY);
        vm.recordLogs();
        token.pushFees();
        assertEq(vm.getRecordedLogs().length, 0, "an empty push emits no payment");
        assertEq(token.creatorFees(address(token)), creatorMeme);
        assertEq(token.creatorFees(address(usdt)), creatorQuote);
        assertEq(token.balanceOf(TREASURY), treasuryMeme);
        assertEq(usdt.balanceOf(TREASURY), treasuryQuote);
        _tradeBoth(token);
        assertEq(token.balanceOf(address(token)), creatorMeme + _pending(token, address(token)));
        assertEq(usdt.balanceOf(address(token)), creatorQuote + _pending(token, address(usdt)));
        assertGt(_pending(token, address(token)), 0);
        assertGt(_pending(token, address(usdt)), 0);
        token.pushFees();
        assertEq(_pending(token, address(token)), 0);
        assertEq(_pending(token, address(usdt)), 0);
        assertGt(token.creatorFees(address(token)), creatorMeme);
        assertGt(token.creatorFees(address(usdt)), creatorQuote);
    }

    function testQuotePayoutFailureRestoresBothClearedBooksAndCanRetry() public {
        _tradeBoth(token);
        uint256 meme = _pending(token, address(token));
        uint256 quote = _pending(token, address(usdt));
        uint256 treasuryMeme = token.balanceOf(TREASURY);
        uint256 treasuryQuote = usdt.balanceOf(TREASURY);
        uint256 lastPush = token.lastPushAt();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.mockCallRevert(address(usdt), abi.encodeWithSelector(IERC20.transfer.selector, TREASURY), "unavailable");
        vm.expectRevert();
        token.pushFees();
        vm.clearMockedCalls();
        assertEq(_pending(token, address(token)), meme);
        assertEq(_pending(token, address(usdt)), quote);
        assertEq(token.lastPushAt(), lastPush);
        assertEq(token.balanceOf(address(token)), meme);
        // Besides the booked fees the token holds the creator's graduation reward (1% of the raise).
        uint256 reward = _vaultOf(token).totalRaised() / 100;
        assertEq(usdt.balanceOf(address(token)), quote + reward);
        assertEq(token.balanceOf(TREASURY), treasuryMeme);
        assertEq(usdt.balanceOf(TREASURY), treasuryQuote);
        assertEq(token.balanceOf(address(appA)), 0);
        assertEq(usdt.balanceOf(address(appA)), 0);
        assertEq(token.creatorFees(address(token)), 0);
        assertEq(token.creatorFees(address(usdt)), reward);
        token.pushFees();
        assertEq(_pending(token, address(token)), 0);
        assertEq(_pending(token, address(usdt)), 0);
    }

    function testAppNotificationsObserveClearedSnapshots() public {
        PendingFeeObserver observer = PendingFeeObserver(
            _proxy(vm.deployCode("PikaPendingFees.t.sol:PendingFeeObserver", abi.encode(address(registry))))
        );
        uint32 id =
            registry.addTemplate(address(observer), PikaAppRegistry.Kind.Contract, "pendingObserver", 1, false);
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(id, 10_000, 10_000, "");
        PikaToken observed = _createWithFees(address(usdt), true, 150, 450, apps);
        _fill(observed, address(usdt));
        _tradeBoth(observed);
        (,, uint256 meme) = observed.unpaid(address(observed));
        (,, uint256 quote) = observed.unpaid(address(usdt));
        assertGt(meme, 0);
        assertGt(quote, 0);
        observed.pushFees();
        assertEq(observer.received(address(observed)), meme);
        assertEq(observer.received(address(usdt)), quote);
        assertEq(_pending(observed, address(observed)), 0);
        assertEq(_pending(observed, address(usdt)), 0);
    }
}

/// @notice setUp and the test execute in separate transactions: cleared fee slots and all six apps start cold.
contract PikaColdPendingFeesTest is PikaInfinityFixture {
    PikaToken private token;

    function setUp() public override {
        super.setUp();
        AppBinding[] memory apps = new AppBinding[](6);
        apps[0] = AppBinding(BURN_APP_ID, 1000, 1000, "");
        apps[1] = AppBinding(DIVIDEND_ID, 2000, 2000, abi.encode(uint256(0)));
        apps[2] = AppBinding(LIQUIDITY_ID, 1000, 1000, "");
        apps[3] = AppBinding(APP_A_ID, 2000, 2000, abi.encode(uint256(1000)));
        apps[4] = AppBinding(APP_B_ID, 2000, 2000, abi.encode(uint256(1000)));
        apps[5] = AppBinding(APP_C_ID, 1000, 1000, abi.encode(uint256(1000)));
        token = _createWithFees(address(usdt), true, 300, 500, apps);
        _fill(token, address(usdt));
        // A prior push has cleared the books. This test's first trade must book fresh slots and push all apps.
        _swap(token, CAROL, false, 300 ether);
        _swap(token, ALICE, true, 1_000_000 ether);
        // Leave quote fees pending too, so the next transaction notifies all six apps in both assets.
        vm.startPrank(ALICE);
        token.approve(address(router), type(uint256).max);
        router.swap(_swapParams(token, true, 500_000 ether, ALICE));
        vm.stopPrank();
        vm.prank(CAROL);
        usdt.approve(address(router), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Trades never push (2026-11-03): a cold buy only books, and the keeper's own cold push then reaches all six
    ///      apps in both assets within the budget the trades' automatic push used to give them (250k + 6 x 300k).
    function testColdKeeperPushAfterClearingReachesAllSixApps() public {
        uint256 start = gasleft();
        vm.prank(CAROL);
        router.swap{ gas: 1_500_000 }(_swapParams(token, false, 200 ether, CAROL));
        emit log_named_uint("cold buy gas (books only)", start - gasleft());
        (uint256 platform, uint256 cut, uint256 project) = token.unpaid(address(usdt));
        assertGt(platform + cut + project, 0, "quote booked");
        (platform, cut, project) = token.unpaid(address(token));
        assertGt(platform + cut + project, 0, "meme booked");

        start = gasleft();
        token.pushFees{ gas: 2_050_000 }();
        emit log_named_uint("cold six-app push gas", start - gasleft());
        (platform, cut, project) = token.unpaid(address(usdt));
        assertEq(platform + cut + project, 0, "quote pushed");
        (platform, cut, project) = token.unpaid(address(token));
        assertEq(platform + cut + project, 0, "meme pushed");
        assertEq(token.lastPushAt(), vm.getBlockTimestamp());
        assertGt(burnApp.pending(address(token), address(token)), 0);
        assertGt(liquidityApp.pending(address(token), address(token)), 0);
        assertGt(appA.booked(address(token), address(token)), 0);
        assertGt(appB.booked(address(token), address(token)), 0);
        assertGt(appC.booked(address(token), address(token)), 0);
        assertGt(token.balanceOf(address(dividendApp)), 0);
    }
}
