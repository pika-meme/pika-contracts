// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaModuleBase } from "./PikaModuleBase.sol";
import { IPikaHub } from "../interfaces/IPikaLaunch.sol";
import { IOpenFourMigrateModule } from "../../openfour/interfaces/IOpenFourMigrateModule.sol";
import { IOpenFourModuleSchema } from "../../openfour/interfaces/IOpenFourModuleSchema.sol";
import { IOpenFourVault } from "../../openfour/interfaces/IOpenFourVault.sol";
import {
    OpenFourTypes, ModuleEncodeSchema, ParamDescriptor
} from "../../openfour/libraries/OpenFourTypes.sol";

/// @notice Pika's OpenFour migrate module: graduates a sold-out launch into its Pancake Infinity launch pool.
/// @dev Core asks `evaluate` after every buy and runs `executeMigration` (phase `MigratePending`) when it says
///      yes. The module moves the vault's whole quote and token balances to the Pika hub, which opens the hooked
///      pool at the curve's final price and locks the full-range position for good. Migration data version 1 is
///      `abi.encode(bytes32 poolId)`, the Infinity pool id. The launch's vault is OpenFour's standard vault
///      (2026-11-05): it closes the sale with at most one whole token left (`remainingForSale <= 1e18`), and that
///      remainder stays locked with the rest of the vault's tokens. The hub prices the pool on the vault's
///      `totalRaised`, or on the vault's whole quote balance should that ever be less: a gap between the vault's
///      books and its balance must not leave a sold-out launch on a closed curve for good (audit 2026-11-08c, D-1).
contract PikaMigrateModule is PikaModuleBase, IOpenFourMigrateModule, IOpenFourModuleSchema {
    uint8 public constant MIGRATED_DATA_VERSION = 1;

    error NotSoldOut();

    constructor(address hub_, address core_) PikaModuleBase(hub_, core_) { }

    /// @dev OpenFour's fee router is not needed: graduation charges no migration fee here.
    function init(address token_, address core_, address, bytes calldata params, string calldata version) external {
        if (params.length != 0) revert InvalidModuleConfiguration();
        _bind(token_, core_, version);
    }

    function descriptor() external view returns (bytes8, string memory, string memory) {
        return _describe("module.migrate.pika_infinity");
    }

    /// @notice Always empty: the migrate module takes no parameters.
    function getInitParams() external pure returns (bytes memory) {
        return "";
    }

    /// @notice A launch graduates as soon as its vault reports the sale sold out.
    function evaluate(OpenFourTypes.MigrateContext calldata ctx)
        external
        view
        returns (OpenFourTypes.MigrateResult memory r)
    {
        _checkToken(ctx.token);
        if (!ctx.soldOut) {
            r.reason = "not sold out";
            return r;
        }
        r.canMigrate = true;
    }

    /// @notice Moves the vault's balances to the hub and graduates there. `hookData` is ignored: the hub reads the
    ///         raised quote from the vault's books and checks Core's record of the launch itself.
    /// @dev The vault's quote balance is normally at least `totalRaised` (the anti-sniper surcharge is kept outside
    ///      the raise). Should it ever fall short, the pool is priced on what the vault holds instead of refusing
    ///      the migration: the alternative would be a launch nobody can ever graduate, with every holder's funds on a
    ///      closed curve. The hub still requires the funds it is told about to be present, and refuses a price too
    ///      close to the protocol's edges (audit 2026-11-08c, D-1).
    function executeMigration(OpenFourTypes.MigrateHookContext calldata ctx, bytes calldata)
        external
        onlyCore
        returns (uint8 migratedDataVersion, bytes memory encodedMigratedData)
    {
        _checkToken(ctx.token);
        IOpenFourVault v = IOpenFourVault(ctx.vault);
        if (!v.isSoldOut()) revert NotSoldOut();
        address quote = v.quoteAsset();
        uint256 raised = v.totalRaised();
        uint256 quoteBalance = IERC20(quote).balanceOf(ctx.vault);
        uint256 tokenBalance = IERC20(_token).balanceOf(ctx.vault);
        uint256 priced = quoteBalance < raised ? quoteBalance : raised;
        v.transferQuoteForMigration(hub, quoteBalance);
        v.transferTokenForMigration(hub, tokenBalance);
        bytes32 poolId = IPikaHub(hub).graduate(_token, priced, quoteBalance - priced);
        return (MIGRATED_DATA_VERSION, abi.encode(poolId));
    }

    function moduleEncodeSchema() external pure returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema("migrate", 1, new ParamDescriptor[](0));
    }
}
