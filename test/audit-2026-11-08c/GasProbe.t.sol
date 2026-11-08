// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PikaInfinityFixture } from "../pika-launch/helpers/PikaInfinityFixture.sol";
import { PikaToken } from "../../src/pika-launch/PikaToken.sol";
import { PikaRouter } from "../../src/pika-launch/PikaRouter.sol";
import { AppBinding } from "../../src/pika-apps/interfaces/IPikaApps.sol";

/// @notice Gas of the hot paths, for the audit's optimization notes (audit 2026-11-08c). Logs only.
contract GasProbe20261108cTest is PikaInfinityFixture {
    function _probe(PikaToken token, string memory label) private {
        address quote = token.quoteAsset();
        // Warm everything once.
        _swap(token, ALICE, false, 100 ether);
        _swap(token, ALICE, true, 1_000_000 ether);
        vm.startPrank(ALICE);
        IERC20(quote).approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        uint256 g = gasleft();
        router.swap(PikaRouter.SwapParams(address(token), false, 100 ether, 1, ALICE, block.timestamp, false));
        uint256 buyGas = g - gasleft();
        g = gasleft();
        router.swap(PikaRouter.SwapParams(address(token), true, 1_000_000 ether, 1, ALICE, block.timestamp, false));
        uint256 sellGas = g - gasleft();
        g = gasleft();
        token.transfer(BOB, 1_000 ether);
        uint256 transferGas = g - gasleft();
        g = gasleft();
        token.transfer(BOB, 1_000 ether);
        uint256 transferWarmGas = g - gasleft();
        vm.stopPrank();
        g = gasleft();
        token.pushFees();
        uint256 pushGas = g - gasleft();
        emit log_string(label);
        emit log_named_uint("  router buy (exact input)", buyGas);
        emit log_named_uint("  router sell (exact input)", sellGas);
        emit log_named_uint("  transfer to a new holder", transferGas);
        emit log_named_uint("  transfer to an existing holder", transferWarmGas);
        emit log_named_uint("  pushFees (both assets)", pushGas);
    }

    function test_Gas_PlatformFeeOnlyLaunch() public {
        PikaToken token = _create(address(usdt), true);
        _fill(token, address(usdt));
        _probe(token, "launch without project fee or apps");
    }

    function test_Gas_LaunchWithDividendBurnAndLiquidity() public {
        AppBinding[] memory apps = new AppBinding[](3);
        apps[0] = AppBinding(DIVIDEND_ID, 5000, 5000, abi.encode(uint256(0)));
        apps[1] = AppBinding(BURN_APP_ID, 2500, 2500, "");
        apps[2] = AppBinding(LIQUIDITY_ID, 2500, 2500, "");
        PikaToken token = _createWithFees(address(usdt), true, 300, 300, apps);
        _fill(token, address(usdt));
        _probe(token, "launch with 3% fees, dividend + burn + liquidity sinks");
    }
}
