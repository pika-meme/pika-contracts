// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PikaSinkBase } from "./PikaSinkBase.sol";

/// @notice "销毁": the burn sink. Buy fees (meme) accumulate and go to the burn address; sell fees (quote) accumulate
///         and a keeper buys meme back with them, which is burned too. Like a tax token's processor, nothing happens
///         inside the trade.
/// @dev Burning is a plain transfer to `0x…dEaD`: the launch token has no burn entry and its supply never changes.
///      A buyback is a buy on the launch's own pool through its router, so it pays the outer fee like any buy; the
///      part of that fee that comes back to this sink is burned with the rest.
contract PikaBurnApp is PikaSinkBase {
    bytes32 public constant KEY = "burn";
    uint16 public constant VERSION = 2;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    event Burned(address indexed token, uint256 amount);
    event BoughtBack(address indexed token, uint256 quoteSpent, uint256 memeReceived);

    constructor(address registry_) PikaSinkBase(registry_) { }

    function templateKey() external pure returns (bytes32) {
        return KEY;
    }

    function version() external pure virtual returns (uint16) {
        return VERSION;
    }

    /// @notice Send every meme this sink holds for the launch to the burn address. Anyone may call it.
    function burn(address token) external nonReentrant returns (uint256 amount) {
        _requireActive();
        _requireRegistered(token);
        amount = _burn(token);
    }

    /// @notice Buy meme back with the quote this sink holds for the launch and burn it, with the meme already
    ///         waiting. Keeper-only: `minOut` guards the buy, which the router fills in full or reverts.
    function buyback(address token, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteSpent, uint256 memeReceived, uint256 burned)
    {
        _requireActive();
        _requireKeeper();
        _requireRegistered(token);
        address quote = _quote(token);
        uint256 amount = pending[token][quote];
        if (amount < _minDispatch(quote)) revert BelowThreshold();
        (quoteSpent, memeReceived) = _swap(token, false, amount, minOut, deadline);
        pending[token][quote] -= quoteSpent;
        pending[token][token] += memeReceived;
        emit BoughtBack(token, quoteSpent, memeReceived);
        burned = _burn(token);
    }

    /// @notice `burn` for several launches. Anyone may call it. A launch whose burn reverts is skipped
    ///         (`DispatchSkipped`) and reports 0.
    function burnMany(address[] calldata tokens) external returns (uint256[] memory amounts) {
        _requireActive();
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            try this.burn(tokens[i]) returns (uint256 amount) {
                amounts[i] = amount;
            } catch (bytes memory reason) {
                emit DispatchSkipped(tokens[i], reason);
            }
        }
    }

    /// @notice `buyback` for several launches, each with its own minimum output, under one deadline. Keeper-only. A
    ///         launch whose buyback reverts (below the floor, `minOut` not met) is skipped (`DispatchSkipped`) and
    ///         keeps its quote for a later dispatch; `done[i]` tells which went through.
    function buybackMany(address[] calldata tokens, uint256[] calldata minOuts, uint256 deadline)
        external
        returns (bool[] memory done)
    {
        _requireActive();
        _requireKeeper();
        if (tokens.length != minOuts.length) revert InvalidParams();
        done = new bool[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            try this.buyback(tokens[i], minOuts[i], deadline) {
                done[i] = true;
            } catch (bytes memory reason) {
                emit DispatchSkipped(tokens[i], reason);
            }
        }
    }

    function _burn(address token) private returns (uint256 amount) {
        amount = pending[token][token];
        if (amount == 0) return 0;
        pending[token][token] = 0;
        _send(token, BURN_ADDRESS, amount);
        emit Burned(token, amount);
    }
}
