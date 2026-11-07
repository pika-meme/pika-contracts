// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { PoolKey } from "infinity-core/src/types/PoolKey.sol";
import { PoolId } from "infinity-core/src/types/PoolId.sol";
import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaLaunchFactory } from "../../src/pika-launch/PikaLaunchFactory.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice 2026-11-07: graduation mints the opening position to the burn address through Pancake's official position
///         manager (no Pika locker), and anyone may add and remove liquidity on a launch pool, fee-free.
contract PikaOpenLiquidityTest is PikaInfinityFixture {
    bytes32 constant BURNED_TOPIC =
        keccak256("GraduationPositionBurned(address,uint256,uint128,uint256,uint256,uint256)");

    function testGraduationMintsOneFullRangeNftToTheBurnAddress() public {
        PikaToken token = _create(address(usdt), true);
        uint256 nextId = positionManager.nextTokenId();
        vm.recordLogs();
        _fill(token, address(usdt));
        (uint256 positionId, uint128 liquidity, uint256 memeUsed, uint256 quoteUsed, uint256 memeBurned) =
            _burnedEvent(address(token));
        assertEq(positionId, nextId, "graduation minted the next NFT");
        assertEq(positionManager.nextTokenId(), nextId + 1, "and only that one");
        assertEq(positionManager.ownerOf(positionId), BURN);
        (PoolKey memory key, int24 lower, int24 upper, uint128 held) = _lpPosition(positionManager, positionId);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(token.poolId()), "on the launch pool");
        assertEq(lower, FULL_LOWER, "the full range on the pools' spacing of 50");
        assertEq(upper, FULL_UPPER);
        assertEq(held, liquidity);
        assertEq(_poolLiquidity(token), liquidity, "the pool opens with the burned position only");
        // The pool's tokens and 98% of the raise went in; the curve's unsold remainder was burned beside it.
        uint256 poolTokens = factory.defaultSupply() / 5;
        assertApproxEqRel(memeUsed, poolTokens, 1e14);
        assertApproxEqRel(quoteUsed, 12_000 ether * 9800 / 10_000, 1e14);
        assertEq(token.balanceOf(BURN), memeBurned);
        assertLe(memeBurned, 1 ether);
        // Nothing stays in the hub or the position manager but the treasury's quote.
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(usdt.balanceOf(address(factory)), factory.pendingTreasuryQuote(address(usdt)));
        assertEq(token.balanceOf(address(positionManager)), 0);
        assertEq(usdt.balanceOf(address(positionManager)), 0);
    }

    function testStrangersLeftoversInThePositionManagerCannotStopGraduation() public {
        PikaToken token = _create(address(usdt), true);
        deal(address(usdt), BOB, 200 ether);
        _buy(token, address(usdt), BOB, 100 ether, BOB);
        uint256 dropped = token.balanceOf(BOB);
        // Somebody leaves meme and quote in Pancake's position manager before the sell-out.
        vm.startPrank(BOB);
        token.transfer(address(positionManager), dropped);
        usdt.transfer(address(positionManager), 50 ether);
        vm.stopPrank();
        uint256 owedBefore = factory.pendingTreasuryQuote(address(usdt));
        _fill(token, address(usdt));
        assertTrue(token.tradingStarted());
        // The sweep brought them to the hub: the meme was burned, the quote is owed to the treasury.
        assertGe(token.balanceOf(BURN), dropped);
        assertGe(factory.pendingTreasuryQuote(address(usdt)) - owedBefore, 50 ether);
        assertEq(token.balanceOf(address(positionManager)), 0);
        assertEq(usdt.balanceOf(address(positionManager)), 0);
        assertEq(_poolLiquidity(token), _burnedLiquidity(token));
    }

    function testAnyoneAddsAndRemovesLiquidityFeeFree() public {
        PikaToken token = _graduated(true);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        tick = _onSpacing(tick);
        token.pushFees();
        uint256 unpaidQuote = _unpaid(token, address(usdt));
        uint256 unpaidMeme = _unpaid(token, address(token));
        uint128 burned = _burnedLiquidity(token);

        // A two-sided range around the price and a full-range position, both by plain wallets.
        (uint256 narrow, uint128 narrowLiquidity) =
            _lpMintMeme(token, ALICE, tick - 500, tick + 500, 100_000 ether, 10 ether);
        (uint256 wide, uint128 wideLiquidity) =
            _lpMintMeme(token, ALICE, FULL_LOWER, FULL_UPPER, 100_000 ether, 10 ether);
        assertEq(positionManager.ownerOf(narrow), ALICE);
        assertEq(positionManager.ownerOf(wide), ALICE);
        assertEq(_poolLiquidity(token), burned + narrowLiquidity + wideLiquidity);

        // Swaps pay the hook's fees as before; the positions earn nothing (the pool has no LP fee).
        _swap(token, CAROL, false, 50 ether);
        _swap(token, CAROL, true, token.balanceOf(CAROL) / 2);
        unpaidQuote = _unpaid(token, address(usdt));
        unpaidMeme = _unpaid(token, address(token));

        _lpDecrease(positionManager, narrow, ALICE, narrowLiquidity, ALICE);
        _lpDecrease(positionManager, wide, ALICE, wideLiquidity, ALICE);
        assertEq(_unpaid(token, address(usdt)), unpaidQuote, "taking liquidity out books no fee");
        assertEq(_unpaid(token, address(token)), unpaidMeme, "in either asset");
        assertEq(_poolLiquidity(token), burned, "only the burned position is left");
        assertEq(token.balanceOf(address(positionManager)), 0);
        assertEq(usdt.balanceOf(address(positionManager)), 0);
    }

    function testOnlyTheOwnerOfAnNftTakesItOut() public {
        PikaToken token = _graduated(true);
        (, int24 tick,,) = manager.getSlot0(token.poolId());
        (uint256 id, uint128 liquidity) =
            _lpMintMeme(token, ALICE, _onSpacing(tick) + 50, _onSpacing(tick) + 300, 10_000 ether, 0);
        vm.expectRevert();
        this.lpDecreaseAs(id, CAROL, liquidity);
        this.lpDecreaseAs(id, ALICE, liquidity);
    }

    function testTheTreasuryClaimsTheGraduationQuote() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        uint256 owed = factory.pendingTreasuryQuote(address(usdt));
        // 1% of the raise (the other 1% is the creator's), plus rounding.
        assertApproxEqAbs(owed, 120 ether, 1e9);
        uint256 before = usdt.balanceOf(TREASURY);
        vm.expectEmit(true, true, false, true, address(factory));
        emit PikaLaunchFactory.TreasuryQuoteClaimed(address(usdt), TREASURY, owed);
        vm.prank(DAVE);
        assertEq(factory.claimTreasuryQuote(address(usdt)), owed);
        assertEq(usdt.balanceOf(TREASURY) - before, owed);
        assertEq(factory.pendingTreasuryQuote(address(usdt)), 0);
        assertEq(factory.claimTreasuryQuote(address(usdt)), 0, "nothing twice");
        // A later graduation of the same quote books on top and is claimed the same way.
        PikaToken second = _create(address(usdt), true);
        _fill(second, address(usdt));
        assertApproxEqAbs(factory.pendingTreasuryQuote(address(usdt)), 120 ether, 1e9);
        assertEq(usdt.balanceOf(address(factory)), factory.pendingTreasuryQuote(address(usdt)));
    }

    function testTheSinksBooksStayCoveredWhenStrangersLeaveQuoteInThePositionManager() public {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(LIQUIDITY_ID, 10_000, 10_000, "");
        PikaToken token = _createWithFees(address(usdt), true, 500, 500, apps);
        _fill(token, address(usdt));
        _swap(token, CAROL, false, 300 ether);
        _swap(token, CAROL, true, token.balanceOf(CAROL) / 2);
        address t = address(token);
        vm.prank(CAROL);
        usdt.transfer(address(positionManager), 7 ether);
        uint128 burned = _burnedLiquidity(token);
        vm.prank(KEEPER);
        (uint128 added,,) = liquidityApp.addLiquidity(t, 1, 0, type(uint160).max, block.timestamp);
        assertGt(added, 0);
        assertEq(_burnedLiquidity(token), burned + added);
        assertGe(token.balanceOf(address(liquidityApp)), liquidityApp.pending(t, t));
        assertGe(usdt.balanceOf(address(liquidityApp)), liquidityApp.pending(t, address(usdt)));
        assertEq(usdt.balanceOf(address(positionManager)), 0);
    }

    function _graduated(bool memeIs0) private returns (PikaToken token) {
        token = _createWithFees(address(usdt), memeIs0, 100, 300, new AppBinding[](0));
        _fill(token, address(usdt));
    }

    function _unpaid(PikaToken token, address asset) private view returns (uint256) {
        (uint256 platform, uint256 cut, uint256 project) = token.unpaid(asset);
        return platform + cut + project;
    }

    /// @dev The hub's `GraduationPositionBurned` for `token` among the recorded logs.
    function _burnedEvent(address token)
        private
        returns (uint256 positionId, uint128 liquidity, uint256 memeUsed, uint256 quoteUsed, uint256 memeBurned)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(factory) || logs[i].topics[0] != BURNED_TOPIC
                    || address(uint160(uint256(logs[i].topics[1]))) != token
            ) continue;
            positionId = uint256(logs[i].topics[2]);
            (liquidity, memeUsed, quoteUsed, memeBurned) = abi.decode(logs[i].data, (uint128, uint256, uint256, uint256));
            return (positionId, liquidity, memeUsed, quoteUsed, memeBurned);
        }
        revert("no GraduationPositionBurned");
    }
}
