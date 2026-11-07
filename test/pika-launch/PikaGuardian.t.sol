// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaFactoryBound } from "../../src/pika-market/PikaFactoryBound.sol";
import { PikaAppRegistry } from "../../src/pika-apps/PikaAppRegistry.sol";
import { PikaAppBase } from "../../src/pika-apps/PikaAppBase.sol";
import { PikaGuard } from "../../src/common/PikaGuard.sol";
import { PikaGuarded } from "../../src/common/PikaGuarded.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";
import { PikaTimelockHandover } from "../../script/PikaTimelockHandover.sol";

/// @notice The guardian (docs/PIKA_CONTRACTS.md §8): one seat (`PikaGuard`) the owner names, read by every guarded
///         contract; it tightens at once and can never loosen. Every switch follows one rule: `setX(false)` /
///         `setX(paused = true)` is the owner's or the guardian's, the other direction the owner's only.
contract PikaGuardianTest is PikaInfinityFixture, PikaTimelockHandover {
    address constant GUARDIAN = address(0x9a2d);
    address constant MULTISIG = address(0x5afe);

    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event AppPaused(address indexed target, bool paused);

    function _one(uint32 id, uint16 buy, uint16 sell) internal pure returns (AppBinding[] memory apps) {
        apps = new AppBinding[](1);
        // The dividend sink takes its minimum holding, the recorder app a stake size; the sinks take nothing.
        bytes memory params = id == DIVIDEND_ID ? abi.encode(uint256(0)) : id == APP_A_ID ? abi.encode(uint256(1000)) : bytes("");
        apps[0] = AppBinding(id, buy, sell, params);
    }

    function _launch(AppBinding[] memory apps) internal returns (PikaToken token) {
        token = _createWithFees(address(usdt), true, 500, 500, apps);
    }

    function _expectLaunchRevert(AppBinding[] memory apps, bytes memory reason) internal {
        LaunchParams memory p = _params(address(usdt), true);
        p.buyFeeBps = 500;
        p.sellFeeBps = 500;
        p.apps = apps;
        _createReverts(CREATOR, p, reason);
    }

    function _name() internal {
        guard.setGuardian(GUARDIAN);
    }

    function _notOwner(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
    }

    // ---------------------------------------------------------------------------------------------------------
    // One seat
    // ---------------------------------------------------------------------------------------------------------

    function testEveryGuardedContractReadsTheSameSeat() public view {
        assertEq(address(factory.guard()), address(guard));
        assertEq(address(registry.guard()), address(guard));
        assertEq(factory.guardian(), address(0));
        assertEq(registry.guardian(), address(0));
    }

    function testOnlyTheOwnerNamesOrReplacesTheGuardian() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(_notOwner(GUARDIAN));
        guard.setGuardian(GUARDIAN);

        vm.expectEmit(address(guard));
        emit GuardianUpdated(address(0), GUARDIAN);
        guard.setGuardian(GUARDIAN);
        assertEq(guard.guardian(), GUARDIAN);
        assertEq(factory.guardian(), GUARDIAN);
        assertEq(registry.guardian(), GUARDIAN);

        // The guardian cannot hand its role to someone else, only drop it; the owner may clear it.
        vm.prank(GUARDIAN);
        vm.expectRevert(_notOwner(GUARDIAN));
        guard.setGuardian(ALICE);
        guard.setGuardian(address(0));
        assertEq(factory.guardian(), address(0));
        // The seat's ownership can never be renounced.
        vm.expectRevert(PikaGuard.RenounceDisabled.selector);
        guard.renounceOwnership();
    }

    function testTheGuardianRenouncesItselfAndNobodyElseCan() public {
        _name();
        vm.prank(ALICE);
        vm.expectRevert(PikaGuard.NotGuardian.selector);
        guard.renounceGuardian();

        vm.prank(GUARDIAN);
        vm.expectEmit(address(guard));
        emit GuardianUpdated(GUARDIAN, address(0));
        guard.renounceGuardian();
        assertEq(factory.guardian(), address(0));
        vm.prank(GUARDIAN);
        vm.expectRevert(PikaGuarded.NotGuardian.selector);
        factory.setLaunchEnabled(false);
        vm.prank(GUARDIAN);
        vm.expectRevert(PikaGuarded.NotGuardian.selector);
        registry.setKeeper(KEEPER, false);
        // The owner names a new one, who acts everywhere at once.
        guard.setGuardian(BOB);
        vm.prank(BOB);
        factory.setLaunchEnabled(false);
        assertFalse(factory.launchEnabled());
    }

    /// @dev Without a guardian nobody, the zero address included, may use the guardian entries.
    function testWithoutAGuardianTheTighteningEntriesAreTheOwnersAlone() public {
        address[3] memory callers = [address(0), ALICE, GUARDIAN];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(PikaGuarded.NotGuardian.selector);
            factory.setLaunchEnabled(false);
            vm.prank(callers[i]);
            vm.expectRevert(PikaGuarded.NotGuardian.selector);
            registry.setKeeper(KEEPER, false);
            vm.prank(callers[i]);
            vm.expectRevert(PikaGuarded.NotGuardian.selector);
            registry.setTemplateEnabled(APP_A_ID, false);
            vm.prank(callers[i]);
            vm.expectRevert(PikaGuarded.NotGuardian.selector);
            registry.setAppPaused(DIVIDEND_ID, true);
        }
        // The owner still has every entry, tightening included.
        factory.setLaunchEnabled(false);
        registry.setAppPaused(DIVIDEND_ID, true);
        assertFalse(factory.launchEnabled());
        assertTrue(registry.appPaused(address(dividendApp)));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Factory: new launches
    // ---------------------------------------------------------------------------------------------------------

    function testTheGuardianStopsNewLaunchesAndOnlyTheOwnerResumesThem() public {
        _name();
        PikaToken before = _create(address(usdt), true);
        vm.prank(GUARDIAN);
        factory.setLaunchEnabled(false);
        assertFalse(factory.launchEnabled());
        LaunchParams memory p = _params(address(usdt), true);
        _createReverts(CREATOR, p, abi.encodePacked(PikaLaunchFactory.Unauthorized.selector));
        // Existing launches trade on.
        _fill(before, address(usdt));
        _swap(before, CAROL, false, 10 ether);

        vm.prank(GUARDIAN);
        vm.expectRevert(_notOwner(GUARDIAN));
        factory.setLaunchEnabled(true);
        factory.setLaunchEnabled(true);
        _create(address(usdt), true);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Registry: keepers and templates
    // ---------------------------------------------------------------------------------------------------------

    function testTheGuardianRevokesKeepersAndOnlyTheOwnerGrants() public {
        _name();
        assertTrue(registry.keepers(KEEPER));
        vm.prank(GUARDIAN);
        registry.setKeeper(KEEPER, false);
        assertFalse(registry.keepers(KEEPER));
        vm.prank(GUARDIAN);
        vm.expectRevert(_notOwner(GUARDIAN));
        registry.setKeeper(KEEPER, true);
        vm.prank(ALICE);
        vm.expectRevert(PikaGuarded.NotGuardian.selector);
        registry.setKeeper(KEEPER, false);
        registry.setKeeper(KEEPER, true);
        assertTrue(registry.keepers(KEEPER));
    }

    function testTheGuardianDisablesTemplatesForNewLaunchesAndOnlyTheOwnerEnables() public {
        _name();
        PikaToken bound = _launch(_one(APP_A_ID, 5000, 5000));
        vm.prank(GUARDIAN);
        registry.setTemplateEnabled(APP_A_ID, false);
        assertFalse(registry.templates(APP_A_ID).enabled);
        _expectLaunchRevert(
            _one(APP_A_ID, 5000, 5000), abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, APP_A_ID)
        );
        // The launch that bound it keeps it.
        assertEq(bound.feeSlots()[0].target, address(appA));
        vm.prank(GUARDIAN);
        vm.expectRevert(_notOwner(GUARDIAN));
        registry.setTemplateEnabled(APP_A_ID, true);
        registry.setTemplateEnabled(APP_A_ID, true);
        _launch(_one(APP_A_ID, 5000, 5000));

        // Disabling a default sink refuses every launch that binds it: the deployed web binds all three.
        vm.prank(GUARDIAN);
        registry.setTemplateEnabled(BURN_APP_ID, false);
        _expectLaunchRevert(
            _one(BURN_APP_ID, 5000, 5000),
            abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, BURN_APP_ID)
        );
        registry.setTemplateEnabled(BURN_APP_ID, true);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Registry: template pause
    // ---------------------------------------------------------------------------------------------------------

    function testAPausedDividendTemplateStillPaysClaimsWhileFeesTradesAndTransfersGoOn() public {
        _name();
        PikaToken token = _launch(_one(DIVIDEND_ID, 10_000, 10_000));
        address t = address(token);
        _fill(token, address(usdt));
        vm.prank(ALICE);
        token.transfer(DAVE, 100_000_000 ether);
        _swap(token, CAROL, false, 300 ether);
        _releaseDividends();
        (uint256 dueBefore,) = dividendApp.pending(t, DAVE);
        assertGt(dueBefore, 0);

        vm.prank(GUARDIAN);
        vm.expectEmit(address(registry));
        emit AppPaused(address(dividendApp), true);
        registry.setAppPaused(DIVIDEND_ID, true);
        assertTrue(registry.appPaused(address(dividendApp)));
        // Claims are never gated by the pause (user decision 2026-11-03): what a holder has earned is its own.
        vm.prank(DAVE);
        (uint256 paidWhilePaused,) = dividendApp.claim(t, DAVE);
        assertEq(paidWhilePaused, dueBefore, "claims go on while paused");
        address[] memory holders = new address[](1);
        holders[0] = DAVE;
        dividendApp.claimFor(t, holders);

        // Trades keep paying the sink (its notification is never gated), transfers keep updating shares, and
        // `refresh` stays open.
        uint256 held = token.balanceOf(address(dividendApp));
        _swap(token, CAROL, false, 300 ether);
        assertGt(token.balanceOf(address(dividendApp)), held, "fees still arrive and are booked");
        (uint256 unreleased,) = dividendApp.unreleased(t, t);
        assertGt(unreleased, 0);
        vm.prank(DAVE);
        token.transfer(BOB, 1_000_000 ether);
        assertEq(dividendApp.shares(t, BOB), 1_000_000 ether, "the holder book follows transfers");
        dividendApp.refresh(t, BOB);
        _releaseDividends();
        (uint256 dueAfter,) = dividendApp.pending(t, DAVE);
        assertGt(dueAfter, 0, "fees booked while paused keep accruing");

        vm.prank(GUARDIAN);
        vm.expectRevert(_notOwner(GUARDIAN));
        registry.setAppPaused(DIVIDEND_ID, false);
        vm.expectEmit(address(registry));
        emit AppPaused(address(dividendApp), false);
        registry.setAppPaused(DIVIDEND_ID, false);
        vm.prank(DAVE);
        (uint256 paid,) = dividendApp.claim(t, DAVE);
        assertEq(paid, dueAfter);
    }

    function testPausedSinksRefuseBurnsBuybacksAndLiquidityAdds() public {
        _name();
        PikaToken burning = _launch(_one(BURN_APP_ID, 5000, 5000));
        _fill(burning, address(usdt));
        _swap(burning, CAROL, false, 300 ether);
        _swap(burning, CAROL, true, 1_000_000 ether);
        PikaToken providing = _launch(_one(LIQUIDITY_ID, 10_000, 10_000));
        _fill(providing, address(usdt));
        _swap(providing, CAROL, false, 300 ether);

        vm.startPrank(GUARDIAN);
        registry.setAppPaused(BURN_APP_ID, true);
        registry.setAppPaused(LIQUIDITY_ID, true);
        vm.stopPrank();
        vm.expectRevert(PikaAppBase.AppIsPaused.selector);
        burnApp.burn(address(burning));
        vm.prank(KEEPER);
        vm.expectRevert(PikaAppBase.AppIsPaused.selector);
        burnApp.buyback(address(burning), 1, block.timestamp);
        vm.prank(KEEPER);
        vm.expectRevert(PikaAppBase.AppIsPaused.selector);
        liquidityApp.addLiquidity(address(providing), 1, 0, type(uint160).max, block.timestamp);
        // Fees keep arriving.
        uint256 waiting = burnApp.pending(address(burning), address(burning));
        _swap(burning, CAROL, false, 100 ether);
        assertGt(burnApp.pending(address(burning), address(burning)), waiting);

        registry.setAppPaused(BURN_APP_ID, false);
        registry.setAppPaused(LIQUIDITY_ID, false);
        assertGt(burnApp.burn(address(burning)), 0);
        vm.prank(KEEPER);
        (, uint256 received,) = burnApp.buyback(address(burning), 1, block.timestamp);
        assertGt(received, 0);
        vm.prank(KEEPER);
        (uint128 added,,) = liquidityApp.addLiquidity(address(providing), 1, 0, type(uint160).max, block.timestamp);
        assertGt(added, 0);
    }

    function testOnlyContractTemplatesCanBePaused() public {
        _name();
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, BURN_ID));
        registry.setAppPaused(BURN_ID, true);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, uint32(99)));
        registry.setAppPaused(99, true);
        vm.expectRevert(abi.encodeWithSelector(PikaAppRegistry.InvalidTemplate.selector, uint32(99)));
        registry.setAppPaused(99, false);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Behind the timelock
    // ---------------------------------------------------------------------------------------------------------

    /// @dev The deployment names the guardian before the handover; afterwards it still acts at once while every
    ///      owner entry, the reversals and the seat itself included, waits for the delay.
    function testTheGuardianActsAtOnceWhileTheOwnerWaitsForTheTimelock() public {
        _name();
        Ownable2Step[] memory owned = new Ownable2Step[](3);
        (owned[0], owned[1], owned[2]) = (factory, registry, guard);
        TimelockController timelock = _handOverToTimelock(owned, address(this), MULTISIG, 1 days);
        assertEq(factory.owner(), address(timelock));
        assertEq(registry.owner(), address(timelock));
        assertEq(guard.owner(), address(timelock));

        vm.startPrank(GUARDIAN);
        factory.setLaunchEnabled(false);
        registry.setKeeper(KEEPER, false);
        registry.setAppPaused(DIVIDEND_ID, true);
        vm.stopPrank();
        assertFalse(factory.launchEnabled());
        assertFalse(registry.keepers(KEEPER));
        assertTrue(registry.appPaused(address(dividendApp)));

        // Even the Safe behind the timelock cannot reverse, or replace the guardian, at once.
        vm.prank(MULTISIG);
        vm.expectRevert(_notOwner(MULTISIG));
        factory.setLaunchEnabled(true);
        vm.prank(MULTISIG);
        vm.expectRevert(_notOwner(MULTISIG));
        guard.setGuardian(ALICE);
        bytes memory resume = abi.encodeCall(factory.setLaunchEnabled, (true));
        vm.prank(MULTISIG);
        timelock.schedule(address(factory), 0, resume, bytes32(0), bytes32(0), 1 days);
        vm.prank(MULTISIG);
        vm.expectRevert();
        timelock.execute(address(factory), 0, resume, bytes32(0), bytes32(0));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MULTISIG);
        timelock.execute(address(factory), 0, resume, bytes32(0), bytes32(0));
        assertTrue(factory.launchEnabled());
    }
}
