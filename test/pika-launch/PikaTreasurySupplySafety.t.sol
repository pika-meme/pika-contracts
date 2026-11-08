// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";
import { IOpenFourVault } from "../../src/openfour/interfaces/IOpenFourVault.sol";

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

    /// @dev A launch token may also be an approved quote. Its own graduation must preserve the treasury's quote
    ///      from other launches, even across multiple graduations and unsolicited token donations to the hub.
    function testFuzzGraduationPreservesTreasuryDebtInLaunchToken(
        bool tokenIs0,
        bool quoteIs0,
        uint8 otherLaunches,
        uint96 donation
    ) public {
        uint256 count = bound(uint256(otherLaunches), 1, 3);
        uint256 extra = bound(uint256(donation), 0, 1000 ether);
        PikaToken token = _create(address(0), tokenIs0);
        _buyAs(token, ALICE, 5 ether, true);
        factory.configureQuote(address(token), true, 10 ether);
        for (uint256 i; i < count; ++i) {
            PikaToken other = _create(address(token), quoteIs0);
            _fill(other, address(token));
        }
        uint256 owed = factory.pendingTreasuryQuote(address(token));
        assertGt(owed, 100 ether * count);
        assertEq(token.balanceOf(address(factory)), owed);
        vm.prank(ALICE);
        token.transfer(address(factory), extra);
        uint256 burnedBefore = token.balanceOf(BURN);

        _fill(token, address(0));

        assertEq(factory.pendingTreasuryQuote(address(token)), owed, "graduation preserves the debt");
        assertEq(token.balanceOf(address(factory)), owed, "the debt remains fully funded");
        uint256 burned = token.balanceOf(BURN) - burnedBefore;
        assertGe(burned, extra, "unreserved donations still burn");
        assertLt(burned, extra + 1 ether, "only donation and graduation dust burn");
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        assertEq(factory.claimTreasuryQuote(address(token)), owed);
        assertEq(token.balanceOf(TREASURY) - treasuryBefore, owed);
        assertEq(factory.pendingTreasuryQuote(address(token)), 0);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function testTreasuryCanClaimBeforeItsQuoteTokenGraduates() public {
        PikaToken token = _create(address(0), false);
        _buyAs(token, ALICE, 5 ether, true);
        factory.configureQuote(address(token), true, 10 ether);
        PikaToken other = _create(address(token), true);
        _fill(other, address(token));
        uint256 owed = factory.pendingTreasuryQuote(address(token));
        assertGt(owed, 100 ether);
        assertEq(factory.claimTreasuryQuote(address(token)), owed);
        uint256 treasuryBefore = token.balanceOf(TREASURY);

        _fill(token, address(0));

        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        assertEq(factory.pendingTreasuryQuote(address(token)), 0);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    /// @dev Exercise the funding check independently of the migrate module: even its authenticated call cannot
    ///      count existing treasury debt as funds delivered for the opening position.
    function testGraduationCannotUseTreasuryDebtToCoverMissingPoolTokens() public {
        PikaToken token = _create(address(0), true);
        _buyAs(token, ALICE, 5 ether, true);
        factory.configureQuote(address(token), true, 10 ether);
        PikaToken other = _create(address(token), true);
        _fill(other, address(token));
        uint256 owed = factory.pendingTreasuryQuote(address(token));
        uint256 poolTokens = factory.defaultSupply() / 5;
        vm.prank(ALICE);
        token.transfer(address(factory), poolTokens - 1);
        deal(address(wbnb), address(factory), 18 ether);
        assertEq(token.balanceOf(address(factory)), poolTokens - 1 + owed);
        vm.mockCall(token.vault(), abi.encodeCall(IOpenFourVault.isSoldOut, ()), abi.encode(true));
        address migrate = token.migrateModule();

        vm.prank(migrate);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.graduate(address(token), 18 ether, 0);

        assertFalse(token.tradingStarted());
        assertEq(factory.pendingTreasuryQuote(address(token)), owed);
        assertEq(token.balanceOf(address(factory)), poolTokens - 1 + owed);
    }
}
