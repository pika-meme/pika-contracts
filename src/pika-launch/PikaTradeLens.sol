// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { PikaToken } from "./PikaToken.sol";
import { IOpenFourVault } from "../openfour/interfaces/IOpenFourVault.sol";
import { IOpenFourRegistry } from "../openfour/interfaces/IOpenFourRegistry.sol";
import { IOpenFourTools, TradeEstimate } from "../openfour/interfaces/IOpenFourTools.sol";
import { PikaLaunchFactory } from "./PikaLaunchFactory.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { PikaAppRegistry } from "../pika-apps/PikaAppRegistry.sol";
import { FeeSlot } from "../pika-apps/interfaces/IPikaApps.sol";

/// @notice Stateless trade quotes, balances and launch options for frontends that call eth_call on a
///         public RPC. It holds nothing and changes nothing.
/// @dev The web reads every quote, balance and allowance from here (web/src/lib/trade-lens.ts) and simulates the
///      transaction against the same block before handing it to the wallet; the server does not quote. A pool quote runs
///      the real swap inside a vault lock, exactly as the router would, and reverts out of the lock with the result,
///      so the pool's own math and the hook's fees all apply; `quote` is therefore not a `view`
///      function in the ABI, but it must always be sent as an eth_call.
interface IPikaLensCore {
    function registry() external view returns (address);
    function wrappedNative() external view returns (address);
}

/// @dev A Pika OpenFour module names the Core its launch was created on.
interface IPikaLensModule {
    function fourCore() external view returns (address);
}

contract PikaTradeLens is ILockCallback {
    /// @notice Interface generation required by the current component release.
    uint32 public constant FEE_PROTOCOL_VERSION = 4;

    uint8 public constant PHASE_INTERNAL = 1;
    uint8 public constant PHASE_EXTERNAL = 2;
    uint16 public constant MAX_SLIPPAGE_BPS = 5000;

    struct Quote {
        uint8 phase;
        address inputAsset; // address(0) is the native coin
        address outputAsset;
        uint256 inputBudget; // wallet funding/approval: the amount itself, nothing is charged on top
        uint256 spent;
        uint256 output;
        uint256 minimumOutput;
        uint256 refund;
        uint256 quoteFee;
        uint256 outerFee; // The outer fee taken out of the output: a buy's project fee (meme), a sell's platform plus project fee (quote).
        uint256 inputFee; // A buy's platform fee, taken out of its quote input and included in `spent`; zero on a sell.
        bool partialFill;
        uint160 sqrtPriceAfterX96; // Pool price after an external swap, otherwise 0.
    }

    struct AssetBalance {
        address asset; // address(0) is the native coin
        uint256 balance;
        address spender;
        uint256 allowance;
    }

    struct Balances {
        uint8 phase;
        uint256 native;
        AssetBalance meme;
        AssetBalance quote;
    }

    /// @notice Whether launches are open on a quote and the terms a creator does not choose.
    struct LaunchOptions {
        bool enabled;
        uint256 supply;
        uint256 maxApps;
        /// @dev The share of the supply a launch sells on the curve, in bps (the factory's `SALE_BPS`).
        uint16 saleBps;
        /// @dev The smallest graduation target the factory takes on this quote, in its smallest unit.
        uint256 minTarget;
    }

    /// @notice A launch's outer fee terms. The creator's wallet takes each fee's remainder after the slots.
    struct FeeInfo {
        uint256 platformFeeBps;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        address creatorFeeRecipient;
        FeeSlot[] slots;
    }

    /// @dev What a simulated Infinity swap is asked to do, and what it reports back by reverting out of the lock.
    struct Simulation {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 limit;
    }

    struct PoolSwap {
        uint256 spent;
        uint256 output;
        uint256 fee;
        uint160 sqrtPriceAfterX96;
    }

    error InvalidQuery();
    error WrongPhase();
    error QuoteUnavailable();
    error NotVault();
    /// @dev Carries a simulation's result out of the vault lock: `gross` is the pool's output before the hook fee,
    ///      `output` the net amount the trader would receive, `inputFee` what the hook took out of the input (a
    ///      buy's platform fee in quote).
    error Simulated(uint256 spent, uint256 gross, uint256 output, uint256 inputFee, uint160 sqrtPriceAfterX96);

    /// @notice Quote a trade of `amount` input. Before graduation the trade runs on OpenFour Core (a buy spends a
    ///         quote budget, `buyByBudget`) and the quote is OpenFour Tools' estimate for the caller; `quoteFee` is OpenFour's total fee. After graduation it is a router swap: the project
    ///         fee comes out of the output in both directions, a buy's platform fee out of the input.
    function quote(address token, bool sell, uint256 amount, uint16 slippageBps) external returns (Quote memory q) {
        if (amount == 0 || amount >= 1 << 127 || slippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidQuery();
        }
        PikaToken t = PikaToken(token);
        q.phase = _phase(t);
        if (q.phase == PHASE_INTERNAL) {
            if (sell) _curveSell(q, t, amount);
            else _curveBuy(q, t, amount);
        } else {
            _poolSwap(q, t, sell, amount);
        }
        if (q.output == 0) revert QuoteUnavailable();
        q.minimumOutput = _fee(q.output, 10_000 - slippageBps);
        q.partialFill = q.spent < amount;
    }

    /// @notice Balances of the assets a trade in the current phase spends, allowances for the launch's router, the
    ///         single trading entry in both phases.
    function balances(address token, address account) external view returns (Balances memory b) {
        PikaToken t = PikaToken(token);
        address spender;
        address quoteAsset;
        if (t.tradingStarted()) {
            b.phase = PHASE_EXTERNAL;
            spender = t.tradingRouter();
            quoteAsset = t.quoteAsset();
        } else {
            b.phase = PHASE_INTERNAL;
            spender = _core(t);
            quoteAsset = t.quoteAsset();
            // A WBNB curve trades native BNB through Core.
            if (quoteAsset == IPikaLensCore(spender).wrappedNative()) quoteAsset = address(0);
        }
        b.native = account.balance;
        b.meme = _asset(token, account, spender);
        b.quote = _asset(quoteAsset, account, spender);
    }

    /// @notice Whether the factory accepts launches for a quote token, the terms a creator does not choose and the
    ///         smallest target it takes on that quote.
    function launchOptions(address factory, address quoteToken) external view returns (LaunchOptions memory o) {
        PikaLaunchFactory f = PikaLaunchFactory(payable(factory));
        // BNB launches use WBNB on the curve.
        if (quoteToken == address(0)) quoteToken = IPikaLensCore(f.core()).wrappedNative();
        (bool quoteEnabled,, uint256 minTarget) = f.quoteConfigs(quoteToken);
        o.enabled = f.launchEnabled() && quoteEnabled;
        o.minTarget = minTarget;
        o.supply = f.defaultSupply();
        o.saleBps = f.SALE_BPS();
        o.maxApps = PikaAppRegistry(f.appRegistry()).maxApps();
    }

    function fees(address token) external view returns (FeeInfo memory f) {
        PikaToken t = PikaToken(token);
        f.platformFeeBps = t.PLATFORM_FEE_BPS();
        f.buyFeeBps = t.buyFeeBps();
        f.sellFeeBps = t.sellFeeBps();
        f.creatorFeeRecipient = t.creatorFeeRecipient();
        f.slots = t.feeSlots();
    }

    function _phase(PikaToken t) private view returns (uint8) {
        if (t.tradingStarted()) return PHASE_EXTERNAL;
        // Sold out: the curve is closed and the pool opens with Core's migration.
        if (IOpenFourVault(t.vault()).isSoldOut()) revert WrongPhase();
        return PHASE_INTERNAL;
    }

    function _tools(PikaToken t) private view returns (IOpenFourTools) {
        return IOpenFourTools(IOpenFourRegistry(IPikaLensCore(_core(t)).registry()).openFourTool());
    }

    /// @dev The Core the launch was created on (its migrate module's), which may be older than the hub's current one.
    function _core(PikaToken t) private view returns (address) {
        return IPikaLensModule(t.migrateModule()).fourCore();
    }

    function _curveSell(Quote memory q, PikaToken t, uint256 amount) private {
        TradeEstimate memory e = _tools(t).estimateSell(address(t), msg.sender, amount, 0, "");
        q.inputAsset = address(t);
        q.outputAsset = t.quoteAsset();
        q.inputBudget = amount;
        q.spent = e.tokenAmount;
        q.output = e.userReceives;
        q.quoteFee = e.totalFee;
    }

    function _curveBuy(Quote memory q, PikaToken t, uint256 amount) private {
        TradeEstimate memory e = _tools(t).estimateBuyByBudget(address(t), msg.sender, amount, 0, "");
        if (e.userPays == 0 || e.userPays > amount || e.tokenAmount == 0) revert QuoteUnavailable();
        q.inputAsset = t.quoteAsset();
        q.outputAsset = address(t);
        q.inputBudget = amount;
        q.spent = e.userPays;
        q.refund = amount - e.userPays;
        q.quoteFee = e.totalFee;
        q.output = e.tokenAmount;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Pool quotes: the swap runs for real inside a vault lock and is reverted
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Same flow as PikaRouter.swap: the output fee is taken out of the gross output inside the swap and a
    ///      buy's platform fee out of its input. The swap runs for real inside a vault lock and is then reverted, so
    ///      a partial fill (the pool running out of liquidity), the hook's fees and every pool rule are
    ///      reported exactly as they would execute. The pool's LP fee is zero by construction.
    function _poolSwap(Quote memory q, PikaToken t, bool sell, uint256 amount) private {
        (Simulation memory sim, address quoteAsset) = _simulation(t, sell, amount);
        uint256 gross;
        (q.spent, gross, q.output, q.inputFee, q.sqrtPriceAfterX96) = _simulate(t.hook().vault(), sim);
        q.outerFee = gross - q.output;
        q.inputBudget = amount;
        (q.inputAsset, q.outputAsset) = sell ? (address(t), quoteAsset) : (quoteAsset, address(t));
        q.refund = amount - q.spent;
    }

    /// @dev The swap to simulate: the launch pool, the direction, the input and the protocol price limit on that side.
    function _simulation(PikaToken t, bool sell, uint256 amount)
        private
        view
        returns (Simulation memory sim, address quoteAsset)
    {
        PoolKey memory key = t.poolKey();
        bool memeIs0 = t.memeIsCurrency0();
        quoteAsset = Currency.unwrap(memeIs0 ? key.currency1 : key.currency0);
        bool zeroForOne = sell == memeIs0;
        sim = Simulation(
            key, zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        );
    }

    /// @dev Runs the swap inside a lock and decodes the result it reverts with. Any other revert (dust that moves
    ///      nothing, a pool rule) means there is no quote.
    function _simulate(IVault vault, Simulation memory sim)
        private
        returns (uint256 spent, uint256 gross, uint256 output, uint256 inputFee, uint160 priceAfter)
    {
        try vault.lock(abi.encode(sim)) { }
        catch (bytes memory reason) {
            if (reason.length == 4 + 32 * 5 && bytes4(reason) == Simulated.selector) {
                assembly ("memory-safe") {
                    spent := mload(add(reason, 36))
                    gross := mload(add(reason, 68))
                    output := mload(add(reason, 100))
                    inputFee := mload(add(reason, 132))
                    priceAfter := mload(add(reason, 164))
                }
                if (spent != 0 && output != 0) return (spent, gross, output, inputFee, priceAfter);
            }
        }
        revert QuoteUnavailable();
    }

    /// @dev Exact-input swap; the hook takes the output fee from the gross output and a buy's platform fee from the
    ///      input. The net output stays as this contract's positive vault delta; any part that arrives as ERC20 is
    ///      counted too, so the result holds whichever way the hook delivers it. Everything is measured as a change
    ///      over the swap: this contract has no business holding tokens, but anyone can send it some, and a stale
    ///      balance must not count as output (audit 2026-10-31 M-1). The input fee is what the hook moved out of the
    ///      vault in the input asset (nothing is settled into it before the revert).
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        Simulation memory sim = abi.decode(data, (Simulation));
        ICLPoolManager manager = ICLPoolManager(address(sim.key.poolManager));
        if (address(manager.vault()) != msg.sender) revert NotVault();
        Balances4 memory b = _snapshot(sim, msg.sender);
        BalanceDelta delta = manager.swap(
            sim.key,
            ICLPoolManager.SwapParams({
                zeroForOne: sim.zeroForOne, amountSpecified: -int256(sim.amountIn), sqrtPriceLimitX96: sim.limit
            }),
            ""
        );
        // The swap's own delta is already net of the hook's deltas.
        (uint256 spent, uint256 kept) = _legs(sim.zeroForOne, delta);
        Balances4 memory a = _snapshot(sim, msg.sender);
        // Net: what stays as a delta plus what arrived as ERC20. Gross: what stays as a delta plus everything the
        // vault paid out (the fee to the token, and the net output when it was delivered as ERC20).
        uint256 output = kept + a.outHeld - b.outHeld;
        uint256 gross = kept + b.outVault - a.outVault;
        // A buy's platform fee left the vault for the token; on a partial fill the unused part of the hook's
        // reservation came back here as ERC20 and is not spent.
        uint256 returned = a.inHeld - b.inHeld;
        uint256 inputFee = b.inVault - a.inVault - returned;
        (uint160 priceAfter,,,) = manager.getSlot0(sim.key.toId());
        // The lock always ends in this revert, which carries the result out.
        revert Simulated(spent - returned, gross, output, inputFee, priceAfter);
    }

    /// @dev Both assets' balances of this contract and of the vault, around the simulated swap.
    struct Balances4 {
        uint256 inHeld;
        uint256 inVault;
        uint256 outHeld;
        uint256 outVault;
    }

    function _snapshot(Simulation memory sim, address vault) private view returns (Balances4 memory b) {
        IERC20 inAsset = IERC20(Currency.unwrap(sim.zeroForOne ? sim.key.currency0 : sim.key.currency1));
        IERC20 outAsset = IERC20(Currency.unwrap(sim.zeroForOne ? sim.key.currency1 : sim.key.currency0));
        b.inHeld = inAsset.balanceOf(address(this));
        b.inVault = inAsset.balanceOf(vault);
        b.outHeld = outAsset.balanceOf(address(this));
        b.outVault = outAsset.balanceOf(vault);
    }

    /// @dev The input the pool took and the output it credited, as magnitudes.
    function _legs(bool zeroForOne, BalanceDelta delta) private pure returns (uint256 spent, uint256 output) {
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // int128 magnitudes always fit in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        spent = inDelta < 0 ? uint256(uint128(-inDelta)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        output = outDelta > 0 ? uint256(uint128(outDelta)) : 0;
    }

    function _asset(address asset, address account, address spender) private view returns (AssetBalance memory a) {
        a.asset = asset;
        a.spender = spender;
        if (asset == address(0)) {
            a.balance = account.balance;
        } else {
            a.balance = IERC20(asset).balanceOf(account);
            a.allowance = IERC20(asset).allowance(account, spender);
        }
    }

    /// @dev Floor of value * bps / 10_000, as the server and token compute fees.
    function _fee(uint256 value, uint256 bps) private pure returns (uint256) {
        return Math.mulDiv(value, bps, 10_000);
    }
}
