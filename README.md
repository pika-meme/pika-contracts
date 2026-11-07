# Pika contracts on OpenFour

[中文](README.zh-CN.md)

Pika is a token launch platform built on [OpenFour](https://four.meme). A launch is created by OpenFour's Core from the
Pika preset and trades on OpenFour's bonding curve (the inner market). When the sale sells out, it graduates into a
Pancake Infinity concentrated-liquidity pool guarded by Pika's hook (the outer market).

This repository holds the contracts and tests submitted for OpenFour's review. Protocol version 12.

## What is under review

| Contract | Role in the preset | Tag | Source |
| --- | --- | --- | --- |
| `PikaToken` | Token implementation (Core clones it, EIP-1167) | `token.pika` | `src/pika-launch/PikaToken.sol` |
| `PikaTokenModule` | Token module | `module.token.pika` | `src/pika-launch/openfour/PikaTokenModule.sol` |
| `PikaMigrateModule` | Migrate module | `module.migrate.pika_infinity` | `src/pika-launch/openfour/PikaMigrateModule.sol` |
| `PikaLaunchFactory` (the hub) | Preset validator, launch registry, graduation | — | `src/pika-launch/PikaLaunchFactory.sol` |

The other slots use OpenFour's registered modules:

| Slot | Module | Tag | Registry key |
| --- | --- | --- | --- |
| Vault | `StandardVault` | `module.vault.standard` | `VAULT_BASIC` |
| Curve | `BondingCurveModule` | `module.curve.bonding` | `CURVE_BONDING` |
| Trade | `SimpleTradeModule` | `module.trade.simple` | `TRADE_SIMPLE` |
| Custom data | None | — | `customDataId = 0` |

The rest of `src/` is the outer market: the migration target and the contracts the token calls. It is included so the
review can follow every call the four contracts make, and so the tests build. None of it is registered with OpenFour.

## Layout

| Path | Contents |
| --- | --- |
| `src/pika-launch/` | Hub, token, the two OpenFour modules (`openfour/`), router, trade lens, order-manager deployer |
| `src/pika-market/` | Outer market: `PikaHook`, `PikaLocker`, `PikaOrderManager`, `PikaLpManager` |
| `src/pika-apps/` | App registry and the three default fee apps (burn, holder dividends, liquidity) |
| `src/common/` | Guardian seat (`PikaGuard`) and fee math |
| `src/openfour/` | OpenFour's public interfaces, `OpenFourTypes`, `OpenFourToken`, `StandardVault` and the OpenZeppelin 4.9.6 files `OpenFourToken` uses, copied unchanged from `four-meme-community/openfour-docs` (MIT). The `StandardVault` copy is only used by the local tests. |
| `src/mocks/` | Mock USDT for testnet deployments |
| `test/` | Tests (see below) |
| `script/` | Testnet and mainnet deployment scripts (the fork tests run them) |
| `lib/` | Git submodules: forge-std 1.12.0, OpenZeppelin 5.4.0 (with upgradeable), Pancake `infinity-core` and `infinity-periphery` |

## Lifecycle

1. **Create.** The creator calls `Core.createToken(createArgs, signature)`.
   - Core asks the validator first. The hub's `validate` checks the whole composition (see below).
   - Core deploys the module proxies and clones `PikaToken`. The token address is
     `CREATE2(CreateDeployer, tokenSalt, clone code)`.
   - The token module initializes the token. While it initializes, the token calls `hub.registerLaunch`. The hub
     accepts only clones of an allowed Pika token implementation, binds the launch's apps through the app registry,
     and pins the current outer components to the token.
   - The whole supply is minted to OpenFour's vault.
2. **Inner market.** All trades go through Core (`buy`, `buyByBudget`, `sell`) on OpenFour's bonding curve: 80% of
   the supply sells for exactly the raise target. OpenFour's FeeRouter takes the inner fees. There is no per-address
   purchase limit.
3. **Graduation.** It happens inside the buy that leaves at most one token for sale (the standard vault's sold-out
   rule).
   - Core calls `PikaMigrateModule`, which moves the vault's quote and tokens to the hub and calls `hub.graduate`.
   - The hub checks Core's record of the token: the token exists, it was created under an allowed preset and Core, the
     caller is that launch's migrate module, and the sale sold out.
   - The hub registers the pool with `PikaHook` and initializes it at the curve's final price.
   - It deploys the launch's order manager.
   - It locks a full-range position forever in `PikaLocker`: the 20% of the supply the curve kept, plus 98% of the
     raise.
   - It credits 1% of the raise to the creator's fee wallet, claimable from the token.
   - The rest of the quote is owed to the treasury.
   - Outer trading opens.
   - The module returns `abi.encode(bytes32 poolId)` (migrated data version 1).
4. **Outer market.** The launch pool is a Pancake Infinity CL pool with `PikaHook` and a 0% LP fee.
   - The hook charges the fees inside the swap: a 0.3% platform fee plus the launch's own buy and sell fees, at most 30%
     per direction in total. The platform takes 10% of each project fee.
   - Any router or locker may trade; the hook has no whitelist.
   - Only the locker, the order managers and `PikaLpManager` can add or remove liquidity. Donations are refused.
   - Trades only book fees in the token. `pushFees` later pays the treasury, the creator's wallet and the apps.

## The hub as validator

`validate` (`IOpenFourPresetValidator`) accepts a creation only if all of these hold:

- `maxSupply` equals the hub's `defaultSupply` (1,000,000,000 tokens with 18 decimals).
- `raiseAmount` is at least the quote's minimum target and at least `MIN_TARGET_FLOOR` (`1e15`).
- `saleAmount` equals `sizing(supply, target).saleAmount`, which is 80% of the supply (`SALE_BPS`).
- The quote asset is an enabled ERC20 (BNB launches use WBNB; Core sends and receives native BNB).
- The token parameters (`PikaTokenParams`: creator fee wallet, buy and sell fees, apps) are within bounds, and the app
  registry accepts the app choices.
- Every module parameter except `tokenParams` is empty: vault, curve, trade, migrate and custom data.

Creation and graduation are allowed separately:

- Turning a preset off (`setPreset(id, false)`) or replacing Core (`setCore`) stops new launches only.
- Launches already on their curve still graduate under the preset and Core they were created with.
- The owner withdraws that separately with `setGraduationPreset` or `setGraduationCore`.

## Trust and permissions

- **Modules.** Their implementations take `(hub, core)` as immutables. An instance initializes only while
  `hub.core()` is still that Core.
- **Anyone can clone the token code outside Core.** Such a token can register with the hub, but it can never graduate:
  graduation needs Core's record.
- **Owner** (behind a timelock; ownership cannot be renounced). The hub's defaults, quotes, Core, allowed token
  implementations and presets, and the outer components for later launches.
- **Guardian** (`PikaGuard`). It can only tighten, and immediately: stop new launches, revoke a keeper, or disable or
  pause an app template.
- **OpenFour governance.** It keeps its usual powers over Core, the Registry (including module upgrades behind the
  beacons) and the FeeRouter.
- **Launched tokens** have no admin entry. A token's outer components stay the ones pinned at registration.

## Compiler settings

| Contracts | Compiler | Built by |
| --- | --- | --- |
| `PikaToken`, `PikaTokenModule`, `PikaMigrateModule`, `PikaLaunchFactory` | OpenFour's environment: solc 0.8.24, optimizer 200, viaIR, EVM paris (Hardhat's default for 0.8.24, as in `developer/startup`) | Hardhat 2.29.1 (`hardhat.config.js`) |
| Everything else (outer market) | solc 0.8.26, optimizer 200, viaIR, EVM cancun | Hardhat, with the same settings as Foundry |

- **Why the outer market keeps 0.8.26.** It uses transient storage (EIP-1153): reentrancy guards, the router's trader
  context, and the hook's per-swap fee cache. Paris does not have it.
- **The four reviewed contracts use no transient storage and no PUSH0.**
- **They reach the outer market only through interfaces.** They never import its source, so each group compiles with
  its own settings.
- **The hub's only reentrancy guard is OpenZeppelin's storage `ReentrancyGuard`,** on `graduate`.
- **Release bytecode comes from Hardhat.** Foundry compiles the whole tree with 0.8.26 for types and tests. The
  deployment scripts and the default-profile tests create the four reviewed contracts from the Hardhat artifacts
  (`script/PikaRelease.sol`), so they run the release bytecode.

## Where this differs from a standard OpenFour preset

- **Two custom modules** (token, migrate) and a custom token implementation. Vault, curve and trade are OpenFour's.
- **The modules depend on the hub.** The token registers with the hub while it initializes. The hub is the validator.
  The migrate module hands all funds to the hub, so the hub's state affects creation and graduation.
- **The migration target is a hooked Pancake Infinity pool,** not a plain V2/V4 pool.
- **The token extends `OpenFourToken`.**
  - On every transfer it reports both balances to the launch's dividend holder book, if it has one. If the book
    reverts, the transfer reverts.
  - It books outer-market fees.
  - It implements permit, and reports its domain with `eip712Domain()` (ERC-5267).
- **The outer market uses a different compiler** (see above).

## Build and test

```bash
git clone https://github.com/pika-meme/pika-contracts.git && cd pika-contracts
git submodule update --init          # not --recursive: the dependencies' own submodules are not needed
npm ci                               # Node 20 or 22
npx hardhat compile                  # release artifacts
FOUNDRY_PROFILE=lite forge test      # fast local suite (Foundry's own build of every contract)
forge test                           # via-IR; deploys the four reviewed contracts from the Hardhat artifacts
```

The default profile needs `npx hardhat compile` first. A full via-IR build takes about 20 minutes, and one solc
process can use about 9 GB of memory.

Fork tests are skipped unless enabled; see `.env.example`.

```bash
RUN_PIKA_FORK=true RPC_URL=<BSC mainnet RPC> forge test --match-path "test/fork/*"
RUN_PIKA_OPENFOUR_FORK=true OPENFOUR_REGISTRY=<fork Registry> PRIVATE_KEY=<its owner> PONS_QUOTE=<mock USDT> \
  forge test --match-path "test/openfour-fork/*" --isolate -vv
```

## Tests

| File | Covers |
| --- | --- |
| `test/openfour/PikaOpenFourLaunch.t.sol` (31) | The lifecycle on a local stand-in for Core: creation and registration, the curve, inner sells, graduation and the opening price, validator rules, module parameters and versions, fake clones, presets and Cores allowed for creation and for graduation |
| `test/openfour-fork/PikaOpenFourTestnetFork.t.sol` (7) | OpenFour's real Core on a BSC testnet fork: deploys with `DeployPikaTestnet`, then creates, trades and graduates; also bad signatures and parameters, fee routing with the standard vault, no purchase limit, token address from salt, and gas per step |
| `test/fork/DeployPikaMainnet.t.sol` (4) | The mainnet deployment script on a BSC mainnet fork with OpenFour's real mainnet Core and Pancake Infinity: full stack, launches on both quotes, timelock handover |
| `test/fork/OpenFourBondingCurve.t.sol`, `OpenFourSimpleTrade.t.sol` (3) | The local stand-ins for OpenFour's closed-source curve and trade modules match the live mainnet modules |
| `test/pika-launch/PikaInfinityFlow.t.sol` (9) | Graduation into the Infinity pool and outer trading end to end |
| `test/pika-launch/PikaProjectFees.t.sol`, `PikaFeeCut.t.sol`, `PikaAutoPush.t.sol`, `PikaPendingFees.t.sol`, `PikaFeePushReview.t.sol` (23) | The token's fee booking and pushes: project fees, the platform's cut, app slots, the creator's wallet |
| `test/pika-launch/PikaGuardian.t.sol`, `PikaTimelock.t.sol` (13) | Guardian and timelock control of the hub |
| `test/pika-launch/PikaAudit.t.sol`, `PikaAuditV10.t.sol` (6) | Regressions: a contract creator cannot block graduation (both quotes, both token orders); fee books match token balances on every fee path; a new holder earns dividends only for the time it holds |

`test/helpers/` holds the local stand-ins:
- `MockOpenFourCore`: Core, Registry, Tools and FeeRouter.
- `OpenFourBondingCurve` and `OpenFourSimpleTrade`: the official curve and trade modules.
- `InfinityArtifacts`: builds the real Pancake Infinity `Vault` and `CLPoolManager` that the tests deploy.

Gas on OpenFour's real Core (BSC testnet fork, `test_GasOnRealCore --isolate`):

| Step | Gas |
| --- | --- |
| Create, with the dividend app | 3.32M |
| Create, no apps | 3.08M |
| Buy by amount, new holder | 522k |
| Buy by amount, existing holder | 481k |
| Sell | 452k |
| Buy that sells out and graduates | 1.56M |
