// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { PikaGuarded } from "../common/PikaGuarded.sol";
import { FeeSlot, AppBinding, IPikaApp } from "./interfaces/IPikaApps.sol";

interface IPikaAppTemplate {
    function registry() external view returns (address);
    function implementation() external view returns (address);
    function upgradeToAndCall(address next, bytes calldata data) external payable;
}

/// @notice Platform-managed app templates a creator can bind to a launch's project fee.
/// @dev Owned by the same timelock as the factory. Listing, disabling and `maxApps` apply to launches created
///      afterwards only: a launch snapshots its fee slots into the token. A contract template is an upgradeable
///      proxy, and `upgradeTemplate` changes its rules for every launch bound to it, existing ones included, so it
///      is reserved for `upgradeAuthority`: a separate TimelockController, never faster than the owner's, whose
///      proposer is the platform multisig, fixed at deployment. New app kinds need only a new template and
///      `addTemplate`.
///
///      The shared guardian (`PikaGuard`, docs/PIKA_CONTRACTS.md §8) may only tighten, at once and without the
///      timelock: revoke a keeper, disable a template for new launches, pause a template's trading entries (the
///      sinks' burn, buyback and liquidity dispatches; dividend claims are never paused). Granting, enabling and
///      unpausing stay with the owner.
contract PikaAppRegistry is Ownable2Step, PikaGuarded {
    enum Kind {
        None,
        /// @dev Receives its share as a plain transfer, without notification (for example the burn address). Only
        ///      buy shares, which are meme: a sell fee is quote and would be lost on such an address.
        Direct,
        /// @dev A shared `IPikaApp` contract that books each amount it receives.
        Contract,
        /// @dev A contract template that is also the launch's holder book: the token tells it every balance change
        ///      (`IPikaHolderBook`). A launch binds at most one.
        HolderBook
    }

    struct Template {
        address target;
        Kind kind;
        bool enabled;
        uint16 version;
        bytes32 key;
        /// @dev A default sink (burn, dividend, liquidity): offered to every launch and not counted against
        ///      `maxApps`.
        bool isDefault;
    }

    /// @dev What a launch bound, as emitted for the indexer.
    struct BoundApp {
        uint32 templateId;
        uint16 version;
        address target;
        uint16 buyShareBps;
        uint16 sellShareBps;
        bytes params;
    }

    /// @notice The most apps a launch binds in total, default sinks included, and the highest `maxApps`: the token's
    ///         `MAX_FEE_SLOTS`, so a launch the registry accepts always fits the token (2026-11-03). Bounds the gas
    ///         every fee push spends on app transfers and notifications.
    uint256 public constant HARD_MAX_APPS = 6;
    uint256 private constant BPS = 10_000;

    Template[] private templateList;
    /// @notice Apps a launch may bind besides the default sinks; one by product rule, the owner may change it.
    uint256 public maxApps = 1;
    mapping(address factory => bool allowed) public factories;
    /// @notice Accounts allowed to run the sink entries that trade on the pool (burn buybacks, liquidity
    ///         rebalancing), since those take a minimum output the caller must set honestly.
    mapping(address account => bool allowed) public keepers;
    /// @notice The only account that may upgrade a template: the upgrade timelock.
    address public immutable upgradeAuthority;
    /// @notice Paused templates, by target: their trading entries refuse (`PikaAppBase._requireActive`). Fees keep
    ///         arriving and being booked, dividend claims go on; a launch's trades and transfers never check this.
    mapping(address target => bool paused) public appPaused;

    error InvalidConfiguration();
    error UnauthorizedFactory();
    error TooManyApps();
    error InvalidTemplate(uint32 templateId);
    error DuplicateTemplate(uint32 templateId);
    error InvalidShares();
    error NoFeeSource(uint32 templateId);
    /// @dev A direct receiver takes a plain transfer and cannot use quote, which is what a sell fee is paid in.
    error DirectReceiverSellShare(uint32 templateId);
    error RenounceDisabled();
    error UnauthorizedUpgrade();

    event TemplateAdded(
        uint32 indexed templateId, address indexed target, Kind kind, bytes32 key, uint16 version, bool isDefault
    );
    event TemplateEnabledChanged(uint32 indexed templateId, bool enabled);
    event TemplateUpgraded(uint32 indexed templateId, address indexed target, address implementation, uint16 version);
    event MaxAppsUpdated(uint256 maxApps);
    event FactoryUpdated(address indexed factory, bool allowed);
    event KeeperUpdated(address indexed account, bool allowed);
    event AppPaused(address indexed target, bool paused);
    event AppsBound(
        address indexed token,
        bytes32 configHash,
        address creatorFeeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        BoundApp[] apps
    );

    constructor(address owner_, address guard_, address upgradeAuthority_) Ownable(owner_) PikaGuarded(guard_) {
        if (upgradeAuthority_ == address(0)) revert InvalidConfiguration();
        upgradeAuthority = upgradeAuthority_;
    }

    /// @dev Without an owner no template could ever change again.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Templates
    // ---------------------------------------------------------------------------------------------------------

    /// @notice List a new template. A contract template must be a proxy (`implementation()` set), answer to `key`
    ///         and `version` and serve this registry. A default sink is offered to every launch outside `maxApps`.
    function addTemplate(address target, Kind kind, bytes32 key, uint16 version, bool isDefault)
        external
        onlyOwner
        returns (uint32 templateId)
    {
        if (target == address(0) || key == bytes32(0) || kind == Kind.None) revert InvalidConfiguration();
        if (
            kind != Kind.Direct
                && (target.code.length == 0
                    || IPikaApp(target).templateKey() != key
                    || IPikaApp(target).version() != version
                    || IPikaAppTemplate(target).registry() != address(this)
                    || IPikaAppTemplate(target).implementation() == address(0))
        ) revert InvalidConfiguration();
        templateId = uint32(templateList.length);
        templateList.push(Template(target, kind, true, version, key, isDefault));
        emit TemplateAdded(templateId, target, kind, key, version, isDefault);
    }

    /// @notice Move a contract template to a new implementation: the same template key, this registry, a higher
    ///         version (checked by the template). Applies at once to every launch bound to it, so only the upgrade
    ///         timelock may call it. `data` is an optional migration call run in the proxy.
    function upgradeTemplate(uint32 templateId, address next, bytes calldata data) external {
        if (msg.sender != upgradeAuthority) revert UnauthorizedUpgrade();
        if (templateId >= templateList.length) revert InvalidTemplate(templateId);
        Template storage t = templateList[templateId];
        if (t.kind == Kind.Direct) revert InvalidTemplate(templateId);
        IPikaAppTemplate(t.target).upgradeToAndCall(next, data);
        uint16 v = IPikaApp(t.target).version();
        t.version = v;
        emit TemplateUpgraded(templateId, t.target, next, v);
    }

    /// @notice A disabled template cannot be bound by new launches; launches that already bound it keep it. The
    ///         guardian may disable, only the owner enables. Disabling a default sink stops the new launches that
    ///         choose it.
    function setTemplateEnabled(uint32 templateId, bool enabled) external {
        if (enabled) _checkOwner();
        else _requireAdminOrGuardian();
        if (templateId >= templateList.length) revert InvalidTemplate(templateId);
        templateList[templateId].enabled = enabled;
        emit TemplateEnabledChanged(templateId, enabled);
    }

    /// @notice Pause or resume a contract template's trading entries (burns, buybacks, liquidity adds). Dividend
    ///         claims are never paused. Pausing is the guardian's call too, at once; only the owner resumes. Fees keep
    ///         arriving meanwhile.
    function setAppPaused(uint32 templateId, bool paused) external {
        if (paused) _requireAdminOrGuardian();
        else _checkOwner();
        if (templateId >= templateList.length) revert InvalidTemplate(templateId);
        Template storage t = templateList[templateId];
        if (t.kind == Kind.Direct) revert InvalidTemplate(templateId);
        appPaused[t.target] = paused;
        emit AppPaused(t.target, paused);
    }

    function _admin() internal view override returns (address) {
        return owner();
    }

    function setMaxApps(uint256 n) external onlyOwner {
        if (n > HARD_MAX_APPS) revert InvalidConfiguration();
        maxApps = n;
        emit MaxAppsUpdated(n);
    }

    function setFactory(address factory, bool allowed) external onlyOwner {
        if (factory.code.length == 0) revert InvalidConfiguration();
        factories[factory] = allowed;
        emit FactoryUpdated(factory, allowed);
    }

    /// @notice Keepers run the sinks' trading entries. The guardian may revoke one, only the owner grants.
    function setKeeper(address account, bool allowed) external {
        if (allowed) _checkOwner();
        else _requireAdminOrGuardian();
        if (account == address(0)) revert InvalidConfiguration();
        keepers[account] = allowed;
        emit KeeperUpdated(account, allowed);
    }

    function templateCount() external view returns (uint256) {
        return templateList.length;
    }

    function templates(uint32 templateId) external view returns (Template memory) {
        if (templateId >= templateList.length) revert InvalidTemplate(templateId);
        return templateList[templateId];
    }

    /// @notice The holder book a launch binding `apps` gets: the first holder-book template among them, zero without
    ///         one. The hub checks it in Core's creation check and hands it to the token with the slots `bindLaunch`
    ///         returns; the token checks both agree and refuses a second holder book.
    function holderBookOf(AppBinding[] calldata apps) external view returns (address book) {
        uint256 n = apps.length;
        for (uint256 i; i < n; ++i) {
            uint32 id = apps[i].templateId;
            if (id >= templateList.length) revert InvalidTemplate(id);
            if (book == address(0) && templateList[id].kind == Kind.HolderBook) book = templateList[id].target;
        }
    }

    /// @notice Validates a launch's app choices, registers it with each contract template and returns the fee
    ///         slots the token stores. Called by the hub inside `registerLaunch`, while the token initializes and
    ///         before its supply exists. Default sinks do not count against `maxApps`; the total, default
    ///         sinks included, is at most `HARD_MAX_APPS`, the token's own slot cap.
    function bindLaunch(
        address token,
        address creatorFeeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        AppBinding[] calldata apps
    ) external returns (FeeSlot[] memory slots) {
        if (!factories[msg.sender]) revert UnauthorizedFactory();
        uint256 n = apps.length;
        if (n > HARD_MAX_APPS) revert TooManyApps();
        uint256 chosen;
        for (uint256 i; i < n; ++i) {
            uint32 id = apps[i].templateId;
            if (id >= templateList.length) revert InvalidTemplate(id);
            if (!templateList[id].isDefault) ++chosen;
        }
        if (chosen > maxApps) revert TooManyApps();
        slots = new FeeSlot[](n);
        BoundApp[] memory bound = new BoundApp[](n);
        uint256 buyTotal;
        uint256 sellTotal;
        for (uint256 i; i < n; ++i) {
            (slots[i], bound[i]) = _bindOne(token, creatorFeeRecipient, buyFeeBps, sellFeeBps, apps, i);
            buyTotal += slots[i].buyShareBps;
            sellTotal += slots[i].sellShareBps;
        }
        if (buyTotal > BPS || sellTotal > BPS) revert InvalidShares();
        bytes32 hash = keccak256(abi.encode(block.chainid, token, creatorFeeRecipient, buyFeeBps, sellFeeBps, bound));
        emit AppsBound(token, hash, creatorFeeRecipient, buyFeeBps, sellFeeBps, bound);
    }

    /// @dev Validates the `i`-th binding against the template list, the fee rates and the bindings before it,
    ///      registers the launch with a contract template, and returns the slot the token stores and the binding the
    ///      event reports.
    function _bindOne(
        address token,
        address creatorFeeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        AppBinding[] calldata apps,
        uint256 i
    ) private returns (FeeSlot memory slot, BoundApp memory app) {
        AppBinding calldata a = apps[i];
        if (a.templateId >= templateList.length) revert InvalidTemplate(a.templateId);
        Template memory t = templateList[a.templateId];
        // A paused template takes no new launches either (audit 2026-11-02, L-2).
        if (!t.enabled || appPaused[t.target] || t.target == creatorFeeRecipient) revert InvalidTemplate(a.templateId);
        for (uint256 j; j < i; ++j) {
            if (apps[j].templateId == a.templateId) revert DuplicateTemplate(a.templateId);
        }
        if ((buyFeeBps == 0 || a.buyShareBps == 0) && (sellFeeBps == 0 || a.sellShareBps == 0)) {
            revert NoFeeSource(a.templateId);
        }
        if (t.kind != Kind.Direct) {
            IPikaApp(t.target).register(token, a.params);
        } else {
            if (a.params.length != 0) revert InvalidTemplate(a.templateId);
            if (a.sellShareBps != 0) revert DirectReceiverSellShare(a.templateId);
        }
        slot = FeeSlot(t.target, a.buyShareBps, a.sellShareBps, t.kind != Kind.Direct, t.kind == Kind.HolderBook);
        app = BoundApp(a.templateId, t.version, t.target, a.buyShareBps, a.sellShareBps, a.params);
    }
}
