// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { Hooks } from "infinity-core/src/libraries/Hooks.sol";
import { CustomRevert } from "infinity-core/src/libraries/CustomRevert.sol";
import { PikaLaunchFactory } from "../../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaToken } from "../../../src/pika-launch/PikaToken.sol";
import { PikaTokenParams } from "../../../src/pika-launch/interfaces/IPikaLaunch.sol";
import { OpenFourTypes } from "../../../src/openfour/libraries/OpenFourTypes.sol";
import { IOpenFourVault } from "../../../src/openfour/interfaces/IOpenFourVault.sol";
import { MockOpenFourCore } from "../../helpers/MockOpenFourCore.sol";
import { PikaRouter } from "../../../src/pika-launch/PikaRouter.sol";
import { PikaTradeLens } from "../../../src/pika-launch/PikaTradeLens.sol";
import { PikaOrderDeployer } from "../../../src/pika-launch/PikaOrderDeployer.sol";
import { PikaHook } from "../../../src/pika-market/infinity/PikaHook.sol";
import { IPikaPositionManager } from "../../../src/pika-market/interfaces/IPikaMarket.sol";
import { PikaAppRegistry } from "../../../src/pika-apps/PikaAppRegistry.sol";
import { PikaGuard } from "../../../src/common/PikaGuard.sol";
import { PikaBurnApp } from "../../../src/pika-apps/PikaBurnApp.sol";
import { PikaDividendApp } from "../../../src/pika-apps/PikaDividendApp.sol";
import { PikaLiquidityApp } from "../../../src/pika-apps/PikaLiquidityApp.sol";
import { AppBinding } from "../../../src/pika-apps/interfaces/IPikaApps.sol";
import { PikaOrderManager } from "../../../src/pika-market/infinity/PikaOrderManager.sol";
import { MockUSDT } from "../../../src/mocks/MockUSDT.sol";
import { MockWBNB } from "../../helpers/MockWBNB.sol";
import { InfinityTestRouter, LockRelay } from "../../helpers/InfinityTestRouter.sol";
import { PikaLpHelpers } from "../../helpers/PikaLpHelpers.sol";
import { PikaFeeMath } from "../../../src/common/libraries/PikaFeeMath.sol";
// Imported so every suite builds the stand-in app's artifact; it is deployed with `vm.deployCode`.
import { PikaRecorderApp } from "../../helpers/PikaRecorderApp.sol";

/// @notice Local Infinity deployment (real Vault and CLPoolManager bytecode) with the whole Pika stack on top.
abstract contract PikaInfinityFixture is PikaLpHelpers {
    using SafeERC20 for IERC20;

    address constant ALICE = address(0xa11ce);
    address constant BOB = address(0xb0b);
    address constant CAROL = address(0xca201);
    address constant DAVE = address(0xda7e);
    address constant CREATOR = address(0xc123);
    address constant TREASURY = address(0xfee);
    /// @dev Allowed by the registry to run the sinks' trading entries.
    address constant KEEPER = address(0x6ee9e2);

    IVault vault;
    ICLPoolManager manager;
    MockWBNB wbnb;
    MockUSDT usdt;
    PikaGuard guard;
    PikaAppRegistry registry;
    /// @dev Pancake's CL position manager (the official LP NFT).
    IPikaPositionManager positionManager;
    /// @dev Three listings of the test-only recorder app, standing in for optional (non-default) apps.
    PikaRecorderApp appA;
    PikaRecorderApp appB;
    PikaRecorderApp appC;
    PikaBurnApp burnApp;
    PikaDividendApp dividendApp;
    PikaLiquidityApp liquidityApp;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    /// @dev Template 0 is the v1 direct burn receiver, kept listed here for the direct-receiver rules; 1 to 3 are
    ///      optional recorder apps; 4 to 6 are the default sinks.
    uint32 constant BURN_ID = 0;
    uint32 constant APP_A_ID = 1;
    uint32 constant APP_B_ID = 2;
    uint32 constant APP_C_ID = 3;
    uint32 constant BURN_APP_ID = 4;
    uint32 constant DIVIDEND_ID = 5;
    uint32 constant LIQUIDITY_ID = 6;
    PikaLaunchFactory factory;
    PikaRouter router;
    PikaHook hook;
    PikaTradeLens lens;
    /// @dev Shaped like the Universal Router.
    InfinityTestRouter ur;
    /// @dev A second router of the same code; the hook treats every locker alike.
    InfinityTestRouter stranger;
    LockRelay relay;
    uint256 salt;
    /// @dev The token side the last `_params` mined for.
    bool minedBaseIs0;
    /// @dev OpenFour Core (local stand-in), the Pika preset and its fee receivers.
    MockOpenFourCore core;
    uint256 constant PRESET_ID = 1778;
    /// @dev OpenFour's treasury (protocol fee); the Pika treasury is the preset author (developer fee).
    address constant OPENFOUR_TREASURY = address(0x4f4);
    address tokenImplementation;

    /// @dev What a creator chooses for a Pika launch; `quoteToken` zero is a BNB launch (WBNB on the curve).
    struct LaunchParams {
        string name;
        string symbol;
        address quoteToken;
        bytes32 salt;
        uint256 target;
        /// @dev The creator's first buy: a quote budget, OpenFour's fees included.
        uint256 initialBuy;
        uint256 minInitialTokens;
        address creatorFeeRecipient;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        AppBinding[] apps;
    }

    function _setUpOpenFour() internal {
        core = new MockOpenFourCore(address(wbnb), OPENFOUR_TREASURY);
        factory.setCore(address(core));
        tokenImplementation = _newToken(address(factory), address(vault), address(manager));
        factory.setTokenImplementation(tokenImplementation, true);
        bytes memory hub = abi.encode(address(factory), address(core));
        core.setPreset(
            PRESET_ID,
            MockOpenFourCore.PresetConfig({
                tokenImpl: tokenImplementation,
                tokenModule: _deploy("PikaTokenModule", hub),
                vault: _deploy("StandardVault"),
                curve: _deploy("OpenFourBondingCurve"),
                trade: _deploy("OpenFourSimpleTrade"),
                migrate: _deploy("PikaMigrateModule", hub),
                customData: address(0),
                validator: address(factory),
                author: TREASURY
            })
        );
        factory.setPreset(PRESET_ID, true);
    }

    function setUp() public virtual {
        vault = _newVault();
        manager = _newManager(address(vault));
        vault.registerApp(address(manager));
        wbnb = new MockWBNB();
        usdt = MockUSDT(_newWithAddress("MockUSDT", address(this)));
        guard = PikaGuard(_newWithAddress("PikaGuard", address(this)));
        registry =
            PikaAppRegistry(_deploy("PikaAppRegistry", abi.encode(address(this), address(guard), address(this))));
        router = PikaRouter(payable(_newRouter(address(wbnb), address(vault), address(manager))));
        hook = PikaHook(_newWithVenue("PikaHook", address(vault), address(manager)));
        positionManager = IPikaPositionManager(_newPositionManager(address(vault), address(manager), address(wbnb)));
        PikaLaunchFactory.Components memory c = PikaLaunchFactory.Components(
            address(router), _newDeployer("PikaOrderDeployer", address(hook)), address(hook), address(positionManager)
        );
        factory = PikaLaunchFactory(
            payable(_deploy(
                    "PikaLaunchFactory",
                    abi.encode(address(this), address(guard), TREASURY, vault, manager, address(registry), c)
                ))
        );
        router.bindFactory(address(factory));
        PikaOrderDeployer(c.orderDeployer).bindFactory(address(factory));
        hook.bindFactory(address(factory));
        registry.setFactory(address(factory), true);
        _setUpOpenFour();
        appA = _newRecorder("appA");
        appB = _newRecorder("appB");
        appC = _newRecorder("appC");
        burnApp = PikaBurnApp(_newApp("PikaBurnApp", address(registry)));
        dividendApp = PikaDividendApp(_newApp("PikaDividendApp", address(registry)));
        liquidityApp = PikaLiquidityApp(
            _proxy(_deploy("PikaLiquidityApp", abi.encode(address(registry), address(positionManager))))
        );
        registry.addTemplate(BURN, PikaAppRegistry.Kind.Direct, "burn", 1, false);
        registry.addTemplate(address(appA), PikaAppRegistry.Kind.Contract, "appA", 2, false);
        registry.addTemplate(address(appB), PikaAppRegistry.Kind.Contract, "appB", 2, false);
        registry.addTemplate(address(appC), PikaAppRegistry.Kind.Contract, "appC", 2, false);
        registry.addTemplate(address(burnApp), PikaAppRegistry.Kind.Contract, "burn", 2, true);
        registry.addTemplate(
            address(dividendApp), PikaAppRegistry.Kind.HolderBook, "dividend", dividendApp.version(), true
        );
        registry.addTemplate(address(liquidityApp), PikaAppRegistry.Kind.Contract, "liquidity", 3, true);
        registry.setKeeper(KEEPER, true);
        // Deployments start at one chosen app per launch (PikaProjectFees checks the default); the local suites
        // bind several to exercise the fee split.
        registry.setMaxApps(3);
        ur = new InfinityTestRouter(IVault(address(vault)), ICLPoolManager(address(manager)));
        stranger = new InfinityTestRouter(IVault(address(vault)), ICLPoolManager(address(manager)));
        relay = new LockRelay(IVault(address(vault)));
        lens = PikaTradeLens(_deploy("PikaTradeLens"));
        factory.configureQuote(address(wbnb), true, 0.1 ether);
        factory.configureQuote(address(usdt), true, 10 ether);
        vm.deal(ALICE, 100 ether);
        vm.deal(CAROL, 100 ether);
        vm.deal(CREATOR, 100 ether);
        deal(address(usdt), ALICE, 100_000 ether);
        deal(address(usdt), CAROL, 100_000 ether);
        vm.warp(1_800_000_000);
    }

    /// @dev A recorder app listed under `key`: an initialized proxy over a new implementation for the registry.
    function _newRecorder(bytes32 key) internal returns (PikaRecorderApp) {
        return PikaRecorderApp(_proxy(_deploy("PikaRecorderApp", abi.encode(address(registry), key))));
    }

    function _components(address token) internal view returns (PikaLaunchFactory.Components memory c) {
        (,, uint32 version) = factory.launches(token);
        (c.router, c.orderDeployer, c.hook, c.positionManager) = factory.components(version);
    }

    function _info(address token) internal view returns (PikaLaunchFactory.Launch memory l) {
        (bool ok, bytes memory data) = address(factory).staticcall(abi.encodeCall(factory.launches, (token)));
        require(ok);
        l = abi.decode(data, (PikaLaunchFactory.Launch));
    }

    function _orders(PikaToken token) internal view returns (PikaOrderManager) {
        return PikaOrderManager(token.orderManager());
    }

    function _poolQuote(PikaToken token) internal view returns (address) {
        return token.quoteAsset();
    }

    function _curveQuote(address quote) internal view returns (address) {
        return quote == address(0) ? address(wbnb) : quote;
    }

    function _create(address quote, bool baseIs0) internal returns (PikaToken token) {
        return _launch(_params(quote, baseIs0));
    }

    /// @dev A launch with the platform fee only: no project fee and no apps.
    function _params(address quote, bool baseIs0) internal returns (LaunchParams memory p) {
        p.name = "Pika Hybrid";
        p.symbol = "BAMB";
        p.quoteToken = quote;
        p.creatorFeeRecipient = CREATOR;
        // The frontend defaults: 18 BNB, or 12,000 of a quote token.
        p.target = quote == address(0) ? 18 ether : 12_000 * 10 ** IERC20Metadata(quote).decimals();
        _mine(p, baseIs0);
    }

    /// @dev Picks the salt that puts the token on the requested side of its quote (Core's clone address depends
    ///      only on the creator and the salt).
    function _mine(LaunchParams memory p, bool baseIs0) internal {
        _mineFor(CREATOR, p, baseIs0);
    }

    function _mineFor(address creator, LaunchParams memory p, bool baseIs0) internal {
        address poolQuote = _curveQuote(p.quoteToken);
        minedBaseIs0 = baseIs0;
        do {
            p.salt = bytes32(++salt);
        } while ((core.predictToken(PRESET_ID, creator, p.salt) < poolQuote) != baseIs0);
    }

    /// @dev Mines again for the side the last `_params` asked for.
    function _mine(LaunchParams memory p) internal {
        _mine(p, minedBaseIs0);
    }

    function _predict(address creator, LaunchParams memory p) internal view returns (address) {
        return core.predictToken(PRESET_ID, creator, p.salt);
    }

    /// @dev OpenFour's creation arguments for a Pika launch.
    function _createArgs(LaunchParams memory p) internal view returns (OpenFourTypes.CreateTokenArgs memory a) {
        uint256 supply = factory.defaultSupply();
        a.presetId = PRESET_ID;
        a.validTimestamp = block.timestamp + 1 hours;
        a.presaleQuote = p.initialBuy;
        a.initParams.name = p.name;
        a.initParams.symbol = p.symbol;
        a.initParams.tokenUri = "ipfs://pika";
        a.initParams.maxSupply = supply;
        a.initParams.saleAmount = factory.sizing(supply, p.target).saleAmount;
        a.initParams.raiseAmount = p.target;
        a.initParams.quoteAsset = _curveQuote(p.quoteToken);
        a.initParams.tokenSalt = p.salt;
        a.initParams.tokenParams =
            abi.encode(PikaTokenParams(p.creatorFeeRecipient, p.buyFeeBps, p.sellFeeBps, p.apps));
    }

    function _launch(LaunchParams memory p) internal returns (PikaToken) {
        return _launchAs(CREATOR, p);
    }

    /// @dev Creates the launch through Core as `creator`; a BNB launch pays its first buy as value.
    function _launchAs(address creator, LaunchParams memory p) internal returns (PikaToken token) {
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(p);
        vm.startPrank(creator);
        if (p.quoteToken != address(0) && p.initialBuy != 0) {
            IERC20(p.quoteToken).forceApprove(address(core), p.initialBuy);
        }
        token = PikaToken(core.createToken{ value: p.quoteToken == address(0) ? p.initialBuy : 0 }(a));
        vm.stopPrank();
    }

    /// @dev Expects Core's creation of `p` by `creator` to revert with `reason` (any reason when empty).
    function _createReverts(address creator, LaunchParams memory p, bytes memory reason) internal {
        OpenFourTypes.CreateTokenArgs memory a = _createArgs(p);
        vm.prank(creator);
        if (reason.length == 0) vm.expectRevert();
        else vm.expectRevert(reason);
        core.createToken(a);
    }

    /// @dev A launch with a project fee per direction and the given app bindings.
    function _createWithFees(address quote, bool baseIs0, uint16 buyBps, uint16 sellBps, AppBinding[] memory apps)
        internal
        returns (PikaToken token)
    {
        LaunchParams memory p = _params(quote, baseIs0);
        p.buyFeeBps = buyBps;
        p.sellFeeBps = sellBps;
        p.apps = apps;
        return _launch(p);
    }

    /// @dev Sells out the curve; the crossing buy opens the pool in the same transaction.
    function _fill(PikaToken token, address quote) internal {
        _sellOut(token, quote);
        assertTrue(token.tradingStarted());
    }

    function _sellOut(PikaToken token, address quote) internal {
        if (quote == address(0)) {
            _buyAs(token, ALICE, 40 ether, true);
        } else {
            _buyAs(token, ALICE, 20_000 * 10 ** IERC20Metadata(quote).decimals(), false);
        }
    }

    /// @dev A curve buy through Core spending at most `budget` (fees included), in BNB or the quote token.
    function _buyAs(PikaToken token, address user, uint256 budget, bool native) internal returns (uint256 received) {
        uint256 before = token.balanceOf(user);
        vm.startPrank(user);
        if (native) {
            core.buyByBudget{ value: budget }(address(token), budget, 1, 0, "");
        } else {
            IERC20(token.quoteAsset()).forceApprove(address(core), budget);
            core.buyByBudget(address(token), budget, 1, 0, "");
        }
        vm.stopPrank();
        received = token.balanceOf(user) - before;
    }

    /// @dev A curve sell through Core; native BNB for a WBNB launch.
    function _curveSell(PikaToken token, address user, uint256 amount) internal returns (uint256 received) {
        address quote = token.quoteAsset();
        bool native = quote == address(wbnb);
        uint256 before = native ? user.balance : IERC20(quote).balanceOf(user);
        vm.startPrank(user);
        IERC20(address(token)).forceApprove(address(core), amount);
        core.sell(address(token), amount, 0, 0, "");
        vm.stopPrank();
        received = (native ? user.balance : IERC20(quote).balanceOf(user)) - before;
    }

    function _vaultOf(PikaToken token) internal view returns (IOpenFourVault) {
        return IOpenFourVault(token.vault());
    }

    function _swapParams(PikaToken token, bool sell, uint256 input, address recipient)
        internal
        view
        returns (PikaRouter.SwapParams memory p)
    {
        p = PikaRouter.SwapParams(address(token), sell, input, 1, recipient, block.timestamp, false);
    }

    function _swap(PikaToken token, address who, bool sell, uint256 input)
        internal
        returns (uint256 spent, uint256 out)
    {
        vm.startPrank(who);
        IERC20(sell ? address(token) : _poolQuote(token)).forceApprove(address(router), type(uint256).max);
        (spent, out) = router.swap(_swapParams(token, sell, input, who));
        vm.stopPrank();
        // Trades only book their fees; the push pays them out, as the keeper does.
        token.pushFees();
    }

    /// @dev Moves the clock (and the block) past the dividend sink's release window, so everything it has booked so
    ///      far is released to the holders of that time.
    function _releaseDividends() internal {
        vm.warp(vm.getBlockTimestamp() + dividendApp.RELEASE_WINDOW());
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev A swap through the Universal-Router-shaped locker: exact input, output taken straight to `who`.
    function _urSwap(PikaToken token, InfinityTestRouter r, address who, bool sell, uint256 input)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(who);
        IERC20(sell ? address(token) : _poolQuote(token)).forceApprove(address(r), type(uint256).max);
        delta = r.swap(token.poolKey(), sell == token.memeIsCurrency0(), -int256(input), who);
        vm.stopPrank();
        token.pushFees();
    }

    /// @dev A curve buy of `amount` quote budget by `user`; Core always delivers to the buyer itself.
    function _buy(PikaToken token, address quote, address user, uint256 amount, address recipient)
        internal
        returns (uint256)
    {
        require(recipient == user, "Core buys deliver to the buyer");
        return _buyAs(token, user, amount, quote == address(0));
    }

    /// @dev What a fee wallet has in `asset`: its balance plus the creator share accrued in the token, which the
    ///      wallet takes by `claimCreatorFees`. Only meaningful for the launch's `creatorFeeRecipient`.
    function _walletTotal(PikaToken token, address asset, address wallet) internal view returns (uint256) {
        return IERC20(asset).balanceOf(wallet) + token.creatorFees(asset);
    }

    /// @dev How the token splits a fee taken out of a gross output: on a sell (quote) the platform fee, the
    ///      platform's cut of the project fee (`PROJECT_FEE_CUT_BPS` of it, rounded down) and the project fee left
    ///      for the slots and the wallet; on a buy the output fee is the project fee alone (meme), its platform fee
    ///      is quote and comes out of the input (`_platformFee`).
    function _feeParts(PikaToken token, uint256 fee, bool buy)
        internal
        view
        returns (uint256 platform, uint256 cut, uint256 project)
    {
        platform = buy ? 0 : fee * 30 / token.outputFeeBps(false);
        project = fee - platform;
        cut = project / 10_000 * 1000 + project % 10_000 * 1000 / 10_000;
        project -= cut;
    }

    /// @dev A buy's platform fee: 0.30% of the quote offered (an exact-input swap reserves it out of the input).
    /// @dev The fee taken out of a gross pool output: the project fee on a buy's meme, the platform plus project
    ///      fee on a sell's quote (what the token's `outputFeeBps` names).
    function _tradeFee(PikaToken token, uint256 value, bool buy) internal view returns (uint256) {
        return PikaFeeMath.feeAt(value, token.outputFeeBps(buy));
    }

    function _platformFee(uint256 quoteIn) internal pure returns (uint256) {
        return quoteIn * 30 / 10_000;
    }

    /// @dev A buy's platform fee on top of the quote the pool took (orders, LP withdrawals, exact-output swaps).
    function _platformFeeOnNet(uint256 quoteTaken) internal pure returns (uint256) {
        return Math.mulDiv(quoteTaken, 10_000, 9970, Math.Rounding.Ceil) - quoteTaken;
    }

    /// @dev What the creator's wallet takes of an output fee when the launch binds no slots: the project fee after
    ///      the platform's cut.
    function _walletPart(PikaToken token, uint256 fee, bool buy) internal view returns (uint256 project) {
        (,, project) = _feeParts(token, fee, buy);
    }

    /// @dev What the treasury takes of an output fee, in that asset: on a sell the platform fee plus the platform's
    ///      cut, on a buy the cut alone (the platform fee is quote).
    function _treasuryPart(PikaToken token, uint256 fee, bool buy) internal view returns (uint256) {
        (uint256 platform, uint256 cut,) = _feeParts(token, fee, buy);
        return platform + cut;
    }

    function _quoteBalance(address quote, address account) internal view returns (uint256) {
        return quote == address(0) ? account.balance : IERC20(quote).balanceOf(account);
    }

    function _order(PikaOrderManager orders, uint256 id) internal view returns (PikaOrderManager.Order memory o) {
        (bool ok, bytes memory data) = address(orders).staticcall(abi.encodeCall(orders.orders, (id)));
        require(ok);
        o = abi.decode(data, (PikaOrderManager.Order));
    }

    function _poolPrice(PikaToken token) internal view returns (uint160 price) {
        (price,,,) = manager.getSlot0(token.poolId());
    }

    function _poolLiquidity(PikaToken token) internal view returns (uint128) {
        return manager.getLiquidity(token.poolId());
    }

    function _vaultBalance(PikaToken token) internal view returns (uint256) {
        return token.balanceOf(address(vault));
    }

    /// @dev The launch pool's liquidity minted to the burn address: the graduation position and every liquidity-sink
    ///      dispatch since.
    function _burnedLiquidity(PikaToken token) internal view returns (uint128 liquidity) {
        (liquidity,) = _burned(positionManager, token.poolId(), 1);
    }

    /// @dev External so a test can `try` it or expect its revert: a Pancake LP NFT minted by `who`.
    function lpMintAs(PoolKey memory key, address who, int24 lower, int24 upper, uint256 a0, uint256 a1)
        external
        returns (uint256 id, uint128 liquidity)
    {
        require(msg.sender == address(this));
        return _lpMint(positionManager, key, who, lower, upper, a0, a1);
    }

    /// @dev External so a test can `try` it or expect its revert: `who` takes `liquidity` out of LP NFT `id`.
    function lpDecreaseAs(uint256 id, address who, uint128 liquidity) external {
        require(msg.sender == address(this));
        _lpDecrease(positionManager, id, who, liquidity, who);
    }

    /// @dev The revert the pool manager raises when the launch hook refuses `callback` with `reason`.
    function _hookError(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev `who` mints a Pancake LP NFT on the launch pool from meme and quote amounts.
    function _lpMintMeme(PikaToken token, address who, int24 lower, int24 upper, uint256 meme, uint256 quote)
        internal
        returns (uint256 id, uint128 liquidity)
    {
        (uint256 a0, uint256 a1) = token.memeIsCurrency0() ? (meme, quote) : (quote, meme);
        return _lpMint(positionManager, token.poolKey(), who, lower, upper, a0, a1);
    }
}
