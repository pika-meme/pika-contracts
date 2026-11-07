// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IOpenFourTradeModule } from "../../src/openfour/interfaces/IOpenFourTradeModule.sol";
import { IOpenFourRegistry } from "../../src/openfour/interfaces/IOpenFourRegistry.sol";
import { OpenFourTypes } from "../../src/openfour/libraries/OpenFourTypes.sol";
import { OpenFourStandardModules } from "../../script/OpenFourStandardModules.sol";
import { OpenFourSimpleTrade } from "../helpers/OpenFourSimpleTrade.sol";

/// @notice OpenFour's simple trade policy (`module.trade.simple`, closed source) on BSC mainnet against the stand-in
///         the mock-Core tests use: a clone of the live implementation and the stand-in, initialized for the same
///         launch, must give the same initialization rules, descriptor, parameters and trade results.
///         Skipped unless `RUN_PIKA_FORK=true`; `PIKA_FORK_BLOCK` pins the block.
contract OpenFourSimpleTradeForkTest is Test {
    address constant OPENFOUR_REGISTRY = 0x912CEf0C3aE9Ab6eB3Ec87cab69371cFb317Ab94;
    address constant TOKEN = address(0xC0FFE);

    address core;
    address implementation;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_PIKA_FORK", false));
        uint256 forkBlock = vm.envOr("PIKA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), forkBlock);
        assertTrue(OpenFourStandardModules.tradeListed(OPENFOUR_REGISTRY), "simple trade policy listed");
        IOpenFourRegistry r = IOpenFourRegistry(OPENFOUR_REGISTRY);
        core = r.openFourCore();
        implementation = r.getModuleImplementation(OpenFourStandardModules.TRADE_KEY);
    }

    function test_MatchesTheLiveTradePolicy() public {
        IOpenFourTradeModule live = IOpenFourTradeModule(Clones.clone(implementation));
        IOpenFourTradeModule standIn = new OpenFourSimpleTrade();
        // Parameters are refused by both.
        IOpenFourTradeModule other = IOpenFourTradeModule(Clones.clone(implementation));
        vm.prank(core);
        vm.expectRevert();
        other.init(TOKEN, core, abi.encode(uint256(1)), "1.0.0");
        IOpenFourTradeModule otherStandIn = new OpenFourSimpleTrade();
        vm.prank(core);
        vm.expectRevert();
        otherStandIn.init(TOKEN, core, abi.encode(uint256(1)), "1.0.0");
        // Both initialize once, from any caller.
        live.init(TOKEN, core, "", "1.0.0");
        standIn.init(TOKEN, core, "", "1.0.0");
        vm.expectRevert();
        live.init(TOKEN, core, "", "1.0.0");
        vm.expectRevert();
        standIn.init(TOKEN, core, "", "1.0.0");
        assertEq(live.getInitParams(), standIn.getInitParams());
        (bytes8 a, string memory b, string memory c) = live.descriptor();
        (bytes8 x, string memory y, string memory z) = standIn.descriptor();
        assertEq(a, x);
        assertEq(b, y);
        assertEq(c, z);
        assertEq(a, bytes8(keccak256("module.trade.simple")));
        uint256[4] memory amounts = [uint256(0), 1, 1e27, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 dir; dir < 2; ++dir) {
                OpenFourTypes.TradeContext memory ctx = _context(TOKEN, amounts[i], dir == 0);
                _same(live.evaluate(ctx), standIn.evaluate(ctx));
            }
        }
        // Another token's trade is refused by both.
        OpenFourTypes.TradeContext memory wrong = _context(address(0xBAD), 1, true);
        vm.expectRevert(bytes("Trade: wrong token"));
        live.evaluate(wrong);
        vm.expectRevert(bytes("Trade: wrong token"));
        standIn.evaluate(wrong);
    }

    function _context(address token, uint256 amount, bool isBuy)
        internal
        view
        returns (OpenFourTypes.TradeContext memory c)
    {
        c = OpenFourTypes.TradeContext({
            token: token,
            trader: address(0xBEEF),
            amount: amount,
            isBuy: isBuy,
            timestamp: block.timestamp,
            blockNumber: block.number,
            remainingForSale: 8e26,
            totalRaised: 1 ether,
            curveQuote: 1e18,
            proof: ""
        });
    }

    function _same(OpenFourTypes.TradeResult memory l, OpenFourTypes.TradeResult memory s) internal pure {
        assertTrue(l.allowed && s.allowed, "allowed");
        assertEq(l.minAmount, s.minAmount, "min");
        assertEq(l.maxAmount, s.maxAmount, "max");
        assertEq(l.maxAmount, type(uint256).max, "no cap");
        assertEq(l.fees.length, 0, "no fees");
        assertEq(s.fees.length, 0, "stand-in fees");
        assertEq(l.revertData, s.revertData, "revert data");
    }
}
