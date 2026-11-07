// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOpenFourRegistry } from "../src/openfour/interfaces/IOpenFourRegistry.sol";
import { ITagDescriptor } from "../src/openfour/interfaces/ITagDescriptor.sol";

/// @notice OpenFour's own modules in the Pika preset: the standard vault (`module.vault.standard`, the vault slot since
///         2026-11-05), the standard bonding curve (`module.curve.bonding`, the curve slot since 2026-11-06) and the
///         simple trade policy (`module.trade.simple`, the trade slot since 2026-11-06, when the purchase limit went).
/// @dev OpenFour lists them as `VAULT_BASIC`, `CURVE_BONDING` and `TRADE_SIMPLE` (openfour-docs developer/fork-deploy):
///      their Registry keys are the keccak256 of those names, not of the tags. The keys are the same on BSC mainnet and
///      on OpenFour's shared testnet developer hub; a developer-owned fork copies the hub's records (`hubRecord`). The
///      hub's vault implementation is byte-identical to mainnet's; its curve implementation is a different build that
///      computes the same sizing, prices and budget fills (checked on a fork, 2026-11-06). The simple trade policy
///      allows every trade with no extra fees and takes no parameters (both builds, checked on a fork, 2026-11-06).
library OpenFourStandardModules {
    bytes32 internal constant VAULT_KEY = 0x3e7c54e066dccd796d82c61050797d9b41fc573ce6b95b1968fb6e21c9df315b;
    string internal constant VAULT_TAG = "module.vault.standard";
    bytes32 internal constant CURVE_KEY = 0x0e4ee145a2864ef2ac97032a3c00ed121816998110d1cf364770093ce952cb47;
    string internal constant CURVE_TAG = "module.curve.bonding";
    bytes32 internal constant TRADE_KEY = 0x379c13a7faced71bfa110d4297fd89666ac21c3407816ab9ef26027c15dce10d;
    string internal constant TRADE_TAG = "module.trade.simple";
    /// @dev OpenFour's shared developer hub Registry on BSC testnet (the source of `ForkOpenFourTestnet`).
    address internal constant TESTNET_HUB_REGISTRY = 0xE5014c0616e528B0ABF7CC120A58032c1FbE7060;

    /// @notice Whether `registry` lists OpenFour's standard vault.
    function vaultListed(address registry) internal view returns (bool) {
        return listed(registry, VAULT_KEY, VAULT_TAG, IOpenFourRegistry.ModuleKind.Vault);
    }

    /// @notice Whether `registry` lists OpenFour's standard bonding curve.
    function curveListed(address registry) internal view returns (bool) {
        return listed(registry, CURVE_KEY, CURVE_TAG, IOpenFourRegistry.ModuleKind.Curve);
    }

    /// @notice Whether `registry` lists OpenFour's simple trade policy.
    function tradeListed(address registry) internal view returns (bool) {
        return listed(registry, TRADE_KEY, TRADE_TAG, IOpenFourRegistry.ModuleKind.Trade);
    }

    /// @notice Whether `registry` lists an active module of `kind` under `key` whose implementation describes itself
    ///         as `tag`.
    function listed(address registry, bytes32 key, string memory tag, IOpenFourRegistry.ModuleKind kind)
        internal
        view
        returns (bool)
    {
        IOpenFourRegistry r = IOpenFourRegistry(registry);
        IOpenFourRegistry.ModuleRecord memory m = r.getModule(key);
        if (m.beacon == address(0) || !m.active || m.kind != kind) return false;
        address impl = r.getModuleImplementation(key);
        if (impl.code.length == 0) return false;
        (, string memory described,) = ITagDescriptor(impl).descriptor();
        return keccak256(bytes(described)) == keccak256(bytes(tag));
    }

    /// @notice The hub's record of a module (implementation and metadata, author and fee share included), for a
    ///         developer-owned fork's Registry owner to list under the same key, as OpenFour's fork-deploy does.
    function hubRecord(bytes32 key, string memory tag, IOpenFourRegistry.ModuleKind kind)
        internal
        view
        returns (address implementation, IOpenFourRegistry.ModuleRecord memory record)
    {
        IOpenFourRegistry hub = IOpenFourRegistry(TESTNET_HUB_REGISTRY);
        require(listed(TESTNET_HUB_REGISTRY, key, tag, kind), "OpenFour hub lacks the module");
        record = hub.getModule(key);
        implementation = hub.getModuleImplementation(key);
    }
}
