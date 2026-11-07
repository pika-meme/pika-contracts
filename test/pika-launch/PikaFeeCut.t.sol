// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice Project fee cut (项目费抽成): the platform takes 10% of every project fee, in the fee's asset; the push pays
///         it to the treasury together with the platform fee, in one transfer, while the slots and the creator's wallet
///         split the other 90% as before.
contract PikaFeeCutTest is PikaInfinityFixture {
    function _appHalf() internal pure returns (AppBinding[] memory apps) {
        apps = new AppBinding[](1);
        apps[0] = AppBinding(APP_A_ID, 5000, 5000, abi.encode(uint256(1000)));
    }

    function _bps(uint256 value, uint256 bps) internal pure returns (uint256) {
        return value / 10_000 * bps + value % 10_000 * bps / 10_000;
    }

    /// @dev The treasury, slot and wallet amounts of one fee, checked against what each receiver gained.
    struct Seen {
        uint256 treasury;
        uint256 app;
        uint256 wallet;
    }

    function _seen(PikaToken token, address asset) internal view returns (Seen memory s) {
        s = Seen(IERC20(asset).balanceOf(TREASURY), IERC20(asset).balanceOf(address(appA)), token.creatorFees(asset));
    }

    function _assertSplit(PikaToken token, address asset, Seen memory before, uint256 fee, bool buy) internal view {
        (uint256 platform, uint256 cut, uint256 project) = _feeParts(token, fee, buy);
        Seen memory a = _seen(token, asset);
        assertEq(a.treasury - before.treasury, platform + cut, "treasury takes the platform fee and the cut");
        assertEq(a.app - before.app, _bps(project, 5000), "slot takes its share of the 90%");
        assertEq(a.wallet - before.wallet, project - _bps(project, 5000), "wallet takes the rest of the 90%");
    }

    /// @dev The three parts of the first `TradeFees` the token emitted since the logs were recorded.
    function _tradeFeesCut(Vm.Log[] memory logs, PikaToken token)
        internal
        returns (uint256 platform, uint256 cut, uint256 project)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token) || logs[i].topics[0] != PikaToken.TradeFees.selector) continue;
            (,, platform, cut, project) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
            return (platform, cut, project);
        }
        fail();
    }

    /// @dev The three parts of the `FeesPushed` the token emitted for `asset` since the logs were recorded.
    function _feesPushed(Vm.Log[] memory logs, PikaToken token, address asset)
        internal
        returns (uint256 platform, uint256 cut, uint256 project)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(token) || logs[i].topics[0] != PikaToken.FeesPushed.selector
                    || address(uint160(uint256(logs[i].topics[1]))) != asset
            ) continue;
            return abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
        fail();
    }

    /// @dev The example from the product request: project fee 1% on buys and 2% on sells. The platform takes 10% of
    ///      each, i.e. 0.10% of a buy's output and 0.20% of a sell's, and the rest splits as before.
    function testCutIsTenPercentOfEachDirectionsProjectFee() public {
        PikaToken token = _createWithFees(address(usdt), true, 100, 200, _appHalf());
        _fill(token, address(usdt));
        assertEq(token.PROJECT_FEE_CUT_BPS(), 1000);
        _assertBuyCut(token);
        _assertSellCut(token);
        // Nothing of the cut stays behind: the token holds only the creator's share.
        assertEq(token.balanceOf(address(token)), token.creatorFees(address(token)));
        assertEq(usdt.balanceOf(address(token)), token.creatorFees(address(usdt)));
    }

    /// @dev Buy: the project fee and its cut are meme, the platform fee is quote.
    function _assertBuyCut(PikaToken token) internal {
        Seen memory before = _seen(token, address(token));
        uint256 vaultBefore = _vaultBalance(token);
        vm.recordLogs();
        (, uint256 out) = _swap(token, CAROL, false, 300 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 gross = vaultBefore - _vaultBalance(token);
        uint256 fee = _tradeFee(token, gross, true);
        assertEq(out, gross - fee, "the trader pays the same total fee");
        _assertSplit(token, address(token), before, fee, true);
        (uint256 platform, uint256 cut, uint256 project) = _tradeFeesCut(logs, token);
        assertEq(cut + project, fee);
        assertApproxEqAbs(cut, gross * 10 / 10_000, 2, "0.10% of the buy");
        assertEq(platform, _platformFee(300 ether), "0.30% platform fee, in quote, out of the input");
        _assertPushMatchesTrade(logs, token, address(token), 0, cut, project);
        _assertPushMatchesTrade(logs, token, address(usdt), platform, 0, 0);
    }

    /// @dev Sell: every fee part is quote.
    function _assertSellCut(PikaToken token) internal {
        Seen memory before = _seen(token, address(usdt));
        uint256 quoteBefore = usdt.balanceOf(address(vault));
        vm.recordLogs();
        (, uint256 received) = _swap(token, ALICE, true, 1_000_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 quoteGross = quoteBefore - usdt.balanceOf(address(vault));
        uint256 fee = _tradeFee(token, quoteGross, false);
        assertEq(received, quoteGross - fee);
        _assertSplit(token, address(usdt), before, fee, false);
        (uint256 platform, uint256 cut, uint256 project) = _tradeFeesCut(logs, token);
        assertEq(platform + cut + project, fee);
        assertApproxEqAbs(cut, quoteGross * 20 / 10_000, 2, "0.20% of the sell");
        _assertPushMatchesTrade(logs, token, address(usdt), platform, cut, project);
    }

    /// @dev The push pays exactly what the trade booked.
    function _assertPushMatchesTrade(
        Vm.Log[] memory logs,
        PikaToken token,
        address asset,
        uint256 platform,
        uint256 cut,
        uint256 project
    ) internal {
        (uint256 pPlatform, uint256 pCut, uint256 pProject) = _feesPushed(logs, token, asset);
        assertEq(pPlatform, platform);
        assertEq(pCut, cut);
        assertEq(pProject, project);
    }

    function testNoProjectFeeMeansNoCut() public {
        PikaToken token = _createWithFees(address(usdt), true, 0, 0, new AppBinding[](0));
        _fill(token, address(usdt));
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        uint256 vaultBefore = _vaultBalance(token);
        vm.recordLogs();
        _swap(token, CAROL, false, 300 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_tradeFee(token, vaultBefore - _vaultBalance(token), true), 0, "nothing comes out of the meme");
        (uint256 platform, uint256 cut, uint256 project) = _tradeFeesCut(logs, token);
        assertEq(platform, _platformFee(300 ether));
        assertEq(cut + project, 0);
        assertEq(token.balanceOf(TREASURY), treasuryBefore);
        (uint256 pPlatform, uint256 pCut, uint256 pProject) = _feesPushed(logs, token, address(usdt));
        assertEq(pPlatform, platform);
        assertEq(pCut + pProject, 0);
    }

    /// @dev Every launch pays its own cut, in both assets, to the one treasury; the cut and the platform fee arrive
    ///      together and the booked amounts are cleared by the push.
    function testEveryLaunchPaysItsCutToTheTreasury() public {
        PikaToken a = _createWithFees(address(usdt), true, 100, 200, _appHalf());
        _fill(a, address(usdt));
        PikaToken b = _createWithFees(address(usdt), true, 300, 100, new AppBinding[](0));
        _fill(b, address(usdt));
        uint256 quoteTreasury = usdt.balanceOf(TREASURY);
        uint256 quoteExpected;
        for (uint256 i; i < 2; ++i) {
            PikaToken t = i == 0 ? a : b;
            uint256 memeTreasury = t.balanceOf(TREASURY);
            vm.recordLogs();
            _swap(t, CAROL, false, 300 ether);
            Vm.Log[] memory buyLogs = vm.getRecordedLogs();
            (uint256 platform, uint256 cut,) = _feesPushed(buyLogs, t, address(t));
            assertGt(cut, 0);
            assertEq(platform, 0, "the meme push carries no platform fee");
            assertEq(t.balanceOf(TREASURY) - memeTreasury, cut, "meme: the cut");
            (platform,,) = _feesPushed(buyLogs, t, address(usdt));
            assertEq(platform, _platformFee(300 ether), "the buy's platform fee is quote");
            quoteExpected += platform;
            vm.recordLogs();
            _swap(t, ALICE, true, 1_000_000 ether);
            (platform, cut,) = _feesPushed(vm.getRecordedLogs(), t, address(usdt));
            assertGt(cut, 0);
            quoteExpected += platform + cut;
            (uint256 uPlatform, uint256 uCut, uint256 uProject) = t.unpaid(address(t));
            assertEq(uint256(uPlatform) + uCut + uProject, 0, "meme book cleared");
            (uPlatform, uCut, uProject) = t.unpaid(address(usdt));
            assertEq(uint256(uPlatform) + uCut + uProject, 0, "quote book cleared");
        }
        assertEq(usdt.balanceOf(TREASURY) - quoteTreasury, quoteExpected, "quote: both launches' fees and cuts");
    }
}
