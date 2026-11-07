// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice The guardian seat every Pika contract shares (docs/PIKA_CONTRACTS.md §8): one emergency account that may
///         use the tightening entries of the contracts reading it (`PikaGuarded`) at once, and nothing else.
/// @dev Owned by the owner timelock, like the factory and the app registry, so naming or replacing the guardian
///      waits for the delay while the guardian itself can drop the role at once when its key may have leaked. One
///      seat for all contracts means the factory and the registry can never disagree about who the guardian is.
contract PikaGuard is Ownable2Step {
    /// @notice The emergency account; zero when none is set.
    address public guardian;

    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);

    error NotGuardian();
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) { }

    /// @dev Without an owner nobody could ever name a guardian again.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Name or replace the guardian; zero removes it. Owner only, so it waits for the timelock.
    function setGuardian(address account) external onlyOwner {
        emit GuardianUpdated(guardian, account);
        guardian = account;
    }

    /// @notice The guardian drops its own role at once.
    function renounceGuardian() external {
        if (guardian == address(0) || msg.sender != guardian) revert NotGuardian();
        emit GuardianUpdated(msg.sender, address(0));
        guardian = address(0);
    }
}
