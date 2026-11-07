// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TransientSlot } from "@openzeppelin/contracts/utils/TransientSlot.sol";
import { ICLHooks } from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { IPoolManager } from "infinity-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "infinity-core/src/interfaces/IHooks.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "infinity-core/src/types/BeforeSwapDelta.sol";
import { CLPoolParametersHelper } from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { PikaFactoryBound } from "../PikaFactoryBound.sol";
import { PikaFeeMath } from "../../common/libraries/PikaFeeMath.sol";
import { IPikaLaunchToken, IPikaHook } from "../interfaces/IPikaMarket.sol";

/// @notice The hook of every Pika pool on Pancake Infinity, shared by all launches of one factory.
/// @dev It decides who may initialize a launch pool and which ranges liquidity may take, and it takes both trade fees
///      inside the swap. The pool charges no LP fee, so a concentrated position earns nothing and is only ever a
///      limit order: such positions come from the launch's order manager alone, where a fill pays the launch's fee on
///      claim (audit 2026-11-07, U-1). Full-range positions are open to everyone (Pancake's position manager or any
///      vault locker): they are two-sided at every price, so they cannot stand in for an order. Removing is open to
///      every position's owner. Pika has no price limits and no venue lock:
///      the token trades on any pool, any locker may swap on the launch pool, and meme crosses the vault boundary as
///      a plain ERC20. Every fee is
///      taken from the swap's own deltas, never on the ERC20 boundary, so a locker that keeps its meme inside the
///      vault (a router hopping into another pool) still pays it. The platform fee is always quote: a buy pays it
///      out of its quote input (reserved on the specified side before an exact-input swap, charged on the
///      unspecified side after an exact-output one), a sell out of the pool's gross quote output. The project fee
///      follows the output: a buy pays it in meme out of the pool's gross meme output, a sell in quote together with
///      the platform fee. Hook deltas settle themselves inside the callbacks through `vault.take`; the pool manager
///      books the matching credit when the callback returns. The token's fee rates are read once per swap, before
///      it, and kept in transient storage for the callback after it.
contract PikaHook is ICLHooks, PikaFactoryBound, IPikaHook {
    using TransientSlot for *;
    using CLPoolParametersHelper for bytes32;

    /// @notice Interface generation required by the current component release.
    uint32 public constant FEE_PROTOCOL_VERSION = 5;

    uint24 public constant POOL_FEE = 0;
    /// @dev Position bounds step by 50 ticks (about 0.5% in price); prices themselves move freely.
    int24 public constant TICK_SPACING = 50;
    /// @notice The full range at this spacing: the outermost ticks a position can use (+-887250).
    int24 public constant MIN_USABLE_TICK = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
    int24 public constant MAX_USABLE_TICK = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

    IVault public immutable override vault;
    ICLPoolManager public immutable override poolManager;

    enum PoolState {
        None,
        Registered,
        Initialized
    }

    /// @dev A launch pool's other currency and state, in one slot. The key is everything else fixed by this hook
    ///      (`buildPoolKey`), so it is rebuilt rather than stored.
    struct Pool {
        address quote;
        PoolState state;
    }

    mapping(address token => Pool pool) private pools;
    mapping(PoolId id => address token) public override poolToken;
    bytes32 private constant PENDING_FEE_TAG = keccak256("pika.hook.pendingFee");
    bytes32 private constant TERMS_TAG = keccak256("pika.hook.terms");

    error InvalidConfiguration();
    error NotPoolManager();
    error UnknownPool();
    error TradingNotStarted();
    error UnauthorizedSender(address sender);
    error InvalidRange();
    error UnsupportedSwap();
    error DonationsDisabled();
    error AmountOverflow();
    error ZeroSwap();

    event PoolRegistered(address indexed token, PoolId indexed id, PoolKey key);

    constructor(IVault vault_, ICLPoolManager poolManager_) {
        if (
            address(vault_).code.length == 0 || address(poolManager_).code.length == 0
                || address(poolManager_.vault()) != address(vault_)
        ) revert InvalidConfiguration();
        vault = vault_;
        poolManager = poolManager_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return _bitmap();
    }

    function _bitmap() private pure returns (uint16) {
        return uint16(
            (1 << HOOKS_BEFORE_INITIALIZE_OFFSET) | (1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET)
                | (1 << HOOKS_BEFORE_SWAP_OFFSET) | (1 << HOOKS_AFTER_SWAP_OFFSET) | (1 << HOOKS_BEFORE_DONATE_OFFSET)
                | (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) | (1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET)
        );
    }

    /// @notice The pool parameters every Pika pool uses: this hook's callbacks and a tick spacing of 50.
    function poolParameters() public pure returns (bytes32) {
        return bytes32(uint256(_bitmap())).setTickSpacing(TICK_SPACING);
    }

    function buildPoolKey(address token, address quoteAsset) public view override returns (PoolKey memory key) {
        if (token == quoteAsset || token == address(0) || quoteAsset == address(0)) revert InvalidConfiguration();
        (address c0, address c1) = token < quoteAsset ? (token, quoteAsset) : (quoteAsset, token);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(this)),
            poolManager: IPoolManager(address(poolManager)),
            fee: POOL_FEE,
            parameters: poolParameters()
        });
    }

    function poolState(address token) external view returns (PoolState) {
        return pools[token].state;
    }

    function poolKey(address token) external view override returns (PoolKey memory) {
        Pool memory p = pools[token];
        if (p.state == PoolState.None) revert UnknownPool();
        return buildPoolKey(token, p.quote);
    }

    /// @notice The factory registers a launch pool right before initializing it and gets its key back: the hook is
    ///         the one place a launch pool's key comes from (`buildPoolKey`, which the token's `poolKey` also asks).
    ///         A launch's quote is an ERC20 (WBNB for BNB), never the native currency zero. Keys are immutable
    ///         afterwards.
    function registerPool(address token, address quote) external override returns (PoolKey memory key) {
        _requireFactory();
        if (pools[token].state != PoolState.None) revert InvalidConfiguration();
        key = buildPoolKey(token, quote);
        PoolId id = key.toId();
        if (poolToken[id] != address(0)) revert InvalidConfiguration();
        pools[token] = Pool(quote, PoolState.Registered);
        poolToken[id] = token;
        emit PoolRegistered(token, id, key);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Pool manager callbacks
    // ---------------------------------------------------------------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        address token = poolToken[key.toId()];
        if (token == address(0) || sender != factory || pools[token].state != PoolState.Registered) {
            revert UnauthorizedSender(sender);
        }
        pools[token].state = PoolState.Initialized;
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert InvalidConfiguration();
    }

    /// @dev Full-range positions are open to anyone, at any time (the hub's graduation position and the liquidity
    ///      sink's top-ups are minted this way, through Pancake's position manager). Any other range may only come from
    ///      the launch's order manager, the locker of every limit order, which charges the launch's fee when the order
    ///      is claimed: on a pool without an LP fee a concentrated position is nothing but a limit order, and one added
    ///      from anywhere else would be a fee-free one (audit 2026-11-07, U-1). The order manager exists only once the
    ///      launch graduated, so nothing else is added before trading starts. A position that touches either end of
    ///      the usable tick range (`MIN_USABLE_TICK`, `MAX_USABLE_TICK`) must span all of it: a few wei in a narrow
    ///      range at either end would otherwise fill that tick's liquidity cap and stop every later full-range position,
    ///      while filling the cap with full-range liquidity would take millions of times the pool's reserves. Removing
    ///      is not hooked: a position's owner may always take it out, and nobody owns the burned ones.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        // A bound off the spacing (any tick past a usable end is) reverts in the pool manager after this callback.
        bool low = params.tickLower == MIN_USABLE_TICK;
        bool high = params.tickUpper == MAX_USABLE_TICK;
        if (low != high) revert InvalidRange();
        // `sender` is the locker that called `modifyLiquidity`: the order manager itself for an order, Pancake's
        // position manager for an LP NFT. Zero before graduation, when no order manager exists yet.
        if (!low && sender != _token(key).orderManager()) revert UnauthorizedSender(sender);
        return this.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert InvalidConfiguration();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert InvalidConfiguration();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert InvalidConfiguration();
    }

    /// @dev The token's fee rates, read once before the swap and kept for the callback after it in one transient
    ///      word.
    struct Terms {
        uint256 platformBps;
        uint256 buyBps;
        uint256 sellBps;
    }

    /// @dev Fees that must be known before the pool swaps are reserved here as a hook delta on the specified side.
    ///      An exact-input buy reserves the platform fee out of its quote input: the pool swaps the rest. An
    ///      exact-output trade asks for a net output, so the pool is told to give out the requested amount plus the
    ///      fee that output carries (a sell's whole fee in quote, a buy's project fee in meme) and the trader pays the
    ///      other asset for both; a buy's platform fee is then charged on that other asset after the swap.
    ///      Exact-input sells pay out of the output after the swap.
    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address token = poolToken[key.toId()];
        IPikaLaunchToken.SwapTerms memory terms = IPikaLaunchToken(token).swapTerms();
        if (!terms.tradingStarted) revert TradingNotStarted();
        address locker = vault.getLocker();
        _storeTerms(token, locker, terms);
        // Registration already fixed the token to this key; its side follows from the callback's currencies.
        bool memeIn = params.zeroForOne == (token == Currency.unwrap(key.currency0));
        if (params.amountSpecified < 0 && memeIn) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _reservation(params, memeIn, terms);
        if (fee > uint256(uint128(type(int128).max))) revert AmountOverflow();
        _slot(PENDING_FEE_TAG, token, locker).asUint256().tstore(fee);
        // Bounded above by the AmountOverflow check.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @dev The fee reserved on the specified side: an exact-input buy's platform fee out of its quote input (the
    ///      pool swaps the rest), an exact-output trade's fee on top of the output it asks for.
    function _reservation(
        ICLPoolManager.SwapParams calldata params,
        bool memeIn,
        IPikaLaunchToken.SwapTerms memory terms
    ) private pure returns (uint256) {
        if (params.amountSpecified < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return PikaFeeMath.feeAt(uint256(-params.amountSpecified), terms.platformFeeBps);
        }
        uint256 bps = memeIn ? terms.platformFeeBps + terms.sellFeeBps : terms.buyFeeBps;
        // forge-lint: disable-next-line(unsafe-typecast)
        return PikaFeeMath.feeOnNet(uint256(params.amountSpecified), bps);
    }

    /// @dev What one swap's callbacks share, kept in memory to stay within the stack limit.
    struct Swap {
        address token;
        IPikaLaunchToken t;
        address sender;
        /// @dev The locker holding the vault lock; the swap's transient state is scoped to it.
        address locker;
        bool memeIs0;
        /// @dev Whether meme is the input (a sell) or the output (a buy).
        bool memeIn;
        bool exactInput;
        /// @dev The amount the swap specified: the net output asked for, or the input offered.
        uint256 specified;
        Terms terms;
        Currency meme;
        Currency quote;
        /// @dev The pool's own deltas, before any hook delta: the gross output it gave and the input it took.
        uint256 gross;
        uint256 taken;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // A swap that moved nothing on either side (dust input whose net or output rounds to zero) is refused:
        // the pool would still emit a Swap of zeros, and nobody should be able to produce one for a fee of 0.
        if (delta.amount0() == 0 || delta.amount1() == 0) revert ZeroSwap();
        Swap memory w;
        w.token = poolToken[key.toId()];
        w.t = IPikaLaunchToken(w.token);
        w.sender = sender;
        // Transient state is scoped to the locker holding the vault lock; read once per swap.
        w.locker = vault.getLocker();
        w.memeIs0 = w.token == Currency.unwrap(key.currency0);
        w.memeIn = params.zeroForOne == w.memeIs0;
        w.exactInput = params.amountSpecified < 0;
        // An int256 magnitude from the pool manager always fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.specified = uint256(w.exactInput ? -params.amountSpecified : params.amountSpecified);
        w.terms = _loadTerms(w.token, w.locker);
        (w.meme, w.quote) = w.memeIs0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 memeDelta, int128 quoteDelta) =
            w.memeIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // An int128 pool delta is at most 2^127 in magnitude, so the casts cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.gross = uint256(uint128(w.memeIn ? quoteDelta : memeDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        w.taken = uint256(uint128(-(w.memeIn ? memeDelta : quoteDelta)));
        int128 hookDelta = w.memeIn ? _afterSell(w) : _afterBuy(w);
        return (this.afterSwap.selector, hookDelta);
    }

    /// @dev A sell: the pool received meme and gave out quote. Both fees come out of the quote output, in quote.
    function _afterSell(Swap memory w) private returns (int128 hookDelta) {
        uint256 fee;
        if (w.exactInput) {
            // Exact input: the fee is carved out of the quote output here and credited to the hook; the locker's
            // quote delta is already net. A partial fill (a price limit or the pool running dry) pays on what the
            // pool actually gave out.
            fee = PikaFeeMath.feeAt(w.gross, w.terms.platformBps + w.terms.sellBps);
            // Smaller than the gross output, which is an int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            hookDelta = int128(uint128(fee));
        } else {
            // Exact output: the reserved fee was added to the pool output and is already the hook's. A partial fill
            // pays the fee on what the pool actually gave; the rest of the reservation goes back to the locker.
            fee = _settleReserved(w, w.quote, w.terms.platformBps + w.terms.sellBps);
        }
        uint256 platform = Math.min(PikaFeeMath.feeAt(w.gross, w.terms.platformBps), fee);
        _take(w.t, w.quote, fee);
        w.t.notifyPoolFee(w.sender, false, platform, fee - platform, w.gross);
    }

    /// @dev A buy: the pool gave out meme for quote. The project fee comes out of the gross meme output, in meme. The
    ///      platform fee is quote: reserved out of the input before an exact-input swap (settled here on what the
    ///      pool actually took), charged on top of the input after an exact-output one.
    function _afterBuy(Swap memory w) private returns (int128 hookDelta) {
        uint256 platform;
        uint256 project;
        if (w.exactInput) {
            // The platform fee was reserved out of the input: a full fill (the pool took the whole rest) pays
            // exactly the reservation, a partial fill pays on what the pool took and returns the rest to the locker.
            platform = _settleReservedInput(w);
            // The project fee is carved out of the output here and credited to the hook, so the locker's delta is
            // already net.
            project = PikaFeeMath.feeAt(w.gross, w.terms.buyBps);
            // Smaller than the gross output, which is an int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            hookDelta = int128(uint128(project));
        } else {
            // Exact output: the reserved project fee was added to the pool output and is already the hook's. A
            // partial fill (a price limit or the pool running dry) pays the fee on what the pool actually gave; the
            // rest of the reservation goes back to the locker as ERC20. The platform fee is charged on top of the
            // quote the pool took, as the hook's delta on that side.
            project = _settleReserved(w, w.meme, w.terms.buyBps);
            platform = PikaFeeMath.feeOnNet(w.taken, w.terms.platformBps);
            if (platform > uint256(uint128(type(int128).max))) revert AmountOverflow();
            // Bounded above.
            // forge-lint: disable-next-line(unsafe-typecast)
            hookDelta = int128(uint128(platform));
        }
        _take(w.t, w.quote, platform);
        _take(w.t, w.meme, project);
        w.t.notifyPoolFee(w.sender, true, platform, project, w.gross);
    }

    /// @dev An exact-output swap reserved the fee its output carries in `beforeSwap`, on top of the requested
    ///      output. A full fill pays exactly the reservation; a partial fill pays `bps` on the gross output and
    ///      returns the rest of the reservation to the locker as ERC20. Returns the fee, which is the hook's to
    ///      move.
    function _settleReserved(Swap memory w, Currency asset, uint256 bps) private returns (uint256 fee) {
        uint256 reserved = _takeReservation(w);
        if (w.gross < reserved) revert UnsupportedSwap();
        fee = w.gross == w.specified + reserved ? reserved : Math.min(PikaFeeMath.feeAt(w.gross, bps), reserved);
        if (reserved > fee) vault.take(asset, w.sender, reserved - fee);
    }

    /// @dev An exact-input buy reserved its platform fee out of the quote input in `beforeSwap`; the pool swapped
    ///      the rest. A full fill (the pool took all of the rest) pays exactly the reservation; a partial fill pays
    ///      the platform fee on top of what the pool took and returns the rest of the reservation to the locker as
    ///      ERC20. Returns the fee, which is the hook's to move.
    function _settleReservedInput(Swap memory w) private returns (uint256 fee) {
        uint256 reserved = _takeReservation(w);
        fee = w.taken == w.specified - reserved
            ? reserved
            : Math.min(PikaFeeMath.feeOnNet(w.taken, w.terms.platformBps), reserved);
        if (reserved > fee) vault.take(w.quote, w.sender, reserved - fee);
    }

    function _takeReservation(Swap memory w) private returns (uint256 reserved) {
        bytes32 pending = _slot(PENDING_FEE_TAG, w.token, w.locker);
        reserved = pending.asUint256().tload();
        pending.asUint256().tstore(0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert DonationsDisabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert DonationsDisabled();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Moves a fee out of the vault into the token: a buy's project fee out of the gross meme output, a platform
    ///      fee or a sell's fee in quote. The token books it on
    ///      `notifyPoolFee`.
    function _take(IPikaLaunchToken t, Currency asset, uint256 fee) private {
        if (fee != 0) vault.take(asset, address(t), fee);
    }

    /// @dev The token's fee rates are read once, before the swap, and kept for the callback after it in one
    ///      transient word per token and locker: platform, buy and sell rates (16 bits each).
    function _storeTerms(address token, address locker, IPikaLaunchToken.SwapTerms memory t) private {
        uint256 word = uint256(t.platformFeeBps) | (uint256(t.buyFeeBps) << 16) | (uint256(t.sellFeeBps) << 32);
        _slot(TERMS_TAG, token, locker).asUint256().tstore(word);
    }

    function _loadTerms(address token, address locker) private view returns (Terms memory t) {
        uint256 word = _slot(TERMS_TAG, token, locker).asUint256().tload();
        t.platformBps = word & 0xffff;
        t.buyBps = (word >> 16) & 0xffff;
        t.sellBps = (word >> 32) & 0xffff;
    }

    function _token(PoolKey calldata key) private view returns (IPikaLaunchToken t) {
        address token = poolToken[key.toId()];
        if (token == address(0)) revert UnknownPool();
        t = IPikaLaunchToken(token);
    }

    /// @dev Transient state is scoped to the token and to the locker holding the vault lock.
    function _slot(bytes32 tag, address token, address locker) private pure returns (bytes32) {
        return keccak256(abi.encode(tag, token, locker));
    }
}
