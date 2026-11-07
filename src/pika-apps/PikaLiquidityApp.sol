// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PikaSinkBase } from "./PikaSinkBase.sol";
import { IPikaLiquidityLocker } from "./interfaces/IPikaApps.sol";
import { IPikaLaunchToken } from "../pika-market/interfaces/IPikaMarket.sol";

/// @notice "增加流动性": the liquidity sink. Project fees accumulate here and a keeper adds them to the launch's
///         permanently locked graduation position, so they can never leave the pool.
/// @dev A buy fee is meme and a sell fee is quote, while the full-range position wants both at the current price.
///      Before adding, the dispatch sells meme or buys it on the launch's own pool so that the two sides are worth
///      about the same, then hands both to the launch's locker, which adds as much as they fund and leaves the rest
///      here. The swap pays the outer fee like any trade (the router fills it in full or reverts); what the locker
///      could not add waits for the next dispatch.
contract PikaLiquidityApp is PikaSinkBase {
    using SafeERC20 for IERC20;

    bytes32 public constant KEY = "liquidity";
    uint16 public constant VERSION = 2;
    uint256 private constant Q96 = 2 ** 96;

    /// @dev `liquidity` is the position's increase; the amounts are what it took.
    event LiquidityAdded(address indexed token, uint128 liquidity, uint256 memeAdded, uint256 quoteAdded);

    constructor(address registry_) PikaSinkBase(registry_) { }

    function templateKey() external pure returns (bytes32) {
        return KEY;
    }

    function version() external pure virtual returns (uint16) {
        return VERSION;
    }

    error PriceOutOfRange(uint160 price, uint160 lower, uint160 upper);
    error Expired();

    /// @notice Add what this sink holds for the launch to its locked position, balancing the two sides on the pool
    ///         first. Keeper-only: `swapMinOut` guards the balancing swap (ignored when none is needed) and the pool
    ///         price must sit inside [`sqrtPriceMinX96`, `sqrtPriceMaxX96`] both before the swap and when the locker
    ///         adds, so a sandwiched dispatch cannot add liquidity at a pushed price. The deadline applies even
    ///         when the two sides are already balanced and no swap is needed.
    function addLiquidity(
        address token,
        uint256 swapMinOut,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96,
        uint256 deadline
    ) external nonReentrant returns (uint128 liquidity, uint256 memeAdded, uint256 quoteAdded) {
        _requireActive();
        _requireKeeper();
        _requireRegistered(token);
        if (block.timestamp > deadline) revert Expired();
        IPikaLaunchToken t = IPikaLaunchToken(token);
        if (!t.tradingStarted()) revert NotGraduated();
        address quote = t.quoteAsset();
        _balance(t, quote, swapMinOut, sqrtPriceMinX96, sqrtPriceMaxX96, deadline);
        // Add whatever is pending now (the swap's own fee reaches this sink only with a later push).
        uint256 meme = pending[token][token];
        uint256 q = pending[token][quote];
        address locker = t.locker();
        IERC20(token).forceApprove(locker, meme);
        IERC20(quote).forceApprove(locker, q);
        (liquidity, memeAdded, quoteAdded) =
            IPikaLiquidityLocker(locker).addToPosition(token, meme, q, sqrtPriceMinX96, sqrtPriceMaxX96);
        IERC20(token).forceApprove(locker, 0);
        IERC20(quote).forceApprove(locker, 0);
        pending[token][token] = meme - memeAdded;
        pending[token][quote] = q - quoteAdded;
        emit LiquidityAdded(token, liquidity, memeAdded, quoteAdded);
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

    /// @dev Checks the pool price sits inside the keeper's range and the pending fees are worth a dispatch, then
    ///      sells or buys meme on the pool so the two pending sides are worth about the same at that price.
    function _balance(
        IPikaLaunchToken t,
        address quote,
        uint256 swapMinOut,
        uint160 sqrtPriceMinX96,
        uint160 sqrtPriceMaxX96,
        uint256 deadline
    ) private {
        address token = address(t);
        (uint160 price, bool memeIs0) = _price(t);
        if (price < sqrtPriceMinX96 || price > sqrtPriceMaxX96) {
            revert PriceOutOfRange(price, sqrtPriceMinX96, sqrtPriceMaxX96);
        }
        uint256 memeValue = _toQuote(pending[token][token], price, memeIs0);
        uint256 q = pending[token][quote];
        if (memeValue + q < _minDispatch(quote)) revert BelowThreshold();
        if (memeValue > q) {
            uint256 sell = _toMeme((memeValue - q) / 2, price, memeIs0);
            if (sell != 0) _rebalance(token, quote, true, sell, swapMinOut, deadline);
        } else if (q > memeValue) {
            uint256 buy = (q - memeValue) / 2;
            if (buy != 0) _rebalance(token, quote, false, buy, swapMinOut, deadline);
        }
    }

    /// @dev One balancing swap, booked against the pending sides: a sell moves meme into quote, a buy the reverse.
    function _rebalance(address token, address quote, bool sellMeme, uint256 amountIn, uint256 minOut, uint256 deadline)
        private
    {
        (uint256 spent, uint256 out) = _swap(token, sellMeme, amountIn, minOut, deadline);
        (address from, address to) = sellMeme ? (token, quote) : (quote, token);
        pending[token][from] -= spent;
        pending[token][to] += out;
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
