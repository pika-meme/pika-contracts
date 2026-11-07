// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

contract PikaTreasurySupplySafetyTest is PikaInfinityFixture {
    function launch() private returns (PikaToken t) {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(DIVIDEND_ID, 10_000, 10_000, abi.encode(uint256(0)));
        t = _createWithFees(address(usdt), true, 500, 500, apps);
        _fill(t, address(usdt));
        vm.prank(ALICE);
        t.transfer(BOB, 100_000_000 ether);
        _swap(t, ALICE, true, 1_000_000 ether);
    }

    function testNewTreasuryTransferCannotKeepCachedShares() public {
        PikaToken t = launch();
        factory.proposeTreasury(BOB);
        vm.prank(BOB);
        factory.acceptTreasury();
        vm.prank(BOB);
        t.transfer(CAROL, 1 ether);
        assertEq(dividendApp.shares(address(t), BOB), 0);
        vm.warp(block.timestamp + 1 days);
        (, uint256 pending) = dividendApp.pending(address(t), BOB);
        assertEq(pending, 0);
    }

    function testClaimAlsoRefreshesDynamicEligibility() public {
        PikaToken t = launch();
        factory.proposeTreasury(BOB);
        vm.prank(BOB);
        factory.acceptTreasury();
        vm.prank(BOB);
        dividendApp.claim(address(t), BOB);
        assertEq(dividendApp.shares(address(t), BOB), 0);
    }

    function testPreExclusionPreservesEarnedIncomeAndPreventsPassiveTreasuryAccrual() public {
        PikaToken t = launch();
        vm.warp(block.timestamp + 12 hours);
        (, uint256 earned) = dividendApp.pending(address(t), BOB);
        assertGt(earned, 0);
        uint256 before = usdt.balanceOf(BOB);
        dividendApp.setExcluded(address(t), BOB, true);
        assertEq(usdt.balanceOf(BOB) - before, earned);
        factory.proposeTreasury(BOB);
        vm.prank(BOB);
        factory.acceptTreasury();
        vm.warp(block.timestamp + 2 days);
        (, uint256 afterRotation) = dividendApp.pending(address(t), BOB);
        assertEq(afterRotation, 0);
        assertEq(dividendApp.shares(address(t), BOB), 0);
    }

    function testMinimumSupplyGraduatesAndSmallerSuppliesAreRefused() public {
        uint256 min = factory.MIN_SUPPLY();
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.setDefaultSupply(min - 1);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.setDefaultSupply(2 ether);
        factory.setDefaultSupply(min);
        PikaToken t = _create(address(usdt), true);
        assertFalse(_vaultOf(t).isSoldOut());
        _fill(t, address(usdt));
        assertTrue(t.tradingStarted());
        assertGe(_vaultOf(t).totalRaised(), 12_000 ether * 999_995 / 1_000_000);
    }
}
