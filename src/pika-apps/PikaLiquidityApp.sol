// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PikaSinkBase } from "./PikaSinkBase.sol";
import { PikaBurnedLiquidity } from "../common/libraries/PikaBurnedLiquidity.sol";
import { IPikaLaunchToken, IPikaPositionManager } from "../pika-market/interfaces/IPikaMarket.sol";

/// @notice "增加流动性": the liquidity sink. Project fees accumulate here and a keeper adds them to the launch pool
///         as full-range liquidity minted to the burn address, so they can never leave the pool.
/// @dev A buy fee is meme and a sell fee is quote, while a full-range position wants both at the current price.
///      Before adding, the dispatch sells meme or buys it on the launch's own pool so that the two sides are worth
///      about the same, then mints a full-range Pancake LP NFT to the burn address with as much as they fund (an
///      NFT owned by the burn address cannot be topped up, so every dispatch mints its own). The swap pays the
///      outer fee like any trade (the router fills it in full or reverts); what the position could not take waits
///      for the next dispatch.
contract PikaLiquidityApp is PikaSinkBase {
    using SafeERC20 for IERC20;

    bytes32 public constant KEY = "liquidity";
    uint16 public constant VERSION = 4;
    uint256 private constant Q96 = 2 ** 96;

    /// @notice Pancake's official CL position manager, which mints the burned positions.
    IPikaPositionManager public immutable positionManager;

    /// @dev `liquidity` is the new burned position's; the amounts are what it took (`positionId` is the LP NFT,
    ///      owned by the burn address).
    event LiquidityAdded(
        address indexed token, uint128 liquidity, uint256 memeAdded, uint256 quoteAdded, uint256 positionId
    );

    constructor(address registry_, address positionManager_) PikaSinkBase(registry_) {
        if (positionManager_.code.length == 0) revert InvalidParams();
        positionManager = IPikaPositionManager(positionManager_);
    }

    function templateKey() external pure returns (bytes32) {
        return KEY;
    }

    function version() external pure virtual returns (uint16) {
        return VERSION;
    }

    error PriceOutOfRange(uint160 price, uint160 lower, uint160 upper);
    error Expired();

    struct Dispatch {
        address token;
        uint256 memeMax;
        uint256 quoteMax;
        uint256 swapMinOut;
        uint160 sqrtPriceMinX96;
        uint160 sqrtPriceMaxX96;
    }

    struct Budget {
        uint256 meme;
        uint256 quote;
    }

    /// @notice Add what this sink holds for the launch to the pool as burned full-range liquidity, balancing the two
    ///         sides on the pool first. Keeper-only: `swapMinOut` guards the balancing swap (ignored when none is
    ///         needed) and the pool price must sit inside [`sqrtPriceMinX96`, `sqrtPriceMaxX96`] both before the swap
    ///         and when the position is minted, so a sandwiched dispatch cannot add liquidity at a pushed price. The
    ///         deadline applies even when the two sides are already balanced and no swap is needed.
    function addLiquidity(
        address token,
        uint256 swapMinOut,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96,
        uint256 deadline
    ) external nonReentrant returns (uint128 liquidity, uint256 memeAdded, uint256 quoteAdded) {
        return _addLiquidity(
            Dispatch(token, type(uint256).max, type(uint256).max, swapMinOut, sqrtPriceMinX96, sqrtPriceMaxX96),
            deadline
        );
    }

    /// @notice Uses at most the two supplied budgets. Fees arriving after preparation stay pending; only the
    ///         selected funds and what their balancing swap returns can enter the burned position.
    function addLiquidityLimited(Dispatch calldata d, uint256 deadline)
        external
        nonReentrant
        returns (uint128 liquidity, uint256 memeAdded, uint256 quoteAdded)
    {
        if (d.sqrtPriceMinX96 == 0 || d.sqrtPriceMaxX96 < d.sqrtPriceMinX96) revert InvalidParams();
        return _addLiquidity(d, deadline);
    }

    function _addLiquidity(Dispatch memory d, uint256 deadline)
        private
        returns (uint128 liquidity, uint256 memeAdded, uint256 quoteAdded)
    {
        _requireActive();
        _requireKeeper();
        _requireRegistered(d.token);
        if (block.timestamp > deadline) revert Expired();
        IPikaLaunchToken t = IPikaLaunchToken(d.token);
        if (!t.tradingStarted()) revert NotGraduated();
        address quote = t.quoteAsset();
        Budget memory budget =
            Budget(Math.min(pending[d.token][d.token], d.memeMax), Math.min(pending[d.token][quote], d.quoteMax));
        _balance(t, quote, budget, d, deadline);
        (uint160 price, bool memeIs0) = _price(t);
        if (price < d.sqrtPriceMinX96 || price > d.sqrtPriceMaxX96) {
            revert PriceOutOfRange(price, d.sqrtPriceMinX96, d.sqrtPriceMaxX96);
        }
        return _mintBurned(t, quote, memeIs0, budget);
    }

    /// @dev Mints whatever is pending now (the balancing swap's own fee reaches this sink only with a later push) as
    ///      a burned full-range position and books what actually left this contract (the pool rounds up). The
    ///      position manager sweeps back whatever it held, a stranger's leftovers included: those only raise this
    ///      contract's balance, so the books stay covered.
    function _mintBurned(IPikaLaunchToken t, address quote, bool memeIs0, Budget memory budget)
        private
        returns (uint128 liquidity, uint256 memeAdded, uint256 quoteAdded)
    {
        address token = address(t);
        uint256 meme = budget.meme;
        uint256 q = budget.quote;
        uint256 memeBefore = IERC20(token).balanceOf(address(this));
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));
        uint256 positionId;
        (positionId, liquidity,,) =
            PikaBurnedLiquidity.mint(positionManager, positionManager.clPoolManager(), t.poolKey(), memeIs0, meme, q);
        memeAdded = _spent(token, memeBefore);
        quoteAdded = _spent(quote, quoteBefore);
        if (memeAdded > meme || quoteAdded > q) revert InvalidParams();
        pending[token][token] -= memeAdded;
        pending[token][quote] -= quoteAdded;
        emit LiquidityAdded(token, liquidity, memeAdded, quoteAdded, positionId);
    }

    /// @notice `addLiquidity` for several launches, each with its own minimum output and price range, under one
    ///         deadline. Keeper-only. A launch whose dispatch reverts (below the floor, price outside its range,
    ///         `swapMinOut` not met) is skipped (`DispatchSkipped`) and keeps its fees for a later dispatch; `done[i]`
    ///         tells which went through. The arrays are parallel and of equal length.
    function addLiquidityMany(
        address[] calldata tokens,
        uint256[] calldata swapMinOuts,
        uint160[] calldata sqrtPriceMinsX96,
        uint160[] calldata sqrtPriceMaxsX96,
        uint256 deadline
    ) external returns (bool[] memory done) {
        _requireActive();
        _requireKeeper();
        uint256 n = tokens.length;
        if (swapMinOuts.length != n || sqrtPriceMinsX96.length != n || sqrtPriceMaxsX96.length != n) {
            revert InvalidParams();
        }
        done = new bool[](n);
        for (uint256 i; i < n; ++i) {
            try this.addLiquidity(tokens[i], swapMinOuts[i], sqrtPriceMinsX96[i], sqrtPriceMaxsX96[i], deadline) {
                done[i] = true;
            } catch (bytes memory reason) {
                emit DispatchSkipped(tokens[i], reason);
            }
        }
    }

    /// @notice Bounded dispatches, independently reverted on failure like `addLiquidityMany`.
    function addLiquidityLimitedMany(Dispatch[] calldata dispatches, uint256 deadline)
        external
        returns (bool[] memory done)
    {
        _requireActive();
        _requireKeeper();
        done = new bool[](dispatches.length);
        for (uint256 i; i < dispatches.length; ++i) {
            try this.addLiquidityLimited(dispatches[i], deadline) {
                done[i] = true;
            } catch (bytes memory reason) {
                emit DispatchSkipped(dispatches[i].token, reason);
            }
        }
    }

    /// @dev Balances only this dispatch's budgets. Global pending balances continue to cover the unselected funds.
    function _balance(IPikaLaunchToken t, address quote, Budget memory budget, Dispatch memory d, uint256 deadline)
        private
    {
        (uint160 price, bool memeIs0) = _price(t);
        if (price < d.sqrtPriceMinX96 || price > d.sqrtPriceMaxX96) {
            revert PriceOutOfRange(price, d.sqrtPriceMinX96, d.sqrtPriceMaxX96);
        }
        uint256 memeValue = _toQuote(budget.meme, price, memeIs0);
        uint256 q = budget.quote;
        if (memeValue + q < _minDispatch(quote)) revert BelowThreshold();
        bool sell = memeValue > q;
        uint256 input = sell ? _toMeme((memeValue - q) / 2, price, memeIs0) : (q - memeValue) / 2;
        if (input == 0) return;
        (uint256 spent, uint256 out) = _swap(d.token, sell, input, d.swapMinOut, deadline);
        if (sell) {
            budget.meme -= spent;
            budget.quote += out;
            pending[d.token][d.token] -= spent;
            pending[d.token][quote] += out;
        } else {
            budget.quote -= spent;
            budget.meme += out;
            pending[d.token][quote] -= spent;
            pending[d.token][d.token] += out;
        }
    }

    /// @dev How much of `asset` left this contract since its balance was `before`.
    function _spent(address asset, uint256 before) private view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance < before ? before - balance : 0;
    }

    /// @dev Meme valued in quote at `sqrtPriceX96`.
    function _toQuote(uint256 meme, uint160 sqrtPriceX96, bool memeIs0) private pure returns (uint256) {
        return memeIs0
            ? Math.mulDiv(Math.mulDiv(meme, sqrtPriceX96, Q96), sqrtPriceX96, Q96)
            : Math.mulDiv(Math.mulDiv(meme, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    /// @dev Quote valued in meme at `sqrtPriceX96`.
    function _toMeme(uint256 quote, uint160 sqrtPriceX96, bool memeIs0) private pure returns (uint256) {
        return memeIs0
            ? Math.mulDiv(Math.mulDiv(quote, Q96, sqrtPriceX96), Q96, sqrtPriceX96)
            : Math.mulDiv(Math.mulDiv(quote, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }
}
