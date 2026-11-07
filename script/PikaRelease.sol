// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";

/// @notice The four contracts OpenFour reviews and registers (token implementation, token and migrate modules, hub)
///         ship as Hardhat builds them with OpenFour's compiler settings: solc 0.8.24, optimizer 200, viaIR, paris
///         (`hardhat.config.js`). Foundry builds the whole tree with solc 0.8.26 for types and tests, so the deployment
///         scripts and the default-profile tests create these four from the Hardhat artifacts. Run
///         `npx hardhat compile` first: a stale or missing artifact deploys stale code or fails.
library PikaRelease {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The Hardhat artifact of `name`, or "" for a contract that ships as Foundry builds it.
    function artifact(string memory name) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("PikaToken")) return "artifacts/src/pika-launch/PikaToken.sol/PikaToken.json";
        if (h == keccak256("PikaLaunchFactory")) {
            return "artifacts/src/pika-launch/PikaLaunchFactory.sol/PikaLaunchFactory.json";
        }
        if (h == keccak256("PikaTokenModule")) {
            return "artifacts/src/pika-launch/openfour/PikaTokenModule.sol/PikaTokenModule.json";
        }
        if (h == keccak256("PikaMigrateModule")) {
            return "artifacts/src/pika-launch/openfour/PikaMigrateModule.sol/PikaMigrateModule.json";
        }
        return "";
    }

    function isRelease(string memory name) internal pure returns (bool) {
        return bytes(artifact(name)).length != 0;
    }

    function creationCode(string memory name) internal view returns (bytes memory) {
        string memory path = artifact(name);
        require(bytes(path).length != 0, string.concat("PikaRelease: not a release contract: ", name));
        return VM.parseJsonBytes(VM.readFile(path), ".bytecode");
    }

    /// @dev Creates `name` from its Hardhat artifact with ABI-encoded constructor `args`. A plain CREATE from the
    ///      calling contract, so a script's broadcast sends it like `new`.
    function deploy(string memory name, bytes memory args) internal returns (address addr) {
        bytes memory code = bytes.concat(creationCode(name), args);
        assembly ("memory-safe") {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), string.concat("PikaRelease: creating ", name, " failed"));
    }
}
