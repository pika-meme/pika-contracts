// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ILockCallback } from "infinity-core/src/interfaces/ILockCallback.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { Currency } from "infinity-core/src/types/Currency.sol";
import { BalanceDelta } from "infinity-core/src/types/BalanceDelta.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaDividendApp } from "../../src/pika-apps/PikaDividendApp.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PikaAppBase } from "../../src/pika-apps/PikaAppBase.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";
import { PikaTokenParams } from "../../src/pika-launch/interfaces/IPikaLaunch.sol";

/// @dev A Universal-Router-shaped locker that lets the caller set the swap's price limit, so a swap can stop early
///      (a partial fill). `resolve` settles the open vault deltas like Pancake's `SETTLE_ALL` / `TAKE_ALL`
///      (`currencyDelta`), the way a real router does; otherwise it settles the swap's returned delta only.
contract LimitLocker is ILockCallback {
    using SafeERC20 for IERC20;

    IVault public immutable vault;
    ICLPoolManager public immutable manager;

    struct Call {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 limit;
        address payer;
        address recipient;
        bool resolve;
    }

    constructor(IVault vault_, ICLPoolManager manager_) {
        vault = vault_;
        manager = manager_;
    }

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        address recipient,
        bool resolve
    ) external returns (BalanceDelta delta) {
        delta = abi.decode(
            vault.lock(abi.encode(Call(key, zeroForOne, amountSpecified, limit, msg.sender, recipient, resolve))),
            (BalanceDelta)
        );
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault));
        Call memory c = abi.decode(data, (Call));
        BalanceDelta delta = manager.swap(
            c.key,
            ICLPoolManager.SwapParams({
                zeroForOne: c.zeroForOne, amountSpecified: c.amountSpecified, sqrtPriceLimitX96: c.limit
            }),
            ""
        );
        if (c.resolve) {
            _settle(c, c.key.currency0, int128(vault.currencyDelta(address(this), c.key.currency0)));
            _settle(c, c.key.currency1, int128(vault.currencyDelta(address(this), c.key.currency1)));
        } else {
            _settle(c, c.key.currency0, delta.amount0());
            _settle(c, c.key.currency1, delta.amount1());
        }
        return abi.encode(delta);
    }

    function _settle(Call memory c, Currency currency, int128 amount) private {
        if (amount < 0) {
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(c.payer, address(vault), uint256(uint128(-amount)));
            vault.settle();
        } else if (amount > 0) {
            vault.take(currency, c.recipient, uint256(uint128(amount)));
        }
    }
}

/// @dev A 6-decimal stablecoin.
contract SixDecimals is ERC20 {
    constructor() ERC20("Six", "SIX") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev A contract wallet (a Safe stands in): it holds tokens and can call the dividend sink itself.
contract ContractWallet {
    function claim(PikaDividendApp app, address token) external returns (uint256, uint256) {
        return app.claim(token, address(this));
    }
}

/// @notice Behaviours checked by the independent review of 2026-11-07 (docs/audit-2026-11-07-independent-review.md).
contract IndependentReview20261107Test is PikaInfinityFixture {
    PikaToken token;

    function setUp() public override {
        super.setUp();
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(DIVIDEND_ID, 10_000, 10_000, abi.encode(uint256(0)));
        token = _createWithFees(address(usdt), true, 100, 100, apps);
        _fill(token, address(usdt));
    }

    /// @dev R-3 (fixed): an exact-input buy through a third-party locker that stops at a price limit pays the platform
    ///      fee on what the pool took; the rest of the reservation is credited to the locker's vault delta, so a
    ///      router that resolves its deltas (Pancake's Universal Router) pays the trader exactly the input less the
    ///      refund. Nothing is left as a loose ERC20 balance of the locker.
    function testPartialFillRefundIsCreditedToTheLockersDelta() public {
        LimitLocker locker = new LimitLocker(IVault(address(vault)), ICLPoolManager(address(manager)));
        uint256 amountIn = 50_000 ether;
        uint256 vaultBefore = usdt.balanceOf(address(vault));
        uint256 swapOwed = _partialBuy(locker, amountIn, true);
        assertLt(swapOwed, amountIn, "partial fill");
        uint256 taken = swapOwed - amountIn * 30 / 10_000;
        uint256 fee = _platformFeeOnNet(taken);
        assertGt(amountIn * 30 / 10_000, fee, "part of the reservation is refunded");
        // The trader paid the pool's take plus the fee actually charged: the refund never left its wallet.
        assertEq(amountIn - usdt.balanceOf(ALICE), taken + fee, "trader pays take + fee");
        assertEq(usdt.balanceOf(address(locker)), 0, "nothing loose on the locker");
        _assertNoDelta(address(locker));
        // The vault holds the pool's take; the fee went to the token, the refund back to the trader.
        assertEq(usdt.balanceOf(address(vault)) - vaultBefore, taken, "vault keeps only the pool's take");
        token.pushFees();
    }

    /// @dev A quote-in buy of `amountIn` by ALICE through `locker`, stopped 100 ticks (about 1%) past the current
    ///      price so that a large input only partly fills. Returns the quote the swap's delta charged.
    function _partialBuy(LimitLocker locker, uint256 amountIn, bool resolve) private returns (uint256 swapOwed) {
        PoolKey memory key = token.poolKey();
        bool memeIs0 = token.memeIsCurrency0();
        (, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtRatioAtTick(memeIs0 ? tick + 100 : tick - 100);
        deal(address(usdt), ALICE, amountIn);
        vm.startPrank(ALICE);
        usdt.approve(address(locker), type(uint256).max);
        BalanceDelta delta = locker.swap(key, !memeIs0, -int256(amountIn), limit, ALICE, resolve);
        vm.stopPrank();
        swapOwed = uint256(uint128(-(memeIs0 ? delta.amount1() : delta.amount0())));
    }

    function _assertNoDelta(address who) private view {
        PoolKey memory key = token.poolKey();
        assertEq(vault.currencyDelta(who, key.currency0), 0);
        assertEq(vault.currencyDelta(who, key.currency1), 0);
    }

    /// @dev R-3: a locker that settles the swap's returned delta and ignores its open vault delta cannot end the
    ///      lock on a partial fill (the refund is a credit it never took), instead of silently losing the refund.
    function testNaiveLockerPartialFillRevertsInsteadOfLosingTheRefund() public {
        LimitLocker locker = new LimitLocker(IVault(address(vault)), ICLPoolManager(address(manager)));
        vm.expectRevert();
        this.partialBuyNaive(locker);
        // A full fill settles by the returned delta as before.
        PoolKey memory key = token.poolKey();
        bool zeroForOne = !token.memeIsCurrency0();
        deal(address(usdt), ALICE, 1_000 ether);
        vm.startPrank(ALICE);
        usdt.approve(address(locker), type(uint256).max);
        locker.swap(
            key,
            zeroForOne,
            -int256(1_000 ether),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            ALICE,
            false
        );
        vm.stopPrank();
    }

    function partialBuyNaive(LimitLocker locker) external {
        _partialBuy(locker, 50_000 ether, false);
    }

    /// @dev R-6 (fixed): `registerLaunch` re-checks the supply Core's `validate` fixed, so a clone of the allowed
    ///      implementation initialized outside Core with another supply is refused; one with the right supply still
    ///      registers (inert: it can never graduate) and is filtered off-chain by Core's `TokenCreated`.
    function testHubRefusesAnOutsideCloneWithAnotherMaxSupply() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(DIVIDEND_ID, 10_000, 10_000, abi.encode(uint256(0)));
        PikaToken.InitArgs memory a;
        a.name = "Odd";
        a.symbol = "ODD";
        a.vault = address(0xbad);
        a.maxSupply = 1;
        a.curveModule = address(1);
        a.tradeModule = address(1);
        a.migrateModule = address(1);
        a.tokenModule = address(1);
        a.creator = address(0xbad);
        a.quoteAsset = address(usdt);
        a.tokenParams = abi.encode(PikaTokenParams(address(0xbad), 100, 100, apps));
        address clone = Clones.clone(tokenImplementation);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        PikaToken(clone).initialize(a);
        assertFalse(factory.isLaunch(clone));
        assertFalse(dividendApp.registered(clone));
        a.maxSupply = factory.defaultSupply();
        clone = Clones.clone(tokenImplementation);
        PikaToken(clone).initialize(a);
        assertTrue(factory.isLaunch(clone));
    }

    /// @dev R-4 (fixed): a contract wallet put on the exclusion list keeps what it earned and claims it itself; the
    ///      owner cannot take it before `RECLAIM_DELAY`, and a wallet that is not excluded cannot be reclaimed at all.
    function testExcludedContractWalletClaimsItsEarnings() public {
        ContractWallet safe = new ContractWallet();
        vm.prank(ALICE);
        token.transfer(address(safe), 1_000_000 ether);
        _swap(token, CAROL, false, 1_000 ether);
        _swap(token, CAROL, true, 1_000_000 ether);
        token.pushFees();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        (uint256 meme, uint256 quote) = dividendApp.pending(address(token), address(safe));
        assertGt(meme, 0);
        assertGt(quote, 0);
        vm.prank(registry.owner());
        dividendApp.setExcluded(address(token), address(safe), true);
        vm.prank(registry.owner());
        vm.expectRevert(PikaAppBase.InvalidParams.selector);
        dividendApp.reclaimUnclaimed(address(token), address(safe));
        uint256 memeBefore = token.balanceOf(address(safe));
        (uint256 m, uint256 q) = safe.claim(dividendApp, address(token));
        assertEq(m, meme, "the listed wallet still claims its past earnings");
        assertEq(q, quote);
        assertEq(token.balanceOf(address(safe)) - memeBefore, meme);
        assertEq(usdt.balanceOf(address(safe)), quote);
        // Not excluded: nothing to reclaim, ever.
        vm.prank(registry.owner());
        vm.expectRevert(PikaAppBase.InvalidParams.selector);
        dividendApp.reclaimUnclaimed(address(token), BOB);
    }

    /// @dev R-10 (fixed): the target floor is 0.001 of a whole quote unit, so a 6-decimal quote can be configured
    ///      with a sensible minimum target; an 18-decimal quote keeps the former 1e15 floor.
    function testTargetFloorFollowsTheQuotesDecimals() public {
        assertEq(factory.targetFloor(18), 1e15);
        assertEq(factory.targetFloor(6), 1e3);
        SixDecimals six = new SixDecimals();
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.configureQuote(address(six), true, 999);
        factory.configureQuote(address(six), true, 1_000e6);
        (bool enabled, uint8 decimals, uint256 minTarget) = factory.quoteConfigs(address(six));
        assertTrue(enabled);
        assertEq(decimals, 6);
        assertEq(minTarget, 1_000e6);
        vm.expectRevert(PikaLaunchFactory.InvalidConfiguration.selector);
        factory.configureQuote(address(usdt), true, 1e15 - 1);
    }

    /// @dev R-9 (fixed): `_openingPrice` now demands the margin the graduation mint needs, and every launch the
    ///      parameter bounds admit (supply 1e6 to 1e18 whole tokens, target 0.001 to 1e12 units of an 18-decimal quote,
    ///      either token order) still passes `validate`, so the tighter bound refuses nothing that was admissible.
    function testValidateStillAdmitsTheParameterExtremes() public {
        uint256[2] memory supplies = [factory.MIN_SUPPLY(), uint256(1e36)];
        uint256[2] memory targets = [uint256(1e15), uint256(1e30)];
        factory.configureQuote(address(usdt), true, 1e15);
        for (uint256 i; i < 2; ++i) {
            factory.setDefaultSupply(supplies[i]);
            for (uint256 j; j < 2; ++j) {
                OpenFourTypes.TokenInitParams memory p = _initParams(supplies[i], targets[j]);
                // The size bound on the opening liquidity is the only reason a corner may be refused.
                (bool ok, bytes memory reason) =
                    address(factory).staticcall(abi.encodeCall(factory.validate, (PRESET_ID, p)));
                if (!ok) {
                    assertEq(bytes4(reason), PikaLaunchFactory.InvalidConfiguration.selector);
                    uint256 liquidity = Math.sqrt(supplies[i] / 5 * (targets[j] * 98 / 100));
                    assertGt(liquidity, type(uint128).max / 2 / 1_774_545, "refused only for its sheer size");
                }
            }
        }
    }

    function _initParams(uint256 supply, uint256 target) private view returns (OpenFourTypes.TokenInitParams memory p) {
        p.name = "Edge";
        p.symbol = "EDGE";
        p.maxSupply = supply;
        p.saleAmount = factory.sizing(supply, target).saleAmount;
        p.raiseAmount = target;
        p.quoteAsset = address(usdt);
        p.tokenParams = abi.encode(PikaTokenParams(address(0xfee), 0, 0, new AppBinding[](0)));
    }

    /// @dev R-2: dropping a preset's graduation right while launches are still on their curves closes their only
    ///      exit. With the local Core the sell-out buy reverts (the real Core's behaviour on a failed migration is
    ///      not public); either way the raise can never reach the pool.
    function testDroppingGraduationStrandsACurveLaunch() public {
        AppBinding[] memory none = new AppBinding[](0);
        PikaToken curve = _createWithFees(address(usdt), true, 0, 0, none);
        factory.setPreset(PRESET_ID, false);
        factory.setGraduationPreset(PRESET_ID, false);
        vm.startPrank(ALICE);
        usdt.approve(address(core), type(uint256).max);
        vm.expectRevert();
        core.buyByBudget(address(curve), 20_000 ether, 1, 0, "");
        vm.stopPrank();
        assertFalse(curve.tradingStarted());
        // Re-allowing graduation (owner, through the timelock) reopens it.
        factory.setGraduationPreset(PRESET_ID, true);
        _fill(curve, address(usdt));
    }

    /// @dev R-1 (hardening): the hub takes `quoteAmount` from the migrate module's word; it could read the vault's
    ///      `totalRaised` itself. Pinned here as the current contract: the two agree for Pika's own module.
    function testGraduationUsesTheVaultsRaiseToday() public {
        AppBinding[] memory none = new AppBinding[](0);
        PikaToken curve = _createWithFees(address(usdt), true, 0, 0, none);
        uint256 pendingBefore = factory.pendingTreasuryQuote(address(usdt));
        _fill(curve, address(usdt));
        uint256 raised = _vaultOf(curve).totalRaised();
        uint256 creator = curve.creatorFees(address(usdt));
        assertEq(creator, raised * 100 / 10_000, "creator gets 1% of the vault's raise");
        // Treasury: the rest of the raise outside the pool plus rounding, never less than 1%.
        assertGe(factory.pendingTreasuryQuote(address(usdt)) - pendingBefore, raised * 100 / 10_000);
    }
}
