// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FeeSlot, AppBinding } from "../../pika-apps/interfaces/IPikaApps.sol";

struct PikaPermit {
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

interface IPikaRouterContext {
    function trader() external view returns (address);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice What a Pika launch fixes in OpenFour's `tokenParams` (decoded by the token while it initializes).
struct PikaTokenParams {
    /// @dev The wallet that claims the creator's share of the project fee.
    address creatorFeeRecipient;
    /// @dev Outer-pool project fee per direction, on top of the platform fee.
    uint16 buyFeeBps;
    uint16 sellFeeBps;
    /// @dev The app templates the project fee is shared with.
    AppBinding[] apps;
}

/// @notice The launch hub (`PikaLaunchFactory`) as the token, the modules and the components see it.
interface IPikaHub {
    /// @notice What a token tells the hub while it initializes.
    struct Registration {
        address creator;
        address quoteAsset;
        uint256 supply;
        PikaTokenParams params;
    }

    /// @notice What the hub hands a newly registered token: the components pinned for it and its fee slots.
    struct Setup {
        address treasury;
        address locker;
        address hook;
        address router;
        address lpManager;
        address holderBook;
        FeeSlot[] slots;
    }

    function core() external view returns (address);
    function treasury() external view returns (address);
    /// @notice Whether `token` registered as a launch of this hub (in either phase).
    function isLaunch(address token) external view returns (bool);
    function registerLaunch(Registration calldata r) external returns (Setup memory s);
    function graduate(address token, uint256 quoteAmount, uint256 extraQuote) external returns (bytes32 poolId);
}
