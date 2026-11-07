// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Write-once bytes kept as the runtime code of a data contract (the SSTORE2 pattern): writing costs about
///         200 gas a byte against about 700 a byte in storage slots, reading is one `extcodecopy`.
/// @dev The data contract's code is a STOP byte followed by the data, so calling it does nothing. Its creation code
///      is a 14-byte prefix that returns everything after itself: PUSH4 size, DUP1, PUSH1 14, PUSH1 0, CODECOPY,
///      PUSH1 0, RETURN.
library PikaCodeBlob {
    error BlobWriteFailed();

    function write(bytes memory data) internal returns (address pointer) {
        bytes memory code = abi.encodePacked(hex"63", uint32(data.length + 1), hex"80600e6000396000f300", data);
        assembly ("memory-safe") {
            pointer := create(0, add(code, 0x20), mload(code))
        }
        if (pointer == address(0)) revert BlobWriteFailed();
    }

    /// @dev Empty for the zero address (nothing written yet).
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 size = pointer.code.length;
        if (size == 0) return data;
        size -= 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }
}
