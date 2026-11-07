// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PikaModuleBase } from "./PikaModuleBase.sol";
import { PikaCodeBlob } from "../libraries/PikaCodeBlob.sol";
import { PikaFeeMath } from "../../common/libraries/PikaFeeMath.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IOpenFourTokenModule } from "../../openfour/interfaces/IOpenFourTokenModule.sol";
import { IOpenFourModuleSchema } from "../../openfour/interfaces/IOpenFourModuleSchema.sol";
import { OpenFourToken } from "../../openfour/token/OpenFourToken.sol";
import {
    OpenFourTypes, ModuleEncodeSchema, ParamDescriptor
} from "../../openfour/libraries/OpenFourTypes.sol";

/// @notice Pika's OpenFour token module: initializes the cloned `PikaToken` with OpenFour's module wiring and the
///         launch's Pika parameters (`tokenParams` = `abi.encode(PikaTokenParams)`), which register it with the hub.
/// @dev Like OpenFour's `StandardTokenModule`, Core (through its create deployer) calls `createToken` once per launch
///      on a fresh BeaconProxy. The parameters run to hundreds of bytes with app bindings, so `getInitParams` keeps
///      them as a data contract's code (`PikaCodeBlob`) rather than in storage slots (2026-11-05).
contract PikaTokenModule is PikaModuleBase, IOpenFourTokenModule, IOpenFourModuleSchema {
    /// @dev The data contract holding `tokenParams`.
    address private _params;

    constructor(address hub_, address core_) PikaModuleBase(hub_, core_) { }

    function descriptor() external view returns (bytes8, string memory, string memory) {
        return _describe("module.token.pika");
    }

    function getInitParams() external view returns (bytes memory) {
        return PikaCodeBlob.read(_params);
    }

    /// @dev Core's create deployer, not Core itself, makes this call (BSC testnet fork, 2026-11-05); like OpenFour's
    ///      StandardTokenModule nothing gates the caller: Core creates the instance and calls it in one transaction.
    function createToken(
        address creator,
        address token_,
        address vault,
        address curveModule,
        address tradeModule,
        address migrateModule,
        address customDataModule,
        OpenFourTypes.TokenCreateParams calldata p,
        string calldata tokenImplVersion,
        string calldata tokenModuleVersion
    ) external returns (uint256, string memory, string memory) {
        if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert InvalidModuleConfiguration();
        _start(token_, tokenModuleVersion);
        _params = PikaCodeBlob.write(p.tokenParams);
        OpenFourToken.InitArgs memory a;
        a.requestId = p.requestId;
        a.name = p.name;
        a.symbol = p.symbol;
        a.vault = vault;
        a.maxSupply = p.maxSupply;
        a.tokenUri = p.tokenUri;
        a.curveModule = curveModule;
        a.tradeModule = tradeModule;
        a.migrateModule = migrateModule;
        a.tokenModule = address(this);
        a.customDataModule = customDataModule;
        a.creator = creator;
        a.quoteAsset = p.quoteAsset;
        a.tokenParams = p.tokenParams;
        a.tokenImplVersion = tokenImplVersion;
        OpenFourToken(token_).initialize(a);
        return (p.maxSupply, p.name, p.symbol);
    }

    /// @notice `tokenParams` is `abi.encode(PikaTokenParams)`: the creator's fee wallet, the outer project fee per
    ///         direction and the app bindings (template id, buy and sell share, app parameters).
    function moduleEncodeSchema() external pure returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory p = new ParamDescriptor[](4);
        // The token's cap on the project fee per direction: the total cap less the platform fee.
        string memory maxFee = Strings.toString(PikaFeeMath.MAX_TOTAL_FEE_BPS - PikaFeeMath.PLATFORM_FEE_BPS);
        p[0] = ParamDescriptor(
            "creatorFeeRecipient",
            "address",
            0,
            true,
            "Fee wallet",
            "0x0000000000000000000000000000000000000000",
            "Zero: the creator. The wallet can hand the role over later.",
            "",
            ""
        );
        p[1] = ParamDescriptor("buyFeeBps", "uint16", 0, true, "Buy project fee (bps)", "0", "", "0", maxFee);
        p[2] = ParamDescriptor("sellFeeBps", "uint16", 0, true, "Sell project fee (bps)", "0", "", "0", maxFee);
        p[3] = ParamDescriptor(
            "apps", "(uint32,uint16,uint16,bytes)[]", 0, true, "Apps", "[]", "Pika app bindings", "", ""
        );
        return ModuleEncodeSchema("token", 1, p);
    }
}
