// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PikaLaunchFactory } from "../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../src/pika-launch/PikaToken.sol";
import { PikaTokenModule } from "../src/pika-launch/openfour/PikaTokenModule.sol";
import { PikaModuleBase } from "../src/pika-launch/openfour/PikaModuleBase.sol";
import { PikaMigrateModule } from "../src/pika-launch/openfour/PikaMigrateModule.sol";
import { PikaRouter } from "../src/pika-launch/PikaRouter.sol";
import { PikaTradeLens } from "../src/pika-launch/PikaTradeLens.sol";
import { PikaOrderDeployer } from "../src/pika-launch/PikaOrderDeployer.sol";
import { PikaHook } from "../src/pika-market/infinity/PikaHook.sol";
import { IPikaPositionManager } from "../src/pika-market/interfaces/IPikaMarket.sol";
import { PikaLiquidityApp } from "../src/pika-apps/PikaLiquidityApp.sol";
import { PikaAppRegistry } from "../src/pika-apps/PikaAppRegistry.sol";
import { PikaGuard } from "../src/common/PikaGuard.sol";
import { PikaTimelockHandover } from "./PikaTimelockHandover.sol";
import { PikaAppsSetup } from "./PikaAppsSetup.sol";
import { OpenFourStandardModules } from "./OpenFourStandardModules.sol";
import { IOpenFourRegistry } from "../src/openfour/interfaces/IOpenFourRegistry.sol";
import { PikaRelease } from "./PikaRelease.sol";

/// @dev Read-only getters of a Safe that the pre-flight checks use.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @dev OpenFour's Registry and Core as the pre-flight checks read them.
interface IOpenFourMainnetRegistry {
    function openFourCore() external view returns (address);
}

interface IOpenFourMainnetCore {
    function wrappedNative() external view returns (address);
    function registry() external view returns (address);
}

/// @notice The production deployment of the protocol (v12, Pika on OpenFour: no price limits, no venue lock) on BNB
///         Chain mainnet (chain 56): everything the BSC testnet deployment (DeployPikaTestnet.s.sol) has, on real
///         assets, except the OpenFour listing. No mock token is deployed.
///         - OpenFour runs the curve. Four.meme owns OpenFour's mainnet Registry and FeeRouter, so this script lists
///           nothing there: it deploys the Pika token implementation and the two Pika module implementations (token,
///           migrate) and logs what Four.meme registers (tags, kinds, the hub as the preset validator, TREASURY_SAFE
///           as the author, the preset fees). The vault, curve and trade slots are OpenFour's own standard vault,
///           bonding curve and simple trade policy, already in their Registry; the preset has no custom data module.
///           The hub accepts the preset once PIKA_PRESET_ID is known: set it in the environment for this run, or
///           later as an owner-timelock call `setPreset(id, true)` (docs/MAINNET_DEPLOYMENT.md).
///         - Platform fees go straight to TREASURY_SAFE (no membership contracts in Pika).
///         - App registry with the three UUPS default sinks (burn, dividend, liquidity)
///           and the template upgrade TimelockController (UPGRADE_TIMELOCK_DELAY, roles to UPGRADE_PROPOSER_SAFE).
///         - The launch hub (PikaLaunchFactory, bound to OpenFour's Core), and one components set on Pancake
///           Infinity: router, hook, the order deployer and Pancake's CL position manager, through which graduation
///           mints each launch's opening position to the burn address (no Pika locker, no Pika LP manager: anyone
///           adds and removes liquidity through Pancake's position manager).
///         - KEEPER may run the sinks' trading entries. The app registry allows one
///           app per launch besides the default sinks (`maxApps` 1).
///         - Quotes: BNB (WBNB on the curve; Core takes and pays native BNB) and USDT.
///         - PikaTradeLens, the stateless quote/balance lens the web calls.
///         - The owner TimelockController (OWNER_TIMELOCK_DELAY, roles to OWNER_SAFE) takes the factory, the app
///           registry and the guardian seat (PikaGuard) in the same run (PikaTimelockHandover).
///         - GUARDIAN sits in PikaGuard, which every guarded contract reads (docs/PIKA_CONTRACTS.md §8): it may stop
///           new launches, revoke the keeper, disable or pause templates at once, and nothing else; every reversal
///           is the owner timelock's.
/// @dev Fill in the CONFIG block below; `run()` refuses while a required address is zero. Simulate first, without
///      `--broadcast`; sign with a CLI signer (`--ledger`, `--account <name>` or `--private-key`; add `--sender
///      <deployer>` when several signers are given):
///        forge script script/DeployPikaMainnet.s.sol:DeployPikaMainnetScript --rpc-url "$RPC_URL" --ledger
///      Afterwards `node script/record_pika.mjs` writes the deployment record for chain 56.
///      `deploy(Config)` runs the same deployment for any configuration, which is how the fork test drives it.
contract DeployPikaMainnetScript is Script, PikaTimelockHandover, PikaAppsSetup {
    // =================================================================================================================
    // CONFIG: fill in before running. Placeholders are address(0); run() refuses while any of them is still zero.
    // =================================================================================================================

    /// @dev Platform admin Safe (must be a deployed Safe): proposer, executor and canceller of the owner timelock,
    ///      which owns the factory and the app registry.
    address internal constant OWNER_SAFE = address(0);
    /// @dev Platform treasury (must be a deployed Safe; may equal OWNER_SAFE): receives every platform fee, the
    ///      platform's cut of project fees and the quote a graduation leaves over (claimed from the factory). Fixed in
    ///      the factory for good.
    address internal constant TREASURY_SAFE = address(0);
    /// @dev Template upgrade Safe (must be a deployed Safe; may equal OWNER_SAFE): proposer, executor and canceller
    ///      of the template upgrade timelock, the only account that may upgrade app templates (existing launches
    ///      included).
    address internal constant UPGRADE_PROPOSER_SAFE = address(0);
    /// @dev Keeper hot wallet (server worker key): the app registry's keeper, the only account that may run the fee
    ///      sinks' trading entries (burn buybacks, liquidity adds).
    address internal constant KEEPER = address(0);
    /// @dev Emergency account (an on-call Safe with a low threshold, or a hardware wallet; not required to be a Safe):
    ///      the guardian in PikaGuard. It can only tighten, so a lost key costs at most a stop the owner lifts
    ///      (after OWNER_TIMELOCK_DELAY). Must differ from both Safes and from every hot key.
    address internal constant GUARDIAN = address(0);

    /// @dev Delay of every owner call (factory, app registry, guard). User decision 2026-11-01, reaffirmed 2026-11-08
    ///      (review 2026-11-07c, T-9): 0 while the deployment settles, to be raised to 24 hours afterwards. A running
    ///      deployment changes its delay only through the timelock itself (`updateDelay`, after its current delay;
    ///      UpdatePikaImplementations PONS_OWNER_TIMELOCK_DELAY), so this constant reaches new deployments only.
    uint256 internal constant OWNER_TIMELOCK_DELAY = 0;
    /// @dev Delay of every app template upgrade, the one entry that reaches funds of existing launches; must not be
    ///      shorter than OWNER_TIMELOCK_DELAY. Same decision: 0 at first, raised later the same way
    ///      (PONS_UPGRADE_TIMELOCK_DELAY) to at least the owner delay.
    uint256 internal constant UPGRADE_TIMELOCK_DELAY = 0;
    /// @dev Both Safes must answer `getThreshold()` with at least this many signatures.
    uint256 internal constant MIN_SAFE_THRESHOLD = 2;

    /// @dev BNB the deployer must hold for gas; it pays nothing else. The deployment is about 60 transactions and
    ///      56M gas (forge reserves ~72M of gas limits; 0.0036 BNB at 0.05 gwei in the 2026-10-20 simulation), so
    ///      0.05 BNB covers gas prices up to ~0.7 gwei.
    uint256 internal constant GAS_RESERVE = 0.05 ether;

    // =================================================================================================================
    // BNB Chain mainnet contracts (validated on chain by the pre-flight checks)
    // =================================================================================================================

    /// @dev OpenFour on BNB Chain mainnet (openfour-docs integration guide §2).
    address public constant OPENFOUR_REGISTRY = 0x912CEf0C3aE9Ab6eB3Ec87cab69371cFb317Ab94;
    address public constant OPENFOUR_CORE = 0xebe7b6C1089D9F72aD07f34E36d898e44E5e27f3;

    /// @dev Pancake Infinity on BNB Chain mainnet.
    address public constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address public constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address public constant UNIVERSAL_ROUTER = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    /// @dev Pancake's official CL position manager (the LP NFT "Pancakeswap Infinity Positions NFT").
    address public constant CL_POSITION_MANAGER = 0x55f4c8abA71A1e923edC303eb4fEfF14608cC226;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev BSC-USD (Binance-Peg Tether), 18 decimals.
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @dev The smallest graduation target a launch may set per quote (2026-10-21): 0.1 BNB, 10 USDT.
    uint256 internal constant MIN_TARGET_BNB = 0.1 ether;
    uint256 internal constant MIN_TARGET_USDT = 10 ether;

    struct Config {
        address deployer;
        address ownerSafe;
        address upgradeProposerSafe;
        address keeper;
        address guardian;
        address treasury;
        uint256 ownerDelay;
        uint256 upgradeDelay;
        uint256 minSafeThreshold;
        uint256 gasReserve;
        /// @dev Interim launch (user decision 2026-10-30): the deployer holds every role (both timelocks' proposer,
        ///      executor and canceller, guardian, keeper, treasury) until the
        ///      owner hands them to the Safes (docs/MAINNET_DEPLOYMENT.md §7). The timelocks and their CONFIG delays
        ///      stay (both 0 since 2026-11-01).
        bool deployerHeld;
        /// @dev The Pika preset id Four.meme listed in OpenFour's Registry; 0 leaves `setPreset` to a later
        ///      owner-timelock call (env PIKA_PRESET_ID).
        uint256 presetId;
    }

    /// @notice The Pika token implementation and the two module implementations Four.meme registers (the vault, curve
    ///         and trade slots are OpenFour's standard vault, bonding curve and simple trade policy; `curve` and
    ///         `trade` record those modules' current implementations).
    struct Modules {
        address tokenImplementation;
        address tokenModule;
        address curve;
        address trade;
        address migrate;
    }

    struct Deployment {
        PikaLaunchFactory factory;
        TimelockController ownerTimelock;
        PikaGuard guard;
        address treasury;
        PikaTradeLens lens;
        Apps apps;
        Modules modules;
        PikaLaunchFactory.Components components;
    }

    /// @notice Deploys with the CONFIG block; the deployer is the CLI signer (`msg.sender` of a script run).
    function run() external returns (Deployment memory) {
        Config memory c = config(msg.sender);
        c.presetId = vm.envOr("PIKA_PRESET_ID", uint256(0));
        return deploy(c);
    }

    /// @notice Interim deployment where the deployer holds every role until it hands them to the Safes:
    ///        forge script script/DeployPikaMainnet.s.sol:DeployPikaMainnetScript --sig 'runDeployerHeld()' ...
    function runDeployerHeld() external returns (Deployment memory) {
        Config memory c = deployerHeldConfig(msg.sender);
        c.presetId = vm.envOr("PIKA_PRESET_ID", uint256(0));
        return deploy(c);
    }

    /// @notice The CONFIG block's delays and limits with every role address set to `deployer`.
    function deployerHeldConfig(address deployer) public pure returns (Config memory c) {
        c = config(deployer);
        (c.ownerSafe, c.upgradeProposerSafe, c.keeper, c.guardian, c.treasury) =
        (deployer, deployer, deployer, deployer, deployer);
        c.deployerHeld = true;
    }

    /// @notice The CONFIG block as a Config for `deployer`.
    function config(address deployer) public pure returns (Config memory c) {
        c.deployer = deployer;
        c.ownerSafe = OWNER_SAFE;
        c.upgradeProposerSafe = UPGRADE_PROPOSER_SAFE;
        c.keeper = KEEPER;
        c.guardian = GUARDIAN;
        c.treasury = TREASURY_SAFE;
        c.ownerDelay = OWNER_TIMELOCK_DELAY;
        c.upgradeDelay = UPGRADE_TIMELOCK_DELAY;
        c.minSafeThreshold = MIN_SAFE_THRESHOLD;
        c.gasReserve = GAS_RESERVE;
    }

    /// @notice The whole deployment for `cfg`: pre-flight checks, one broadcast from `cfg.deployer`, then the
    ///         post-deployment checks. Reverts before broadcasting anything if a check fails.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        _checkConfig(cfg);
        _checkChain(cfg);

        vm.startBroadcast(cfg.deployer);
        d.guard = new PikaGuard(cfg.deployer);
        d.treasury = cfg.treasury;
        d.apps =
            _deployApps(cfg.deployer, address(d.guard), cfg.upgradeProposerSafe, cfg.upgradeDelay, CL_POSITION_MANAGER);
        _deployFactory(cfg, d);
        _wire(cfg, d);
        d.lens = new PikaTradeLens();
        Ownable2Step[] memory owned = new Ownable2Step[](3);
        (owned[0], owned[1], owned[2]) = (d.factory, d.apps.registry, d.guard);
        d.ownerTimelock = _handOverToTimelock(owned, cfg.deployer, cfg.ownerSafe, cfg.ownerDelay);
        vm.stopBroadcast();

        _verifyFactory(cfg, d);
        _verifyMarkets(cfg, d);
        _verifyRoles(cfg, d);
        _log(cfg, d);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Pre-flight checks (nothing is broadcast before they pass)
    // -----------------------------------------------------------------------------------------------------------------

    function _checkConfig(Config memory cfg) internal view {
        string memory missing;
        if (cfg.ownerSafe == address(0)) missing = string.concat(missing, " OWNER_SAFE");
        if (cfg.upgradeProposerSafe == address(0)) missing = string.concat(missing, " UPGRADE_PROPOSER_SAFE");
        if (cfg.keeper == address(0)) missing = string.concat(missing, " KEEPER");
        if (cfg.guardian == address(0)) missing = string.concat(missing, " GUARDIAN");
        if (cfg.treasury == address(0)) missing = string.concat(missing, " TREASURY_SAFE");
        require(
            bytes(missing).length == 0,
            string.concat("CONFIG incomplete in script/DeployPikaMainnet.s.sol, set:", missing)
        );
        require(
            cfg.deployer != address(0) && cfg.deployer != DEFAULT_SENDER,
            "no deployer: sign with --ledger, --account or --private-key (add --sender when several signers are given)"
        );
        require(
            cfg.upgradeDelay >= cfg.ownerDelay, "UPGRADE_TIMELOCK_DELAY must not be shorter than OWNER_TIMELOCK_DELAY"
        );
        if (cfg.deployerHeld) {
            address[5] memory roles = [cfg.ownerSafe, cfg.upgradeProposerSafe, cfg.keeper, cfg.guardian, cfg.treasury];
            for (uint256 i; i < roles.length; ++i) {
                require(roles[i] == cfg.deployer, "deployer-held: every role must be the deployer");
            }
            return;
        }
        _requireSafe(cfg.ownerSafe, "OWNER_SAFE", cfg.minSafeThreshold);
        _requireSafe(cfg.upgradeProposerSafe, "UPGRADE_PROPOSER_SAFE", cfg.minSafeThreshold);
        _requireSafe(cfg.treasury, "TREASURY_SAFE", cfg.minSafeThreshold);
        // The deployer and the keeper are separate hot keys, and neither is one of the Safes.
        address[2] memory hot = [cfg.deployer, cfg.keeper];
        for (uint256 i; i < hot.length; ++i) {
            require(
                hot[i] != cfg.ownerSafe && hot[i] != cfg.upgradeProposerSafe && hot[i] != cfg.treasury,
                "deployer and KEEPER must not be a Safe"
            );
        }
        require(cfg.deployer != cfg.keeper, "deployer and KEEPER must differ");
        // The guardian is its own key: neither Safe (their timelocks already hold every power) nor a hot key.
        require(
            cfg.guardian != cfg.ownerSafe && cfg.guardian != cfg.upgradeProposerSafe && cfg.guardian != cfg.treasury,
            "GUARDIAN must not be one of the Safes"
        );
        for (uint256 i; i < hot.length; ++i) {
            require(cfg.guardian != hot[i], "GUARDIAN must differ from the deployer and the keeper");
        }
    }

    /// @dev A Safe: deployed code that answers `getThreshold()` with at least `minThreshold`.
    function _requireSafe(address safe, string memory name, uint256 minThreshold) internal view {
        require(safe.code.length != 0, string.concat(name, " has no code: it must be a deployed Safe"));
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeCall(ISafe.getThreshold, ()));
        require(ok && ret.length == 32, string.concat(name, " does not answer getThreshold(): not a Safe"));
        require(abi.decode(ret, (uint256)) >= minThreshold, string.concat(name, " threshold below MIN_SAFE_THRESHOLD"));
    }

    /// @dev The chain, the Pancake and token contracts the deployment binds forever, and the deployer's funds.
    function _checkChain(Config memory cfg) internal view {
        require(block.chainid == 56, "BNB Chain mainnet (chain 56) only");
        require(address(ICLPoolManager(CL_POOL_MANAGER).vault()) == VAULT, "wrong Infinity vault");
        require(UNIVERSAL_ROUTER.code.length != 0, "Infinity Universal Router missing");
        require(
            address(IPikaPositionManager(CL_POSITION_MANAGER).clPoolManager()) == CL_POOL_MANAGER
                && address(IPikaPositionManager(CL_POSITION_MANAGER).vault()) == VAULT,
            "wrong Infinity position manager"
        );
        require(
            keccak256(bytes(IERC20Metadata(WBNB).symbol())) == keccak256("WBNB")
                && IERC20Metadata(WBNB).decimals() == 18,
            "wrong WBNB"
        );
        require(
            keccak256(bytes(IERC20Metadata(USDT).symbol())) == keccak256("USDT")
                && IERC20Metadata(USDT).decimals() == 18,
            "wrong USDT"
        );
        require(
            IOpenFourMainnetRegistry(OPENFOUR_REGISTRY).openFourCore() == OPENFOUR_CORE
                && IOpenFourMainnetCore(OPENFOUR_CORE).registry() == OPENFOUR_REGISTRY
                && IOpenFourMainnetCore(OPENFOUR_CORE).wrappedNative() == WBNB,
            "wrong OpenFour Core or Registry"
        );
        require(OpenFourStandardModules.vaultListed(OPENFOUR_REGISTRY), "OpenFour standard vault not listed");
        require(OpenFourStandardModules.curveListed(OPENFOUR_REGISTRY), "OpenFour bonding curve not listed");
        require(OpenFourStandardModules.tradeListed(OPENFOUR_REGISTRY), "OpenFour simple trade policy not listed");
        require(cfg.deployer.balance >= cfg.gasReserve, "deployer holds less BNB than GAS_RESERVE");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Deployment steps (inside the broadcast)
    // -----------------------------------------------------------------------------------------------------------------

    function _deployFactory(Config memory cfg, Deployment memory d) internal {
        IVault vault = IVault(VAULT);
        ICLPoolManager manager = ICLPoolManager(CL_POOL_MANAGER);
        address treasury = d.treasury;
        PikaHook hook = new PikaHook(vault, manager);
        d.components = PikaLaunchFactory.Components(
            address(new PikaRouter(WBNB, vault, manager)),
            address(new PikaOrderDeployer(hook)),
            address(hook),
            CL_POSITION_MANAGER
        );
        d.factory = PikaLaunchFactory(
            payable(
                PikaRelease.deploy(
                    "PikaLaunchFactory",
                    abi.encode(
                        cfg.deployer, address(d.guard), treasury, vault, manager, address(d.apps.registry), d.components
                    )
                )
            )
        );
        address hub = address(d.factory);
        d.modules.tokenImplementation = PikaRelease.deploy("PikaToken", abi.encode(hub, vault, manager));
        d.modules.tokenModule = PikaRelease.deploy("PikaTokenModule", abi.encode(hub, OPENFOUR_CORE));
        d.modules.curve =
            IOpenFourRegistry(OPENFOUR_REGISTRY).getModuleImplementation(OpenFourStandardModules.CURVE_KEY);
        d.modules.trade =
            IOpenFourRegistry(OPENFOUR_REGISTRY).getModuleImplementation(OpenFourStandardModules.TRADE_KEY);
        d.modules.migrate = PikaRelease.deploy("PikaMigrateModule", abi.encode(hub, OPENFOUR_CORE));
    }

    /// @dev Everything that needs the deployer as factory and registry owner, before the timelock handover. The
    ///      templates are listed after the factory deployment: the indexer follows the registry from that block.
    function _wire(Config memory cfg, Deployment memory d) internal {
        PikaLaunchFactory.Components memory c = d.components;
        address factory = address(d.factory);
        PikaRouter(payable(c.router)).bindFactory(factory);
        PikaOrderDeployer(c.orderDeployer).bindFactory(factory);
        PikaHook(c.hook).bindFactory(factory);
        d.apps.registry.setFactory(factory, true);
        d.guard.setGuardian(cfg.guardian);
        _listApps(d.apps);
        _configureSinks(d.apps, cfg.keeper);
        d.factory.setCore(OPENFOUR_CORE);
        d.factory.setTokenImplementation(d.modules.tokenImplementation, true);
        if (cfg.presetId != 0) d.factory.setPreset(cfg.presetId, true);
        d.factory.configureQuote(WBNB, true, MIN_TARGET_BNB);
        d.factory.configureQuote(USDT, true, MIN_TARGET_USDT);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Post-deployment checks
    // -----------------------------------------------------------------------------------------------------------------

    function _verifyFactory(Config memory cfg, Deployment memory d) internal view {
        PikaLaunchFactory f = d.factory;
        require(f.PROTOCOL_VERSION() == 12, "protocol v12 required");
        require(f.componentsVersion() == 1 && f.launchEnabled(), "factory state");
        require(f.treasury() == d.treasury, "factory treasury is not TREASURY_SAFE");
        require(address(f.vault()) == VAULT && address(f.poolManager()) == CL_POOL_MANAGER, "factory Infinity");
        require(f.core() == OPENFOUR_CORE && f.appRegistry() == address(d.apps.registry), "factory core and registry");
        address token = d.modules.tokenImplementation;
        require(f.tokenImplementations(token), "token implementation not allowed");
        require(
            PikaToken(token).factory() == address(f) && address(PikaToken(token).canonicalVault()) == VAULT
                && address(PikaToken(token).poolManager()) == CL_POOL_MANAGER && PikaToken(token).treasury() == d.treasury,
            "token implementation wiring"
        );
        address[2] memory modules = [d.modules.tokenModule, d.modules.migrate];
        for (uint256 i; i < modules.length; ++i) {
            require(PikaModuleBase(modules[i]).hub() == address(f), "module hub");
        }
        require(cfg.presetId == 0 || f.presets(cfg.presetId), "preset");
        (bool bnbEnabled, uint8 bnbDecimals, uint256 bnbMinTarget) = f.quoteConfigs(WBNB);
        (bool usdtEnabled, uint8 usdtDecimals, uint256 usdtMinTarget) = f.quoteConfigs(USDT);
        require(bnbEnabled && bnbDecimals == 18 && usdtEnabled && usdtDecimals == 18, "BNB and USDT quotes");
        require(bnbMinTarget == MIN_TARGET_BNB && usdtMinTarget == MIN_TARGET_USDT, "quote minimum targets");
        // What the web reads before offering a launch: both quotes open, one optional app, the minimum targets.
        address[2] memory quotes = [address(0), USDT];
        for (uint256 i; i < quotes.length; ++i) {
            PikaTradeLens.LaunchOptions memory o = d.lens.launchOptions(address(f), quotes[i]);
            require(
                o.enabled && o.maxApps == 1 && o.minTarget == (i == 0 ? MIN_TARGET_BNB : MIN_TARGET_USDT),
                "lens launch options"
            );
        }
    }

    function _verifyMarkets(Config memory cfg, Deployment memory d) internal view {
        PikaLaunchFactory.Components memory c = d.components;
        address f = address(d.factory);
        (address router, address orders, address hook, address positionManager) = d.factory.components(1);
        require(
            router == c.router && orders == c.orderDeployer && hook == c.hook
                && positionManager == CL_POSITION_MANAGER,
            "published components"
        );
        require(
            PikaRouter(payable(c.router)).factory() == f && PikaOrderDeployer(c.orderDeployer).factory() == f
                && PikaHook(c.hook).factory() == f,
            "components not bound"
        );
        require(PikaOrderDeployer(c.orderDeployer).implementation() != address(0), "order manager");
        // Fee sinks: listed in order, the liquidity sink minting through Pancake's position manager, the keeper set.
        PikaAppRegistry r = d.apps.registry;
        require(r.factories(f) && r.templateCount() == 3 && r.maxApps() == 1, "registry");
        address[3] memory targets = [d.apps.burn, d.apps.dividend, d.apps.liquidity];
        for (uint256 i; i < targets.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            PikaAppRegistry.Template memory t = r.templates(uint32(i));
            require(t.target == targets[i] && t.enabled && t.isDefault, "app templates");
        }
        require(
            address(PikaLiquidityApp(d.apps.liquidity).positionManager()) == CL_POSITION_MANAGER, "sinks not wired"
        );
        require(r.keepers(cfg.keeper), "keeper not set");
    }

    /// @dev Every owner and upgrade role sits with a timelock run by a Safe; the deployer keeps none.
    function _verifyRoles(Config memory cfg, Deployment memory d) internal view {
        TimelockController owner = d.ownerTimelock;
        TimelockController upgrade = d.apps.upgradeTimelock;
        require(
            d.factory.owner() == address(owner) && d.apps.registry.owner() == address(owner)
                && d.guard.owner() == address(owner),
            "factory handover"
        );
        require(
            d.factory.pendingOwner() == address(0) && d.apps.registry.pendingOwner() == address(0)
                && d.guard.pendingOwner() == address(0),
            "pending owners"
        );
        require(d.apps.registry.upgradeAuthority() == address(upgrade), "template upgrade authority");
        require(d.guard.guardian() == cfg.guardian, "guardian");
        address g = address(d.guard);
        require(
            address(d.factory.guard()) == g && address(d.apps.registry.guard()) == g,
            "guard not shared"
        );
        require(owner.getMinDelay() == cfg.ownerDelay && upgrade.getMinDelay() == cfg.upgradeDelay, "timelock delays");
        if (cfg.deployerHeld) {
            _requireDeployerHeldTimelock(owner, cfg.deployer);
            _requireDeployerHeldTimelock(upgrade, cfg.deployer);
            require(d.apps.registry.keepers(cfg.deployer), "deployer-held keeper");
            return;
        }
        _requireTimelockRoles(owner, cfg.ownerSafe, cfg.deployer);
        _requireTimelockRoles(upgrade, cfg.upgradeProposerSafe, cfg.deployer);
        require(!d.apps.registry.keepers(cfg.deployer), "deployer kept the keeper role");
    }

    /// @dev Interim: `deployer` proposes, executes and cancels; the timelock still administers itself.
    function _requireDeployerHeldTimelock(TimelockController t, address deployer) internal view {
        require(
            t.hasRole(t.PROPOSER_ROLE(), deployer) && t.hasRole(t.EXECUTOR_ROLE(), deployer)
                && t.hasRole(t.CANCELLER_ROLE(), deployer),
            "deployer-held timelock roles"
        );
        require(
            !t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer) && t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t)),
            "timelock admin"
        );
        require(!t.hasRole(t.EXECUTOR_ROLE(), address(0)), "open executor role");
    }

    /// @dev `safe` proposes, executes and cancels; the timelock administers itself; `deployer` holds nothing.
    function _requireTimelockRoles(TimelockController t, address safe, address deployer) internal view {
        bytes32[4] memory roles = [t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE(), t.DEFAULT_ADMIN_ROLE()];
        for (uint256 i; i < roles.length; ++i) {
            require(!t.hasRole(roles[i], deployer), "deployer kept a timelock role");
            require(t.hasRole(roles[i], i < 3 ? safe : address(t)), "timelock roles");
        }
        // Executing is not open to everyone.
        require(!t.hasRole(t.EXECUTOR_ROLE(), address(0)), "open executor role");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------------------------------------------------

    function _log(Config memory cfg, Deployment memory d) internal view {
        PikaLaunchFactory.Components memory c = d.components;
        console2.log("Chain ID", block.chainid);
        console2.log("Deployer", cfg.deployer);
        console2.log("Launch hub (PikaLaunchFactory)", address(d.factory));
        console2.log("Protocol version", uint256(d.factory.PROTOCOL_VERSION()));
        console2.log("OpenFour Core", OPENFOUR_CORE);
        console2.log("Quote USDT", USDT);
        _logOpenFourListing(d);
        console2.log("Pika preset id accepted by the hub (0 = later owner-timelock setPreset)", cfg.presetId);
        console2.log("Trading router", c.router);
        console2.log("Pool hook", c.hook);
        console2.log("Pancake CL position manager (graduation LP NFTs to 0xdead)", c.positionManager);
        console2.log("Order deployer", c.orderDeployer);
        console2.log("Trade lens", address(d.lens));
        console2.log("App registry", address(d.apps.registry));
        console2.log("Burn app", d.apps.burn);
        console2.log("Dividend app", d.apps.dividend);
        console2.log("Liquidity app", d.apps.liquidity);
        console2.log("Treasury (TREASURY_SAFE)", d.treasury);
        console2.log("Registry keeper", cfg.keeper);
        console2.log("Guardian seat (PikaGuard)", address(d.guard));
        console2.log("Guardian", cfg.guardian);
        console2.log("Owner timelock", address(d.ownerTimelock));
        console2.log("Owner timelock delay (s)", cfg.ownerDelay);
        console2.log("Owner timelock roles (OWNER_SAFE)", cfg.ownerSafe);
        _logSafe(cfg.ownerSafe);
        console2.log("Template upgrade timelock", address(d.apps.upgradeTimelock));
        console2.log("Template upgrade delay (s)", cfg.upgradeDelay);
        console2.log("Template upgrade roles (UPGRADE_PROPOSER_SAFE)", cfg.upgradeProposerSafe);
        _logSafe(cfg.upgradeProposerSafe);
        if (cfg.deployerHeld) {
            console2.log("INTERIM: the deployer holds every role; hand them to the Safes (MAINNET_DEPLOYMENT.md 7)");
            console2.log("NEXT: node script/record_pika.mjs (chain 56) writes the deployment record");
            return;
        }
        console2.log("NEXT: node script/record_pika.mjs (chain 56) writes the deployment record");
    }

    /// @dev What Four.meme registers in OpenFour's Registry: Pika's keys are keccak256 of the tags.
    function _logOpenFourListing(Deployment memory d) internal pure {
        console2.log("FOR FOUR.MEME: upsertTokenImpl token.pika", d.modules.tokenImplementation);
        console2.log("FOR FOUR.MEME: upsertModule module.token.pika (kind 0)", d.modules.tokenModule);
        console2.log("FOR FOUR.MEME: vault slot: OpenFour's module.vault.standard, Registry key");
        console2.logBytes32(OpenFourStandardModules.VAULT_KEY);
        console2.log("FOR FOUR.MEME: curve slot: OpenFour's module.curve.bonding, Registry key");
        console2.logBytes32(OpenFourStandardModules.CURVE_KEY);
        console2.log("FOR FOUR.MEME: trade slot: OpenFour's module.trade.simple, Registry key");
        console2.logBytes32(OpenFourStandardModules.TRADE_KEY);
        console2.log("FOR FOUR.MEME: upsertModule module.migrate.pika_infinity (kind 4)", d.modules.migrate);
        console2.log("FOR FOUR.MEME: customData slot: none (customDataId = 0)");
        console2.log("FOR FOUR.MEME: preset validator (the hub)", address(d.factory));
        console2.log("FOR FOUR.MEME: preset author (developer fee)", d.treasury);
        console2.log("FOR FOUR.MEME: preset fees: protocol 50 bps + developer 50 bps (as Creator Incentives)");
    }

    function _logSafe(address safe) internal view {
        if (safe.code.length == 0) {
            console2.log("  (not a Safe: an EOA)");
            return;
        }
        console2.log("  Safe threshold", ISafe(safe).getThreshold());
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeCall(ISafe.getOwners, ()));
        if (!ok) return;
        address[] memory owners = abi.decode(ret, (address[]));
        for (uint256 i; i < owners.length; ++i) {
            console2.log("  Safe owner", owners[i]);
        }
    }
}
