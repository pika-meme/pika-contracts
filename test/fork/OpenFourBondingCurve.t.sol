// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IOpenFourCurveModule } from "../../src/openfour/interfaces/IOpenFourCurveModule.sol";
import { IOpenFourRegistry } from "../../src/openfour/interfaces/IOpenFourRegistry.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { OpenFourStandardModules } from "../../script/OpenFourStandardModules.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { PikaGraduationMath } from "../../src/pika-launch/libraries/PikaGraduationMath.sol";
import { OpenFourBondingCurve } from "../helpers/OpenFourBondingCurve.sol";

/// @notice OpenFour's bonding curve (`module.curve.bonding`, closed source) on BSC mainnet against the stand-in the
///         mock-Core tests use and the hub's sizing: a clone of the live implementation and the stand-in, initialized
///         with the same Pika launch, must agree on the reserves, prices, buys, sells and budget buys.
///         Skipped unless `RUN_PIKA_FORK=true`; `PIKA_FORK_BLOCK` pins the block.
contract OpenFourBondingCurveForkTest is Test {
    address constant OPENFOUR_REGISTRY = 0x912CEf0C3aE9Ab6eB3Ec87cab69371cFb317Ab94;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant TOKEN = address(0xC0FFE);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    address core;
    address implementation;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_PIKA_FORK", false));
        uint256 forkBlock = vm.envOr("PIKA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), forkBlock);
        IOpenFourRegistry r = IOpenFourRegistry(OPENFOUR_REGISTRY);
        assertTrue(OpenFourStandardModules.curveListed(OPENFOUR_REGISTRY), "bonding curve listed");
        core = r.openFourCore();
        implementation = r.getModuleImplementation(OpenFourStandardModules.CURVE_KEY);
    }

    function test_MatchesTheLiveCurve() public {
        uint256[5] memory targets = [uint256(18 ether), 0.01 ether + 1, 7.284207964119141687 ether, 12_000 ether, 1e15];
        for (uint256 i; i < targets.length; ++i) {
            _compare(targets[i]);
        }
    }

    function testFuzz_MatchesTheLiveCurve(uint256 target, uint256 seed) public {
        target = bound(target, 1e15, 1e30);
        (IOpenFourCurveModule live, IOpenFourCurveModule standIn,) = _pair(target);
        uint256 sale = SUPPLY * 8000 / 10_000;
        uint256 remaining = sale;
        uint256 raised;
        for (uint256 i; i < 6 && remaining > 0; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = bound(seed, 1e9, remaining);
            uint256 cost = _sameBuy(live, standIn, amount, remaining, raised);
            if (cost == 0) continue; // too small to price: refused by both
            raised += cost;
            remaining -= amount;
            if (remaining == 0) break;
            uint256 budget = bound(seed >> 128, 1, target);
            _sameReverse(live, standIn, budget, remaining, raised);
            uint256 sold = sale - remaining;
            uint256 back = bound(seed >> 64, 1e9, sold);
            uint256 out = _sameSell(live, standIn, back, remaining, raised);
            if (out != 0 && out <= raised) {
                remaining += back;
                raised -= out;
            }
        }
    }

    function _compare(uint256 target) internal {
        (IOpenFourCurveModule live, IOpenFourCurveModule standIn, PikaLaunchFactory.Sizing memory s) = _pair(target);
        OpenFourTypes.CurveLiquiditySnapshot memory l = live.getLiquiditySnapshot(TOKEN, s.saleAmount, 0);
        assertEq(l.initialQuoteLiquidity, s.virtualQuote, "virtual quote");
        assertEq(l.initialTokenLiquidity, s.virtualTokens, "virtual tokens");
        assertEq(live.getInitialPrice(), standIn.getInitialPrice(), "initial price");
        uint256 remaining = s.saleAmount;
        uint256 raised;
        uint256[4] memory buys = [s.saleAmount / 8, s.saleAmount / 3 + 12_345, 1 ether, s.saleAmount / 5 + 777];
        for (uint256 i; i < buys.length; ++i) {
            raised += _sameBuy(live, standIn, buys[i], remaining, raised);
            remaining -= buys[i];
            _sameReverse(live, standIn, target / (i + 3) + i, remaining, raised);
            assertEq(
                live.getLastPrice(TOKEN, remaining, raised), standIn.getLastPrice(TOKEN, remaining, raised), "price"
            );
        }
        _sameSell(live, standIn, s.saleAmount / 50, remaining, raised);
        _sameSell(live, standIn, 3 ether + 1, remaining, raised);
        // Selling out from the start raises the target, short by at most a few wei, and ends at the pool's price.
        uint256 all = _sameBuy(live, standIn, s.saleAmount, s.saleAmount, 0);
        assertApproxEqRel(all, target, 1e6, "a full sale raises the target");
        assertApproxEqRel(
            live.getLastPrice(TOKEN, 0, all), s.poolQuote * 1e18 / s.poolTokens, 1e12, "the sale ends at the pool price"
        );
    }

    function _pair(uint256 target)
        internal
        returns (IOpenFourCurveModule live, IOpenFourCurveModule standIn, PikaLaunchFactory.Sizing memory s)
    {
        s = _sizing(target);
        OpenFourTypes.TokenCreateParams memory p;
        p.name = "X";
        p.symbol = "X";
        p.maxSupply = SUPPLY;
        p.saleAmount = s.saleAmount;
        p.raiseAmount = target;
        p.quoteAsset = WBNB;
        live = IOpenFourCurveModule(Clones.clone(implementation));
        standIn = IOpenFourCurveModule(address(new OpenFourBondingCurve()));
        vm.startPrank(core);
        live.init(TOKEN, core, p, "", "1.0.0");
        standIn.init(TOKEN, core, p, "", "1.0.0");
        vm.stopPrank();
    }

    /// @dev The hub's sizing (`PikaLaunchFactory.sizing`), from its constants and library without deploying a hub.
    function _sizing(uint256 target) internal pure returns (PikaLaunchFactory.Sizing memory s) {
        s.saleAmount = SUPPLY * 8000 / 10_000;
        s.poolTokens = SUPPLY - s.saleAmount;
        s.poolQuote = target * PikaGraduationMath.POOL_QUOTE_BPS / 10_000;
        (s.virtualQuote, s.virtualTokens) = PikaGraduationMath.bondingReserves(SUPPLY, s.saleAmount, target);
    }

    function _ctx(uint256 amount, bool isBuy, uint256 remaining, uint256 raised)
        internal
        pure
        returns (OpenFourTypes.CurveContext memory c)
    {
        c.token = TOKEN;
        c.trader = address(0xB0B);
        c.amount = amount;
        c.isBuy = isBuy;
        c.remainingForSale = remaining;
        c.totalRaised = raised;
    }

    function _sameBuy(
        IOpenFourCurveModule live,
        IOpenFourCurveModule standIn,
        uint256 amount,
        uint256 remaining,
        uint256 raised
    ) internal view returns (uint256) {
        OpenFourTypes.CurveResult memory a = live.evaluate(_ctx(amount, true, remaining, raised));
        OpenFourTypes.CurveResult memory b = standIn.evaluate(_ctx(amount, true, remaining, raised));
        assertEq(a.executable, b.executable, "buy executable");
        assertEq(a.quoteAmount, b.quoteAmount, "buy quote");
        assertEq(a.adjustedAmount, b.adjustedAmount, "buy adjusted");
        return a.quoteAmount;
    }

    function _sameSell(
        IOpenFourCurveModule live,
        IOpenFourCurveModule standIn,
        uint256 amount,
        uint256 remaining,
        uint256 raised
    ) internal view returns (uint256) {
        OpenFourTypes.CurveResult memory a = live.evaluate(_ctx(amount, false, remaining, raised));
        OpenFourTypes.CurveResult memory b = standIn.evaluate(_ctx(amount, false, remaining, raised));
        assertEq(a.executable, b.executable, "sell executable");
        assertEq(a.quoteAmount, b.quoteAmount, "sell quote");
        return a.quoteAmount;
    }

    function _sameReverse(
        IOpenFourCurveModule live,
        IOpenFourCurveModule standIn,
        uint256 budget,
        uint256 remaining,
        uint256 raised
    ) internal view {
        (uint256 t1, uint256 q1) = live.evaluateReverse(TOKEN, true, budget, remaining, raised, 0);
        (uint256 t2, uint256 q2) = standIn.evaluateReverse(TOKEN, true, budget, remaining, raised, 0);
        assertEq(t1, t2, "budget tokens");
        assertEq(q1, q2, "budget quote");
    }
}
