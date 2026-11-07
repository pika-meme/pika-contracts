// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PikaAppRegistry } from "../src/pika-apps/PikaAppRegistry.sol";
import { PikaAppBase } from "../src/pika-apps/PikaAppBase.sol";
import { PikaBurnApp } from "../src/pika-apps/PikaBurnApp.sol";
import { PikaDividendApp } from "../src/pika-apps/PikaDividendApp.sol";
import { PikaLiquidityApp } from "../src/pika-apps/PikaLiquidityApp.sol";
import { PikaLocker } from "../src/pika-market/infinity/PikaLocker.sol";

/// @notice Deploys the app registry and the three default sinks (burn, dividend, liquidity), owned by the deployer
///         until the timelock handover; `_listApps` lists the templates after the factory deployment and
///         `_configureSinks` wires the sinks to the locker and the keeper. The registry starts with `maxApps` 1: a
///         launch binds at most one app besides the default sinks.
/// @dev Template ids: 0 burn, 1 dividend, 2 liquidity, the default sinks. The optional staking, FOMO3D and land
///      templates were removed on 2026-10-30 (tag `contracts-all-apps-2026-10-30`). All are ERC1967 proxies over
///      their first implementation; `PikaAppRegistry.upgradeTemplate` moves them later, and only from the upgrade
///      timelock deployed here: a separate TimelockController with its own delay (`upgradeDelay`) whose proposer,
///      executor and canceller is `upgradeProposer`, the platform multisig. It administers itself, so its delay can
///      only change through itself.
abstract contract PikaAppsSetup {
    struct Apps {
        PikaAppRegistry registry;
        TimelockController upgradeTimelock;
        address burn;
        address dividend;
        address liquidity;
    }

    function _deployApps(address deployer, address guard, address upgradeProposer, uint256 upgradeDelay)
        internal
        returns (Apps memory a)
    {
        require(upgradeProposer != address(0), "upgrade timelock proposer required");
        address[] memory roles = new address[](1);
        roles[0] = upgradeProposer;
        a.upgradeTimelock = new TimelockController(upgradeDelay, roles, roles, address(0));
        a.registry = new PikaAppRegistry(deployer, guard, address(a.upgradeTimelock));
        a.burn = _proxy(address(new PikaBurnApp(address(a.registry))));
        a.dividend = _proxy(address(new PikaDividendApp(address(a.registry))));
        a.liquidity = _proxy(address(new PikaLiquidityApp(address(a.registry))));
    }

    function _proxy(address implementation) internal returns (address) {
        return address(new ERC1967Proxy(implementation, abi.encodeCall(PikaAppBase.initialize, ())));
    }

    /// @dev Lists the templates once the factory exists: the indexer follows the registry from the factory's
    ///      deployment block, so a template listed before it would never be watched.
    function _listApps(Apps memory a) internal {
        a.registry.addTemplate(a.burn, PikaAppRegistry.Kind.Contract, "burn", 2, true);
        a.registry
            .addTemplate(
                a.dividend, PikaAppRegistry.Kind.HolderBook, "dividend", PikaDividendApp(a.dividend).version(), true
            );
        a.registry.addTemplate(a.liquidity, PikaAppRegistry.Kind.Contract, "liquidity", 2, true);
    }

    /// @dev The locker admits the liquidity sink, and `keeper` may run the sinks' trading entries. Runs while the
    ///      deployer still owns the factory (the locker checks the factory's owner).
    function _configureSinks(Apps memory a, address locker, address keeper) internal {
        PikaLocker(locker).setLiquidityApp(a.liquidity, true);
        a.registry.setKeeper(keeper, true);
    }
}
