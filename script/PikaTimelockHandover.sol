// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Puts Ownable2Step contracts (the factory and the app registry) behind one fresh TimelockController within
///         one broadcast.
/// @dev The timelock starts with a zero delay so it can accept ownership and hand its roles to `owner` at once, then
///      the same batch sets `delay`. Afterwards every owner call needs schedule -> wait `delay` -> execute, and
///      only `owner` may propose, execute or cancel. The timelock administers itself; nobody can bypass the delay.
///      A zero `delay` (the mainnet interim launch, user decision 2026-11-01) keeps schedule + execute but lets them
///      run back to back; raise it later with `updateDelay` through the timelock.
abstract contract PikaTimelockHandover {
    function _handOverToTimelock(Ownable2Step target, address deployer, address owner, uint256 delay)
        internal
        returns (TimelockController timelock)
    {
        Ownable2Step[] memory owned = new Ownable2Step[](1);
        owned[0] = target;
        return _handOverToTimelock(owned, deployer, owner, delay);
    }

    function _handOverToTimelock(Ownable2Step[] memory owned, address deployer, address owner, uint256 delay)
        internal
        returns (TimelockController timelock)
    {
        address[] memory bootstrap = new address[](1);
        bootstrap[0] = deployer;
        timelock = new TimelockController(0, bootstrap, bootstrap, address(0));
        for (uint256 t; t < owned.length; ++t) {
            owned[t].transferOwnership(address(timelock));
        }

        bool handOff = owner != deployer;
        uint256 count = owned.length + (handOff ? 7 : 1);
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory payloads = new bytes[](count);
        uint256 i;
        for (; i < owned.length; ++i) {
            targets[i] = address(owned[i]);
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
        if (handOff) {
            bytes32[3] memory roles = [timelock.PROPOSER_ROLE(), timelock.EXECUTOR_ROLE(), timelock.CANCELLER_ROLE()];
            for (uint256 r; r < 3; ++r) {
                targets[i] = address(timelock);
                payloads[i++] = abi.encodeCall(IAccessControl.grantRole, (roles[r], owner));
            }
            for (uint256 r; r < 3; ++r) {
                targets[i] = address(timelock);
                payloads[i++] = abi.encodeCall(IAccessControl.revokeRole, (roles[r], deployer));
            }
        }
        targets[i] = address(timelock);
        payloads[i] = abi.encodeCall(TimelockController.updateDelay, (delay));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), 0);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        for (uint256 t; t < owned.length; ++t) {
            require(
                owned[t].owner() == address(timelock) && owned[t].pendingOwner() == address(0), "timelock not owner"
            );
        }
        require(timelock.getMinDelay() == delay, "timelock delay not set");
        require(
            timelock.hasRole(timelock.PROPOSER_ROLE(), owner) && timelock.hasRole(timelock.EXECUTOR_ROLE(), owner)
                && timelock.hasRole(timelock.CANCELLER_ROLE(), owner),
            "owner roles missing"
        );
        require(
            !handOff
                || (!timelock.hasRole(timelock.PROPOSER_ROLE(), deployer)
                    && !timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer)),
            "deployer roles kept"
        );
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "deployer is admin");
    }
}
