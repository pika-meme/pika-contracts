// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOpenFourTradeModule } from "../../src/openfour/interfaces/IOpenFourTradeModule.sol";
import { IOpenFourModuleSchema } from "../../src/openfour/interfaces/IOpenFourModuleSchema.sol";
import { OpenFourTypes, ModuleEncodeSchema, ParamDescriptor } from "../../src/openfour/libraries/OpenFourTypes.sol";

/// @notice Test stand-in for OpenFour's closed-source simple trade policy (`SimpleTradeModule`, `module.trade.simple`),
///         the Pika preset's trade slot since 2026-11-06 (when the purchase limit went). Written from the BSC mainnet
///         implementation's observed behaviour (`0x020481FcC62530680242CB61F2323396Cb8BbC55`); mock-Core tests use
///         it, the testnet and mainnet use the real module. `test/fork/OpenFourSimpleTrade.t.sol` checks it against
///         the real one.
/// @dev Initializes once (any caller) and takes no parameters; every trade of the bound token is allowed with no
///      amount bounds and no extra fees; another token's trade reverts.
contract OpenFourSimpleTrade is IOpenFourTradeModule, IOpenFourModuleSchema {
    bytes8 private constant ID = bytes8(keccak256("module.trade.simple"));

    address public token;
    address public fourCore;
    string private _version;

    function init(address token_, address core_, bytes calldata params, string calldata moduleVersion) external {
        require(token == address(0) && token_ != address(0) && core_ != address(0), "Trade: init");
        require(params.length == 0, "Trade: params");
        token = token_;
        fourCore = core_;
        _version = moduleVersion;
    }

    function descriptor() external view returns (bytes8, string memory, string memory) {
        return (ID, "module.trade.simple", _version);
    }

    function evaluate(OpenFourTypes.TradeContext calldata ctx)
        external
        view
        returns (OpenFourTypes.TradeResult memory r)
    {
        require(ctx.token == token, "Trade: wrong token");
        r.allowed = true;
        r.maxAmount = type(uint256).max;
        r.fees = new OpenFourTypes.FeeTier[](0);
    }

    function getInitParams() external pure returns (bytes memory) {
        return "";
    }

    function moduleEncodeSchema() external pure returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema("trade", 1, new ParamDescriptor[](0));
    }
}
