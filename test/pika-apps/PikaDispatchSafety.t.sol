// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaSinkBase } from "../../src/pika-apps/PikaSinkBase.sol";
import { PikaLiquidityApp } from "../../src/pika-apps/PikaLiquidityApp.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";
import { TickMath } from "infinity-core/src/pool-cl/libraries/TickMath.sol";

contract PikaDispatchSafetyTest is PikaInfinityFixture {
    function launch(uint32 app, bool side) private returns (PikaToken t) {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(app, 10_000, 10_000, "");
        t = _createWithFees(address(usdt), side, 500, 500, apps);
        _fill(t, address(usdt));
        _swap(t, ALICE, true, 20_000_000 ether);
    }

    function testPreviewRollsBackAndBoundedBuybackRetainsRemainder() public {
        PikaToken t = launch(BURN_APP_ID, true);
        uint256 beforeQuote = burnApp.pending(address(t), address(usdt));
        uint256 cap = beforeQuote / 3;
        uint160 beforePrice = _poolPrice(t);
        uint256 beforeTokenQuote = usdt.balanceOf(address(t));
        (uint256 output, uint160 afterPrice) = burnApp.previewSwap(address(t), false, cap);
        assertGt(output, 0);
        assertGt(afterPrice, beforePrice);
        assertEq(_poolPrice(t), beforePrice);
        assertEq(usdt.balanceOf(address(t)), beforeTokenQuote);
        assertEq(usdt.balanceOf(address(burnApp)), beforeQuote);
        assertEq(usdt.allowance(address(burnApp), address(router)), 0);
        vm.prank(KEEPER);
        (uint256 spent, uint256 bought,) = burnApp.buybackLimited(address(t), cap, output, block.timestamp);
        assertEq(spent, cap);
        assertEq(bought, output);
        assertEq(burnApp.pending(address(t), address(usdt)), beforeQuote - cap);
        assertEq(usdt.balanceOf(address(burnApp)), beforeQuote - cap);
        assertEq(_poolPrice(t), afterPrice);
    }

    function testPreviewCannotBeUsedToExecuteSwapOrQuoteUnbookedFunds() public {
        PikaToken t = launch(BURN_APP_ID, true);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        burnApp.simulateSwap(address(t), false, 1 ether);
        uint256 tooMuch = burnApp.pending(address(t), address(usdt)) + 1;
        vm.expectRevert(bytes4(keccak256("InvalidParams()")));
        burnApp.previewSwap(address(t), false, tooMuch);
    }

    function testZeroMinimumRevertsWithoutChangingBooks() public {
        PikaToken t = launch(BURN_APP_ID, false);
        uint256 booked = burnApp.pending(address(t), address(usdt));
        vm.prank(KEEPER);
        vm.expectRevert(PikaSinkBase.MissingMinimumOutput.selector);
        burnApp.buybackLimited(address(t), booked / 2, 0, block.timestamp);
        assertEq(burnApp.pending(address(t), address(usdt)), booked);
        assertEq(usdt.balanceOf(address(burnApp)), booked);
    }

    function testBoundedLiquidityDoesNotConsumeOtherLaunchOrUnselectedFunds() public {
        PikaToken t = launch(LIQUIDITY_ID, false);
        PikaToken other = launch(LIQUIDITY_ID, true);
        uint256 booked = liquidityApp.pending(address(t), address(usdt));
        uint256 otherBooked = liquidityApp.pending(address(other), address(usdt));
        uint256 cap = booked / 3;
        (uint256 output,) = liquidityApp.previewSwap(address(t), false, cap / 2);
        PikaLiquidityApp.Dispatch memory d = PikaLiquidityApp.Dispatch(
            address(t), 0, cap, output, TickMath.MIN_SQRT_RATIO + 1, TickMath.MAX_SQRT_RATIO - 1
        );
        vm.prank(KEEPER);
        (uint128 minted,, uint256 used) = liquidityApp.addLiquidityLimited(d, block.timestamp);
        assertGt(minted, 0);
        assertLe(used, cap / 2 + 1);
        uint256 left = liquidityApp.pending(address(t), address(usdt));
        assertGe(left, booked - cap);
        assertEq(liquidityApp.pending(address(other), address(usdt)), otherBooked);
        assertEq(usdt.balanceOf(address(liquidityApp)), left + otherBooked);
        assertEq(t.balanceOf(address(liquidityApp)), liquidityApp.pending(address(t), address(t)));
    }

    function testBoundedBatchSkipsOnlyTheInvalidMinimum() public {
        PikaToken a = launch(BURN_APP_ID, true);
        PikaToken b = launch(BURN_APP_ID, false);
        address[] memory tokens = new address[](2);
        tokens[0] = address(a);
        tokens[1] = address(b);
        uint256[] memory maxima = new uint256[](2);
        maxima[0] = burnApp.pending(address(a), address(usdt)) / 2;
        maxima[1] = burnApp.pending(address(b), address(usdt)) / 2;
        uint256[] memory minima = new uint256[](2);
        (minima[0],) = burnApp.previewSwap(address(a), false, maxima[0]);
        uint256 beforeB = burnApp.pending(address(b), address(usdt));
        vm.prank(KEEPER);
        bool[] memory done = burnApp.buybackLimitedMany(tokens, maxima, minima, block.timestamp);
        assertTrue(done[0]);
        assertFalse(done[1]);
        assertEq(burnApp.pending(address(b), address(usdt)), beforeB);
    }
}
