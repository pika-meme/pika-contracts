// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { IOpenFourVault } from "../../src/openfour/interfaces/IOpenFourVault.sol";
import { IOpenFourCurveModule } from "../../src/openfour/interfaces/IOpenFourCurveModule.sol";
import { IOpenFourTradeModule } from "../../src/openfour/interfaces/IOpenFourTradeModule.sol";
import { IOpenFourMigrateModule } from "../../src/openfour/interfaces/IOpenFourMigrateModule.sol";
import { IOpenFourTokenModule } from "../../src/openfour/interfaces/IOpenFourTokenModule.sol";
import { IOpenFourCustomDataModule } from "../../src/openfour/interfaces/IOpenFourCustomDataModule.sol";
import { IOpenFourPresetValidator } from "../../src/openfour/interfaces/IOpenFourPresetValidator.sol";
import { TradeEstimate } from "../../src/openfour/interfaces/IOpenFourTools.sol";

interface IMockWrapped {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Local stand-in for OpenFour Core, Registry, Tools and FeeRouter, following the public lifecycle in
///         openfour-docs (developer guide §4, integration guide §13). OpenFour's production Core is closed source;
///         the BSC testnet fork runs the real one.
/// @dev Creation: validator → clone token → clone modules → token module → module `init`s → record → Trading →
///      presale buy. Buy: curve → trade → fees → vault `onBuy` → data `afterHook` → SoldOut → migrate. A
///      migration that fails reverts the buy (the real Core's behaviour here is not public).
///      Fees: `protocolFeeBps` to the treasury and `devFeeBps` to the preset author, both on the curve quote, on top
///      of a buy and out of a sell. Modules are EIP-1167 clones here instead of BeaconProxies.
contract MockOpenFourCore {
    using SafeERC20 for IERC20;

    struct PresetConfig {
        address tokenImpl;
        address tokenModule;
        address vault;
        address curve;
        address trade;
        address migrate;
        address customData;
        address validator;
        address author;
    }

    address public immutable wrappedNative;
    address public treasury;
    uint16 public protocolFeeBps = 50;
    uint16 public devFeeBps = 50;
    uint256 public nextRequestId = 1;

    mapping(uint256 presetId => PresetConfig) public presetConfigs;
    mapping(address token => OpenFourTypes.RuntimeConfig) internal _tokens;

    error NotFound();
    error BadPhase();
    error Slippage();
    error NotExecutable(string reason);
    error AmountOutOfRange();

    event TokenCreated(address indexed token, uint256 indexed presetId, address indexed creator);
    event TradeExecuted(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 curveQuote,
        uint256 traderQuote,
        uint256 protocolFee,
        uint256 devFee
    );
    event MigrateExecuted(address indexed token, uint8 migratedDataVersion, bytes encodedMigratedData);

    constructor(address wrappedNative_, address treasury_) {
        wrappedNative = wrappedNative_;
        treasury = treasury_;
    }

    receive() external payable { }

    /// @notice Core's `tokens(token)` getter: the record's fields as separate return values (the tuple encoding
    ///         without its leading offset word), as the compiler-generated getter returns them.
    function tokens(address token) external view {
        bytes memory enc = abi.encode(_tokens[token]);
        assembly ("memory-safe") {
            return(add(enc, 0x40), sub(mload(enc), 0x20))
        }
    }

    function record(address token) external view returns (OpenFourTypes.RuntimeConfig memory) {
        return _tokens[token];
    }

    // -- Registry / Tools / FeeRouter stand-ins --------------------------------------------------------------

    function registry() external view returns (address) {
        return address(this);
    }

    function openFourTool() external view returns (address) {
        return address(this);
    }

    function setFees(uint16 protocolBps, uint16 devBps) external {
        protocolFeeBps = protocolBps;
        devFeeBps = devBps;
    }

    function setPreset(uint256 presetId, PresetConfig calldata c) external {
        presetConfigs[presetId] = c;
    }

    function predictToken(uint256 presetId, address creator, bytes32 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(presetConfigs[presetId].tokenImpl, _salt(creator, salt));
    }

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    // -- Creation --------------------------------------------------------------------------------------------

    function createToken(OpenFourTypes.CreateTokenArgs calldata a) external payable returns (address token) {
        PresetConfig memory c = presetConfigs[a.presetId];
        if (c.tokenImpl == address(0)) revert NotFound();
        IOpenFourPresetValidator(c.validator).validate(a.presetId, a.initParams);
        token = Clones.cloneDeterministic(c.tokenImpl, _salt(msg.sender, a.initParams.tokenSalt));
        OpenFourTypes.RuntimeConfig storage r = _tokens[token];
        r.version = 1;
        r.creator = msg.sender;
        r.presetId = a.presetId;
        r.token = token;
        r.vault = Clones.clone(c.vault);
        r.curveModule = Clones.clone(c.curve);
        r.tradeModule = Clones.clone(c.trade);
        r.migrateModule = Clones.clone(c.migrate);
        r.tokenModule = Clones.clone(c.tokenModule);
        if (c.customData != address(0)) r.customData = Clones.clone(c.customData);
        OpenFourTypes.TokenCreateParams memory p = _createParams(a);
        IOpenFourTokenModule(r.tokenModule)
            .createToken(
                msg.sender, token, r.vault, r.curveModule, r.tradeModule, r.migrateModule, r.customData, p, "1.0.0",
                "1.0.0"
            );
        _initModules(r, p, a.initParams);
        r.name = a.initParams.name;
        r.symbol = a.initParams.symbol;
        r.maxSupply = a.initParams.maxSupply;
        r.saleAmount = a.initParams.saleAmount;
        r.raiseAmount = a.initParams.raiseAmount;
        r.quoteAsset = a.initParams.quoteAsset;
        r.createBlock = block.number;
        r.exists = true;
        r.antiSniperEnabled = a.antiSniperEnabled;
        IOpenFourVault(r.vault).setPhase(OpenFourTypes.Phase.Trading);
        emit TokenCreated(token, a.presetId, msg.sender);
        if (a.presaleQuote != 0) {
            uint256 value = msg.value;
            if (a.initParams.quoteAsset == wrappedNative && value != 0) IMockWrapped(wrappedNative).deposit{ value: value }();
            else IERC20(a.initParams.quoteAsset).safeTransferFrom(msg.sender, address(this), a.presaleQuote);
            uint256 spent = _buyByBudget(token, msg.sender, a.presaleQuote, 0, true);
            if (a.presaleQuote > spent) _sendQuote(a.initParams.quoteAsset, msg.sender, a.presaleQuote - spent, value != 0);
        }
    }

    function _createParams(OpenFourTypes.CreateTokenArgs calldata a)
        private
        returns (OpenFourTypes.TokenCreateParams memory p)
    {
        p.requestId = a.requestId == 0 ? nextRequestId++ : a.requestId;
        p.name = a.initParams.name;
        p.symbol = a.initParams.symbol;
        p.maxSupply = a.initParams.maxSupply;
        p.saleAmount = a.initParams.saleAmount;
        p.raiseAmount = a.initParams.raiseAmount;
        p.quoteAsset = a.initParams.quoteAsset;
        p.tokenUri = a.initParams.tokenUri;
        p.tokenParams = a.initParams.tokenParams;
        p.tokenSalt = a.initParams.tokenSalt;
    }

    function _initModules(
        OpenFourTypes.RuntimeConfig storage r,
        OpenFourTypes.TokenCreateParams memory p,
        OpenFourTypes.TokenInitParams calldata ip
    ) private {
        IOpenFourVault(r.vault).init(r.token, address(this), r.creator, r.migrateModule, p, ip.vaultParams, "1.0.0");
        IOpenFourCurveModule(r.curveModule).init(r.token, address(this), p, ip.curveParams, "1.0.0");
        IOpenFourTradeModule(r.tradeModule).init(r.token, address(this), ip.tradeParams, "1.0.0");
        IOpenFourMigrateModule(r.migrateModule).init(r.token, address(this), address(this), ip.migrateParams, "1.0.0");
        if (r.customData != address(0)) {
            IOpenFourCustomDataModule(r.customData).init(r.token, address(this), ip.customDataParams, "1.0.0");
        }
    }

    // -- Trading ---------------------------------------------------------------------------------------------

    function _evalCurve(OpenFourTypes.RuntimeConfig memory r, address trader, uint256 amount, bool isBuy)
        private
        view
        returns (OpenFourTypes.CurveResult memory)
    {
        IOpenFourVault v = IOpenFourVault(r.vault);
        OpenFourTypes.CurveContext memory ctx;
        ctx.token = r.token;
        ctx.trader = trader;
        ctx.amount = amount;
        ctx.isBuy = isBuy;
        ctx.remainingForSale = v.remainingForSale();
        ctx.totalRaised = v.totalRaised();
        ctx.timestamp = block.timestamp;
        return IOpenFourCurveModule(r.curveModule).evaluate(ctx);
    }

    function _evalTrade(
        OpenFourTypes.RuntimeConfig memory r,
        address trader,
        uint256 amount,
        bool isBuy,
        uint256 curveQuote
    ) private view returns (OpenFourTypes.TradeResult memory t) {
        IOpenFourVault v = IOpenFourVault(r.vault);
        OpenFourTypes.TradeContext memory ctx;
        ctx.token = r.token;
        ctx.trader = trader;
        ctx.amount = amount;
        ctx.isBuy = isBuy;
        ctx.timestamp = block.timestamp;
        ctx.blockNumber = block.number;
        ctx.remainingForSale = v.remainingForSale();
        ctx.totalRaised = v.totalRaised();
        ctx.curveQuote = curveQuote;
        t = IOpenFourTradeModule(r.tradeModule).evaluate(ctx);
        OpenFourTypes.revertIfDisallowed(t);
    }

    function _afterHook(
        OpenFourTypes.RuntimeConfig memory r,
        address trader,
        uint256 amount,
        bool isBuy,
        uint256 curveQuote,
        uint256 traderQuote
    ) private {
        if (r.customData == address(0)) return;
        OpenFourTypes.TradeHookContext memory ctx;
        ctx.token = r.token;
        ctx.trader = trader;
        ctx.requestedAmount = amount;
        ctx.executedAmount = amount;
        ctx.isBuy = isBuy;
        ctx.timestamp = block.timestamp;
        ctx.blockNumber = block.number;
        ctx.curveQuote = curveQuote;
        ctx.traderQuote = traderQuote;
        IOpenFourCustomDataModule(r.customData).afterHook(ctx);
    }

    function _payFees(OpenFourTypes.RuntimeConfig memory r, uint256 protocolFee, uint256 devFee) private {
        if (protocolFee != 0) IERC20(r.quoteAsset).safeTransfer(treasury, protocolFee);
        if (devFee != 0) IERC20(r.quoteAsset).safeTransfer(presetConfigs[r.presetId].author, devFee);
    }

    function _tradeParams(address trader, uint256 amount, uint256 curveQuote, uint256 protocolFee, uint256 devFee)
        private
        pure
        returns (OpenFourTypes.VaultTradeParams memory p)
    {
        p.trader = trader;
        p.tokenAmount = amount;
        p.curveQuote = curveQuote;
        p.protocolFee = protocolFee;
        p.devFee = devFee;
    }

    function _fees(uint256 curveQuote) public view returns (uint256 protocolFee, uint256 devFee) {
        protocolFee = curveQuote * protocolFeeBps / 10_000;
        devFee = curveQuote * devFeeBps / 10_000;
    }

    /// @notice Exact-amount buy: `amount` tokens for at most `maxPayAmount` quote (native BNB as value on WBNB).
    function buy(address token, uint256 amount, uint256 maxPayAmount, uint256, bytes calldata) external payable {
        OpenFourTypes.RuntimeConfig memory r = _live(token);
        bool native = msg.value != 0;
        if (native) {
            if (r.quoteAsset != wrappedNative || msg.value != maxPayAmount) revert BadPhase();
            IMockWrapped(wrappedNative).deposit{ value: msg.value }();
        } else {
            IERC20(r.quoteAsset).safeTransferFrom(msg.sender, address(this), maxPayAmount);
        }
        uint256 paid = _executeBuy(r, msg.sender, amount, false);
        if (paid > maxPayAmount) revert Slippage();
        if (maxPayAmount > paid) _sendQuote(r.quoteAsset, msg.sender, maxPayAmount - paid, native);
    }

    /// @notice Buy the most tokens `maxPayAmount` (fees included) buys, at least `minAmountOut`.
    function buyByBudget(address token, uint256 maxPayAmount, uint256 minAmountOut, uint256, bytes calldata)
        external
        payable
    {
        OpenFourTypes.RuntimeConfig memory r = _live(token);
        bool native = msg.value != 0;
        if (native) {
            if (r.quoteAsset != wrappedNative || msg.value != maxPayAmount) revert BadPhase();
            IMockWrapped(wrappedNative).deposit{ value: msg.value }();
        } else {
            IERC20(r.quoteAsset).safeTransferFrom(msg.sender, address(this), maxPayAmount);
        }
        uint256 balanceBefore = IERC20(token).balanceOf(msg.sender);
        uint256 paid = _buyByBudget(token, msg.sender, maxPayAmount, 0, false);
        if (IERC20(token).balanceOf(msg.sender) - balanceBefore < minAmountOut) revert Slippage();
        if (maxPayAmount > paid) _sendQuote(r.quoteAsset, msg.sender, maxPayAmount - paid, native);
    }

    function _buyByBudget(address token, address trader, uint256 budget, uint256, bool presale)
        private
        returns (uint256)
    {
        OpenFourTypes.RuntimeConfig memory r = _tokens[token];
        uint256 amount = _budgetAmount(r, trader, budget);
        if (presale) {
            uint256 net = budget * 10_000 / (10_000 + protocolFeeBps + devFeeBps);
            IOpenFourVault v = IOpenFourVault(r.vault);
            (uint256 wanted,) = IOpenFourCurveModule(r.curveModule)
                .evaluateReverse(r.token, true, net, v.remainingForSale(), v.totalRaised(), block.timestamp);
            if (wanted > amount) revert AmountOutOfRange();
        }
        if (amount == 0) revert AmountOutOfRange();
        return _executeBuy(r, trader, amount, false);
    }

    /// @dev Tokens a fee-inclusive budget buys: the curve's reverse quote for the budget net of fees, clamped to the
    ///      trade module's cap (the real Core searches the largest amount within it). The creator's first buy is the
    ///      exception: past the cap it reverts (`CoreErrTradeMax` on the BSC testnet fork, 2026-11-05).
    function _budgetAmount(OpenFourTypes.RuntimeConfig memory r, address trader, uint256 budget)
        private
        view
        returns (uint256 amount)
    {
        uint256 net = budget * 10_000 / (10_000 + protocolFeeBps + devFeeBps);
        IOpenFourVault v = IOpenFourVault(r.vault);
        (amount,) = IOpenFourCurveModule(r.curveModule)
            .evaluateReverse(r.token, true, net, v.remainingForSale(), v.totalRaised(), block.timestamp);
        OpenFourTypes.TradeResult memory t = _evalTrade(r, trader, amount, true, 0);
        if (amount > t.maxAmount) amount = t.maxAmount;
    }

    /// @dev Prices, checks and books a buy of `amount` tokens funded from this contract's balance; returns what the
    ///      trader paid (curve quote plus fees).
    function _executeBuy(OpenFourTypes.RuntimeConfig memory r, address trader, uint256 amount, bool)
        private
        returns (uint256 paid)
    {
        OpenFourTypes.CurveResult memory c = _evalCurve(r, trader, amount, true);
        if (!c.executable) revert NotExecutable(c.reason);
        if (c.adjustedAmount != 0) amount = c.adjustedAmount;
        OpenFourTypes.TradeResult memory t = _evalTrade(r, trader, amount, true, c.quoteAmount);
        if (amount < t.minAmount || amount > t.maxAmount) revert AmountOutOfRange();
        (uint256 protocolFee, uint256 devFee) = _fees(c.quoteAmount);
        paid = c.quoteAmount + protocolFee + devFee;
        IERC20(r.quoteAsset).safeTransfer(r.vault, c.quoteAmount);
        _payFees(r, protocolFee, devFee);
        IOpenFourVault v = IOpenFourVault(r.vault);
        v.onBuy(_tradeParams(trader, amount, c.quoteAmount, protocolFee, devFee));
        _afterHook(r, trader, amount, true, c.quoteAmount, paid);
        emit TradeExecuted(r.token, trader, true, amount, c.quoteAmount, paid, protocolFee, devFee);
        if (v.isSoldOut()) {
            v.setPhase(OpenFourTypes.Phase.SoldOut);
            _tryMigrate(r);
        }
    }

    /// @notice Sell `amount` tokens for at least `minReceiveAmount` quote (native BNB when the quote is WBNB and
    ///         `options` bit0 is clear).
    function sell(address token, uint256 amount, uint256 minReceiveAmount, uint256 options, bytes calldata) external {
        OpenFourTypes.RuntimeConfig memory r = _live(token);
        OpenFourTypes.CurveResult memory c = _evalCurve(r, msg.sender, amount, false);
        if (!c.executable) revert NotExecutable(c.reason);
        _evalTrade(r, msg.sender, amount, false, c.quoteAmount);
        (uint256 protocolFee, uint256 devFee) = _fees(c.quoteAmount);
        uint256 net = c.quoteAmount - protocolFee - devFee;
        if (net < minReceiveAmount) revert Slippage();
        IERC20(token).safeTransferFrom(msg.sender, r.vault, amount);
        IOpenFourVault(r.vault).onSell(_tradeParams(msg.sender, amount, c.quoteAmount, protocolFee, devFee));
        IOpenFourVault(r.vault).transferQuote(address(this), c.quoteAmount);
        _payFees(r, protocolFee, devFee);
        _sendQuote(r.quoteAsset, msg.sender, net, r.quoteAsset == wrappedNative && options & 1 == 0);
        _afterHook(r, msg.sender, amount, false, c.quoteAmount, net);
        emit TradeExecuted(token, msg.sender, false, amount, c.quoteAmount, net, protocolFee, devFee);
    }

    /// @notice Anyone may retry a migration whose conditions hold.
    function migrate(address token) external {
        OpenFourTypes.RuntimeConfig memory r = _tokens[token];
        if (!r.exists) revert NotFound();
        _tryMigrate(r);
    }

    function _tryMigrate(OpenFourTypes.RuntimeConfig memory r) private {
        IOpenFourVault v = IOpenFourVault(r.vault);
        OpenFourTypes.Phase phase = v.phase();
        if (phase != OpenFourTypes.Phase.Trading && phase != OpenFourTypes.Phase.SoldOut) return;
        OpenFourTypes.MigrateContext memory mc;
        mc.token = r.token;
        mc.totalRaised = v.totalRaised();
        mc.remainingForSale = v.remainingForSale();
        mc.soldOut = v.isSoldOut();
        mc.timestamp = block.timestamp;
        OpenFourTypes.MigrateResult memory m = IOpenFourMigrateModule(r.migrateModule).evaluate(mc);
        if (!m.canMigrate) return;
        v.setPhase(OpenFourTypes.Phase.MigratePending);
        OpenFourTypes.MigrateHookContext memory ctx;
        ctx.vault = r.vault;
        ctx.token = r.token;
        ctx.quoteAsset = r.quoteAsset;
        ctx.creator = r.creator;
        ctx.totalRaised = mc.totalRaised;
        ctx.remainingForSale = mc.remainingForSale;
        ctx.timestamp = block.timestamp;
        (uint8 version, bytes memory data) = IOpenFourMigrateModule(r.migrateModule).executeMigration(ctx, m.data);
        if (r.customData != address(0)) IOpenFourCustomDataModule(r.customData).onMigrate(ctx);
        v.setPhase(OpenFourTypes.Phase.Migrated);
        emit MigrateExecuted(r.token, version, data);
    }

    function _live(address token) private view returns (OpenFourTypes.RuntimeConfig memory r) {
        r = _tokens[token];
        if (!r.exists) revert NotFound();
        if (r.paused || IOpenFourVault(r.vault).phase() != OpenFourTypes.Phase.Trading) revert BadPhase();
    }

    function _sendQuote(address quote, address to, uint256 amount, bool native) private {
        if (amount == 0) return;
        if (native) {
            IMockWrapped(wrappedNative).withdraw(amount);
            (bool ok,) = to.call{ value: amount }("");
            require(ok, "native send");
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    // -- Tools estimates (for the trade lens) ----------------------------------------------------------------

    function estimateBuyByBudget(address token, address trader, uint256 maxPayAmount, uint256, bytes calldata)
        external
        view
        returns (TradeEstimate memory e)
    {
        OpenFourTypes.RuntimeConfig memory r = _tokens[token];
        e.tokenAmount = _budgetAmount(r, trader, maxPayAmount);
        OpenFourTypes.CurveResult memory c = _evalCurve(r, trader, e.tokenAmount, true);
        (uint256 protocolFee, uint256 devFee) = _fees(c.quoteAmount);
        e.curveQuote = c.quoteAmount;
        e.totalFee = protocolFee + devFee;
        e.userPays = c.quoteAmount + e.totalFee;
        e.executionPrice = e.tokenAmount == 0 ? 0 : Math.mulDiv(c.quoteAmount, 1e18, e.tokenAmount);
    }

    function estimateSell(address token, address trader, uint256 amount, uint256, bytes calldata)
        external
        view
        returns (TradeEstimate memory e)
    {
        OpenFourTypes.CurveResult memory c = _evalCurve(_tokens[token], trader, amount, false);
        (uint256 protocolFee, uint256 devFee) = _fees(c.quoteAmount);
        e.curveQuote = c.quoteAmount;
        e.totalFee = protocolFee + devFee;
        e.userReceives = c.quoteAmount - e.totalFee;
        e.tokenAmount = amount;
    }
}
