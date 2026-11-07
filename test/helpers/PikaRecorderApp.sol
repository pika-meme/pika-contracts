// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PikaAppBase } from "../../src/pika-apps/PikaAppBase.sol";

/// @notice A test-only contract app template that just records what it was booked. It stands in for an optional app
///         (the staking, FOMO3D and land templates were removed from source on 2026-10-30, tag
///         `contracts-all-apps-2026-10-30`) so the suites still cover what every contract template shares: binding
///         beside the default sinks, the fee split, notification and upgrades through the registry.
/// @dev The key is fixed per implementation (an immutable, so the proxy answers with it), which lets one source
///      serve several listed templates. Parameters: `abi.encode(uint256)` in whole tokens, 1 to 1e9.
contract PikaRecorderApp is PikaAppBase {
    bytes32 private immutable key;

    /// @notice Everything booked per launch and asset, through notifications.
    mapping(address token => mapping(address asset => uint256)) public booked;
    mapping(address token => uint256) public param;

    constructor(address registry_, bytes32 key_) PikaAppBase(registry_) {
        key = key_;
    }

    function templateKey() external view returns (bytes32) {
        return key;
    }

    function version() external pure virtual returns (uint16) {
        return 2;
    }

    function _register(address token, bytes calldata params) internal override {
        if (params.length != 32) revert InvalidParams();
        param[token] = _wholeTokens(abi.decode(params, (uint256)), 1, 1e9);
    }

    function _book(address token, address asset, uint256 amount) internal override {
        booked[token][asset] += amount;
    }
}
