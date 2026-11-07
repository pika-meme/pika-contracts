// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaInfinityFixture } from "./helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { PikaAppBase } from "../../src/pika-apps/PikaAppBase.sol";
import { PikaAppRegistry } from "../../src/pika-apps/PikaAppRegistry.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @dev A test app reinvests half its first quote distribution during a manual push's notification.
contract FeeReinvestmentReviewApp is PikaAppBase {
    bool public reinvested;

    constructor(address registry_) PikaAppBase(registry_) { }

    function templateKey() external pure returns (bytes32) {
        return "feeReinvestmentReview";
    }

    function version() external pure returns (uint16) {
        return 1;
    }

    function _register(address, bytes calldata) internal override { }

    function _book(address token, address asset, uint256 amount) internal override {
        if (asset == token || reinvested) return;
        reinvested = true;
        address router = PikaToken(token).tradingRouter();
        require(IERC20(asset).approve(router, amount / 2));
        PikaRouter(payable(router))
            .swap(PikaRouter.SwapParams(token, false, amount / 2, 1, address(this), block.timestamp, false));
    }
}

contract PikaFeePushReviewTest is PikaInfinityFixture {
    function _launch(uint32 appId, bytes memory params) private returns (PikaToken token) {
        AppBinding[] memory apps = new AppBinding[](1);
        apps[0] = AppBinding(appId, 5000, 5000, params);
        token = _createWithFees(address(usdt), true, 150, 450, apps);
        _fill(token, address(usdt));
        vm.prank(CAROL);
        usdt.approve(address(router), type(uint256).max);
        vm.prank(ALICE);
        token.approve(address(router), type(uint256).max);
    }

    function _pending(PikaToken token, address asset) private view returns (uint256) {
        (uint256 platform, uint256 cut, uint256 project) = token.unpaid(asset);
        return platform + cut + project;
    }

    function _assertSolvent(PikaToken token) private view {
        address t = address(token);
        assertEq(token.balanceOf(t), _pending(token, t) + token.creatorFees(t), "meme liabilities match funds");
        assertEq(
            usdt.balanceOf(t),
            _pending(token, address(usdt)) + token.creatorFees(address(usdt)),
            "quote liabilities match funds"
        );
    }

    function _distributed(PikaToken token, address asset) private view returns (uint256) {
        return IERC20(asset).balanceOf(TREASURY) + IERC20(asset).balanceOf(address(appA)) + token.creatorFees(asset);
    }

    function _pushChecked(PikaToken token) private {
        address t = address(token);
        uint256 memeDue = _pending(token, t);
        uint256 quoteDue = _pending(token, address(usdt));
        uint256 memeBefore = _distributed(token, t);
        uint256 quoteBefore = _distributed(token, address(usdt));
        token.pushFees();
        assertEq(_distributed(token, t) - memeBefore, memeDue, "exactly the pending meme was distributed");
        assertEq(
            _distributed(token, address(usdt)) - quoteBefore, quoteDue, "exactly the pending quote was distributed"
        );
        assertEq(_pending(token, t), 0);
        assertEq(_pending(token, address(usdt)), 0);
        token.pushFees();
        assertEq(_distributed(token, t) - memeBefore, memeDue, "no duplicate meme payout");
        assertEq(_distributed(token, address(usdt)) - quoteBefore, quoteDue, "no duplicate quote payout");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzzRepeatedBatchesKeepBothAssetsFullyAccounted(uint64 seed) public {
        PikaToken token = _launch(APP_A_ID, abi.encode(uint256(1000)));
        for (uint256 i; i < 8; ++i) {
            uint256 choice = (uint256(seed) >> (i * 8)) & 255;
            vm.prank(CAROL);
            router.swap(_swapParams(token, false, (choice + 1) * 1 ether, CAROL));
            _assertSolvent(token);
            vm.prank(ALICE);
            router.swap(_swapParams(token, true, (choice + 1) * 1000 ether, ALICE));
            _assertSolvent(token);
            if (choice % 2 == 0 || i == 7) {
                _pushChecked(token);
                _assertSolvent(token);
                if (choice % 3 == 0 || i == 7) {
                    uint256 memeOwed = token.creatorFees(address(token));
                    uint256 quoteOwed = token.creatorFees(address(usdt));
                    uint256 memeBefore = token.balanceOf(DAVE);
                    uint256 quoteBefore = usdt.balanceOf(DAVE);
                    vm.prank(CREATOR);
                    token.claimCreatorFees(DAVE);
                    assertEq(token.balanceOf(DAVE) - memeBefore, memeOwed);
                    assertEq(usdt.balanceOf(DAVE) - quoteBefore, quoteOwed);
                    _assertSolvent(token);
                }
            }
        }
    }

    function testFeesFromNotificationTradeSurviveTheCurrentPush() public {
        FeeReinvestmentReviewApp app = FeeReinvestmentReviewApp(
            _proxy(vm.deployCode("PikaFeePushReview.t.sol:FeeReinvestmentReviewApp", abi.encode(address(registry))))
        );
        uint32 id =
            registry.addTemplate(address(app), PikaAppRegistry.Kind.Contract, "feeReinvestmentReview", 1, false);
        PikaToken token = _launch(id, "");
        vm.prank(CAROL);
        router.swap(_swapParams(token, false, 300 ether, CAROL));
        vm.prank(ALICE);
        router.swap(_swapParams(token, true, 1_000_000 ether, ALICE));
        token.pushFees();
        assertTrue(app.reinvested());
        // The quote notification's buy creates quote platform fees and meme project fees after their snapshots.
        assertGt(_pending(token, address(token)), 0, "new meme fees remain pending");
        assertGt(_pending(token, address(usdt)), 0, "new quote fees remain pending");
        _assertSolvent(token);
        token.pushFees();
        assertEq(_pending(token, address(token)), 0);
        assertEq(_pending(token, address(usdt)), 0);
        _assertSolvent(token);
    }
}
