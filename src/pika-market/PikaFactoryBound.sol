// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A shared component that serves exactly one launch factory.
/// @dev The factory's constructor needs component addresses, so components exist first. The account that created
///      the component binds the factory once, after it exists; the factory verifies the binding before accepting it.
abstract contract PikaFactoryBound {
    address private immutable binder;
    address public factory;

    error Unauthorized();
    error InvalidFactory();

    event FactoryBound(address indexed factory);

    constructor() {
        binder = msg.sender;
    }

    function bindFactory(address factory_) external {
        if (msg.sender != binder) revert Unauthorized();
        if (factory != address(0) || factory_.code.length == 0) revert InvalidFactory();
        factory = factory_;
        emit FactoryBound(factory_);
    }

    function _requireFactory() internal view {
        if (msg.sender != factory) revert Unauthorized();
    }
}
