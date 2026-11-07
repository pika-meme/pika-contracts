// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Builds the Pancake Infinity Vault and CLPoolManager artifacts that tests deploy with `vm.deployCode`. No test
// imports this file, so their code is compiled once here, with the production settings, and never inside a test.
import { Vault } from "infinity-core/src/Vault.sol";
import { CLPoolManager } from "infinity-core/src/pool-cl/CLPoolManager.sol";
