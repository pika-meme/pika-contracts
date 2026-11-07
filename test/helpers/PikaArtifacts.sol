// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IVault } from "infinity-core/src/interfaces/IVault.sol";
import { ICLPoolManager } from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
// Small and protocol-free: imported only so `_proxy` finds its artifact in every test directory.
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PikaRelease } from "../../script/PikaRelease.sol";

/// @notice Deploys protocol and Pancake Infinity contracts from their build artifacts with `vm.deployCode`.
/// @dev A test that writes `new X(...)` embeds X's creation code, so solc regenerates X under via-IR for every test
///      file. Deploying the artifact keeps each test compilation down to the test code itself; the deployed bytecode
///      is the one `forge build` produced for `src/`. Only interfaces of the Infinity contracts are imported here, so
///      test files never pull their code into a test compilation (`InfinityArtifacts.sol` builds the artifacts).
///
///      The token implementation, the token and migrate modules and the hub ship with OpenFour's compiler settings
///      (`PikaRelease`): the default profile deploys them from the Hardhat artifacts (`npx hardhat compile` first), so
///      its tests and gas numbers run the code that ships. The lite profile deploys its own build of them.
abstract contract PikaArtifacts is Test {
    function _deploy(string memory name, bytes memory args) internal returns (address) {
        if (PikaRelease.isRelease(name) && !_lite()) return PikaRelease.deploy(name, args);
        return vm.deployCode(string.concat(name, ".sol:", name), args);
    }

    function _deploy(string memory name) internal returns (address) {
        return _deploy(name, "");
    }

    function _lite() private view returns (bool) {
        return keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256("lite");
    }

    function _newVault() internal returns (IVault) {
        return IVault(_deploy("Vault"));
    }

    function _newManager(address vault_) internal returns (ICLPoolManager) {
        return ICLPoolManager(_deploy("CLPoolManager", abi.encode(vault_)));
    }

    /// @dev Contracts whose constructor takes (vault, poolManager): PikaHook.
    function _newWithVenue(string memory name, address vault_, address manager_) internal returns (address) {
        return _deploy(name, abi.encode(vault_, manager_));
    }

    /// @dev Pancake's CL position manager (the LP NFT). No Permit2 and no descriptor: the tests pay it from its own
    ///      balance (`SETTLE` with the position manager as payer) and never render a token URI.
    function _newPositionManager(address vault_, address manager_, address weth_) internal returns (address) {
        return vm.deployCode(
            "CLPositionManager.sol:CLPositionManager",
            abi.encode(vault_, manager_, address(0), uint256(300_000), address(0), weth_)
        );
    }

    function _newToken(address hub_, address vault_, address manager_) internal returns (address) {
        return _deploy("PikaToken", abi.encode(hub_, vault_, manager_));
    }

    function _newRouter(address wbnb, address vault_, address manager_) internal returns (address) {
        return _deploy("PikaRouter", abi.encode(wbnb, vault_, manager_));
    }

    /// @dev Contracts whose constructor takes one address: PikaGuard (owner), app template implementations
    ///      (registry), MockUSDT (owner).
    function _newWithAddress(string memory name, address a) internal returns (address) {
        return _deploy(name, abi.encode(a));
    }

    /// @dev An app template as deployed: an initialized ERC1967 proxy over a new implementation for `registry_`.
    function _newApp(string memory name, address registry_) internal returns (address) {
        return _proxy(_newWithAddress(name, registry_));
    }

    function _proxy(address implementation) internal returns (address) {
        return _deploy("ERC1967Proxy", abi.encode(implementation, abi.encodeWithSignature("initialize()")));
    }

    /// @dev The component deployers live in one source file.
    /// @dev An order deployer builds its implementation for one hook.
    function _newDeployer(string memory name, address hook) internal returns (address) {
        return vm.deployCode(string.concat("PikaOrderDeployer.sol:", name), abi.encode(hook));
    }
}
