// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaTradeLens } from "../../src/pika-launch/PikaTradeLens.sol";
import { PikaTokenParams, IPikaHub } from "../../src/pika-launch/interfaces/IPikaLaunch.sol";
import { PikaMigrateModule } from "../../src/pika-launch/openfour/PikaMigrateModule.sol";
import { OpenFourBondingCurve } from "../helpers/OpenFourBondingCurve.sol";
import { PikaGraduationMath } from "../../src/pika-launch/libraries/PikaGraduationMath.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { OpenFourToken } from "../../src/openfour/token/OpenFourToken.sol";
import { IOpenFourVault } from "../../src/openfour/interfaces/IOpenFourVault.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";
import { MockOpenFourCore } from "../helpers/MockOpenFourCore.sol";

interface IOpenFourTokenModuleLike {
    function getInitParams() external view returns (bytes memory);
    function descriptor() external view returns (bytes8, string memory, string memory);
}

/// @notice The Pika launch lifecycle on OpenFour: Core creates and trades the curve through the Pika modules, the hub
///         registers the token and graduates it into its Infinity launch pool.
contract PikaOpenFourLaunchTest is PikaInfinityFixture {
    function test_CreateRegistersLaunchAndMintsToVault() public {
        PikaToken token = _create(address(0), true);
        IOpenFourVault v = _vaultOf(token);
        assertEq(token.totalSupply(), factory.defaultSupply());
        assertEq(token.balanceOf(address(v)), factory.defaultSupply());
        assertEq(token.factory(), address(factory));
        assertEq(token.quoteAsset(), address(wbnb));
        assertEq(factory.coreRecord(address(token)).creator, CREATOR);
        assertTrue(factory.isLaunch(address(token)));
        assertFalse(factory.isLaunch(address(usdt)));
        assertEq(address(token.hook()), address(hook));
        assertEq(token.tradingRouter(), address(router));
        assertFalse(token.tradingStarted());
        (bytes8 tagId, string memory tag,) = token.descriptor();
        assertEq(tag, "token.pika");
        assertEq(tagId, bytes8(keccak256("token.pika")));
        (, PikaLaunchFactory.Phase phase,) = factory.launches(address(token));
        assertEq(uint8(phase), uint8(PikaLaunchFactory.Phase.Internal));
        assertEq(uint8(v.phase()), uint8(OpenFourTypes.Phase.Trading));
        assertEq(v.remainingForSale(), factory.sizing(factory.defaultSupply(), 18 ether).saleAmount);
        assertTrue(token.isPlatformAccount(address(v)));
        assertTrue(token.isPlatformAccount(token.migrateModule()));
        OpenFourTypes.RuntimeConfig memory r = factory.coreRecord(address(token));
        assertTrue(r.exists);
        assertEq(r.presetId, PRESET_ID);
    }

    function test_CurveIsOpenFourBondingCurve() public {
        PikaToken token = _create(address(0), true);
        OpenFourBondingCurve curve = OpenFourBondingCurve(token.curveModule());
        (, string memory tag,) = curve.descriptor();
        assertEq(tag, "module.curve.bonding");
        uint256 supply = factory.defaultSupply();
        PikaLaunchFactory.Sizing memory s = factory.sizing(supply, 18 ether);
        // OpenFour's 80/20 split; the pool opens with 98% of the target. The virtual reserves are what OpenFour's
        // mainnet bonding curve sets up for 18 BNB on a billion tokens (read on chain, 2026-11-06).
        assertEq(s.saleAmount, 800_000_000 ether);
        assertEq(s.poolTokens, 200_000_000 ether);
        assertEq(s.poolQuote, 17.64 ether);
        assertEq(s.virtualQuote, 6_164_383_561_643_835_616);
        assertEq(s.virtualTokens, 1_073_972_602_739_726_027_397_260_273);
        assertEq(curve.virtualQuote(), s.virtualQuote);
        assertEq(curve.virtualTokens(), s.virtualTokens);
        assertEq(curve.getInitialPrice(), 5_739_795_923);
        uint256 got = _buyAs(token, ALICE, 1 ether, true);
        assertGt(got, 0);
        IOpenFourVault v = _vaultOf(token);
        // The vault books the curve quote net of OpenFour's 1% (0.5% protocol + 0.5% developer).
        uint256 raised = v.totalRaised();
        assertApproxEqAbs(raised, uint256(1 ether) * 10_000 / 10_100, 1e6);
        assertEq(wbnb.balanceOf(address(v)), raised);
        assertEq(wbnb.balanceOf(OPENFOUR_TREASURY), raised * 50 / 10_000);
        assertEq(wbnb.balanceOf(TREASURY), raised * 50 / 10_000);
        // Constant product with a fixed invariant: tokens out = y0 − k / (x0 + raised).
        uint256 expected = s.virtualTokens - s.virtualQuote * s.virtualTokens / (s.virtualQuote + raised);
        assertApproxEqRel(got, expected, 1e9);
    }

    function test_SellReturnsQuoteLessFees() public {
        PikaToken token = _create(address(usdt), true);
        uint256 got = _buyAs(token, ALICE, 1000 ether, false);
        uint256 beforeUsdt = usdt.balanceOf(ALICE);
        uint256 out = _curveSell(token, ALICE, got / 2);
        assertGt(out, 0);
        assertEq(usdt.balanceOf(ALICE), beforeUsdt + out);
        assertEq(token.balanceOf(ALICE), got - got / 2);
    }

    function test_NativeSellPaysBnb() public {
        PikaToken token = _create(address(0), false);
        uint256 got = _buyAs(token, ALICE, 2 ether, true);
        uint256 out = _curveSell(token, ALICE, got);
        assertGt(out, 1.9 ether);
        assertLt(out, 2 ether);
    }

    function test_SellOutGraduatesIntoLockedPool() public {
        PikaToken token = _create(address(0), true);
        uint256 balanceBefore = ALICE.balance;
        uint256 creatorBefore = wbnb.balanceOf(CREATOR);
        uint256 treasuryOwedBefore = factory.pendingTreasuryQuote(address(wbnb));
        IOpenFourVault v = _vaultOf(token);
        _fill(token, address(0));
        uint256 raised = v.totalRaised();
        assertEq(uint8(v.phase()), uint8(OpenFourTypes.Phase.Migrated));
        assertEq(v.remainingForSale(), 0);
        assertEq(token.balanceOf(address(v)), 0);
        assertEq(wbnb.balanceOf(address(v)), 0);
        (, PikaLaunchFactory.Phase phase,) = factory.launches(address(token));
        assertEq(uint8(phase), uint8(PikaLaunchFactory.Phase.External));
        assertTrue(token.orderManager() != address(0));
        assertGt(_poolLiquidity(token), 0);
        // The buyer paid the target plus fees and got the refund.
        assertApproxEqRel(balanceBefore - ALICE.balance, 18 ether * 10_100 / 10_000, 1e15);
        // The pool opened at the curve's final price: 98% of the raise against the 20% of the supply it kept.
        uint256 poolTokens = factory.defaultSupply() / 5;
        uint160 expected = PikaGraduationMath.sqrtPriceX96FromAmounts(poolTokens, raised * 9800 / 10_000);
        assertApproxEqRel(uint256(_poolPrice(token)), uint256(expected), 1e14);
        OpenFourBondingCurve curve = OpenFourBondingCurve(token.curveModule());
        assertApproxEqRel(
            uint256(expected),
            uint256(PikaGraduationMath.sqrtPriceX96FromAmounts(1e18, curve.getLastPrice(address(token), 0, raised))),
            1e12
        );
        // 1% of the raise credited to the creator's fee wallet (claimed from the token), the other 1% owed to the
        // treasury.
        assertEq(wbnb.balanceOf(CREATOR), creatorBefore);
        assertEq(token.creatorFees(address(wbnb)), raised / 100);
        assertEq(wbnb.balanceOf(address(token)), raised / 100);
        vm.prank(CREATOR);
        token.claimCreatorFees(CREATOR);
        assertEq(wbnb.balanceOf(CREATOR) - creatorBefore, raised / 100);
        assertApproxEqAbs(factory.pendingTreasuryQuote(address(wbnb)) - treasuryOwedBefore, raised / 100, 1e9);
        assertEq(uint8(IOpenFourVault(token.vault()).phase()), uint8(OpenFourTypes.Phase.Migrated));
    }

    function test_SellOutQuoteSideGraduates() public {
        PikaToken token = _create(address(usdt), false);
        _fill(token, address(usdt));
        assertTrue(token.tradingStarted());
        deal(address(usdt), BOB, 100 ether);
        (, uint256 out) = _swap(token, BOB, false, 100 ether);
        assertGt(out, 0);
    }

    function test_PoolTradesAfterGraduation() public {
        PikaToken token = _create(address(0), true);
        _fill(token, address(0));
        deal(address(wbnb), BOB, 1 ether);
        (uint256 spent, uint256 out) = _swap(token, BOB, false, 1 ether);
        assertEq(spent, 1 ether);
        assertGt(out, 0);
        (spent, out) = _swap(token, BOB, true, out / 2);
        assertGt(out, 0);
    }

    function test_RouterRefusesCurvePhase() public {
        PikaToken token = _create(address(0), true);
        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(PikaRouter.InvalidTrade.selector);
        router.swap{ value: 1 ether }(
            PikaRouter.SwapParams(address(token), false, 1 ether, 1, BOB, block.timestamp, true)
        );
    }

    /// @dev No purchase limit (removed 2026-11-06): the trade slot is OpenFour's simple trade policy, so one buyer may
    ///      take any share of the sale, over several buys, after selling, or through a contract.
    function test_NoPurchaseLimit() public {
        LaunchParams memory p = _params(address(0), true);
        p.initialBuy = 1 ether;
        PikaToken token = _launch(p);
        uint256 supply = factory.defaultSupply();
        assertGt(token.balanceOf(CREATOR), supply / 100);
        uint256 got = _buyAs(token, ALICE, 2 ether, true);
        assertGt(got, supply / 50);
        _curveSell(token, ALICE, got / 2);
        uint256 more = _buyAs(token, ALICE, 2 ether, true);
        assertGt(more, supply / 50);
        // An exact-amount buy of a tenth of the supply goes through as well.
        vm.deal(BOB, 100 ether);
        vm.prank(BOB);
        core.buy{ value: 100 ether }(address(token), supply / 10, 100 ether, 0, "");
        assertEq(token.balanceOf(BOB), supply / 10);
        (bytes8 id, string memory tag,) = IOpenFourTokenModuleLike(token.tradeModule()).descriptor();
        assertEq(id, bytes8(keccak256("module.trade.simple")));
        assertEq(tag, "module.trade.simple");
        assertEq(token.customData(), address(0));
    }

    function test_FakeCloneRegistersButCannotGraduate() public {
        // Anyone can clone the Pika token implementation and initialize it outside Core.
        address fake = Clones.clone(tokenImplementation);
        OpenFourToken.InitArgs memory a;
        a.name = "Fake";
        a.symbol = "FAKE";
        a.vault = address(this);
        a.maxSupply = 1 ether;
        a.curveModule = address(1);
        a.tradeModule = address(2);
        a.migrateModule = address(this);
        a.tokenModule = address(3);
        a.creator = address(this);
        a.quoteAsset = address(wbnb);
        a.tokenParams = abi.encode(PikaTokenParams(address(this), 0, 0, new AppBinding[](0)));
        PikaToken(fake).initialize(a);
        (, PikaLaunchFactory.Phase phase,) = factory.launches(fake);
        assertEq(uint8(phase), uint8(PikaLaunchFactory.Phase.Internal));
        // It is unknown to Core, so it can never open a pool.
        vm.expectRevert();
        factory.graduate(fake, 1 ether, 0);
    }

    function test_OnlyAllowedClonesRegister() public {
        IPikaHub.Registration memory r;
        r.creator = address(this);
        r.quoteAsset = address(wbnb);
        r.params.creatorFeeRecipient = address(this);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        factory.registerLaunch(r);
        // A clone of an implementation the owner refused cannot register either.
        factory.setTokenImplementation(tokenImplementation, false);
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(_params(address(0), true));
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        core.createToken(a);
    }

    function test_GraduateOnlyFromTheLaunchsMigrateModule() public {
        PikaToken token = _create(address(0), true);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        factory.graduate(address(token), 1 ether, 0);
    }

    function test_ValidatorRejectsBadParameters() public {
        LaunchParams memory p = _params(address(0), true);
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(p);
        // Wrong sale amount for the target.
        a.initParams.saleAmount -= 1;
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        core.createToken(a);
        // Wrong supply.
        a = _createArgs(p);
        a.initParams.maxSupply += 1;
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        core.createToken(a);
        // Target below the quote's minimum.
        p.target = 0.01 ether;
        a = _createArgs(p);
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        core.createToken(a);
        // Outer fees over the cap.
        p = _params(address(0), true);
        p.buyFeeBps = 2971;
        a = _createArgs(p);
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        core.createToken(a);
        // Trade parameters (OpenFour's simple trade policy takes none: no purchase limit).
        p = _params(address(0), true);
        a = _createArgs(p);
        a.initParams.tradeParams = abi.encode(factory.defaultSupply() / 100);
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        core.createToken(a);
        // Parameters for a module that takes none.
        p = _params(address(0), true);
        a = _createArgs(p);
        a.initParams.curveParams = hex"01";
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        core.createToken(a);
        // An unlisted quote.
        a = _createArgs(p);
        a.initParams.quoteAsset = address(router);
        vm.prank(CREATOR);
        vm.expectRevert();
        core.createToken(a);
        // A preset the hub does not allow.
        factory.setPreset(PRESET_ID, false);
        a = _createArgs(p);
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        core.createToken(a);
    }

    function test_RefusedPresetStillGraduatesItsLaunches() public {
        PikaToken token = _create(address(0), true);
        factory.setPreset(PRESET_ID, false);
        assertFalse(factory.presets(PRESET_ID));
        assertTrue(factory.graduationPresets(PRESET_ID));
        // New launches of the preset are refused...
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(_params(address(0), true));
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        core.createToken(a);
        // ...while the launch already on its curve still graduates.
        _fill(token, address(0));
    }

    function test_GraduationPresetIsDroppedOnlyOnPurpose() public {
        PikaToken token = _create(address(0), true);
        // A preset new launches may use cannot lose graduation.
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.setGraduationPreset(PRESET_ID, false);
        factory.setPreset(PRESET_ID, false);
        factory.setGraduationPreset(PRESET_ID, false);
        vm.deal(ALICE, 40 ether);
        vm.prank(ALICE);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        core.buyByBudget{ value: 40 ether }(address(token), 40 ether, 1, 0, "");
        // Allowing the preset again allows its graduation again.
        factory.setPreset(PRESET_ID, true);
        _fill(token, address(0));
    }

    function test_LaunchesOfAnEarlierCoreStillGraduate() public {
        PikaToken token = _create(address(0), true);
        MockOpenFourCore next = new MockOpenFourCore(address(wbnb), OPENFOUR_TREASURY);
        factory.setCore(address(next));
        assertTrue(factory.graduationCores(address(core)));
        assertTrue(factory.graduationCores(address(next)));
        // The lens still trades the launch through the Core it was created on.
        PikaTradeLens.Balances memory b = lens.balances(address(token), ALICE);
        assertEq(b.meme.spender, address(core));
        _fill(token, address(0));
    }

    function test_DroppedCoreCannotGraduate() public {
        PikaToken token = _create(address(0), true);
        // The current Core cannot be dropped.
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.setGraduationCore(address(core), false);
        MockOpenFourCore next = new MockOpenFourCore(address(wbnb), OPENFOUR_TREASURY);
        factory.setCore(address(next));
        factory.setGraduationCore(address(core), false);
        vm.deal(ALICE, 40 ether);
        vm.prank(ALICE);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        core.buyByBudget{ value: 40 ether }(address(token), 40 ether, 1, 0, "");
    }

    function test_LaunchStopStopsCreation() public {
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(_params(address(0), true));
        factory.setLaunchEnabled(false);
        vm.prank(CREATOR);
        vm.expectRevert(PikaLaunchFactory.Unauthorized.selector);
        core.createToken(a);
    }

    function test_LensQuotesCurveAndPool() public {
        PikaToken token = _create(address(0), true);
        vm.prank(ALICE);
        PikaTradeLens.Quote memory q = lens.quote(address(token), false, 1 ether, 100);
        assertEq(q.phase, 1);
        assertEq(q.inputAsset, address(wbnb));
        assertGt(q.output, 0);
        uint256 got = _buyAs(token, ALICE, 1 ether, true);
        assertEq(q.output, got);
        PikaTradeLens.Balances memory b = lens.balances(address(token), ALICE);
        assertEq(b.meme.spender, address(core));
        _fill(token, address(0));
        q = lens.quote(address(token), false, 1 ether, 100);
        assertEq(q.phase, 2);
        assertGt(q.output, 0);
    }

    function test_DividendBookSeesCurveHolders() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(DIVIDEND_ID, 10_000, 10_000, abi.encode(uint256(0)));
        PikaToken token = _createWithFees(address(0), true, 100, 100, apps);
        uint256 got = _buyAs(token, ALICE, 1 ether, true);
        assertEq(dividendApp.expectedShares(address(token), ALICE), got);
        assertEq(dividendApp.expectedShares(address(token), token.vault()), 0);
        _fill(token, address(0));
        (, uint256 out) = _swap(token, ALICE, true, got / 2);
        assertGt(out, 0);
    }

    function test_CreatorFirstBuyCanSellOutAndGraduate() public {
        LaunchParams memory p = _params(address(0), false);
        p.initialBuy = 40 ether;
        uint256 before = CREATOR.balance;
        PikaToken token = _launch(p);
        assertTrue(token.tradingStarted());
        assertEq(_vaultOf(token).remainingForSale(), 0);
        assertApproxEqRel(before - CREATOR.balance, 18 ether * 10_100 / 10_000, 1e15);
    }

    function test_ExtraVaultQuoteIsOwedToTheTreasury() public {
        PikaToken token = _create(address(usdt), true);
        deal(address(usdt), BOB, 5 ether);
        vm.prank(BOB);
        usdt.transfer(token.vault(), 5 ether);
        _fill(token, address(usdt));
        assertGe(factory.pendingTreasuryQuote(address(usdt)), 5 ether);
        assertEq(usdt.balanceOf(address(factory)), factory.pendingTreasuryQuote(address(usdt)));
        uint256 before = usdt.balanceOf(TREASURY);
        factory.claimTreasuryQuote(address(usdt));
        assertGe(usdt.balanceOf(TREASURY) - before, 5 ether);
        assertEq(usdt.balanceOf(address(factory)), 0);
        assertEq(factory.pendingTreasuryQuote(address(usdt)), 0);
    }

    function test_DonatedTokensDoNotMoveTheOpeningPrice() public {
        PikaToken a = _create(address(usdt), true);
        PikaToken b = _create(address(usdt), true);
        deal(address(usdt), BOB, 100 ether);
        _buyAs(b, BOB, 100 ether, false);
        address bVault = b.vault();
        uint256 donated = b.balanceOf(BOB);
        vm.prank(BOB);
        b.transfer(bVault, donated);
        _fill(a, address(usdt));
        _fill(b, address(usdt));
        assertApproxEqRel(uint256(_poolPrice(a)), uint256(_poolPrice(b)), 1e12);
        // The donation is burned with the excess supply.
        uint256 burnedA = a.balanceOf(BURN);
        uint256 burnedB = b.balanceOf(BURN);
        assertGt(burnedB, burnedA);
        assertEq(a.balanceOf(address(factory)), 0);
        assertEq(b.balanceOf(address(factory)), 0);
    }

    function test_DefaultSupplyChangeAppliesToLaterLaunches() public {
        PikaToken before = _create(address(0), true);
        factory.setDefaultSupply(500_000_000 ether);
        PikaToken later = _create(address(0), true);
        assertEq(before.totalSupply(), 1_000_000_000 ether);
        assertEq(later.totalSupply(), 500_000_000 ether);
        _fill(before, address(0));
        _fill(later, address(0));
    }

    function test_ComponentsArePinnedAtRegistration() public {
        PikaToken before = _create(address(usdt), true);
        PikaRouter updated = PikaRouter(payable(_newRouter(address(wbnb), address(vault), address(manager))));
        updated.bindFactory(address(factory));
        PikaLaunchFactory.Components memory c = _components(address(before));
        c.router = address(updated);
        factory.setComponents(c);
        PikaToken later = _create(address(usdt), true);
        assertEq(before.tradingRouter(), address(router));
        assertEq(later.tradingRouter(), address(updated));
        _fill(before, address(usdt));
        _fill(later, address(usdt));
    }

    function test_ModulesRefuseAForeignCore() public {
        PikaToken token = _create(address(0), true);
        PikaMigrateModule migrate = PikaMigrateModule(token.migrateModule());
        OpenFourTypes.MigrateHookContext memory ctx;
        ctx.token = address(token);
        vm.expectRevert();
        migrate.executeMigration(ctx, "");
        // A module clone initialized against another Core is refused at init.
        (,,,,, address migrateImpl,,,) = core.presetConfigs(PRESET_ID);
        PikaMigrateModule fresh = PikaMigrateModule(Clones.clone(migrateImpl));
        vm.expectRevert(bytes4(keccak256("InvalidModuleConfiguration()")));
        fresh.init(address(token), address(this), address(0), "", "1.0.0");
    }

    function test_ModulesReportTheirParametersAndVersion() public {
        LaunchParams memory p = _params(address(usdt), true);
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(p);
        PikaToken token = _launch(p);
        // The token module keeps the whole tokenParams as a data contract's code.
        assertEq(IOpenFourTokenModuleLike(token.tokenModule()).getInitParams(), a.initParams.tokenParams);
        assertEq(IOpenFourTokenModuleLike(token.tradeModule()).getInitParams(), "");
        assertEq(IOpenFourTokenModuleLike(token.vault()).getInitParams(), "");
        assertEq(IOpenFourTokenModuleLike(token.curveModule()).getInitParams(), "");
        assertEq(IOpenFourTokenModuleLike(token.migrateModule()).getInitParams(), "");
        assertEq(token.customData(), address(0));
        (bytes8 id, string memory tag, string memory version) = IOpenFourTokenModuleLike(token.vault()).descriptor();
        // The vault is OpenFour's standard vault.
        assertEq(id, bytes8(keccak256("module.vault.standard")));
        assertEq(tag, "module.vault.standard");
        assertEq(version, "1.0.0");
        assertEq(IOpenFourVault(token.vault()).fourCore(), address(core));
        assertEq(IOpenFourVault(token.vault()).token(), address(token));
    }

    function test_ModuleVersionSnapshotOfAnyLength() public {
        PikaToken token = _create(address(0), true);
        (,,,,, address migrateImpl,,,) = core.presetConfigs(PRESET_ID);
        string[4] memory versions = ["", "12345678901", "123456789012", "a much longer registry version string, 2026-11-05"];
        for (uint256 i; i < versions.length; ++i) {
            PikaMigrateModule fresh = PikaMigrateModule(Clones.clone(migrateImpl));
            vm.prank(address(core));
            fresh.init(address(token), address(core), address(0), "", versions[i]);
            (,, string memory version) = fresh.descriptor();
            assertEq(version, versions[i]);
            assertEq(fresh.token(), address(token));
            // Bound once.
            vm.expectRevert(bytes4(keccak256("AlreadyInitialized()")));
            fresh.init(address(token), address(core), address(0), "", "1.0.0");
        }
        // The implementation itself can never be bound.
        vm.expectRevert(bytes4(keccak256("AlreadyInitialized()")));
        PikaMigrateModule(migrateImpl).init(address(token), address(core), address(0), "", "1.0.0");
    }

    function test_TradeParamsMustBeEmpty() public {
        LaunchParams memory p = _params(address(usdt), true);
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(p);
        factory.validate(PRESET_ID, a.initParams);
        a.initParams.tradeParams = abi.encode(uint256(0));
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.validate(PRESET_ID, a.initParams);
        a.initParams.tradeParams = hex"00";
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.validate(PRESET_ID, a.initParams);
    }

    /// @dev OpenFour's standard vault closes the sale once at most one whole token is left. The buy that gets there
    ///      graduates; the unsold remainder stays locked and the pool opens within one token in the reserve of the
    ///      curve's last price.
    function test_SaleClosesWithAtMostOneTokenLeft() public {
        PikaToken token = _create(address(0), true);
        IOpenFourVault v = _vaultOf(token);
        // A little more than a whole token left keeps the sale open.
        _buyExact(token, BOB, v.remainingForSale() - 1 ether - 1e9);
        assertEq(v.remainingForSale(), 1 ether + 1e9);
        assertEq(uint8(v.phase()), uint8(OpenFourTypes.Phase.Trading));
        assertFalse(token.tradingStarted());
        // OpenFour's curve rounds a buy's cost down: a single wei costs nothing and is refused.
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectRevert();
        core.buy{ value: 1 ether }(address(token), 1, 1 ether, 0, "");
        // The smallest buy that costs something and leaves at most one token closes it.
        _buyExact(token, ALICE, 1e9);
        assertEq(v.remainingForSale(), 1 ether);
        assertEq(uint8(v.phase()), uint8(OpenFourTypes.Phase.Migrated));
        assertTrue(token.tradingStarted());
        assertEq(token.balanceOf(address(v)), 0);
        uint256 raised = v.totalRaised();
        assertLt(raised, 18 ether);
        uint160 expected =
            PikaGraduationMath.sqrtPriceX96FromAmounts(factory.defaultSupply() / 5, raised * 9800 / 10_000);
        assertApproxEqRel(uint256(_poolPrice(token)), uint256(expected), 1e14);
    }

    function _buyExact(PikaToken token, address user, uint256 amount) internal {
        vm.deal(user, 100 ether);
        vm.prank(user);
        core.buy{ value: 40 ether }(address(token), amount, 40 ether, 0, "");
    }

    function test_VaultKeepsItsBooks() public {
        PikaToken token = _create(address(0), true);
        IOpenFourVault v = IOpenFourVault(token.vault());
        uint256 sale = v.initialSaleAmount();
        assertEq(v.remainingForSale(), sale);
        assertEq(v.totalRaised(), 0);
        uint256 got = _buyAs(token, ALICE, 1 ether, true);
        assertEq(v.remainingForSale(), sale - got);
        assertEq(v.soldAmount(), got);
        uint256 raised = v.totalRaised();
        assertGt(raised, 0);
        assertEq(v.antiSniperQuoteAccrued(), 0);
        _curveSell(token, ALICE, got / 2);
        assertEq(v.remainingForSale(), sale - got + got / 2);
        assertLt(v.totalRaised(), raised);
    }
}
