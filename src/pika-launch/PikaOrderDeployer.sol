// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { PikaOrderManager } from "../pika-market/infinity/PikaOrderManager.sol";
import { PikaFactoryBound } from "../pika-market/PikaFactoryBound.sol";
import { IPikaHook, IPikaLaunchToken } from "../pika-market/interfaces/IPikaMarket.sol";

/// @notice Limit-order managers for launch pools: holds one implementation, built for one hook, and hands out a
///         clone of it when a launch graduates.
/// @dev Keeps the hub's bytecode below EIP-170 and makes graduation pay for a small proxy instead of full contract
///      code. The clone carries the launch token, its quote and the quote's decimals (which size its smallest order)
///      as immutable arguments; everything else it needs is in the implementation. The hub pins the deployer, and therefore the implementation and its hook, per launch, and
///      accepts a deployer only together with the hook it was built for. The deployer never custodies funds; the
///      clone is initialized in the same call that creates it.
contract PikaOrderDeployer is PikaFactoryBound {
    /// @notice Interface generation required by the current component release.
    uint32 public constant FEE_PROTOCOL_VERSION = 5;

    address public immutable implementation;
    /// @notice The hook the implementation's clones trade beside.
    address public immutable hook;

    constructor(IPikaHook hook_) {
        hook = address(hook_);
        implementation = address(new PikaOrderManager(hook_));
    }

    function deploy(address token) external returns (PikaOrderManager orders) {
        _requireFactory();
        address quote = IPikaLaunchToken(token).quoteAsset();
        // The hub admits quotes of 6 to 18 decimals only; the clone's minimum order follows from them.
        uint8 quoteDecimals = IERC20Metadata(quote).decimals();
        orders = PikaOrderManager(
            Clones.cloneWithImmutableArgs(implementation, abi.encodePacked(token, quote, quoteDecimals))
        );
        orders.initialize();
    }
}
