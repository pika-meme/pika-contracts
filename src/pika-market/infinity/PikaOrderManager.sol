// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { IHooks } from "infinity-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "infinity-core/src/interfaces/IPoolManager.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { LiquidityAmounts } from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { CLPoolParametersHelper } from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import { V3PriceMath } from "../../common/V3PriceMath.sol";
import { PikaVaultSettle } from "./PikaVaultSettle.sol";
import { IPikaLaunchToken, IPikaHook } from "../interfaces/IPikaMarket.sol";
import { PikaPermit } from "../../pika-launch/interfaces/IPikaLaunch.sol";

/// @notice Limit orders on a launch's Pancake Infinity pool. Each order owns a separate single-sided position in the
///         pool. A filled order pays the launch's outer fee for its direction when it is claimed. A sell pays both
///         fees in quote out of the quote it bought. A buy pays its project fee in meme out of the meme it bought and
///         its platform fee in quote: the platform fee is set aside from the quote deposited (`platformReserve`,
///         0.30% of it) when the order is placed, the rest works in the range, and on claim the fee on what the
///         range actually converted is taken from the reserve and the remainder returned. Only the owner can cancel.
/// @dev One owner per order. The manager is the locker that creates and removes order positions (salt = order id), so
///      it owns them in the pool manager and the hook admits only it. Launch pools charge no LP fee, so a closed
///      position returns principal only. Deployed as EIP-1167 clones of one implementation, one per launch, when the
///      launch graduates (the hub opens its pool); orders open once the pool trades.
///
///      Everything a clone needs besides its orders is fixed (2026-11-06): the vault, pool manager, hook and pool
///      parameters are implementation immutables (the deployer builds the implementation for one hook), and the launch
///      token and its quote are the clone's immutable arguments, so a graduation writes no manager state but the
///      quote allowance. An order is three slots; what a settled order pays out follows from them.
contract PikaOrderManager is ReentrancyGuardTransient, ILockCallback {
    using SafeERC20 for IERC20;
    using PikaVaultSettle for int128;
    using CLPoolParametersHelper for bytes32;

    uint256 public constant MIN_INPUT = 1_000_000;
    /// @notice The order model the indexer and API rely on (functions, events, `orders`). The 2026-11-06 storage
    ///         layout keeps it, so it stays 9.
    uint256 public constant ORDER_VERSION = 9;
    /// @dev Launch pools charge no LP fee (`PikaHook.POOL_FEE`).
    uint24 private constant POOL_FEE = 0;

    error InvalidConfiguration();
    error InvalidOrder();
    error InvalidState();
    error NotSingleSided();
    error NotFullyFilled();
    error InvalidMint();
    error NothingToClaim();
    error UnsupportedToken();
    error UnauthorizedOwner();
    error Expired();
    error SlippageExceeded();
    error NotVault();

    enum Status {
        None,
        Funding,
        Active,
        Settled,
        Cancelled
    }

    /// @notice An order as `orders` reports it: the fields the contract stored before 2026-11-06.
    struct Order {
        bool zeroForOne;
        int24 tickLower;
        int24 tickUpper;
        Status status;
        bool claimed;
        uint256 input;
        uint128 liquidity;
        uint256 inputUsed;
        /// @dev What a settled order pays out before the claim's fees; zero otherwise.
        uint256 payout0;
        uint256 payout1;
        /// @dev The bought amount (quote for a sell, meme for a buy) the claim fee is charged on.
        uint256 feeBasis;
        /// @dev A buy's platform fee reserve, set aside from `input` in quote; zero for a sell.
        uint256 reserve;
    }

    /// @dev An order in three slots. `input` and `reserve` are bounded at placement; pool amounts are int128.
    struct StoredOrder {
        address owner;
        bool zeroForOne;
        int24 tickLower;
        int24 tickUpper;
        Status status;
        bool claimed;
        uint128 input;
        uint128 reserve;
        /// @dev While the order is active, its position's liquidity; once it closed, the bought amount the claim fee
        ///      is charged on (`feeBasis`).
        uint128 liquidityOrFeeBasis;
        uint128 inputUsed;
    }

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    /// @notice The launch pools' hook, which this implementation's clones trade beside.
    address public immutable hook;
    bytes32 private immutable poolParameters;
    /// @dev The launch pools' tick spacing (50): an order's bounds sit on it.
    int24 private immutable tickSpacing;
    /// @dev The order deployer that built this implementation, the only caller of `initialize`.
    address private immutable deployer;
    address private immutable self;

    uint256 private orderCount;
    mapping(uint256 orderId => StoredOrder) private stored;

    /// @dev The order's range is in the event, so the indexer never reads `orders`. `input` is what the owner
    ///      deposited; `reserve` is the part of a buy's quote set aside for the platform fee (zero for a sell), so
    ///      `input - reserve` works in the range.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        uint256 input,
        uint256 reserve,
        bool zeroForOne,
        int24 tickLower,
        int24 tickUpper
    );
    event FundingCancelled(uint256 indexed orderId, address indexed owner, uint256 input);
    event OrderActivated(uint256 indexed orderId, uint128 liquidity, uint256 inputUsed);
    /// @dev `feeBasis` is the bought amount (quote for a sell, meme for a buy) charged the order fee on claim.
    event OrderSettled(uint256 indexed orderId, uint256 amount0, uint256 amount1, uint256 feeBasis);
    event OrderCancelled(uint256 indexed orderId, address indexed owner);
    event Claimed(
        uint256 indexed orderId, address indexed owner, address indexed recipient, uint256 amount0, uint256 amount1
    );

    constructor(IPikaHook hook_) {
        vault = hook_.vault();
        poolManager = hook_.poolManager();
        hook = address(hook_);
        bytes32 parameters = hook_.poolParameters();
        poolParameters = parameters;
        tickSpacing = parameters.getTickSpacing();
        deployer = msg.sender;
        self = address(this);
    }

    /// @notice Called once on each clone by the deployer, in the call that creates it: every fee paid in quote (a
    ///         sell's fees, a buy's platform fee) is pulled by the token on claim.
    function initialize() external {
        if (msg.sender != deployer || address(this) == self) revert InvalidConfiguration();
        (address base, address quote) = _assets();
        IERC20(quote).forceApprove(base, type(uint256).max);
    }

    /// @notice The launch token whose pool this manager serves.
    function token() public view returns (address base) {
        (base,) = _assets();
    }

    /// @dev The clone's immutable arguments: the launch token and its quote asset.
    function _assets() private view returns (address base, address quote) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        if (args.length != 40) revert InvalidConfiguration();
        assembly ("memory-safe") {
            base := shr(96, mload(add(args, 0x20)))
            quote := shr(96, mload(add(args, 0x34)))
        }
    }

    function poolKey() public view returns (PoolKey memory) {
        (address base, address quote) = _assets();
        return _key(base, quote);
    }

    /// @dev The launch pool's key for the clone's two assets (read once per entry, O-4).
    function _key(address base, address quote) private view returns (PoolKey memory) {
        (address c0, address c1) = base < quote ? (base, quote) : (quote, base);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(poolManager)),
            fee: POOL_FEE,
            parameters: poolParameters
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    function token0() public view returns (IERC20) {
        (address base, address quote) = _assets();
        return IERC20(base < quote ? base : quote);
    }

    function token1() public view returns (IERC20) {
        (address base, address quote) = _assets();
        return IERC20(base < quote ? quote : base);
    }

    /// @notice The id the next order will get; ids start at 1.
    function nextOrderId() external view returns (uint256) {
        return orderCount + 1;
    }

    function orderOwner(uint256 orderId) external view returns (address) {
        return stored[orderId].owner;
    }

    /// @notice An order in the fields the contract stored before 2026-11-06. A settled order's payouts are what it can claim before
    ///         fees: the bought amount and the unused input; other orders report none.
    function orders(uint256 orderId)
        external
        view
        returns (bool, int24, int24, Status, bool, uint256, uint128, uint256, uint256, uint256, uint256, uint256)
    {
        _returnOrder(orderId);
    }

    /// @dev Ends the call with the order's twelve fields. `Order` is twelve static fields, one clean word each, in the
    ///      order of `orders`' return values, so its memory is exactly their ABI encoding.
    function _returnOrder(uint256 orderId) private view {
        Order memory o = _view(stored[orderId]);
        assembly ("memory-safe") {
            return(o, 384)
        }
    }

    function _view(StoredOrder storage s) private view returns (Order memory o) {
        o.zeroForOne = s.zeroForOne;
        o.tickLower = s.tickLower;
        o.tickUpper = s.tickUpper;
        o.status = s.status;
        o.claimed = s.claimed;
        o.input = s.input;
        o.inputUsed = s.inputUsed;
        o.reserve = s.reserve;
        if (s.status == Status.Active) o.liquidity = s.liquidityOrFeeBasis;
        if (s.status == Status.Settled || s.status == Status.Cancelled) o.feeBasis = s.liquidityOrFeeBasis;
        if (s.status == Status.Settled) (o.payout0, o.payout1) = _settledPayouts(s);
    }

    /// @dev A settled order closed fully converted: it pays out what it bought and the input its position never
    ///      took.
    function _settledPayouts(StoredOrder storage s) private view returns (uint256 amount0, uint256 amount1) {
        uint256 bought = s.liquidityOrFeeBasis;
        uint256 unused = uint256(s.input) - s.reserve - s.inputUsed;
        return s.zeroForOne ? (unused, bought) : (bought, unused);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Placing and activating
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Allocate a fresh order even when its owner, direction and range match an existing order. The order
    ///         activates in the same transaction when the price already sits on the correct side of its range;
    ///         otherwise it waits funded until anyone calls `activate`.
    function placeOrder(bool zeroForOne, int24 tickLower, int24 tickUpper, uint256 amount)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        return _place(zeroForOne, tickLower, tickUpper, amount);
    }

    /// @notice Place a meme-funded order with an EIP-2612 signature for this manager, in one transaction.
    /// @dev A front-run permit only consumes the signature; the allowance it set is then used as usual.
    function placeOrderWithPermit(
        bool zeroForOne,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount,
        PikaPermit calldata permit
    ) external nonReentrant returns (uint256 orderId) {
        try IERC20Permit(address(zeroForOne ? token0() : token1()))
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) { }
            catch { }
        return _place(zeroForOne, tickLower, tickUpper, amount);
    }

    /// @dev The clone exists only once its pool trades (the hub creates it at graduation, right before opening
    ///      trading), so there is no phase to check.
    function _place(bool zeroForOne, int24 tickLower, int24 tickUpper, uint256 amount)
        private
        returns (uint256 orderId)
    {
        // Both bounds sit on the pool's tick spacing, strictly inside the usable range: its two ends belong to
        // full-range positions only (the hook refuses a narrow range there, audit 2026-11-02 M-1), and a bound off the
        // spacing could never be added to the pool.
        int24 spacing = tickSpacing;
        if (
            amount < MIN_INPUT || amount > type(uint128).max || tickLower >= tickUpper
                || tickLower <= TickMath.minUsableTick(spacing) || tickUpper >= TickMath.maxUsableTick(spacing)
                || tickLower % spacing != 0 || tickUpper % spacing != 0
        ) revert InvalidOrder();
        orderId = ++orderCount;
        StoredOrder storage created = stored[orderId];
        created.owner = msg.sender;
        created.zeroForOne = zeroForOne;
        created.tickLower = tickLower;
        created.tickUpper = tickUpper;
        created.status = Status.Funding;
        // Bounded above.
        // forge-lint: disable-next-line(unsafe-typecast)
        created.input = uint128(amount);
        (address base, address quote) = _assets();
        _deposit(created, orderId, amount, base, quote);
        PoolKey memory key = _key(base, quote);
        (uint160 spot, bool unlocked) = _spot(key);
        if (unlocked && _singleSided(zeroForOne, spot, tickLower, tickUpper)) _activate(orderId, created, key);
    }

    /// @dev Pulls the order's input. A buy deposits quote: the platform fee's reserve is set aside from it and the
    ///      rest works in the range.
    function _deposit(StoredOrder storage created, uint256 orderId, uint256 amount, address base, address quote)
        private
    {
        bool sell = created.zeroForOne == (base < quote);
        IERC20 input = IERC20(sell ? base : quote);
        uint256 reserve;
        if (!sell) {
            reserve = IPikaLaunchToken(base).platformReserve(amount);
            // At most the amount, which fits.
            // forge-lint: disable-next-line(unsafe-typecast)
            created.reserve = uint128(reserve);
        }
        uint256 beforeBalance = input.balanceOf(address(this));
        input.safeTransferFrom(msg.sender, address(this), amount);
        if (input.balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
        emit OrderPlaced(orderId, msg.sender, amount, reserve, created.zeroForOne, created.tickLower, created.tickUpper);
    }

    /// @notice Open this order's single-sided position. Anyone may activate a funded order.
    function activate(uint256 orderId) external nonReentrant returns (uint128 liquidity) {
        StoredOrder storage order = stored[orderId];
        if (order.status != Status.Funding) revert InvalidState();
        PoolKey memory key = poolKey();
        (uint160 spot, bool unlocked) = _spot(key);
        if (!unlocked || !_singleSided(order.zeroForOne, spot, order.tickLower, order.tickUpper)) {
            revert NotSingleSided();
        }
        return _activate(orderId, order, key);
    }

    function canActivate(uint256 orderId) external view returns (bool) {
        StoredOrder storage order = stored[orderId];
        if (order.status != Status.Funding) return false;
        (uint160 spot, bool unlocked) = _spot(poolKey());
        return unlocked && _singleSided(order.zeroForOne, spot, order.tickLower, order.tickUpper);
    }

    /// @dev Whether the pool price sits on the side of the range that leaves the order's input alone.
    function _singleSided(bool zeroForOne, uint160 spot, int24 tickLower, int24 tickUpper) private pure returns (bool) {
        return zeroForOne ? spot <= TickMath.getSqrtRatioAtTick(tickLower) : spot >= TickMath.getSqrtRatioAtTick(tickUpper);
    }

    function _activate(uint256 orderId, StoredOrder storage order, PoolKey memory key)
        private
        returns (uint128 liquidity)
    {
        order.status = Status.Active;
        bool zeroForOne = order.zeroForOne;
        uint256 totalInput = uint256(order.input) - order.reserve;
        uint160 lower = TickMath.getSqrtRatioAtTick(order.tickLower);
        uint160 upper = TickMath.getSqrtRatioAtTick(order.tickUpper);
        // The fees on the bought asset are paid on claim out of it, so the whole working input goes into the range.
        liquidity = zeroForOne
            ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, totalInput)
            : LiquidityAmounts.getLiquidityForAmount1(lower, upper, totalInput);
        if (liquidity == 0) revert InvalidMint();
        BalanceDelta delta = _modify(orderId, order, int256(uint256(liquidity)), key);
        if (delta.amount0() > 0 || delta.amount1() > 0) revert InvalidMint();
        uint256 used0 = delta.amount0().negative();
        uint256 used1 = delta.amount1().negative();
        uint256 used = zeroForOne ? used0 : used1;
        if (used == 0 || used > totalInput || (zeroForOne ? used1 : used0) != 0) revert InvalidMint();
        if (V3PriceMath.quote(used, zeroForOne ? lower : upper, zeroForOne, false) < 2) revert InvalidMint();
        order.liquidityOrFeeBasis = liquidity;
        // At most the input, which fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        order.inputUsed = uint128(used);
        emit OrderActivated(orderId, liquidity, used);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Cancelling
    // -------------------------------------------------------------------------------------------------------------

    /// @notice The owner can take a funded, not yet activated order back in full. `cancelOrder` does the same to a
    ///         recipient of the owner's choice.
    function cancelFunding(uint256 orderId) external nonReentrant returns (uint256 input) {
        StoredOrder storage order = stored[orderId];
        if (order.owner != msg.sender) revert UnauthorizedOwner();
        return _cancelFunding(orderId, order, msg.sender);
    }

    /// @notice Exit the caller's entire order at its current composition, with net payout protection. A funded order
    ///         that has not activated goes back in full, to `recipient` as well; an order someone already settled is
    ///         claimed.
    function cancelOrder(uint256 orderId, address recipient, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert Expired();
        StoredOrder storage order = stored[orderId];
        if (order.owner != msg.sender) revert UnauthorizedOwner();
        if (recipient == address(0) || recipient == address(this)) revert InvalidOrder();
        (amount0, amount1) = _cancel(orderId, order, recipient);
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();
    }

    function _cancelFunding(uint256 orderId, StoredOrder storage order, address recipient)
        private
        returns (uint256 input)
    {
        if (order.status != Status.Funding) revert InvalidState();
        input = order.input;
        order.status = Status.Cancelled;
        (order.zeroForOne ? token0() : token1()).safeTransfer(recipient, input);
        emit FundingCancelled(orderId, order.owner, input);
    }

    /// @dev `recipient` is the owner's choice through `cancelOrder`, where the owner is authenticated.
    function _cancel(uint256 orderId, StoredOrder storage order, address recipient)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        Status status = order.status;
        if (status == Status.Funding) {
            uint256 input = _cancelFunding(orderId, order, recipient);
            if (order.zeroForOne) amount0 = input;
            else amount1 = input;
        } else if (status == Status.Settled) {
            // Anyone may settle a filled order first; the owner's cancel then claims it (audit 2026-11-02, L-4).
            (amount0, amount1) = _settledPayouts(order);
            (amount0, amount1) = _claim(orderId, order, recipient, amount0, amount1);
        } else {
            (amount0, amount1) = _close(orderId, order, false);
            (amount0, amount1) = _claim(orderId, order, recipient, amount0, amount1);
            order.status = Status.Cancelled;
            emit OrderCancelled(orderId, order.owner);
        }
    }

    // -------------------------------------------------------------------------------------------------------------
    // Settling and claiming
    // -------------------------------------------------------------------------------------------------------------

    /// @notice Redeem a fully converted order; the owner can also cancel an incomplete order. Anyone may settle, so a
    ///         filled order's position cannot convert back when the price returns.
    /// @dev An incomplete conversion reverts the entire close.
    function settle(uint256 orderId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _close(orderId, stored[orderId], true);
    }

    /// @dev Removes the order's whole position into this contract. The pool charges no LP fee, so the removal returns
    ///      principal only: outside the range it is all the bought asset. Returns what the order pays out before the
    ///      claim's fees, the unused input included; only the bought amount (the fee basis) is kept, since a settled
    ///      order is fully converted and its payouts follow from it.
    function _close(uint256 orderId, StoredOrder storage order, bool requireFullFill)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        if (order.status != Status.Active) revert InvalidState();
        bool zeroForOne = order.zeroForOne;
        BalanceDelta delta = _modify(orderId, order, -int256(uint256(order.liquidityOrFeeBasis)), poolKey());
        amount0 = delta.amount0().positive();
        amount1 = delta.amount1().positive();
        if (requireFullFill && (zeroForOne ? amount0 : amount1) != 0) revert NotFullyFilled();
        // The fee is charged on what the order bought, in that asset; a pool delta always fits 128 bits.
        uint256 feeBasis = zeroForOne ? amount1 : amount0;
        uint256 unused = uint256(order.input) - order.reserve - order.inputUsed;
        if (zeroForOne) amount0 += unused;
        else amount1 += unused;
        order.status = Status.Settled;
        // forge-lint: disable-next-line(unsafe-typecast)
        order.liquidityOrFeeBasis = uint128(feeBasis);
        emit OrderSettled(orderId, amount0, amount1, feeBasis);
    }

    /// @notice Claim this order's principal and unused input, net of the fees on what it bought (a buy also gets the
    ///         unused part of its platform reserve back). A fully converted order that nobody has settled yet is
    ///         settled in the same transaction.
    function claim(uint256 orderId, address recipient)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        StoredOrder storage order = stored[orderId];
        if (order.owner != msg.sender) revert UnauthorizedOwner();
        if (order.status == Status.Active) (amount0, amount1) = _close(orderId, order, true);
        else (amount0, amount1) = _settledPayouts(order);
        return _claim(orderId, order, recipient, amount0, amount1);
    }

    /// @dev Pays a closed order's `amount0` / `amount1` out, less its fees. The caller has checked that the caller
    ///      owns the order.
    function _claim(uint256 orderId, StoredOrder storage order, address recipient, uint256 amount0, uint256 amount1)
        private
        returns (uint256, uint256)
    {
        if (order.status != Status.Settled || recipient == address(0) || recipient == address(this)) {
            revert InvalidState();
        }
        if (order.claimed) revert NothingToClaim();
        order.claimed = true;
        (address base, address quote) = _assets();
        bool memeIs0 = base < quote;
        (amount0, amount1) = _chargeFees(order, base, memeIs0, amount0, amount1);
        if (amount0 != 0) IERC20(memeIs0 ? base : quote).safeTransfer(recipient, amount0);
        if (amount1 != 0) IERC20(memeIs0 ? quote : base).safeTransfer(recipient, amount1);
        emit Claimed(orderId, order.owner, recipient, amount0, amount1);
        return (amount0, amount1);
    }

    /// @dev Takes the order's fees out of its payouts. A sell pays both fees in quote out of the quote it bought
    ///      (pulled by the token). A buy pays the project fee in meme out of the meme it bought and the platform fee in
    ///      quote out of its reserve, on the quote the range actually converted (the working input less what came
    ///      back); the rest of the reserve is the owner's.
    function _chargeFees(StoredOrder storage order, address base, bool memeIs0, uint256 amount0, uint256 amount1)
        private
        returns (uint256, uint256)
    {
        bool zeroForOne = order.zeroForOne;
        uint256 feeBasis = order.liquidityOrFeeBasis;
        if (zeroForOne == memeIs0) {
            uint256 fee = IPikaLaunchToken(base).chargeSellFee(order.owner, feeBasis, zeroForOne ? amount1 : amount0);
            return zeroForOne ? (amount0, amount1 - fee) : (amount0 - fee, amount1);
        }
        uint256 reserve = order.reserve;
        uint256 quoteSpent = uint256(order.input) - reserve - (zeroForOne ? amount0 : amount1);
        (uint256 platformFee, uint256 projectFee) = IPikaLaunchToken(base)
            .chargeBuyFees(order.owner, quoteSpent, feeBasis, reserve, zeroForOne ? amount1 : amount0);
        uint256 refund = reserve - platformFee;
        return zeroForOne ? (amount0 + refund, amount1 - projectFee) : (amount0 - projectFee, amount1 + refund);
    }

    // -------------------------------------------------------------------------------------------------------------
    // Pool
    // -------------------------------------------------------------------------------------------------------------

    /// @dev The pool's sqrt price and whether the vault is free to open or close positions right now.
    function _spot(PoolKey memory key) private view returns (uint160 spot, bool unlocked) {
        (spot,,,) = poolManager.getSlot0(key.toId());
        unlocked = vault.getLocker() == address(0);
    }

    /// @dev Runs one position change inside the vault lock and returns the position's balance delta. The key travels
    ///      in the lock data, so the callback does not read the clone's arguments again.
    function _modify(uint256 orderId, StoredOrder storage order, int256 liquidityDelta, PoolKey memory key)
        private
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            vault.lock(abi.encode(orderId, order.tickLower, order.tickUpper, liquidityDelta, key)), (BalanceDelta)
        );
    }

    /// @dev Opening settles the input from this contract's balance; closing takes the principal here. Nothing is
    ///      ever kept as a vault delta. Only this contract's own `lock` calls reach here (the vault calls back its
    ///      locker), so the key in the data is this contract's own.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (uint256 orderId, int24 lower, int24 upper, int256 liquidityDelta, PoolKey memory key) =
            abi.decode(data, (uint256, int24, int24, int256, PoolKey));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: bytes32(orderId)
            }),
            ""
        );
        PikaVaultSettle.settleOrTake(vault, key.currency0, delta.amount0(), address(this));
        PikaVaultSettle.settleOrTake(vault, key.currency1, delta.amount1(), address(this));
        return abi.encode(delta);
    }
}
