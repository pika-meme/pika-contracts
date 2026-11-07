// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPikaHub } from "../interfaces/IPikaLaunch.sol";

/// @notice What every Pika OpenFour module shares: the hub and the Core it serves, the launch token and the Registry
///         version snapshot.
/// @dev Implementations sit behind OpenFour Registry beacons; Core deploys one BeaconProxy per launch and calls the
///      module's `init` in the creation transaction. The hub and Core are implementation immutables: every instance
///      serves the Pika hub and the OpenFour Core it was built for, and initializes only while the hub names that
///      Core. A new Core takes new implementations (and, being a new OpenFour deployment, a new Registry anyway).
///
///      Core creates two Pika instances per launch, the token and migrate modules (the vault, curve and trade policy
///      are OpenFour's standard ones and there is no custom data module), so each keeps only what
///      the launch needs (2026-11-05): the token address is also the initialized flag, the version snapshot shares
///      the token's slot when it fits (up to 11 bytes, like "1.0.0"), and parameters that are always empty are not
///      stored. The implementation itself holds a placeholder token, so it can never be initialized.
abstract contract PikaModuleBase {
    /// @notice The Pika launch hub (`PikaLaunchFactory`).
    address public immutable hub;
    /// @dev OpenFour Core, the only caller of the module's write entries.
    address internal immutable _core;

    address private constant IMPLEMENTATION = address(1);
    uint8 private constant LONG_VERSION = type(uint8).max;

    /// @dev The launch token this instance serves; zero until `init`. One slot with the short version below.
    address internal _token;
    bytes11 private _shortVersion;
    /// @dev The version's length, or `LONG_VERSION` when it is kept in `_longVersion`.
    uint8 private _versionLength;
    string private _longVersion;

    error InvalidModuleConfiguration();
    error AlreadyInitialized();
    error OnlyCore();
    error WrongToken();

    constructor(address hub_, address core_) {
        if (hub_.code.length == 0 || core_.code.length == 0) revert InvalidModuleConfiguration();
        hub = hub_;
        _core = core_;
        _token = IMPLEMENTATION;
    }

    modifier onlyCore() {
        if (msg.sender != _core) revert OnlyCore();
        _;
    }

    /// @dev Binds a fresh instance to its launch, once. Core passes itself as `core_`.
    function _bind(address token_, address core_, string calldata version) internal {
        if (core_ != _core) revert InvalidModuleConfiguration();
        _start(token_, version);
    }

    /// @dev `_bind` for an entry Core does not pass itself to (the token module's `createToken`).
    function _start(address token_, string calldata version) internal {
        if (_token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0) || IPikaHub(hub).core() != _core) revert InvalidModuleConfiguration();
        _token = token_;
        uint256 n = bytes(version).length;
        if (n <= 11) {
            _shortVersion = bytes11(bytes(version));
            _versionLength = uint8(n);
        } else {
            _versionLength = LONG_VERSION;
            _longVersion = version;
        }
    }

    function _checkToken(address token_) internal view {
        if (token_ != _token) revert WrongToken();
    }

    /// @notice The launch token this instance serves.
    function token() public view returns (address) {
        return _token;
    }

    /// @notice OpenFour Core.
    function fourCore() public view returns (address) {
        return _core;
    }

    /// @dev The module's stable tag (`ITagDescriptor`), with the Registry version snapshot taken at creation.
    function _describe(string memory tag) internal view returns (bytes8, string memory, string memory) {
        return (bytes8(keccak256(bytes(tag))), tag, _version());
    }

    function _version() private view returns (string memory) {
        uint256 n = _versionLength;
        if (n == LONG_VERSION) return _longVersion;
        bytes11 v = _shortVersion;
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = v[i];
        }
        return string(out);
    }
}
