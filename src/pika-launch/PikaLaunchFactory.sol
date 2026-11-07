// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { PikaGuarded } from "../common/PikaGuarded.sol";
import { PikaFeeMath } from "../common/libraries/PikaFeeMath.sol";
import { PikaToken } from "./PikaToken.sol";
import { PikaGraduationMath } from "./libraries/PikaGraduationMath.sol";
import {
    IPikaFactoryBound, IPikaHook, IPikaLocker, IPikaLpManager, IPikaOrderDeployer
} from "../pika-market/interfaces/IPikaMarket.sol";
import { IPikaHub, PikaTokenParams } from "./interfaces/IPikaLaunch.sol";
import { FeeSlot, IPikaLaunchAppRegistry } from "../pika-apps/interfaces/IPikaApps.sol";
import { OpenFourTypes } from "../openfour/libraries/OpenFourTypes.sol";
import { IOpenFourPresetValidator } from "../openfour/interfaces/IOpenFourPresetValidator.sol";
import { IOpenFourVault } from "../openfour/interfaces/IOpenFourVault.sol";

/// @notice Pika launch hub on OpenFour. OpenFour Core creates every launch (token, vault, curve, trade and migrate
///         modules) from the Pika preset and runs OpenFour's standard vault, bonding curve and trade policy
///         (`module.vault.standard`, `module.curve.bonding`, `module.trade.simple`); the hub holds what Pika adds around it: the owner's launch rules (quotes,
///         minimum targets, supply, app registry, outer components), the creation check Core runs as the preset's
///         validator, the launch registry every outer component trusts, and graduation into the launch's
///         permanently locked Pancake Infinity pool.
/// @dev The contract keeps the name `PikaLaunchFactory`: every outer component is bound to it as its "factory".
///
///      Trust: a token registers itself while it initializes. The hub accepts only an EIP-1167 clone of a Pika token
///      implementation the owner allowed, so the registering code is always Pika's own (it books only fees it really
///      holds). Anyone may clone and initialize that code outside Core; such a launch stays inert because only
///      graduation opens a pool, and graduation requires Core's record of the token under an allowed preset with the
///      calling migrate module, after the sale sold out. Indexers list only launches Core created (`TokenCreated`
///      under a Pika preset).
///
///      Creation and graduation are allowed separately: refusing a preset or replacing Core stops new launches, while
///      the launches already on their curves keep graduating under the preset and Core they were created with
///      (`graduationPresets`, `graduationCores`) until the owner drops those too.
///
///      Admin controls new launch defaults/admission and implementations; ownership is meant to sit behind a
///      timelock and cannot be renounced. Existing launches keep the components pinned at their registration. The
///      shared guardian (`PikaGuard`) may only tighten: stop new launches, revoke a keeper, disable and pause a
///      template on the app registry.
contract PikaLaunchFactory is Ownable2Step, PikaGuarded, ReentrancyGuard, IPikaHub, IOpenFourPresetValidator {
    using SafeERC20 for IERC20;

    uint32 public constant PROTOCOL_VERSION = 12;
    /// @notice The share of the supply a launch sells on the curve, in bps: OpenFour's standard 80/20 split. The
    ///         rest opens the launch pool.
    uint16 public constant SALE_BPS = 8000;
    /// @notice The share of the raised quote the launch pool opens with, in bps. OpenFour's bonding curve ends at
    ///         exactly this share of the target against the pool's tokens, so the pool opens at the curve's last price.
    uint16 public constant POOL_QUOTE_BPS = uint16(PikaGraduationMath.POOL_QUOTE_BPS);
    /// @notice The share of the raised quote credited to the launch's creator fee wallet at graduation, in bps (the
    ///         wallet claims it from the token with its other creator fees). The rest of the raise outside the pool
    ///         (and anything else the vault held) goes to the treasury.
    uint16 public constant CREATOR_GRADUATION_BPS = 100;
    /// @notice The smallest minimum target `configureQuote` accepts, in the quote's smallest units.
    uint256 public constant MIN_TARGET_FLOOR = 1e15;

    /// @notice Shared trading and graduation components. Every change publishes a new version; a launch pins the
    ///         version current at its registration.
    struct Components {
        address router;
        address locker;
        address orderDeployer;
        address hook;
        address lpManager;
    }

    struct QuoteConfig {
        bool enabled;
        uint8 decimals;
        uint256 minTarget;
    }

    enum Phase {
        None,
        Internal,
        External
    }

    struct Launch {
        address quoteToken;
        Phase phase;
        uint32 componentsVersion;
    }

    /// @notice A launch's sizing for a supply and target: what the curve sells, the tokens and quote the pool opens
    ///         with once the curve raised the target, and the virtual reserves OpenFour's bonding curve starts from.
    struct Sizing {
        uint256 saleAmount;
        uint256 poolTokens;
        uint256 poolQuote;
        uint256 virtualQuote;
        uint256 virtualTokens;
    }

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    address public immutable treasury;

    /// @notice OpenFour Core for new launches: the Pika modules initialize only while the hub names their Core.
    address public core;
    address public appRegistry;
    mapping(uint32 version => Components) public components;
    uint32 public componentsVersion;
    bool public launchEnabled = true;
    uint256 public defaultSupply = 1_000_000_000 ether;
    mapping(address quote => QuoteConfig) public quoteConfigs;
    mapping(address token => Launch) public launches;
    /// @notice Pika token implementations whose clones may register.
    mapping(address implementation => bool) public tokenImplementations;
    /// @notice OpenFour presets new launches may use (Core's creation check).
    mapping(uint256 presetId => bool) public presets;
    /// @notice OpenFour presets whose launches may graduate here. Allowing a preset allows its graduation too;
    ///         refusing it afterwards stops only new launches.
    mapping(uint256 presetId => bool) public graduationPresets;
    /// @notice OpenFour Cores whose records graduation trusts. `setCore` adds the new Core and keeps the earlier
    ///         ones, whose launches may still be on their curves.
    mapping(address core => bool) public graduationCores;

    error InvalidConfiguration();
    error WrongPhase();
    error UnsupportedQuote();
    error PoolUnavailable();
    error RenounceDisabled();
    error Unauthorized();
    error VaultLocked();

    event QuoteConfigured(address indexed quote, uint8 decimals, bool enabled, uint256 minTarget);
    /// @notice A Pika token registered while Core created it. Only launches Core lists under a Pika preset are real.
    event LaunchRegistered(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        uint32 componentsVersion,
        address creatorFeeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        address holderBook
    );
    /// @dev `orders` is the launch's order manager; `liquidity` is the locked graduation position.
    event PoolGraduated(
        address indexed token,
        address indexed orders,
        address router,
        uint128 liquidity,
        uint256 quoteAmount,
        uint256 memeAmount
    );
    /// @notice The creator fee wallet's share of the raise, in the quote asset, credited at graduation to the wallet's
    ///         claimable creator fees in the token (`PikaToken.claimCreatorFees`).
    event CreatorGraduationReward(address indexed token, address indexed recipient, uint256 amount);
    /// @notice The launch pool opened at graduation.
    event PoolOpened(address indexed token, bytes32 indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);
    event LaunchEnabled(bool enabled);
    event CoreUpdated(address indexed previousCore, address indexed newCore);
    event AppRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    event DefaultSupplyUpdated(uint256 previousSupply, uint256 newSupply);
    event TokenImplementationSet(address indexed implementation, bool allowed);
    event PresetSet(uint256 indexed presetId, bool allowed);
    event GraduationPresetSet(uint256 indexed presetId, bool allowed);
    event GraduationCoreSet(address indexed core, bool allowed);
    event ComponentsUpdated(
        uint32 indexed version,
        address router,
        address locker,
        address orderDeployer,
        address hook,
        address lpManager
    );

    constructor(
        address owner_,
        address guard_,
        address treasury_,
        IVault vault_,
        ICLPoolManager poolManager_,
        address appRegistry_,
        Components memory comps
    ) Ownable(owner_) PikaGuarded(guard_) {
        if (
            treasury_ == address(0) || address(vault_).code.length == 0 || address(poolManager_).code.length == 0
                || address(poolManager_.vault()) != address(vault_) || appRegistry_.code.length == 0
        ) revert InvalidConfiguration();
        treasury = treasury_;
        vault = vault_;
        poolManager = poolManager_;
        appRegistry = appRegistry_;
        _publish(comps);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Without an owner no default, quote or component could ever change again.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _admin() internal view override returns (address) {
        return owner();
    }

    /// @notice OpenFour Core for new launches; graduation trusts its records from now on. Earlier Cores stay trusted
    ///         for graduation (their launches may still be on their curves) until `setGraduationCore` drops them.
    function setCore(address core_) external onlyOwner {
        if (core_.code.length == 0) revert InvalidConfiguration();
        emit CoreUpdated(core, core_);
        core = core_;
        if (!graduationCores[core_]) _setGraduationCore(core_, true);
    }

    /// @notice Trust or stop trusting an OpenFour Core's records for graduation. The current Core cannot be dropped.
    function setGraduationCore(address core_, bool allowed) external onlyOwner {
        if (core_ == address(0) || (!allowed && core_ == core)) revert InvalidConfiguration();
        _setGraduationCore(core_, allowed);
    }

    function _setGraduationCore(address core_, bool allowed) private {
        graduationCores[core_] = allowed;
        emit GraduationCoreSet(core_, allowed);
    }

    /// @notice Allow or refuse clones of a Pika token implementation to register.
    function setTokenImplementation(address implementation, bool allowed) external onlyOwner {
        if (allowed) {
            PikaToken impl = PikaToken(implementation);
            if (
                implementation.code.length == 0 || impl.factory() != address(this) || impl.canonicalVault() != vault
                    || impl.poolManager() != poolManager
            ) revert InvalidConfiguration();
        }
        tokenImplementations[implementation] = allowed;
        emit TokenImplementationSet(implementation, allowed);
    }

    /// @notice Allow or refuse new launches of an OpenFour preset (Core's creation check). Allowing it also lets its
    ///         launches graduate; refusing it leaves graduation open for the launches already created.
    function setPreset(uint256 presetId, bool allowed) external onlyOwner {
        presets[presetId] = allowed;
        emit PresetSet(presetId, allowed);
        if (allowed && !graduationPresets[presetId]) _setGraduationPreset(presetId, true);
    }

    /// @notice Allow or refuse graduation for an OpenFour preset's launches. A preset that new launches may still use
    ///         cannot lose graduation.
    function setGraduationPreset(uint256 presetId, bool allowed) external onlyOwner {
        if (!allowed && presets[presetId]) revert InvalidConfiguration();
        _setGraduationPreset(presetId, allowed);
    }

    function _setGraduationPreset(uint256 presetId, bool allowed) private {
        graduationPresets[presetId] = allowed;
        emit GraduationPresetSet(presetId, allowed);
    }

    /// @notice Accept or refuse a quote asset (an ERC20; WBNB for BNB launches) for new launches and set the smallest
    ///         graduation target a launch on it may choose; existing launches are not affected.
    function configureQuote(address quote, bool enabled, uint256 minTarget) external onlyOwner {
        uint8 decimals = IERC20Metadata(quote).decimals();
        if (decimals < 6 || decimals > 18 || minTarget < MIN_TARGET_FLOOR || minTarget > 1e30) {
            revert InvalidConfiguration();
        }
        quoteConfigs[quote] = QuoteConfig(enabled, decimals, minTarget);
        emit QuoteConfigured(quote, decimals, enabled, minTarget);
    }

    /// @notice App templates and launch options for launches created afterwards; existing launches keep theirs.
    function setAppRegistry(address registry) external onlyOwner {
        if (registry.code.length == 0) revert InvalidConfiguration();
        emit AppRegistryUpdated(appRegistry, registry);
        appRegistry = registry;
    }

    /// @notice Whether new launches may be created. Stopping them is the guardian's call too; only the owner
    ///         re-enables them. Existing launches are not affected.
    function setLaunchEnabled(bool enabled) external {
        if (enabled) _checkOwner();
        else _requireAdminOrGuardian();
        launchEnabled = enabled;
        emit LaunchEnabled(enabled);
    }

    /// @notice Total supply every new launch must mint. Existing launches keep theirs.
    function setDefaultSupply(uint256 supply) external onlyOwner {
        if (supply < 1 ether || supply > 1e36) revert InvalidConfiguration();
        emit DefaultSupplyUpdated(defaultSupply, supply);
        defaultSupply = supply;
    }

    /// @notice Publish a new set of shared components for launches registered afterwards.
    function setComponents(Components calldata c) external onlyOwner {
        _requireBound(c.router);
        _requireBound(c.locker);
        _requireBound(c.orderDeployer);
        _requireBound(c.hook);
        if (
            IPikaLocker(c.locker).treasury() != treasury || IPikaLocker(c.locker).vault() != vault
                || IPikaLocker(c.locker).poolManager() != poolManager || IPikaHook(c.hook).vault() != vault
                || IPikaHook(c.hook).poolManager() != poolManager || c.lpManager.code.length == 0
                || IPikaLpManager(c.lpManager).vault() != vault
                || IPikaLpManager(c.lpManager).poolManager() != poolManager
                || address(IPikaLpManager(c.lpManager).hook()) != c.hook
        ) revert InvalidConfiguration();
        _publish(c);
    }

    function _publish(Components memory c) private {
        // An order deployer serves the hook its implementation was built for.
        if (IPikaOrderDeployer(c.orderDeployer).hook() != c.hook) revert InvalidConfiguration();
        uint32 version = ++componentsVersion;
        components[version] = c;
        emit ComponentsUpdated(version, c.router, c.locker, c.orderDeployer, c.hook, c.lpManager);
    }

    function _requireBound(address component) private view {
        if (component.code.length == 0 || IPikaFactoryBound(component).factory() != address(this)) {
            revert InvalidConfiguration();
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Creation: Core's preset validator, then the token's registration
    // ---------------------------------------------------------------------------------------------------------

    /// @notice The sizing for a supply and target: the curve sells `SALE_BPS` of the supply; at sell-out the pool
    ///         opens with the rest of the supply and `POOL_QUOTE_BPS` of the target, the curve's last price. The
    ///         virtual reserves mirror OpenFour's bonding curve (see `PikaGraduationMath.bondingReserves`).
    function sizing(uint256 supply, uint256 target) public pure returns (Sizing memory s) {
        s.saleAmount = supply * SALE_BPS / 10_000;
        s.poolTokens = supply - s.saleAmount;
        s.poolQuote = target * POOL_QUOTE_BPS / 10_000;
        (s.virtualQuote, s.virtualTokens) = PikaGraduationMath.bondingReserves(supply, s.saleAmount, target);
    }

    /// @notice Core's creation check for the Pika preset: the launch must use the owner's supply, an accepted quote
    ///         and target, the 80/20 sale split, valid outer fees, and no module parameters (OpenFour's vault, curve
    ///         and trade policy and the Pika migrate module take none; the preset has no custom data module). The app choices are checked when the token registers
    ///         (same transaction).
    function validate(uint256 presetId, OpenFourTypes.TokenInitParams calldata p) external view {
        if (!presets[presetId] || !launchEnabled) revert Unauthorized();
        if (
            bytes(p.name).length == 0 || bytes(p.name).length > 64 || bytes(p.symbol).length == 0
                || bytes(p.symbol).length > 16 || p.maxSupply != defaultSupply
        ) revert InvalidConfiguration();
        QuoteConfig memory quote = quoteConfigs[p.quoteAsset];
        if (!quote.enabled || IERC20Metadata(p.quoteAsset).decimals() != quote.decimals) revert UnsupportedQuote();
        if (p.raiseAmount < MIN_TARGET_FLOOR || p.raiseAmount < quote.minTarget || p.raiseAmount > 1e30) {
            revert InvalidConfiguration();
        }
        Sizing memory s = sizing(p.maxSupply, p.raiseAmount);
        if (p.saleAmount != s.saleAmount || s.poolQuote == 0) revert InvalidConfiguration();
        // The pool must open whichever side the token address falls on.
        _openingPrice(true, s.poolTokens, s.poolQuote);
        _openingPrice(false, s.poolTokens, s.poolQuote);
        // The token's outer fee bounds, checked again here so a bad launch fails in Core's validation rather than
        // deep inside the token's initialization. The app registry bounds the app count.
        PikaTokenParams memory t = abi.decode(p.tokenParams, (PikaTokenParams));
        if (
            t.creatorFeeRecipient == address(0)
                || PikaFeeMath.PLATFORM_FEE_BPS + t.buyFeeBps > PikaFeeMath.MAX_TOTAL_FEE_BPS
                || PikaFeeMath.PLATFORM_FEE_BPS + t.sellFeeBps > PikaFeeMath.MAX_TOTAL_FEE_BPS
        ) revert InvalidConfiguration();
        IPikaLaunchAppRegistry(appRegistry).holderBookOf(t.apps);
        if (
            p.vaultParams.length != 0 || p.curveParams.length != 0 || p.tradeParams.length != 0
                || p.migrateParams.length != 0 || p.customDataParams.length != 0
        ) revert InvalidConfiguration();
    }

    /// @notice Called by a Pika token while it initializes, inside Core's creation. Binds the launch's apps and
    ///         returns the components pinned for it.
    function registerLaunch(Registration calldata r) external returns (Setup memory s) {
        address token = msg.sender;
        if (!launchEnabled) revert Unauthorized();
        if (!tokenImplementations[_cloneImplementation(token)]) revert Unauthorized();
        if (launches[token].phase != Phase.None) revert WrongPhase();
        if (!quoteConfigs[r.quoteAsset].enabled) revert UnsupportedQuote();
        uint32 version = componentsVersion;
        Components memory comp = components[version];
        address recipient = r.params.creatorFeeRecipient;
        if (
            recipient == token || recipient == r.quoteAsset || recipient == address(vault)
                || recipient == address(poolManager) || recipient == appRegistry || recipient == address(this)
                || recipient == comp.router || recipient == comp.locker || recipient == comp.orderDeployer
                || recipient == comp.hook || recipient == comp.lpManager || recipient == core
        ) revert InvalidConfiguration();
        IPikaLaunchAppRegistry registry = IPikaLaunchAppRegistry(appRegistry);
        s.holderBook = registry.holderBookOf(r.params.apps);
        s.slots = registry.bindLaunch(token, recipient, r.params.buyFeeBps, r.params.sellFeeBps, r.params.apps);
        s.treasury = treasury;
        s.locker = comp.locker;
        s.hook = comp.hook;
        s.router = comp.router;
        s.lpManager = comp.lpManager;
        launches[token] = Launch(r.quoteAsset, Phase.Internal, version);
        emit LaunchRegistered(
            token,
            r.creator,
            r.quoteAsset,
            version,
            recipient,
            r.params.buyFeeBps,
            r.params.sellFeeBps,
            s.holderBook
        );
    }

    /// @inheritdoc IPikaHub
    function isLaunch(address token) external view returns (bool) {
        return launches[token].phase != Phase.None;
    }

    /// @dev The implementation behind an EIP-1167 minimal proxy (OpenZeppelin `Clones` layout, which Core uses),
    ///      zero for any other code.
    function _cloneImplementation(address account) private view returns (address impl) {
        if (account.code.length != 45) return address(0);
        bytes memory code = account.code;
        bytes32 head;
        bytes32 tail;
        assembly ("memory-safe") {
            head := mload(add(code, 0x20))
            impl := shr(96, mload(add(code, 0x2a)))
            tail := mload(add(code, 0x3e))
        }
        // 363d3d373d3d3d363d73 <impl> 5af43d82803e903d91602b57fd5bf3
        if (
            bytes10(head) != bytes10(0x363d3d373d3d3d363d73) || bytes15(tail) != bytes15(0x5af43d82803e903d91602b57fd5bf3)
        ) return address(0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Graduation: the migrate module, inside Core's migration
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Graduation of a sold-out launch in one step, called by its migrate module after it moved the vault's
    ///         quote and tokens here: open the launch pool at the curve's final price, seed and lock a full-range
    ///         position with the tokens the curve kept and `POOL_QUOTE_BPS` of the raise, pay the creator fee wallet
    ///         `CREATOR_GRADUATION_BPS` of the raise, and open pool trading. `quoteAmount` is the curve's raised quote
    ///         (it sets the price); the raise's remainder and `extraQuote` (whatever else the vault held: the
    ///         anti-sniper surcharge, donations) are left to the locker for the treasury. The unsold remainder the
    ///         vault may hold (at most one token) stays locked.
    function graduate(address tokenAddress, uint256 quoteAmount, uint256 extraQuote)
        external
        nonReentrant
        returns (bytes32 poolId)
    {
        Launch memory l = launches[tokenAddress];
        if (l.phase != Phase.Internal) revert WrongPhase();
        (uint256 poolTokens, uint256 swept) = _checkGraduation(tokenAddress, l.quoteToken, quoteAmount, extraQuote);
        Components memory comp = components[l.componentsVersion];
        PikaToken token = PikaToken(tokenAddress);
        poolId = _openPool(token, l.quoteToken, comp, poolTokens, quoteAmount * POOL_QUOTE_BPS / 10_000);
        uint128 liquidity = _seedPosition(token, comp.locker, l.quoteToken, poolTokens, swept, quoteAmount, extraQuote);
        token.openTrading();
        launches[tokenAddress].phase = Phase.External;
        emit PoolGraduated(tokenAddress, token.orderManager(), comp.router, liquidity, quoteAmount, swept);
    }

    /// @dev The record of the Core the calling migrate module serves (a Core graduation trusts, not necessarily the
    ///      current one) must name the caller as the launch's migrate module under a preset allowed to graduate, with
    ///      the sale sold out (OpenFour's standard vault: at most one whole token left unsold) and the funds here.
    ///      Returns the tokens the pool opens with (the supply the curve did not sell) and every token the vault
    ///      held, the unsold remainder included.
    function _checkGraduation(address tokenAddress, address quote, uint256 quoteAmount, uint256 extraQuote)
        private
        view
        returns (uint256 poolTokens, uint256 swept)
    {
        (bool ok, bytes memory out) = msg.sender.staticcall(abi.encodeWithSignature("fourCore()"));
        if (!ok || out.length != 32) revert Unauthorized();
        address launchCore = abi.decode(out, (address));
        if (!graduationCores[launchCore]) revert Unauthorized();
        OpenFourTypes.RuntimeConfig memory record = _coreRecord(launchCore, tokenAddress);
        if (
            !record.exists || msg.sender != record.migrateModule || !graduationPresets[record.presetId]
                || record.quoteAsset != quote
        ) revert Unauthorized();
        if (!IOpenFourVault(record.vault).isSoldOut()) revert WrongPhase();
        swept = IERC20(tokenAddress).balanceOf(address(this));
        poolTokens = record.maxSupply - record.saleAmount;
        if (
            quoteAmount * POOL_QUOTE_BPS / 10_000 == 0 || swept < poolTokens
                || IERC20(quote).balanceOf(address(this)) < quoteAmount + extraQuote
        ) revert InvalidConfiguration();
        if (vault.getLocker() != address(0)) revert VaultLocked();
    }

    /// @dev Registers the launch pool with its hook (which builds the key), initializes it at the curve's final
    ///      price and attaches its order manager.
    function _openPool(PikaToken token, address quote, Components memory comp, uint256 poolTokens, uint256 poolQuote)
        private
        returns (bytes32 poolId)
    {
        uint160 price = _openingPrice(address(token) < quote, poolTokens, poolQuote);
        PoolKey memory key = IPikaHook(comp.hook).registerPool(address(token), quote);
        poolManager.initialize(key, price);
        token.configureOuter(IPikaOrderDeployer(comp.orderDeployer).deploy(address(token)));
        poolId = PoolId.unwrap(key.toId());
        emit PoolOpened(address(token), poolId, key, price);
    }

    /// @dev Credits the creator fee wallet its share of the raise in the quote asset. It is not paid out here: a
    ///      wallet that cannot receive the quote (a blacklisting stablecoin) must not be able to stop graduation.
    function _payCreator(PikaToken token, address quote, uint256 quoteAmount) private returns (uint256 reward) {
        reward = quoteAmount * CREATOR_GRADUATION_BPS / 10_000;
        if (reward == 0) return 0;
        IERC20(quote).safeTransfer(address(token), reward);
        token.creditCreatorFees(reward);
        emit CreatorGraduationReward(address(token), token.creatorFeeRecipient(), reward);
    }

    /// @dev Credits the creator fee wallet its share, then hands every token and the remaining quote to the locker,
    ///      which seeds the full-range position at the pool's price (the pool's tokens and `POOL_QUOTE_BPS` of the
    ///      raise) and keeps the rest locked (meme) or owed to the treasury (quote).
    function _seedPosition(
        PikaToken token,
        address locker,
        address quote,
        uint256 poolTokens,
        uint256 swept,
        uint256 quoteAmount,
        uint256 extraQuote
    ) private returns (uint128 liquidity) {
        uint256 quoteIn = quoteAmount + extraQuote - _payCreator(token, quote, quoteAmount);
        IERC20(address(token)).safeTransfer(locker, swept);
        IERC20(quote).safeTransfer(locker, quoteIn);
        uint256 usedMeme;
        uint256 usedQuote;
        (liquidity, usedMeme, usedQuote) = IPikaLocker(locker).lockPosition(address(token), poolTokens, quoteIn);
        if (usedMeme < poolTokens * 9999 / 10_000 || usedQuote < quoteAmount * POOL_QUOTE_BPS / 10_000 * 9999 / 10_000)
        {
            revert InvalidConfiguration();
        }
    }

    /// @notice The current Core's runtime record of `token` (`OpenFourCore.tokens`).
    function coreRecord(address token) external view returns (OpenFourTypes.RuntimeConfig memory) {
        return _coreRecord(core, token);
    }

    /// @dev `core_`'s record of `token`. The getter returns the record's fields as separate values, which encode
    ///      exactly like the record as one tuple after its offset word.
    function _coreRecord(address core_, address token)
        private
        view
        returns (OpenFourTypes.RuntimeConfig memory record)
    {
        (bool ok, bytes memory out) = core_.staticcall(abi.encodeWithSignature("tokens(address)", token));
        if (!ok) revert Unauthorized();
        record = abi.decode(bytes.concat(bytes32(uint256(32)), out), (OpenFourTypes.RuntimeConfig));
    }

    /// @dev The pool's opening price for `seed` meme against `quote`, once the liquidity is representable.
    function _openingPrice(bool memeIs0, uint256 seed, uint256 quote) private pure returns (uint160 price) {
        price = memeIs0
            ? PikaGraduationMath.sqrtPriceX96FromAmounts(seed, quote)
            : PikaGraduationMath.sqrtPriceX96FromAmounts(quote, seed);
        if (price <= TickMath.MIN_SQRT_RATIO * 4 || price >= TickMath.MAX_SQRT_RATIO / 4) {
            revert InvalidConfiguration();
        }
        uint256 liquidityEstimate =
            memeIs0 ? Math.mulDiv(seed, price, uint256(1) << 96) : Math.mulDiv(seed, uint256(1) << 96, price);
        if (liquidityEstimate == 0 || liquidityEstimate > type(uint128).max / 2 / 1_774_545) {
            revert InvalidConfiguration();
        }
    }
}
