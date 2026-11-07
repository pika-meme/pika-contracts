// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PikaGuarded } from "../../src/common/PikaGuarded.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaFactoryBound } from "../../src/pika-market/PikaFactoryBound.sol";
import { PikaTimelockHandover } from "../../script/PikaTimelockHandover.sol";

/// @notice The deploy scripts' handover: after it, every factory owner call waits for the timelock delay.
contract PikaTimelockTest is PikaInfinityFixture, PikaTimelockHandover {
    address constant MULTISIG = address(0x5afe);

    function testFactoryOwnerCallsWaitForTheTimelockAndRolesMoveToOwner() public {
        TimelockController timelock = _handOverToTimelock(factory, address(this), MULTISIG, 2 days);
        assertEq(factory.owner(), address(timelock));
        assertEq(timelock.getMinDelay(), 2 days);
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));

        // Without a guardian the stop is the owner's alone; the resume always is.
        vm.expectRevert(PikaGuarded.NotGuardian.selector);
        factory.setLaunchEnabled(false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setLaunchEnabled(true);
        bytes memory pause = abi.encodeCall(factory.setLaunchEnabled, (false));
        vm.expectRevert();
        timelock.schedule(address(factory), 0, pause, bytes32(0), bytes32(0), 2 days);
        vm.prank(MULTISIG);
        vm.expectRevert();
        timelock.schedule(address(factory), 0, pause, bytes32(0), bytes32(0), 1 days);
        vm.prank(MULTISIG);
        timelock.schedule(address(factory), 0, pause, bytes32(0), bytes32(0), 2 days);
        vm.prank(MULTISIG);
        vm.expectRevert();
        timelock.execute(address(factory), 0, pause, bytes32(0), bytes32(0));
        // Launching keeps working while the change waits.
        _create(address(usdt), true);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(MULTISIG);
        timelock.execute(address(factory), 0, pause, bytes32(0), bytes32(0));
        assertFalse(factory.launchEnabled());

        // Even the timelock cannot drop ownership.
        bytes memory renounce = abi.encodeCall(Ownable.renounceOwnership, ());
        vm.prank(MULTISIG);
        timelock.schedule(address(factory), 0, renounce, bytes32(0), bytes32(0), 2 days);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(MULTISIG);
        vm.expectRevert(PikaLaunchFactory.RenounceDisabled.selector);
        timelock.execute(address(factory), 0, renounce, bytes32(0), bytes32(0));
        assertEq(factory.owner(), address(timelock));
    }

    function testDeployerKeepsTimelockRolesWhenItIsTheOwner() public {
        TimelockController timelock = _handOverToTimelock(factory, address(this), address(this), 10 minutes);
        assertEq(factory.owner(), address(timelock));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(this)));
        assertEq(timelock.getMinDelay(), 10 minutes);
    }
}
