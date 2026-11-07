require("@nomicfoundation/hardhat-toolbox");
// Reads the sources path (`src`) and the remappings from foundry.toml / remappings.txt, so both tools build the same tree.
require("@nomicfoundation/hardhat-foundry");

// OpenFour's compile environment, as in its `developer/startup/hardhat.config.js` (do not change): solc 0.8.24,
// optimizer 200, viaIR. No evmVersion, so Hardhat compiles for paris (no PUSH0, no transient storage), which is what
// OpenFour's own deployed Core and vault were built for.
const OPENFOUR = {
  version: "0.8.24",
  settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true },
};

// The outer market keeps the settings it was built and tested with: solc 0.8.26 for cancun (it uses transient
// storage), optimizer 200, viaIR. These are the Foundry default profile's settings.
const OUTER = {
  version: "0.8.26",
  settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: "cancun" },
};

// What OpenFour reviews and registers, built with OpenFour's settings: the token implementation, the token and
// migrate modules, and the hub (the preset's validator). They reach the outer market only through interfaces. Every
// other source builds with OUTER.
const OPENFOUR_SOURCES = [
  "src/pika-launch/PikaToken.sol",
  "src/pika-launch/openfour/PikaTokenModule.sol",
  "src/pika-launch/openfour/PikaMigrateModule.sol",
  "src/pika-launch/PikaLaunchFactory.sol",
];

module.exports = {
  solidity: {
    compilers: [OUTER],
    overrides: Object.fromEntries(OPENFOUR_SOURCES.map((source) => [source, OPENFOUR])),
  },
  paths: {
    cache: "cache-hardhat",
    artifacts: "artifacts",
    tests: "test-hardhat",
  },
};

module.exports.OPENFOUR_SOURCES = OPENFOUR_SOURCES;
