// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PikaGraduationMath } from "../../src/pika-launch/libraries/PikaGraduationMath.sol";
import { IOpenFourCurveModule } from "../../src/openfour/interfaces/IOpenFourCurveModule.sol";
import { IOpenFourModuleSchema } from "../../src/openfour/interfaces/IOpenFourModuleSchema.sol";
import {
    OpenFourTypes, ModuleEncodeSchema, ParamDescriptor
} from "../../src/openfour/libraries/OpenFourTypes.sol";

/// @notice Test stand-in for OpenFour's closed-source bonding curve (`BondingCurveModule`, `module.curve.bonding`),
///         the Pika preset's curve slot since 2026-11-06. Written from the BSC mainnet implementation's observed
///         behaviour (`0xeAcb4085088a84f7dfC9AEBf8F0116A418f2600b`); mock-Core tests use it, the testnet and
///         mainnet use the real module. `test/fork/OpenFourBondingCurve.t.sol` checks it against the real one.
/// @dev A constant product with a fixed invariant `k = virtualQuote · virtualTokens` (it never follows the vault's
///      books): at a vault state the curve holds `virtualQuote + totalRaised` quote against
///      `virtualTokens − saleAmount + remainingForSale` tokens. A buy of n costs `⌊k / (y − n)⌋ − x`, a sell of n pays
///      `x − ⌊k / (y + n)⌋`; a budget b buys the most tokens whose cost fits, `y − ⌊k / (x + b + 1)⌋ − 1`.
contract OpenFourBondingCurve is IOpenFourCurveModule, IOpenFourModuleSchema {
    uint256 private constant UNIT = 1e18;

    address public token;
    address public core;
    uint256 public virtualQuote;
    uint256 public virtualTokens;
    uint256 public saleAmount;

    function init(
        address token_,
        address core_,
        OpenFourTypes.TokenCreateParams calldata p,
        bytes calldata,
        string calldata
    ) external {
        require(token == address(0) && token_ != address(0) && msg.sender == core_, "BondingCurve: init");
        token = token_;
        core = core_;
        saleAmount = p.saleAmount;
        (virtualQuote, virtualTokens) = PikaGraduationMath.bondingReserves(p.maxSupply, p.saleAmount, p.raiseAmount);
    }

    function descriptor() external pure returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "module.curve.bonding";
        tagId = bytes8(keccak256(bytes(tag)));
        version = "1.0.0";
    }

    function evaluate(OpenFourTypes.CurveContext calldata ctx)
        external
        view
        returns (OpenFourTypes.CurveResult memory r)
    {
        require(ctx.token == token, "BondingCurve: wrong token");
        (uint256 x, uint256 y) = _reserves(ctx.remainingForSale, ctx.totalRaised);
        uint256 k = virtualQuote * virtualTokens;
        if (ctx.isBuy) {
            uint256 amount = Math.min(ctx.amount, ctx.remainingForSale);
            if (amount == 0) return OpenFourTypes.CurveResult(false, 0, 0, "sold out");
            uint256 after_ = k / (y - amount);
            if (after_ <= x) return OpenFourTypes.CurveResult(false, 0, 0, "price too small");
            r.executable = true;
            r.quoteAmount = after_ - x;
            if (amount < ctx.amount) r.adjustedAmount = amount;
            return r;
        }
        uint256 left = k / (y + ctx.amount);
        if (ctx.amount == 0 || left >= x) return OpenFourTypes.CurveResult(false, 0, 0, "price too small");
        r.executable = true;
        r.quoteAmount = x - left;
    }

    function evaluateReverse(
        address token_,
        bool isBuy,
        uint256 quoteBudget,
        uint256 remainingForSale,
        uint256 totalRaised,
        uint256
    ) external view returns (uint256 tokenAmount, uint256 curveQuote) {
        require(token_ == token, "BondingCurve: wrong token");
        if (!isBuy || quoteBudget == 0 || remainingForSale == 0) return (0, 0);
        (uint256 x, uint256 y) = _reserves(remainingForSale, totalRaised);
        uint256 k = virtualQuote * virtualTokens;
        uint256 floor_ = k / (x + quoteBudget + 1);
        if (floor_ + 1 >= y) return (0, 0);
        tokenAmount = Math.min(y - floor_ - 1, remainingForSale);
        curveQuote = k / (y - tokenAmount) - x;
    }

    /// @notice The cost of the first whole token.
    function getInitialPrice() external view returns (uint256) {
        return virtualQuote * virtualTokens / (virtualTokens - UNIT) - virtualQuote;
    }

    function getLastPrice(address, uint256 remainingForSale, uint256 totalRaised) external view returns (uint256) {
        (uint256 x, uint256 y) = _reserves(remainingForSale, totalRaised);
        return x * UNIT / y;
    }

    function getLiquiditySnapshot(address, uint256 remainingForSale, uint256 totalRaised)
        external
        view
        returns (OpenFourTypes.CurveLiquiditySnapshot memory s)
    {
        s.available = true;
        s.initialQuoteLiquidity = virtualQuote;
        s.initialTokenLiquidity = virtualTokens;
        (s.currentQuoteLiquidity, s.currentTokenLiquidity) = _reserves(remainingForSale, totalRaised);
        s.remainingForSale = remainingForSale;
        s.totalRaised = totalRaised;
        s.lastPrice = s.currentQuoteLiquidity * UNIT / s.currentTokenLiquidity;
    }

    function getInitParams() external pure returns (bytes memory) {
        return "";
    }

    function moduleEncodeSchema() external pure returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema("curve", 1, new ParamDescriptor[](0));
    }

    function _reserves(uint256 remainingForSale, uint256 totalRaised) private view returns (uint256 x, uint256 y) {
        x = virtualQuote + totalRaised;
        y = virtualTokens - saleAmount + remainingForSale;
    }
}
