// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { MockUSDT } from "../src/mocks/MockUSDT.sol";
import { PikaLaunchFactory } from "../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../src/pika-launch/PikaToken.sol";
import { PikaLocker } from "../src/pika-market/infinity/PikaLocker.sol";
import { PikaRouter } from "../src/pika-launch/PikaRouter.sol";
import { PikaTradeLens } from "../src/pika-launch/PikaTradeLens.sol";
import { PikaOrderDeployer } from "../src/pika-launch/PikaOrderDeployer.sol";
import { PikaHook } from "../src/pika-market/infinity/PikaHook.sol";
import { PikaLpManager } from "../src/pika-market/infinity/PikaLpManager.sol";
import { PikaGuard } from "../src/common/PikaGuard.sol";
import { PikaTokenModule } from "../src/pika-launch/openfour/PikaTokenModule.sol";
import { PikaMigrateModule } from "../src/pika-launch/openfour/PikaMigrateModule.sol";
import { OpenFourTypes } from "../src/openfour/libraries/OpenFourTypes.sol";
import { IOpenFourRegistry } from "../src/openfour/interfaces/IOpenFourRegistry.sol";
import { PikaTimelockHandover } from "./PikaTimelockHandover.sol";
import { PikaAppsSetup } from "./PikaAppsSetup.sol";
import { OpenFourStandardModules } from "./OpenFourStandardModules.sol";
import { PikaRelease } from "./PikaRelease.sol";

/// @notice OpenFour Registry and FeeRouter governance entries a Registry owner uses to list a preset.
interface IOpenFourAdminRegistry {
    function owner() external view returns (address);
    function openFourCore() external view returns (address);
    function openFourTool() external view returns (address);
    function upsertModule(
        bytes32 moduleKey,
        address implementation,
        uint8 kind,
        OpenFourTypes.ModuleMetadata calldata metadata,
        bool active
    ) external;
    function upsertTokenImpl(bytes32 tokenImplId, address implementation, string calldata version) external;
    function upsertPreset(OpenFourTypes.Preset calldata preset) external;
    function getModuleImplementation(bytes32 moduleKey) external view returns (address);
}

interface IOpenFourAdminCore {
    function feeRouter() external view returns (address);
    function wrappedNative() external view returns (address);
}

interface IOpenFourAdminFeeRouter {
    struct OverriddenFeeConfig {
        uint16 protocolFeeBps;
        uint16 developerFeePoolBps;
        uint16 maxProtocolDevFeeBps;
        uint16 maxTaxBps;
        uint8 maxTaxTiers;
        bool active;
        uint256 partnerProtocolShareBps;
    }

    function setPresetFeeConfig(uint256 presetId, OverriddenFeeConfig calldata cfg) external;
}

/// @notice Pika on OpenFour, BSC testnet: the outer Infinity components, the app registry with the three default
///         sinks, the launch hub, the Pika token implementation and the two Pika OpenFour modules (token, migrate),
///         listed as the Pika preset in a developer-owned OpenFour fork (`ForkOpenFourTestnet`, `OPENFOUR_REGISTRY`).
///         The vault, curve and trade slots are OpenFour's standard vault, bonding curve and simple trade policy: the
///         fork lists them from OpenFour's testnet hub when it does not yet. The preset has no custom data module.
/// @dev Simulate first. PRIVATE_KEY signs only on chain 97 and must own the OpenFour Registry and FeeRouter.
///      The preset charges what OpenFour mainnet charges community presets: 0.5% protocol plus 0.5% developer fee
///      (to the Pika treasury, the preset author) on the curve, half of the protocol fee shared with the partner.
///      The hub, the app registry and the guardian seat end up behind a TimelockController (PONS_TIMELOCK_DELAY,
///      default 10 minutes); PONS_GUARDIAN (default the deployer) is the guardian.
contract DeployPikaTestnetScript is Script, PikaTimelockHandover, PikaAppsSetup {
    uint256 internal constant MIN_TARGET_BNB = 0.1 ether;
    uint256 internal constant MIN_TARGET_USDT = 10 ether;
    address public constant VAULT = 0x2CdB3EC82EE13d341Dc6E73637BE0Eab79cb79dD;
    address public constant CL_POOL_MANAGER = 0x36A12c70c9Cf64f24E89ee132BF93Df2DCD199d4;
    address public constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    struct Modules {
        address tokenImpl;
        address tokenModule;
        address vault;
        address curve;
        address trade;
        address migrate;
    }

    struct Deployment {
        PikaLaunchFactory hub;
        MockUSDT quote;
        PikaGuard guard;
        Apps apps;
        PikaLaunchFactory.Components components;
        PikaTradeLens lens;
        Modules modules;
        TimelockController timelock;
        uint256 presetId;
    }

    function run() external returns (Deployment memory d) {
        require(block.chainid == 97, "BSC testnet only");
        require(address(ICLPoolManager(CL_POOL_MANAGER).vault()) == VAULT, "wrong Infinity vault");
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address owner = vm.envOr("PONS_OWNER", deployer);
        address guardian = vm.envOr("PONS_GUARDIAN", deployer);
        address treasury = vm.envOr("PONS_TREASURY", owner);
        address existingQuote = vm.envOr("PONS_QUOTE", address(0));
        uint256 delay = vm.envOr("PONS_TIMELOCK_DELAY", uint256(10 minutes));
        uint256 upgradeDelay = vm.envOr("PONS_UPGRADE_TIMELOCK_DELAY", uint256(30 minutes));
        IOpenFourAdminRegistry registry = IOpenFourAdminRegistry(vm.envAddress("OPENFOUR_REGISTRY"));
        d.presetId = vm.envOr("PIKA_PRESET_ID", uint256(1_778_000_000_001));
        address core = registry.openFourCore();
        require(registry.owner() == deployer, "deployer must own the OpenFour Registry");
        require(IOpenFourAdminCore(core).wrappedNative() == WBNB, "Core wrapped native");
        require(upgradeDelay >= delay, "upgrade timelock must not be faster");

        vm.startBroadcast(key);
        d.quote = existingQuote == address(0) ? new MockUSDT(deployer) : MockUSDT(existingQuote);
        d.guard = new PikaGuard(deployer);
        d.apps = _deployApps(deployer, address(d.guard), owner, upgradeDelay);
        d.components = _deployComponents(treasury);
        d.hub = PikaLaunchFactory(
            payable(
                PikaRelease.deploy(
                    "PikaLaunchFactory",
                    abi.encode(
                        deployer,
                        address(d.guard),
                        treasury,
                        IVault(VAULT),
                        ICLPoolManager(CL_POOL_MANAGER),
                        address(d.apps.registry),
                        d.components
                    )
                )
            )
        );
        _bind(d);
        d.guard.setGuardian(guardian);
        _listApps(d.apps);
        _configureSinks(d.apps, d.components.locker, vm.envOr("PONS_KEEPER", deployer));
        d.hub.setCore(core);
        d.modules = _deployModules(address(d.hub), core);
        d.hub.setTokenImplementation(d.modules.tokenImpl, true);
        _listPreset(registry, IOpenFourAdminCore(core).feeRouter(), d, treasury);
        d.hub.setPreset(d.presetId, true);
        d.hub.configureQuote(WBNB, true, MIN_TARGET_BNB);
        d.hub.configureQuote(address(d.quote), true, MIN_TARGET_USDT);
        d.lens = new PikaTradeLens();
        Ownable2Step[] memory owned = new Ownable2Step[](3);
        (owned[0], owned[1], owned[2]) = (d.hub, d.apps.registry, d.guard);
        d.timelock = _handOverToTimelock(owned, deployer, owner, delay);
        vm.stopBroadcast();

        _check(d, core, treasury, guardian);
        _log(d, core, deployer, treasury);
    }

    function _deployComponents(address treasury) internal returns (PikaLaunchFactory.Components memory c) {
        IVault v = IVault(VAULT);
        ICLPoolManager m = ICLPoolManager(CL_POOL_MANAGER);
        PikaHook hook = new PikaHook(v, m);
        c.router = address(new PikaRouter(WBNB, v, m));
        c.locker = address(new PikaLocker(v, m, treasury));
        c.orderDeployer = address(new PikaOrderDeployer(hook));
        c.hook = address(hook);
        c.lpManager = address(new PikaLpManager(v, m, hook));
    }

    function _bind(Deployment memory d) internal {
        PikaRouter(payable(d.components.router)).bindFactory(address(d.hub));
        PikaLocker(d.components.locker).bindFactory(address(d.hub));
        PikaOrderDeployer(d.components.orderDeployer).bindFactory(address(d.hub));
        PikaHook(d.components.hook).bindFactory(address(d.hub));
        d.apps.registry.setFactory(address(d.hub), true);
    }

    function _deployModules(address hub, address core) internal returns (Modules memory m) {
        m.tokenImpl = PikaRelease.deploy("PikaToken", abi.encode(hub, IVault(VAULT), ICLPoolManager(CL_POOL_MANAGER)));
        m.tokenModule = PikaRelease.deploy("PikaTokenModule", abi.encode(hub, core));
        m.migrate = PikaRelease.deploy("PikaMigrateModule", abi.encode(hub, core));
    }

    function _id(string memory tag) internal pure returns (bytes32) {
        return keccak256(bytes(tag));
    }

    function _module(
        IOpenFourAdminRegistry registry,
        string memory tag,
        address impl,
        uint8 kind,
        string memory name,
        address author
    ) internal {
        registry.upsertModule(
            _id(tag),
            impl,
            kind,
            OpenFourTypes.ModuleMetadata({
                moduleId: _id(tag), version: "1.0.0", name: name, description: "Pika launch", author: author, feeShareBps: 0
            }),
            true
        );
    }

    /// @dev Lists one of OpenFour's own modules in the fork from OpenFour's testnet hub, unless it is there already.
    function _listStandard(
        IOpenFourAdminRegistry registry,
        bytes32 key,
        string memory tag,
        IOpenFourRegistry.ModuleKind kind
    ) internal {
        if (OpenFourStandardModules.listed(address(registry), key, tag, kind)) return;
        (address impl, IOpenFourRegistry.ModuleRecord memory rec) = OpenFourStandardModules.hubRecord(key, tag, kind);
        registry.upsertModule(key, impl, uint8(kind), rec.metadata, true);
    }

    /// @dev Registers the Pika token implementation and modules in the OpenFour Registry (and OpenFour's standard vault,
    ///      bonding curve and simple trade policy from the hub's records, if the fork lacks them), lists the Pika
    ///      preset with the hub as its validator, the treasury as its author and no custom data module, and sets the
    ///      preset's fees.
    function _listPreset(IOpenFourAdminRegistry registry, address feeRouter, Deployment memory d, address treasury)
        internal
    {
        Modules memory m = d.modules;
        registry.upsertTokenImpl(_id("token.pika"), m.tokenImpl, "1.0.0");
        _module(registry, "module.token.pika", m.tokenModule, 0, "PikaTokenModule", treasury);
        _module(registry, "module.migrate.pika_infinity", m.migrate, 4, "PikaMigrateModule", treasury);
        _listStandard(
            registry,
            OpenFourStandardModules.VAULT_KEY,
            OpenFourStandardModules.VAULT_TAG,
            IOpenFourRegistry.ModuleKind.Vault
        );
        _listStandard(
            registry,
            OpenFourStandardModules.CURVE_KEY,
            OpenFourStandardModules.CURVE_TAG,
            IOpenFourRegistry.ModuleKind.Curve
        );
        _listStandard(
            registry,
            OpenFourStandardModules.TRADE_KEY,
            OpenFourStandardModules.TRADE_TAG,
            IOpenFourRegistry.ModuleKind.Trade
        );
        d.modules.vault = registry.getModuleImplementation(OpenFourStandardModules.VAULT_KEY);
        d.modules.curve = registry.getModuleImplementation(OpenFourStandardModules.CURVE_KEY);
        d.modules.trade = registry.getModuleImplementation(OpenFourStandardModules.TRADE_KEY);
        registry.upsertPreset(
            OpenFourTypes.Preset({
                id: d.presetId,
                name: "Pika",
                description: "Pika: OpenFour bonding curve, graduating into a locked Pancake Infinity pool",
                version: "1.0.0",
                active: true,
                createEnabled: true,
                validator: address(d.hub),
                tokenModuleId: _id("module.token.pika"),
                vaultModuleId: OpenFourStandardModules.VAULT_KEY,
                curveModuleId: OpenFourStandardModules.CURVE_KEY,
                tradeModuleId: OpenFourStandardModules.TRADE_KEY,
                migrateModuleId: _id("module.migrate.pika_infinity"),
                tokenImplId: _id("token.pika"),
                customDataId: bytes32(0),
                author: treasury
            })
        );
        IOpenFourAdminFeeRouter(feeRouter)
            .setPresetFeeConfig(
                d.presetId,
                IOpenFourAdminFeeRouter.OverriddenFeeConfig({
                    protocolFeeBps: 50,
                    developerFeePoolBps: 50,
                    maxProtocolDevFeeBps: 100,
                    maxTaxBps: 1000,
                    maxTaxTiers: 5,
                    active: true,
                    partnerProtocolShareBps: 5000
                })
            );
    }

    function _check(Deployment memory d, address core, address treasury, address guardian) internal view {
        PikaLaunchFactory.Components memory c = d.components;
        require(d.hub.treasury() == treasury && PikaLocker(c.locker).treasury() == treasury, "treasury");
        require(d.hub.PROTOCOL_VERSION() == 12 && d.quote.decimals() == 18, "protocol or quote decimals");
        require(
            PikaLocker(c.locker).factory() == address(d.hub)
                && PikaOrderDeployer(c.orderDeployer).factory() == address(d.hub)
                && PikaHook(c.hook).factory() == address(d.hub) && d.apps.registry.factories(address(d.hub))
                && d.apps.registry.templateCount() == 3 && PikaLocker(c.locker).liquidityApps(d.apps.liquidity),
            "components not bound"
        );
        require(
            d.hub.core() == core && d.hub.presets(d.presetId) && d.hub.tokenImplementations(d.modules.tokenImpl),
            "OpenFour wiring"
        );
        address registry = vm.envAddress("OPENFOUR_REGISTRY");
        require(OpenFourStandardModules.vaultListed(registry), "standard vault not listed");
        require(OpenFourStandardModules.curveListed(registry), "bonding curve not listed");
        require(OpenFourStandardModules.tradeListed(registry), "simple trade policy not listed");
        require(
            d.hub.owner() == address(d.timelock) && d.apps.registry.owner() == address(d.timelock)
                && d.guard.guardian() == guardian,
            "handover"
        );
    }

    function _log(Deployment memory d, address core, address deployer, address treasury) internal pure {
        console2.log("Deployer", deployer);
        console2.log("Launch hub (PikaLaunchFactory)", address(d.hub));
        console2.log("OpenFour Core", core);
        console2.log("Pika preset id", d.presetId);
        console2.log("Mock USDT", address(d.quote));
        console2.log("Token implementation", d.modules.tokenImpl);
        console2.log("Token module", d.modules.tokenModule);
        console2.log("Vault (OpenFour module.vault.standard implementation)", d.modules.vault);
        console2.log("Curve (OpenFour module.curve.bonding implementation)", d.modules.curve);
        console2.log("Trade (OpenFour module.trade.simple implementation)", d.modules.trade);
        console2.log("Migrate module", d.modules.migrate);
        console2.log("Trading router", d.components.router);
        console2.log("LP locker", d.components.locker);
        console2.log("Order deployer", d.components.orderDeployer);
        console2.log("Pool hook", d.components.hook);
        console2.log("LP manager", d.components.lpManager);
        console2.log("Trade lens", address(d.lens));
        console2.log("Guardian seat (PikaGuard)", address(d.guard));
        console2.log("Timelock", address(d.timelock));
        console2.log("App registry", address(d.apps.registry));
        console2.log("Burn app", d.apps.burn);
        console2.log("Dividend app", d.apps.dividend);
        console2.log("Liquidity app", d.apps.liquidity);
        console2.log("Treasury", treasury);
    }
}
