// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { IHooks } from "infinity-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "infinity-core/src/interfaces/IPoolManager.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { OpenFourToken } from "../openfour/token/OpenFourToken.sol";
import { ERC20 } from "../openfour/oz/ERC20.sol";
import { IPikaHook, IPikaOrderBook, IPikaLaunchToken } from "../pika-market/interfaces/IPikaMarket.sol";
import { IPikaRouterContext, IPikaHub, PikaTokenParams } from "./interfaces/IPikaLaunch.sol";
import { FeeSlot, IPikaApp, IPikaHolderBook } from "../pika-apps/interfaces/IPikaApps.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PikaFeeMath } from "../common/libraries/PikaFeeMath.sol";

/// @notice Pika launch token on OpenFour: the same fixed-supply token trades on its OpenFour bonding curve (Core with
///         OpenFour's standard curve and vault) and then on its launch pool, a hooked Pancake Infinity pool. It is
///         not locked to that pool: like any ERC20 it may trade on any venue, but only the launch pool takes the
///         launch's fees.
/// @dev OpenFour Core clones this implementation (EIP-1167) and the Pika token module initializes the clone in the
///      creation transaction. The OpenFour part (`OpenFourToken`) keeps the standard getters Core, Tools and indexers
///      read; the Pika part registers the launch with the hub (`PikaLaunchFactory`) and stores what the hub pins for
///      it. The hub is the only account that moves the launch to the pool; there is no owner path of any kind.
///
///      Both outer fees are taken by the hook inside the launch pool's swap and handed here at once. The platform
///      fee is always quote: a buy pays it out of its quote input, a sell out of the pool's gross quote output. The
///      project fee follows the output: a buy pays it in meme out of the pool's gross meme output, a sell in quote
///      out of the gross quote output. Every outer fee is the platform fee plus the launch's project fee for that
///      direction; the platform takes `PROJECT_FEE_CUT_BPS` of the project fee as its cut (项目费抽成), the rest
///      goes to the launch's app slots by their shares and whatever they leave to the creator's wallet. A trade only
///      books; `pushFees` (anyone, run by the platform keeper) pays. Curve trades pay OpenFour's fees, not these.
///
///      A launch that bound the holder book (the dividend sink) reports every balance change to it (both parties
///      and their balances); who earns is the book's rule, the token answers `isPlatformAccount` as data for it.
contract PikaToken is OpenFourToken {
    using SafeERC20 for IERC20;

    /// @notice Interface generation required by the current component release.
    uint32 public constant FEE_PROTOCOL_VERSION = 5;

    /// @notice Platform share of every outer trade, both directions, always paid in the quote asset.
    uint256 public constant PLATFORM_FEE_BPS = PikaFeeMath.PLATFORM_FEE_BPS;
    /// @notice The platform's cut of the project fee (项目费抽成), in basis points of the project fee.
    uint256 public constant PROJECT_FEE_CUT_BPS = 1000;
    /// @notice Cap on platform plus project fee, per direction.
    uint256 public constant MAX_TOTAL_FEE_BPS = PikaFeeMath.MAX_TOTAL_FEE_BPS;
    /// @notice The default sinks (burn, dividend, liquidity) plus the apps the registry allows.
    uint256 public constant MAX_FEE_SLOTS = 6;
    /// @notice Launch pools charge no LP fee: both trade fees are the hook's.
    uint24 public constant POOL_FEE = 0;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    string private constant PERMIT_VERSION = "1";

    /// @notice The launch hub: registers the launch, graduates it and is the only account that opens its pool.
    address public immutable factory;
    IVault public immutable canonicalVault;
    ICLPoolManager public immutable poolManager;

    /// @dev One asset's fees awaiting distribution, in two slots: the platform part (quote only) and the project
    ///      fee's two parts. Every part is stored one above its amount once the asset booked anything, and a push
    ///      leaves it at one instead of zero, so the trades after a push rewrite warm nonzero slots rather than
    ///      initialize them again (about 17k gas a slot). `unpaid` reports the amounts. The project parts fit 128
    ///      bits: they never exceed the fees this token actually received.
    struct FeeBook {
        uint256 platform;
        uint128 cut;
        uint128 project;
    }

    // Slot read by the hook on every swap: the hook, the project fees and the phase.
    address private _hook;
    uint16 private _buyFeeBps;
    uint16 private _sellFeeBps;
    /// @notice Whether the launch pool is open (set at graduation).
    bool public tradingStarted;

    address private _quote;
    /// @notice When booked fees were last pushed; the pool's opening before the first push.
    uint64 public lastPushAt;
    address private _router;
    /// @notice When the pool opened; app periods count from here.
    uint64 public tradingStartedAt;
    address private _creatorFeeRecipient;
    address private _holderBook;
    /// @notice The launch's order manager, created with the pool at graduation.
    address public orderManager;
    /// @notice The address the creator fee wallet proposed as its successor; zero when none is pending.
    address public pendingCreatorFeeRecipient;
    /// @dev The launch pool's parameters (the hook's callbacks and tick spacing), copied from the hook at creation so
    ///      `poolKey` needs no call (O-3). The hook registers the pool under the same key at graduation.
    bytes32 private _poolParameters;
    /// @dev `keccak256(name())`, fixed at creation, for the EIP-712 domain (O-2).
    bytes32 private _nameHash;

    /// @dev The launch's own addresses that are not immutables: its outer components, OpenFour's Core, vault and
    ///      modules, the order manager and the fee slots. One read answers `isPlatformAccount` for any of them.
    mapping(address account => bool own) private own;
    /// @notice The creator's share of project fees pushed (and, in quote, of the raise at graduation) not yet
    ///         claimed, per asset.
    mapping(address asset => uint256) public creatorFees;
    /// @dev Fees not yet pushed, by asset (see `FeeBook`; `unpaid` reads it).
    mapping(address asset => FeeBook) private books;
    FeeSlot[] private slots;
    /// @notice EIP-2612 nonces.
    mapping(address owner => uint256) public nonces;

    error InvalidConfiguration();
    error UnauthorizedComponent();
    error NothingToClaim();
    error PermitExpired();
    error InvalidSignature();

    /// @notice The launch's Pika configuration, fixed at creation.
    event PikaLaunchConfigured(
        address indexed creator,
        address indexed quoteAsset,
        address creatorFeeRecipient,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        address holderBook
    );
    /// @notice The launch's order manager, created with its pool.
    event PoolConfigured(address indexed orders);
    event TradingActivated();
    /// @notice One fee charge (see the contract notes for the assets).
    event TradeFees(
        address indexed account, bool buy, uint256 value, uint256 platformFee, uint256 projectFeeCut, uint256 projectFee
    );
    /// @notice One push of an asset's booked fees.
    event FeesPushed(address indexed asset, uint256 platformFee, uint256 projectFeeCut, uint256 projectFee);
    /// @notice The push before a creator claim failed and was undone; the claim stood.
    event AutoPushFailed();
    event CreatorFeesClaimed(address indexed to, uint256 memeAmount, uint256 quoteAmount);
    /// @notice The creator fee wallet named `proposed` as its successor (zero withdraws a proposal).
    event CreatorFeeRecipientProposed(address indexed current, address indexed proposed);
    /// @notice The creator fee wallet changed: `current` accepted the proposal and claims from now on.
    event CreatorFeeRecipientChanged(address indexed previous, address indexed current);

    constructor(address factory_, IVault vault_, ICLPoolManager poolManager_) {
        if (
            factory_.code.length == 0 || address(vault_).code.length == 0 || address(poolManager_).code.length == 0
                || address(poolManager_.vault()) != address(vault_)
        ) revert InvalidConfiguration();
        factory = factory_;
        canonicalVault = vault_;
        poolManager = poolManager_;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Initialization (OpenFour token module, inside Core's createToken)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Run once by the Pika token module in Core's creation transaction. Registers the launch with the hub
    ///         (which binds the apps) before the supply is minted to OpenFour's vault, so the holder book sees the
    ///         mint.
    function initialize(InitArgs calldata c) external override initializer {
        _initPika(c);
        __OpenFourToken_init(c);
        _nameHash = keccak256(bytes(c.name));
    }

    function _initPika(InitArgs calldata c) private {
        if (c.quoteAsset == address(0) || c.quoteAsset == address(this) || c.creator == address(0)) {
            revert InvalidConfiguration();
        }
        PikaTokenParams memory p = abi.decode(c.tokenParams, (PikaTokenParams));
        // The fee wallet defaults to the creator (audit 2026-11-07, U-6); the hub and the apps see the resolved one.
        if (p.creatorFeeRecipient == address(0)) p.creatorFeeRecipient = c.creator;
        if (
            p.creatorFeeRecipient == address(this) || PLATFORM_FEE_BPS + p.buyFeeBps > MAX_TOTAL_FEE_BPS
                || PLATFORM_FEE_BPS + p.sellFeeBps > MAX_TOTAL_FEE_BPS
        ) revert InvalidConfiguration();
        // The apps read the quote while registering.
        _quote = c.quoteAsset;
        IPikaHub.Setup memory s = IPikaHub(factory)
            .registerLaunch(
                IPikaHub.Registration({ creator: c.creator, quoteAsset: c.quoteAsset, supply: c.maxSupply, params: p })
            );
        if (
            s.router.code.length == 0 || s.positionManager.code.length == 0 || s.hook.code.length == 0
                || address(IPikaHook(s.hook).vault()) != address(canonicalVault)
        ) revert InvalidConfiguration();
        _hook = s.hook;
        _poolParameters = IPikaHook(s.hook).poolParameters();
        _buyFeeBps = p.buyFeeBps;
        _sellFeeBps = p.sellFeeBps;
        _router = s.router;
        _creatorFeeRecipient = p.creatorFeeRecipient;
        _holderBook = s.holderBook;
        _bindSlots(s.slots, s.holderBook);
        own[s.router] = true;
        own[s.hook] = true;
        // Pancake's position manager holds meme only inside a transaction (positions sit in the vault).
        own[s.positionManager] = true;
        // OpenFour's components hold or move supply on the curve: never dividend holders.
        own[c.vault] = true;
        own[c.curveModule] = true;
        own[c.tradeModule] = true;
        own[c.migrateModule] = true;
        own[c.tokenModule] = true;
        if (c.customDataModule != address(0)) own[c.customDataModule] = true;
        // Core itself: the mock never holds supply, the real one is closed source, and whatever it may hold across a
        // transaction must not count as a dividend holder (review 2026-11-07c, T-4).
        own[IPikaHub(factory).core()] = true;
        emit PikaLaunchConfigured(
            c.creator, c.quoteAsset, p.creatorFeeRecipient, p.buyFeeBps, p.sellFeeBps, s.holderBook
        );
    }

    function _bindSlots(FeeSlot[] memory bound, address book) private {
        if (bound.length > MAX_FEE_SLOTS) revert InvalidConfiguration();
        uint256 buyShares;
        uint256 sellShares;
        bool bookBound;
        for (uint256 i; i < bound.length; ++i) {
            FeeSlot memory s = bound[i];
            if (s.target == address(0) || s.target == address(this) || s.target == address(canonicalVault)) {
                revert InvalidConfiguration();
            }
            buyShares += s.buyShareBps;
            sellShares += s.sellShareBps;
            if (s.holders) {
                if (bookBound || !s.notify || s.target != book) revert InvalidConfiguration();
                bookBound = true;
            }
            own[s.target] = true;
            slots.push(s);
        }
        if (buyShares > 10_000 || sellShares > 10_000 || (book != address(0) && !bookBound)) {
            revert InvalidConfiguration();
        }
    }

    function _descriptorTag() internal pure override returns (string memory) {
        return "token.pika";
    }

    // ---------------------------------------------------------------------------------------------------------
    // Launch configuration
    // ---------------------------------------------------------------------------------------------------------

    function hook() public view returns (IPikaHook) {
        return IPikaHook(_hook);
    }

    /// @notice The platform treasury, which takes the platform share of every outer fee: the hub's current one, so the
    ///         owner's replacement (`PikaLaunchFactory.proposeTreasury` / `acceptTreasury`) reaches every launch
    ///         (audit 2026-11-07, U-6).
    function treasury() public view returns (address) {
        return IPikaHub(factory).treasury();
    }

    function tradingRouter() external view returns (address) {
        return _router;
    }

    function creatorFeeRecipient() external view returns (address) {
        return _creatorFeeRecipient;
    }

    /// @notice The pool's other asset: the quote token (WBNB for a BNB launch). Every platform fee and every sell
    ///         fee is paid in it.
    function quoteAsset() public view returns (address) {
        return _quote;
    }

    /// @notice The dividend sink of this launch, told about every balance change; zero when none was bound.
    function holderBook() external view returns (address) {
        return _holderBook;
    }

    /// @notice Project fee per direction, on top of the platform fee; fixed at creation.
    function buyFeeBps() external view returns (uint16) {
        return _buyFeeBps;
    }

    function sellFeeBps() external view returns (uint16) {
        return _sellFeeBps;
    }

    function memeIsCurrency0() public view returns (bool) {
        return address(this) < _quote;
    }

    /// @notice The launch's Infinity pool key: the hook's key for this token and its quote, the one the hook
    ///         registers at graduation (`buildPoolKey`), built here from the parameters copied at creation.
    function poolKey() public view returns (PoolKey memory key) {
        address q = _quote;
        (address c0, address c1) = address(this) < q ? (address(this), q) : (q, address(this));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(_hook),
            poolManager: IPoolManager(address(poolManager)),
            fee: POOL_FEE,
            parameters: _poolParameters
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    /// @notice Fees not yet pushed in `asset`: the platform fee (quote only), the platform's cut of the project fee
    ///         and the project fee's rest for the slots and the creator.
    function unpaid(address asset) external view returns (uint256 platform, uint256 cut, uint256 project) {
        FeeBook storage b = books[asset];
        return (_amount(b.platform), _amount(b.cut), _amount(b.project));
    }

    /// @notice The project-fee receivers besides the creator's wallet, which takes the rest of each fee.
    function feeSlots() external view returns (FeeSlot[] memory) {
        return slots;
    }

    /// @notice The platform fee, in basis points; always paid in the quote asset.
    function platformFeeBps() external pure returns (uint16) {
        return uint16(PLATFORM_FEE_BPS);
    }

    /// @notice The fee a gross pool output carries, in basis points: the project fee on a buy's meme output, the
    ///         platform plus the project fee on a sell's quote output.
    function outputFeeBps(bool buy) public view returns (uint256) {
        return buy ? _buyFeeBps : PLATFORM_FEE_BPS + _sellFeeBps;
    }

    /// @notice The quote a component sets aside from a buy's quote budget for the platform fee.
    function platformReserve(uint256 quoteBudget) external pure returns (uint256) {
        return PikaFeeMath.reserve(quoteBudget, PLATFORM_FEE_BPS);
    }

    /// @notice What the hook's swap callbacks need, in one read.
    function swapTerms() external view returns (IPikaLaunchToken.SwapTerms memory t) {
        t.tradingStarted = tradingStarted;
        t.platformFeeBps = uint16(PLATFORM_FEE_BPS);
        t.buyFeeBps = _buyFeeBps;
        t.sellFeeBps = _sellFeeBps;
    }

    /// @notice What the router needs before a trade, in one read.
    struct RouterContext {
        bool tradingStarted;
        address router;
        address quoteAsset;
        bool memeIsCurrency0;
        PoolKey key;
    }

    function routerContext() external view returns (RouterContext memory c) {
        c.tradingStarted = tradingStarted;
        c.router = _router;
        c.quoteAsset = _quote;
        c.memeIsCurrency0 = address(this) < _quote;
        c.key = poolKey();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Graduation, driven by the hub
    // ---------------------------------------------------------------------------------------------------------

    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedComponent();
        _;
    }

    /// @notice Attach the order manager the hub created with the pool at graduation.
    function configureOuter(address orders_) external onlyFactory {
        if (
            orderManager != address(0) || orders_.code.length == 0 || IPikaOrderBook(orders_).token() != address(this)
        ) revert InvalidConfiguration();
        orderManager = orders_;
        own[orders_] = true;
        // The only platform account added after the supply exists. Its address is predictable, so it may already
        // hold tokens and shares: the book rereads it under the rules now that it is a platform account.
        address book = _holderBook;
        if (book != address(0) && balanceOf(orders_) != 0) IPikaHolderBook(book).refresh(address(this), orders_);
        emit PoolConfigured(orders_);
    }

    /// @notice Credit the creator fee wallet's share of the raise, which the hub moved here in the quote asset at
    ///         graduation; the wallet claims it with its other creator fees.
    function creditCreatorFees(uint256 amount) external onlyFactory {
        creatorFees[_quote] += amount;
    }

    /// @notice Open pool trading once the graduation position is in place.
    function openTrading() external onlyFactory {
        if (tradingStarted || orderManager == address(0)) revert InvalidConfiguration();
        tradingStarted = true;
        tradingStartedAt = uint64(block.timestamp);
        lastPushAt = uint64(block.timestamp);
        emit TradingActivated();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Fees: booked per pool trade, paid by `pushFees`
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Pays everything trades booked since the last push, in both assets. Open to anyone; trades never push.
    ///         `lastPushAt` moves only when something was paid (audit 2026-11-07, U-9).
    function pushFees() external {
        address q = _quote;
        bool paid = _push(address(this), true, q);
        if (_push(q, false, q)) paid = true;
        if (paid) lastPushAt = uint64(block.timestamp);
    }

    /// @notice Pays out everything accrued for the creator's fee wallet, in both assets, to `to`, after pushing the
    ///         booked fees. Anyone may push it to the wallet itself; only the wallet may name another receiver. A push
    ///         that fails does not block the claim (audit 2026-11-02, L-1).
    function claimCreatorFees(address to) external returns (uint256 memeAmount, uint256 quoteAmount) {
        address wallet = _creatorFeeRecipient;
        address q = _quote;
        if (to != wallet && msg.sender != wallet) revert UnauthorizedComponent();
        if (to == address(0) || to == address(this)) revert InvalidConfiguration();
        try this.pushFees() { }
        catch {
            emit AutoPushFailed();
        }
        memeAmount = creatorFees[address(this)];
        quoteAmount = creatorFees[q];
        if (memeAmount == 0 && quoteAmount == 0) revert NothingToClaim();
        creatorFees[address(this)] = 0;
        creatorFees[q] = 0;
        if (memeAmount != 0) _transfer(address(this), to, memeAmount);
        if (quoteAmount != 0) IERC20(q).safeTransfer(to, quoteAmount);
        emit CreatorFeesClaimed(to, memeAmount, quoteAmount);
    }

    /// @notice The creator fee wallet names its successor, which takes over when it accepts (two steps, so a typo
    ///         cannot strand the fees); zero withdraws a pending proposal. Only the current wallet may call this
    ///         (audit 2026-11-07, U-6: the wallet used to be fixed for the launch's life).
    function proposeCreatorFeeRecipient(address next) external {
        if (msg.sender != _creatorFeeRecipient) revert UnauthorizedComponent();
        // Not the token itself and none of the launch's own accounts, which never hold a wallet's share.
        if (next == address(this) || own[next] || next == address(canonicalVault)) revert InvalidConfiguration();
        pendingCreatorFeeRecipient = next;
        emit CreatorFeeRecipientProposed(msg.sender, next);
    }

    /// @notice The proposed wallet takes over: it claims every creator fee from now on, the accrued ones included.
    function acceptCreatorFeeRecipient() external {
        address next = pendingCreatorFeeRecipient;
        if (next == address(0) || msg.sender != next) revert UnauthorizedComponent();
        emit CreatorFeeRecipientChanged(_creatorFeeRecipient, next);
        _creatorFeeRecipient = next;
        pendingCreatorFeeRecipient = address(0);
    }

    /// @notice A filled sell order's fee (platform plus project), paid by the order manager in quote by allowance to
    ///         this token, on the `quoteBought` the order returned; at most `maxFee`.
    function chargeSellFee(address account, uint256 quoteBought, uint256 maxFee) external returns (uint256 fee) {
        _requireSettler();
        fee = PikaFeeMath.feeAt(quoteBought, outputFeeBps(false));
        if (fee > maxFee) fee = maxFee;
        if (fee != 0) IERC20(_quote).safeTransferFrom(msg.sender, address(this), fee);
        uint256 platform = _platformPart(fee, _sellFeeBps);
        _book(account, false, quoteBought, platform, fee - platform);
    }

    /// @notice A filled buy order's fees, paid by the order manager from what it holds.
    function chargeBuyFees(
        address account,
        uint256 quoteSpent,
        uint256 memeBought,
        uint256 maxPlatformFee,
        uint256 maxProjectFee
    ) external returns (uint256 platformFee, uint256 projectFee) {
        _requireSettler();
        platformFee = PikaFeeMath.feeOnNet(quoteSpent, PLATFORM_FEE_BPS);
        if (platformFee > maxPlatformFee) platformFee = maxPlatformFee;
        projectFee = PikaFeeMath.feeAt(memeBought, _buyFeeBps);
        if (projectFee > maxProjectFee) projectFee = maxProjectFee;
        if (platformFee != 0) IERC20(_quote).safeTransferFrom(msg.sender, address(this), platformFee);
        if (projectFee != 0) _transfer(msg.sender, address(this), projectFee);
        _book(account, true, memeBought, platformFee, projectFee);
    }

    function _requireSettler() private view {
        if (msg.sender != orderManager || !tradingStarted) {
            revert UnauthorizedComponent();
        }
    }

    /// @notice The hook moved one swap's fees into this contract; both are booked at once. The account is `sender`,
    ///         the locker of the swap, or the trader behind our router.
    function notifyPoolFee(address sender, bool buy, uint256 platformFee, uint256 projectFee, uint256 value) external {
        if (msg.sender != _hook) revert UnauthorizedComponent();
        _book(_trader(sender), buy, value, platformFee, projectFee);
    }

    function _trader(address party) private view returns (address account) {
        address r = _router;
        account = party == r ? IPikaRouterContext(r).trader() : party;
        if (account == address(0)) revert UnauthorizedComponent();
    }

    function _platformPart(uint256 fee, uint256 projectBps) private pure returns (uint256) {
        return fee * PLATFORM_FEE_BPS / (PLATFORM_FEE_BPS + projectBps);
    }

    function _book(address account, bool buy, uint256 value, uint256 platformFee, uint256 projectFee) private {
        if (platformFee == 0 && projectFee == 0) return;
        address q = _quote;
        uint256 cut = PikaFeeMath.feeAt(projectFee, PROJECT_FEE_CUT_BPS);
        uint256 project = projectFee - cut;
        if (platformFee != 0) {
            FeeBook storage qb = books[q];
            qb.platform = _plus(qb.platform, platformFee);
        }
        if (projectFee != 0) {
            FeeBook storage b = books[buy ? address(this) : q];
            (b.cut, b.project) = (_plus128(b.cut, cut), _plus128(b.project, project));
        }
        emit TradeFees(account, buy, value, platformFee, cut, project);
    }

    /// @dev A book part's amount: zero before the first booking, one below the stored value after it.
    function _amount(uint256 stored) private pure returns (uint256) {
        return stored == 0 ? 0 : stored - 1;
    }

    /// @dev A book part's stored value after adding `amount`.
    function _plus(uint256 stored, uint256 amount) private pure returns (uint256) {
        return (stored == 0 ? 1 : stored) + amount;
    }

    function _plus128(uint128 stored, uint256 amount) private pure returns (uint128) {
        return SafeCast.toUint128(_plus(stored, amount));
    }

    /// @dev Pays one asset's booked fees: the platform part and the cut to the treasury, the project part to the
    ///      slots by their shares and the rest to the creator's claimable share. The snapshot is cleared (each part
    ///      back to its zero marker) before any transfer or notification; any failure rolls the clearing and all
    ///      payouts back together. Returns whether anything was paid.
    function _push(address asset, bool buy, address q) private returns (bool) {
        FeeBook storage stored = books[asset];
        uint256 platform = _amount(stored.platform);
        uint256 cut = _amount(stored.cut);
        uint256 project = _amount(stored.project);
        if (platform == 0 && cut == 0 && project == 0) return false;
        if (platform != 0) stored.platform = 1;
        if (cut != 0 || project != 0) (stored.cut, stored.project) = (1, 1);
        if (platform + cut != 0) _pay(asset, treasury(), platform + cut, q);
        if (project != 0) {
            uint256 left = project;
            uint256 n = slots.length;
            for (uint256 i; i < n; ++i) {
                FeeSlot memory s = slots[i];
                uint256 amount = PikaFeeMath.feeAt(project, buy ? s.buyShareBps : s.sellShareBps);
                if (amount == 0) continue;
                left -= amount;
                _pay(asset, s.target, amount, q);
                if (s.notify) IPikaApp(s.target).onProjectFee(asset, buy, amount);
            }
            if (left != 0) creatorFees[asset] += left;
        }
        emit FeesPushed(asset, platform, cut, project);
        return true;
    }

    function _pay(address asset, address to, uint256 amount, address q) private {
        if (asset == address(this)) _transfer(address(this), to, amount);
        else IERC20(q).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Transfers: plain ERC20 moves, reported to the holder book
    // ---------------------------------------------------------------------------------------------------------

    /// @dev OpenFour's standard token refuses transfers to or from a listed pool before migration
    ///      (`_blocksBeforeMigration`). Pika has no venue lock and its migrate module never lists a pool, so that
    ///      check could never fire; skipping it saves its three storage reads (the phase and both `migratedPools`
    ///      entries) on every transfer (review 2026-11-07c, O-1). The phase and `migratedPools` themselves stay as
    ///      OpenFour's getters.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        ERC20._beforeTokenTransfer(from, to, amount);
    }

    /// @dev Balances and dividend shares stand or fall together (user decision, following Flap, 2026-11-03): a book
    ///      that reverts reverts the transfer too. The token only reports both parties and their balances; every
    ///      rule about who earns lives in the book. The launch's own accounts (`_isOwn`) never hold shares, so the
    ///      token reports a zero balance for them and skips the call when both parties are its own: the book then
    ///      needs no `isPlatformAccount` call on the hot path (audit 2026-11-07, O-1). The treasury is not among
    ///      them here (it is the hub's and may change); the book asks for it, which only happens on a push.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
        address book = _holderBook;
        if (book == address(0)) return;
        bool fromOwn = _isOwn(from);
        bool toOwn = _isOwn(to);
        if (fromOwn && toOwn) return;
        IPikaHolderBook(book).setShares(from, fromOwn ? 0 : balanceOf(from), to, toOwn ? 0 : balanceOf(to));
    }

    /// @dev The launch's own accounts, fixed for its life: the zero and burn addresses, the Infinity vault, the token
    ///      itself, the hub, the outer components, OpenFour's vault and modules, the app slots and the order manager.
    function _isOwn(address account) private view returns (bool) {
        return account == address(0) || account == DEAD || account == address(canonicalVault)
            || account == address(this) || account == factory || own[account];
    }

    /// @notice Whether `account` is one of the launch's platform accounts: the zero and burn addresses, the Infinity
    ///         vault, the hub and treasury, the outer components, OpenFour's vault and modules and the app slots.
    /// @dev The treasury is the hub's current one, read last so the launch's own accounts never pay for the call. A
    ///      treasury change does not move dividend shares by itself: the book rereads an account's balance on its
    ///      next transfer or on anyone's `refresh`.
    function isPlatformAccount(address account) external view returns (bool) {
        return _isOwn(account) || account == treasury();
    }

    // ---------------------------------------------------------------------------------------------------------
    // EIP-2612 permit and its ERC-5267 domain
    // ---------------------------------------------------------------------------------------------------------

    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, _nameHash, keccak256(bytes(PERMIT_VERSION)), block.chainid, address(this))
        );
    }

    /// @notice ERC-5267: the EIP-712 domain `permit` signs under, so wallets and front ends read it instead of
    ///         guessing it. Fields 0x0f: name, version, chain id and this token; no salt, no extensions. The name is
    ///         fixed at creation, so the domain never changes (no `EIP712DomainChanged`).
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", name(), PERMIT_VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (ECDSA.recover(digest, v, r, s) != owner) revert InvalidSignature();
        _approve(owner, spender, value);
    }
}
