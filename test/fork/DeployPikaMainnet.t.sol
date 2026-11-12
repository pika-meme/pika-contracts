// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { PikaGuarded } from "../../src/common/PikaGuarded.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { DeployPikaMainnetScript } from "../../script/DeployPikaMainnet.s.sol";
import { OpenFourStandardModules } from "../../script/OpenFourStandardModules.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { PikaTokenParams } from "../../src/pika-launch/interfaces/IPikaLaunch.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaTradeLens } from "../../src/pika-launch/PikaTradeLens.sol";
import { PikaBurnApp } from "../../src/pika-apps/PikaBurnApp.sol";
import { PikaDividendApp } from "../../src/pika-apps/PikaDividendApp.sol";
import { PikaSinkBase } from "../../src/pika-apps/PikaSinkBase.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

interface IMainnetOpenFourRegistry {
    function owner() external view returns (address);
    function upsertModule(
        bytes32 moduleKey,
        address implementation,
        uint8 kind,
        OpenFourTypes.ModuleMetadata calldata metadata,
        bool active
    ) external;
    function upsertTokenImpl(bytes32 tokenImplId, address implementation, string calldata version) external;
    function upsertPreset(OpenFourTypes.Preset calldata preset) external;
}

interface IMainnetOpenFourFeeRouter {
    struct OverriddenFeeConfig {
        uint16 protocolFeeBps;
        uint16 developerFeePoolBps;
        uint16 maxProtocolDevFeeBps;
        uint16 maxTaxBps;
        uint8 maxTaxTiers;
        bool active;
        uint256 partnerProtocolShareBps;
    }

    function owner() external view returns (address);
    function setPresetFeeConfig(uint256 presetId, OverriddenFeeConfig calldata cfg) external;
    function devFeePending(address quoteAsset, address author) external view returns (uint256);
}

interface IMainnetOpenFourCore {
    function signer() external view returns (address);
    function feeRouter() external view returns (address);
    function createToken(bytes memory createArgs, bytes memory signature) external payable returns (address token);
    function buyByBudget(address token, uint256 maxPayAmount, uint256 minAmountOut, uint256 options, bytes calldata)
        external
        payable;
}

/// @dev Stands in for a deployed Safe: code that answers `getThreshold()` and `getOwners()`.
contract MockSafe {
    uint256 private immutable threshold;

    constructor(uint256 threshold_) {
        threshold = threshold_;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external pure returns (address[] memory owners) {
        owners = new address[](2);
        (owners[0], owners[1]) = (address(0x5a1), address(0x5a2));
    }

    receive() external payable { }
}

/// @notice The production mainnet deployment script, run on a BSC mainnet fork against the real Pancake Infinity,
///         WBNB, USDT and OpenFour's real mainnet Core: its pre-flight refusals, then the full deployment with test
///         role addresses, Four.meme's listing (pranked as the Registry and FeeRouter owner), the hub's `setPreset`
///         as an owner-timelock call from the Safe, and launches on both quotes (BNB and USDT) created through Core
///         (its creation signer swapped for a test key in storage), bought, graduated and traded on Infinity, with a
///         keeper sink dispatch.
///         Skipped unless `RUN_PIKA_FORK=true`; `PIKA_FORK_BLOCK` pins the block.
contract DeployPikaMainnetForkTest is Test {
    using SafeERC20 for IERC20;

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    string constant INCOMPLETE = "CONFIG incomplete in script/DeployPikaMainnet.s.sol, set:";

    DeployPikaMainnetScript script;
    address deployer = makeAddr("deployer");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address ownerSafe;
    address upgradeSafe;
    address treasurySafe;
    uint256 salt;
    uint256 constant PRESET_ID = 1_778_000_000_056;
    address constant OPENFOUR_REGISTRY = 0x912CEf0C3aE9Ab6eB3Ec87cab69371cFb317Ab94;
    IMainnetOpenFourCore constant CORE = IMainnetOpenFourCore(0xebe7b6C1089D9F72aD07f34E36d898e44E5e27f3);
    uint256 signerKey = 0x51617;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_PIKA_FORK", false));
        uint256 forkBlock = vm.envOr("PIKA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), forkBlock);
        assertEq(block.chainid, 56, "BSC mainnet fork required");
        emit log_named_uint("BSC fork block", block.number);
        // The script is deployed from its artifact, so this test does not embed (and re-optimize) its bytecode.
        script = DeployPikaMainnetScript(vm.deployCode("DeployPikaMainnet.s.sol:DeployPikaMainnetScript"));
        ownerSafe = address(new MockSafe(3));
        upgradeSafe = address(new MockSafe(2));
        treasurySafe = address(new MockSafe(2));
        vm.deal(deployer, 1 ether);
        deal(USDT, deployer, 5 ether);
        vm.deal(creator, 1 ether);
        vm.deal(buyer, 200 ether);
        deal(USDT, buyer, 100_000 ether);
    }

    /// @dev The CONFIG block's delays, amounts and limits with this test's role addresses.
    function _config() internal view returns (DeployPikaMainnetScript.Config memory c) {
        c = script.config(deployer);
        c.ownerSafe = ownerSafe;
        c.upgradeProposerSafe = upgradeSafe;
        c.keeper = keeper;
        c.guardian = guardian;
        c.treasury = treasurySafe;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Pre-flight refusals: nothing is broadcast
    // -----------------------------------------------------------------------------------------------------------------

    function testRunRefusesWhileTheConfigIsIncomplete() public {
        DeployPikaMainnetScript.Config memory c = script.config(deployer);
        if (c.ownerSafe == address(0) && c.upgradeProposerSafe == address(0) && c.keeper == address(0)) {
            vm.expectRevert(
                bytes(
                    string.concat(
                        INCOMPLETE,
                        " OWNER_SAFE UPGRADE_PROPOSER_SAFE KEEPER GUARDIAN TREASURY_SAFE"
                    )
                )
            );
        } else {
            // Filled in (2026-11-12): the CONFIG is complete, so an unfunded deployer is the first refusal.
            vm.deal(address(this), 0);
            vm.expectRevert(bytes("deployer holds less BNB than GAS_RESERVE"));
        }
        script.run();

        c = _config();
        c.keeper = address(0);
        c.treasury = address(0);
        _expectRefusal(c, string.concat(INCOMPLETE, " KEEPER TREASURY_SAFE"));
    }

    function testDeployRefusesUnsafeConfigs() public {
        DeployPikaMainnetScript.Config memory c = _config();
        c.deployer = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
        _expectRefusal(
            c,
            "no deployer: sign with --ledger, --account or --private-key (add --sender when several signers are given)"
        );

        c = _config();
        c.ownerSafe = makeAddr("eoa");
        _expectRefusal(c, "OWNER_SAFE has no code: it must be a deployed Safe");
        c = _config();
        c.upgradeProposerSafe = USDT;
        _expectRefusal(c, "UPGRADE_PROPOSER_SAFE does not answer getThreshold(): not a Safe");
        c = _config();
        c.ownerSafe = address(new MockSafe(1));
        _expectRefusal(c, "OWNER_SAFE threshold below MIN_SAFE_THRESHOLD");

        c = _config();
        c.treasury = makeAddr("eoa");
        _expectRefusal(c, "TREASURY_SAFE has no code: it must be a deployed Safe");
        c = _config();
        c.guardian = keeper;
        _expectRefusal(c, "GUARDIAN must differ from the deployer and the keeper");
        c = _config();
        c.guardian = deployer;
        _expectRefusal(c, "GUARDIAN must differ from the deployer and the keeper");
        c = _config();
        c.keeper = upgradeSafe;
        _expectRefusal(c, "deployer and KEEPER must not be a Safe");

        c = _config();
        c.ownerDelay = 1 hours;
        c.upgradeDelay = c.ownerDelay - 1;
        _expectRefusal(c, "UPGRADE_TIMELOCK_DELAY must not be shorter than OWNER_TIMELOCK_DELAY");

        c = _config();
        vm.deal(deployer, c.gasReserve - 1);
        _expectRefusal(c, "deployer holds less BNB than GAS_RESERVE");

        vm.chainId(97);
        _expectRefusal(_config(), "BNB Chain mainnet (chain 56) only");
    }

    function _expectRefusal(DeployPikaMainnetScript.Config memory c, string memory reason) internal {
        uint64 nonce = vm.getNonce(c.deployer);
        vm.expectRevert(bytes(reason));
        script.deploy(c);
        assertEq(vm.getNonce(c.deployer), nonce, "nothing broadcast");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The deployment and what it must support
    // -----------------------------------------------------------------------------------------------------------------

    function testDeploysTheFullStackAndLaunchesOnBothQuotes() public {
        DeployPikaMainnetScript.Config memory c = _config();
        uint256 usdtBefore = IERC20(USDT).balanceOf(deployer);
        DeployPikaMainnetScript.Deployment memory d = script.deploy(c);
        PikaLaunchFactory factory = d.factory;

        // The deployer spent gas only and handed every owner role to the timelocks and the Safe.
        assertEq(IERC20(USDT).balanceOf(deployer), usdtBefore);
        assertEq(factory.owner(), address(d.ownerTimelock));
        assertEq(d.apps.registry.upgradeAuthority(), address(d.apps.upgradeTimelock));
        assertEq(d.guard.owner(), address(d.ownerTimelock));
        assertEq(d.guard.guardian(), guardian);
        assertEq(factory.guardian(), guardian);
        assertEq(d.apps.registry.guardian(), guardian);
        assertEq(d.treasury, treasurySafe);
        assertEq(factory.treasury(), treasurySafe);
        // The deployer is neither owner nor guardian: it can neither stop nor resume launches.
        vm.prank(deployer);
        vm.expectRevert(PikaGuarded.NotGuardian.selector);
        factory.setLaunchEnabled(false);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        factory.setLaunchEnabled(true);

        // Native BNB with a project fee both ways and the dividend sink (minimum holding 1,000 tokens): router buys,
        // the crossing buy graduates, then the pool trades through the router with native BNB.
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(1, 5000, 5000, abi.encode(uint256(1000)));
        _listPreset(d);
        PikaToken bnb = _create(d, address(0), 100, 100, apps);
        assertEq(PikaDividendApp(d.apps.dividend).minHolding(address(bnb)), 1000 ether);
        _graduate(factory, bnb, address(0), 18 ether);
        _poolTrades(d.components.router, bnb, 0.5 ether);
        assertGt(
            IMainnetOpenFourFeeRouter(CORE.feeRouter()).devFeePending(WBNB, treasurySafe),
            0,
            "the curve's developer fee is owed to the treasury"
        );
        // Trades book their fees; the push pays the sinks. The dividend sink releases each booking linearly over
        // RELEASE_WINDOW (dividend v5), so let the window pass before reading what the holder earned.
        bnb.pushFees();
        _poolTrades(d.components.router, bnb, 0.5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        bnb.pushFees();
        vm.warp(vm.getBlockTimestamp() + PikaDividendApp(d.apps.dividend).RELEASE_WINDOW());
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 due, uint256 quoteDue) = PikaDividendApp(d.apps.dividend).pending(address(bnb), buyer);
        assertGt(due + quoteDue, 0, "the holder earns dividends");

        // USDT with a sell fee: the burn sink books both sides and only the keeper buys back.
        apps[0] = AppBinding(0, 5000, 5000, "");
        PikaToken usdt = _create(d, USDT, 100, 100, apps);
        assertEq(address(usdt.hook()), d.components.hook);
        _graduate(factory, usdt, USDT, 12_000 ether);
        _poolTrades(d.components.router, usdt, 50 ether);
        usdt.pushFees();
        PikaBurnApp burnApp = PikaBurnApp(d.apps.burn);
        assertGt(burnApp.pending(address(usdt), address(usdt)), 0, "buy fee share booked in meme");
        assertGt(burnApp.pending(address(usdt), USDT), 0, "sell fee share booked in quote");
        assertGt(burnApp.burn(address(usdt)), 0);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vm.prank(deployer);
        vm.expectRevert(PikaSinkBase.NotKeeper.selector);
        burnApp.buyback(address(usdt), 1, deadline);
        vm.prank(keeper);
        (uint256 quoteSpent,, uint256 burned) = burnApp.buyback(address(usdt), 1, deadline);
        assertGt(quoteSpent, 0);
        assertGt(burned, 0);
        assertGt(IERC20(USDT).balanceOf(d.treasury), 0, "USDT fees reach the treasury");

        // The lens reports both quotes open, one optional app per launch and the minimum targets.
        PikaTradeLens.LaunchOptions memory o = d.lens.launchOptions(address(factory), address(0));
        assertTrue(o.enabled);
        assertEq(o.maxApps, 1);
        assertEq(o.minTarget, 0.1 ether);
        o = d.lens.launchOptions(address(factory), USDT);
        assertTrue(o.enabled);
        assertEq(o.minTarget, 10 ether);
    }

    /// @notice The mainnet CONFIG of 2026-11-12: one Safe in every Safe seat and the guardian seat, the deployer as the
    ///         keeper. The deployer keeps the keeper role and nothing else; the Safe stops launches at once.
    function testDeploysWithOneSafeAsGuardianAndTheDeployerAsKeeper() public {
        DeployPikaMainnetScript.Config memory c = _config();
        (c.upgradeProposerSafe, c.treasury, c.guardian, c.keeper) = (ownerSafe, ownerSafe, ownerSafe, deployer);
        DeployPikaMainnetScript.Deployment memory d = script.deploy(c);
        PikaLaunchFactory factory = d.factory;

        assertEq(d.guard.guardian(), ownerSafe);
        assertEq(factory.treasury(), ownerSafe);
        assertTrue(d.apps.registry.keepers(deployer), "the deployer is the keeper");
        TimelockController owner = d.ownerTimelock;
        TimelockController upgrade = d.apps.upgradeTimelock;
        assertTrue(
            owner.hasRole(owner.PROPOSER_ROLE(), ownerSafe) && upgrade.hasRole(upgrade.PROPOSER_ROLE(), ownerSafe)
        );
        assertFalse(
            owner.hasRole(owner.PROPOSER_ROLE(), deployer) || upgrade.hasRole(upgrade.PROPOSER_ROLE(), deployer)
        );

        // The deployer is neither owner nor guardian; the Safe, as guardian, stops launches without the timelock.
        vm.prank(deployer);
        vm.expectRevert(PikaGuarded.NotGuardian.selector);
        factory.setLaunchEnabled(false);
        vm.prank(ownerSafe);
        factory.setLaunchEnabled(false);
        assertFalse(factory.launchEnabled());
    }

    /// @dev Real Core accepts a Pika token as another launch's quote. Its later graduation must leave that quote's
    ///      existing treasury liability funded; all configuration and execution here are local fork calls.
    function testGraduationPreservesTreasuryDebtInPikaQuote() public {
        DeployPikaMainnetScript.Deployment memory d = script.deploy(_config());
        _listPreset(d);
        PikaToken token = _create(d, address(0), 0, 0, new AppBinding[](0));
        _coreBuy(token, address(0), 5 ether);
        bytes memory call = abi.encodeCall(PikaLaunchFactory.configureQuote, (address(token), true, 10 ether));
        vm.startPrank(ownerSafe);
        d.ownerTimelock.schedule(address(d.factory), 0, call, bytes32(0), bytes32(0), 0);
        d.ownerTimelock.execute(address(d.factory), 0, call, bytes32(0), bytes32(0));
        vm.stopPrank();
        PikaToken other = _create(d, address(token), 0, 0, new AppBinding[](0));
        _graduate(d.factory, other, address(token), 12_000 ether);
        uint256 owed = d.factory.pendingTreasuryQuote(address(token));
        assertGt(owed, 100 ether);
        assertEq(token.balanceOf(address(d.factory)), owed);

        _coreBuy(token, address(0), 36 ether);

        assertTrue(token.tradingStarted());
        assertEq(d.factory.pendingTreasuryQuote(address(token)), owed);
        assertEq(token.balanceOf(address(d.factory)), owed);
        uint256 before = token.balanceOf(d.treasury);
        assertEq(d.factory.claimTreasuryQuote(address(token)), owed);
        assertEq(token.balanceOf(d.treasury) - before, owed);
        assertEq(token.balanceOf(address(d.factory)), 0);
    }

    /// @dev Owner calls run through the owner timelock, proposed and executed by OWNER_SAFE after the delay. The
    ///      CONFIG delays are 0 (2026-11-01); a non-zero delay shows the mechanism.
    function testOwnerSafeRunsTheTimelockAfterTheDelay() public {
        DeployPikaMainnetScript.Config memory c = _config();
        (c.ownerDelay, c.upgradeDelay) = (1 days, 1 days);
        DeployPikaMainnetScript.Deployment memory d = script.deploy(c);
        TimelockController timelock = d.ownerTimelock;
        address factory = address(d.factory);
        bytes memory call = abi.encodeCall(PikaLaunchFactory.setLaunchEnabled, (false));
        bytes32 proposer = timelock.PROPOSER_ROLE();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, proposer)
        );
        timelock.schedule(factory, 0, call, bytes32(0), bytes32(0), c.ownerDelay);
        vm.prank(ownerSafe);
        timelock.schedule(factory, 0, call, bytes32(0), bytes32(0), c.ownerDelay);
        vm.prank(ownerSafe);
        vm.expectRevert();
        timelock.execute(factory, 0, call, bytes32(0), bytes32(0));
        vm.warp(vm.getBlockTimestamp() + c.ownerDelay);
        vm.prank(ownerSafe);
        timelock.execute(factory, 0, call, bytes32(0), bytes32(0));
        assertFalse(d.factory.launchEnabled());
        // Template upgrades are reserved to the separate timelock run by UPGRADE_PROPOSER_SAFE.
        TimelockController upgrade = d.apps.upgradeTimelock;
        assertTrue(upgrade.hasRole(upgrade.PROPOSER_ROLE(), upgradeSafe));
        assertFalse(upgrade.hasRole(upgrade.PROPOSER_ROLE(), ownerSafe));
        assertEq(upgrade.getMinDelay(), c.upgradeDelay);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Four.meme's part, pranked: the Registry owner lists the Pika token and modules (OpenFour's own standard
    ///      vault, bonding curve and simple trade policy in the vault, curve and trade slots, no custom data module)
    ///      as a preset with the hub as its validator and the
    ///      treasury as its author, the FeeRouter owner sets its fees. Then OWNER_SAFE runs the hub's `setPreset`
    ///      through the owner timelock, and Core's creation signer becomes a test key.
    function _listPreset(DeployPikaMainnetScript.Deployment memory d) internal {
        IMainnetOpenFourRegistry r = IMainnetOpenFourRegistry(OPENFOUR_REGISTRY);
        vm.startPrank(r.owner());
        r.upsertTokenImpl(keccak256("token.pika"), d.modules.tokenImplementation, "1.0.0");
        _module(r, "module.token.pika", d.modules.tokenModule, 0);
        _module(r, "module.migrate.pika_infinity", d.modules.migrate, 4);
        r.upsertPreset(
            OpenFourTypes.Preset({
                id: PRESET_ID,
                name: "Pika",
                description: "Pika rehearsal",
                version: "1.0.0",
                active: true,
                createEnabled: true,
                validator: address(d.factory),
                tokenModuleId: keccak256("module.token.pika"),
                vaultModuleId: OpenFourStandardModules.VAULT_KEY,
                curveModuleId: OpenFourStandardModules.CURVE_KEY,
                tradeModuleId: OpenFourStandardModules.TRADE_KEY,
                migrateModuleId: keccak256("module.migrate.pika_infinity"),
                tokenImplId: keccak256("token.pika"),
                customDataId: bytes32(0),
                author: d.treasury
            })
        );
        vm.stopPrank();
        IMainnetOpenFourFeeRouter fr = IMainnetOpenFourFeeRouter(CORE.feeRouter());
        vm.prank(fr.owner());
        fr.setPresetFeeConfig(
            PRESET_ID, IMainnetOpenFourFeeRouter.OverriddenFeeConfig(50, 50, 100, 1000, 5, true, 5000)
        );
        // The hub accepts the preset through the owner timelock (delay 0 in CONFIG), proposed by OWNER_SAFE.
        bytes memory call = abi.encodeCall(PikaLaunchFactory.setPreset, (PRESET_ID, true));
        vm.startPrank(ownerSafe);
        d.ownerTimelock.schedule(address(d.factory), 0, call, bytes32(0), bytes32(0), 0);
        d.ownerTimelock.execute(address(d.factory), 0, call, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertTrue(d.factory.presets(PRESET_ID));
        _swapSigner();
    }

    function _module(IMainnetOpenFourRegistry r, string memory tag, address impl, uint8 kind) internal {
        bytes32 id = keccak256(bytes(tag));
        r.upsertModule(id, impl, kind, OpenFourTypes.ModuleMetadata(id, "1.0.0", tag, "Pika", treasurySafe, 0), true);
    }

    /// @dev Finds the storage word `signer()` reads and replaces the address in it with the test signer.
    function _swapSigner() internal {
        address current = CORE.signer();
        vm.record();
        CORE.signer();
        (bytes32[] memory reads,) = vm.accesses(address(CORE));
        address next = vm.addr(signerKey);
        for (uint256 i; i < reads.length; ++i) {
            bytes32 word = vm.load(address(CORE), reads[i]);
            for (uint256 shift; shift <= 96; shift += 8) {
                if (address(uint160(uint256(word) >> shift)) != current) continue;
                uint256 mask = uint256(type(uint160).max) << shift;
                vm.store(
                    address(CORE), reads[i], bytes32((uint256(word) & ~mask) | (uint256(uint160(next)) << shift))
                );
                assertEq(CORE.signer(), next, "signer swapped");
                return;
            }
        }
        revert("Core signer slot not found");
    }

    function _create(
        DeployPikaMainnetScript.Deployment memory d,
        address quote,
        uint16 buyFeeBps,
        uint16 sellFeeBps,
        AppBinding[] memory apps
    ) internal returns (PikaToken token) {
        PikaLaunchFactory factory = d.factory;
        uint256 target = quote == address(0) ? 18 ether : 12_000 ether;
        uint256 supply = factory.defaultSupply();
        OpenFourTypes.CreateTokenArgs memory a;
        a.requestId = ++salt;
        a.presetId = PRESET_ID;
        a.validTimestamp = vm.getBlockTimestamp() + 1 hours;
        a.initParams.name = "Pika Mainnet Rehearsal";
        a.initParams.symbol = "BMR";
        a.initParams.maxSupply = supply;
        a.initParams.saleAmount = factory.sizing(supply, target).saleAmount;
        a.initParams.raiseAmount = target;
        a.initParams.quoteAsset = quote == address(0) ? WBNB : quote;
        a.initParams.tokenSalt = keccak256(abi.encode("pika-rehearsal", salt));
        a.initParams.tokenParams = abi.encode(PikaTokenParams(creator, buyFeeBps, sellFeeBps, apps));
        bytes memory createArgs = abi.encode(a);
        bytes32 digest =
            keccak256(abi.encodePacked("createOpenFourToken", block.chainid, creator, keccak256(createArgs)));
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(signerKey, MessageHashUtils.toEthSignedMessageHash(digest));
        vm.prank(creator);
        token = PikaToken(CORE.createToken(createArgs, abi.encodePacked(r, sig, v)));
        assertEq(token.quoteAsset(), quote == address(0) ? WBNB : quote);
        assertFalse(token.tradingStarted());
    }

    /// @dev A first curve buy through Core, then a buy of twice the target that sells the curve out and opens the
    ///      pool in the same transaction (the excess is refunded).
    function _graduate(PikaLaunchFactory factory, PikaToken token, address quote, uint256 target) internal {
        uint256 first = _coreBuy(token, quote, target / 100);
        assertGt(first, 0);
        assertFalse(token.tradingStarted());
        _coreBuy(token, quote, target * 2);
        assertTrue(token.tradingStarted(), "graduated");
        assertEq(uint256(_phase(factory, address(token))), uint256(PikaLaunchFactory.Phase.External));
    }

    function _coreBuy(PikaToken token, address quote, uint256 budget) internal returns (uint256 received) {
        bool native = quote == address(0);
        uint256 before = token.balanceOf(buyer);
        vm.startPrank(buyer);
        if (!native) IERC20(quote).forceApprove(address(CORE), budget);
        CORE.buyByBudget{ value: native ? budget : 0 }(address(token), budget, 1, 0, "");
        vm.stopPrank();
        received = token.balanceOf(buyer) - before;
    }

    /// @dev A pool buy and a pool sell through the router.
    function _poolTrades(address router, PikaToken token, uint256 quoteIn) internal {
        address quote = token.quoteAsset() == WBNB ? address(0) : token.quoteAsset();
        uint256 bought = _routerBuy(router, token, quote, quoteIn);
        assertGt(bought, 0, "pool buy");
        vm.startPrank(buyer);
        IERC20(address(token)).forceApprove(router, bought);
        (uint256 spent, uint256 output) = PikaRouter(payable(router))
            .swap(
                PikaRouter.SwapParams(
                    address(token), true, bought, 1, buyer, vm.getBlockTimestamp(), quote == address(0)
                )
            );
        vm.stopPrank();
        assertEq(spent, bought);
        assertGt(output, 0, "pool sell");
    }

    function _routerBuy(address router, PikaToken token, address quote, uint256 amount)
        internal
        returns (uint256 output)
    {
        bool native = quote == address(0);
        vm.startPrank(buyer);
        if (!native) IERC20(quote).forceApprove(router, amount);
        (, output) = PikaRouter(payable(router)).swap{ value: native ? amount : 0 }(
            PikaRouter.SwapParams(address(token), false, amount, 1, buyer, vm.getBlockTimestamp(), native)
        );
        vm.stopPrank();
    }

    function _phase(PikaLaunchFactory factory, address token) internal view returns (PikaLaunchFactory.Phase) {
        (, PikaLaunchFactory.Phase phase,) = factory.launches(token);
        return phase;
    }
}
