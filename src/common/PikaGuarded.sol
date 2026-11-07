// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The guardian seat, as the guarded contracts read it (`PikaGuard`).
interface IPikaGuard {
    function guardian() external view returns (address);
}

/// @notice A contract whose tightening entries the shared guardian may also use (docs/PIKA_CONTRACTS.md §8).
/// @dev One rule for every switch: moving it towards "off" (stop, pause, disable, revoke, untrust) is the admin's or
///      the guardian's call, at once; moving it back is the admin's only, so on mainnet it waits for the admin's
///      timelock. The admin is whatever account the derived contract answers in `_admin()`: its owner, or its
///      factory's. The guardian lives in one `PikaGuard` all guarded contracts share, so it is named, replaced and
///      renounced in one place and can never differ between them.
abstract contract PikaGuarded {
    /// @notice The shared guardian seat.
    IPikaGuard public immutable guard;

    error InvalidGuard();
    error NotGuardian();

    constructor(address guard_) {
        if (guard_.code.length == 0) revert InvalidGuard();
        guard = IPikaGuard(guard_);
    }

    /// @notice The emergency account; zero when none is set.
    function guardian() public view returns (address) {
        return guard.guardian();
    }

    /// @dev The account that holds every power here.
    function _admin() internal view virtual returns (address);

    /// @dev The tightening direction of a switch: the admin, or the guardian when one is set. Without a guardian the
    ///      zero address is nobody.
    function _requireAdminOrGuardian() internal view {
        if (msg.sender == _admin()) return;
        address g = guard.guardian();
        if (g == address(0) || msg.sender != g) revert NotGuardian();
    }
}
