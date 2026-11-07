// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPikaApp, IPikaAppToken, IPikaAppRegistry } from "./interfaces/IPikaApps.sol";

/// @notice What every contract app template shares: registration by the app registry and fee booking on the
///         token's notification. The token's push and the booking stand or fall together: a booking that reverts
///         reverts the push, so a template never holds fees it has not booked.
/// @dev One template contract serves every launch that binds it; all books are keyed by the launch token and the
///      asset: a buy fee arrives in the launch token, a sell fee in the launch's quote asset, and each is booked and
///      paid out in its own asset. Balances of different launches of the same quote asset share one ERC20 balance
///      but never one book. Anything sent to a template without a notification (a plain transfer) is never booked
///      and stays out of every distribution. Templates have no owner and no withdrawal entry beyond what users are
///      owed.
///
///      Upgrades: a template is an ERC1967 proxy (UUPS) and every launch that bound it follows its implementation.
///      Only the registry can upgrade it (`PikaAppRegistry.upgradeTemplate`, i.e. the timelock), to an
///      implementation with the same key and registry and a higher version. Storage is append-only: the base
///      contracts reserve gaps, and templates append their own fields at the end.
abstract contract PikaAppBase is IPikaApp, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Launch tokens have 18 decimals; template parameters are given in whole tokens.
    uint256 internal constant UNIT = 1e18;

    address public immutable registry;
    mapping(address token => bool) public registered;
    /// @dev Room for later base fields; a new field takes one slot from here (49: the slot of the removed
    ///      `syncedFailed` mapping joined it, so existing layouts are unchanged).
    uint256[49] private __gap;

    error Unauthorized();
    error UnknownLaunch();
    error InvalidParams();
    error NotGraduated();
    error InvalidUpgrade();
    error AppIsPaused();

    event LaunchRegistered(address indexed token, bytes params);
    event FeeBooked(address indexed token, address indexed asset, bool buy, uint256 amount);

    constructor(address registry_) {
        if (registry_.code.length == 0) revert InvalidParams();
        registry = registry_;
        _disableInitializers();
    }

    /// @notice Run once by the proxy's constructor.
    function initialize() external initializer {
        _initialize();
    }

    /// @notice The implementation behind this template's proxy; zero on an implementation itself.
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function register(address token, bytes calldata params) external {
        if (msg.sender != registry) revert Unauthorized();
        if (registered[token]) revert InvalidParams();
        registered[token] = true;
        _register(token, params);
        emit LaunchRegistered(token, params);
    }

    function onProjectFee(address asset, bool buy, uint256 amount) external {
        address token = msg.sender;
        if (!registered[token]) revert UnknownLaunch();
        _book(token, asset, amount);
        emit FeeBooked(token, asset, buy, amount);
    }

    /// @dev The registry upgrades through `upgradeToAndCall`; the next implementation must be the same template for
    ///      the same registry with a higher version. `UUPSUpgradeable` also checks it is upgradeable itself.
    function _authorizeUpgrade(address next) internal view override {
        if (msg.sender != registry) revert Unauthorized();
        if (
            next.code.length == 0 || IPikaApp(next).templateKey() != this.templateKey()
                || PikaAppBase(next).registry() != registry || IPikaApp(next).version() <= this.version()
        ) revert InvalidUpgrade();
    }

    /// @dev State a template sets up once in its proxy.
    function _initialize() internal virtual { }

    function _register(address token, bytes calldata params) internal virtual;

    /// @dev Books `amount` of `asset` the token already transferred here. Constant work only: it runs inside the
    ///      token's fee push, which reverts with it.
    function _book(address token, address asset, uint256 amount) internal virtual;

    /// @dev The launch's quote asset, in which its sell fees arrive.
    function _quote(address token) internal view returns (address) {
        return IPikaAppToken(token).quoteAsset();
    }

    function _requireRegistered(address token) internal view {
        if (!registered[token]) revert UnknownLaunch();
    }

    /// @dev The registry's pause of this template (the guardian's emergency stop). Only the sinks' trading entries
    ///      (burn, buyback, liquidity dispatch) check it; `register`, `onProjectFee`, a holder book's `setShares` and
    ///      the dividend claims never do, so a paused template keeps receiving and booking fees, keeps paying holders
    ///      what they earned, and never blocks a launch's trades or transfers.
    function _requireActive() internal view {
        if (IPikaAppRegistry(registry).appPaused(address(this))) revert AppIsPaused();
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (amount != 0) IERC20(asset).safeTransfer(to, amount);
    }

    function _wholeTokens(uint256 count, uint256 min, uint256 max) internal pure returns (uint256) {
        if (count < min || count > max) revert InvalidParams();
        return count * UNIT;
    }
}
