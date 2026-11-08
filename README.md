# Pika contracts on OpenFour

[中文](README.zh-CN.md)

Protocol **12**, contracts **v12.9.0**, exported from `johnyjt/pika` commit `1d2bdc6`.
This repository contains the source and focused tests submitted for OpenFour review. It does not contain production
credentials, deployment records, server code, or operational tooling. The descriptions below refer to this source
snapshot; they do not assert that any live deployment has been upgraded.

## Review scope

| Contract | Role | Source |
| --- | --- | --- |
| `PikaToken` | Fixed-supply token implementation, cloned by Core (EIP-1167); tag `token.pika` | `src/pika-launch/PikaToken.sol` |
| `PikaTokenModule` | Initializes the token; tag `module.token.pika` | `src/pika-launch/openfour/PikaTokenModule.sol` |
| `PikaMigrateModule` | Moves a sold-out launch into Infinity; tag `module.migrate.pika_infinity` | `src/pika-launch/openfour/PikaMigrateModule.sol` |
| `PikaLaunchFactory` | Preset validator, trusted launch registry, graduation hub | `src/pika-launch/PikaLaunchFactory.sol` |

OpenFour supplies the registered `module.vault.standard` (`VAULT_BASIC`), `module.curve.bonding`
(`CURVE_BONDING`) and `module.trade.simple` (`TRADE_SIMPLE`) modules. There is no custom-data module.
Core, Registry, Tools, FeeRouter, the production curve and trade module are external dependencies, not audited source
in this repository. Their public interfaces and the reference standard vault are included under `src/openfour/`.

All Pika outer-market code is included so the review can follow the four reviewed contracts' complete call graph:

- `src/pika-market/`: Infinity hook and limit-order manager.
- `src/pika-apps/`: App registry, burn, dividend and liquidity templates.
- `src/common/`: guardian seat, fee math and burned-liquidity minting.
- `src/pika-launch/`: hub, token, modules, router, order-manager deployer and trade lens.
- `script/`: only the deployment scripts/helpers used by the fork tests.
- `lib/`: pinned git submodules; OpenZeppelin is **5.4.0** for Pika, while the vendored OpenFour token uses **4.9.6**.

`OpenFourToken._beforeTokenTransfer` is virtual so Pika can override the standard migrated-pool restriction.
Pika has no venue lock; its migrate module does not populate that pool list. The standard vault copy is used by
local tests; real launches use the registered OpenFour vault.

## Lifecycle and fund flows

1. The creator calls OpenFour `Core.createToken(createArgs, signature)`. The hub validates the preset, supply,
   quote, target, fee rates and parameter shape. Core deploys the token and module instances atomically.
2. During initialization the token registers with the hub, binds its apps, and pins the current outer components.
   The hub admits only EIP-1167 clones of allowed Pika implementations. The full supply is minted to OpenFour's vault.
3. Core runs the inner buys and sells on the bonding curve. The sale allocation is **80%** of supply; OpenFour's
   FeeRouter handles inner-market fees. There is no Pika per-address purchase cap.
4. The standard vault reports sold out with at most **one whole token** remaining for sale. Core calls the migrate
   module, which transfers the vault's tokens and quote to the hub. Graduation checks the trusted Core's actual
   record, allowed preset, calling migrate module, sold-out state, available balances and an unlocked Infinity vault.
5. The hub initializes the launch pool, deploys its order manager, and credits **1% of the actual raise** to the
   creator's claimable quote fees. **20% of supply + 98% of the actual raise** fund a full-range Pancake Infinity
   `CLPositionManager` NFT minted directly to `0x000000000000000000000000000000000000dEaD`.
6. Unsold/rounding meme is sent to the burn address. Remaining quote, including extra vault receipts, is booked
   as `pendingTreasuryQuote`. Anyone may trigger its payment to the treasury. The pool then opens for trading.

The NFT owner cannot be recovered; Pika has no entry to withdraw the graduation liquidity. This relies on the
configured official position manager and Infinity contracts. The pool uses tick spacing **50**, full range
**[-887250, 887250]**, and **zero LP fee**.

## Admission and fees

- Default supply is **1,000,000,000 tokens**, with 18 decimals. An owner-configured supply must be between
  `MIN_SUPPLY = 1_000_000 ether` and `1e36` smallest units. The lower bound limits the one-token sale remainder's
  missing raise to approximately **5 ppm**, apart from quote-unit rounding.
- Supply and the 80/20 allocation are checked at creation. The quote must be enabled, with recorded decimals
  between 6 and 18. The configured target floor in this snapshot is `MIN_TARGET_FLOOR = 1e15` smallest quote units;
  the per-quote minimum can be higher. Creation also checks that the opening pool price/liquidity is representable.
- Quote accounting assumes plain, non-rebasing ERC20 transfers without transfer taxes; quote admission is an owner responsibility.
- Only `tokenParams` carries creator configuration. Vault, curve, trade, migrate and custom-data parameters are empty.
- Each outer direction charges a **0.3% platform fee** plus a fixed project fee; the sum of configured rates is at
  most **10%**. Platform fees are always quote. Buy project fees are meme output; sell project fees are quote output.
- The platform receives **10% of the project fee**. The rest goes to bound app slots and the creator's remainder.
  Trading only books fees. `pushFees` transfers and notifies apps atomically; a failed transfer/notification rolls
  the entire push back. Already-accrued creator claims can survive a failed automatic push.
- The hook charges any router/locker using the launch pool. Other pools and venues remain available to the token.
  Full-range liquidity is open to third parties; other ranges must be created by the launch's order manager, which
  charges order fees on claim. A fully converted order can convert back until `settle` removes its position.

## v12.9.0 changes since v12.7.0

- **v12.8.0, Core as a platform account (T-4):** `PikaToken._initPika` marks the hub's current Core as one of the
  launch's own accounts, so whatever Core holds inside a transaction never counts as a dividend holder, and Core
  cannot be proposed as the creator fee wallet.
- **v12.8.0, quote-denominated order floor (T-5):** `PikaOrderManager`'s flat `MIN_INPUT = 1e6` becomes
  `minQuoteInput()` = 1/100 of a quote unit (`MIN_INPUT_DIVISOR`). A quote-funded order is measured by its
  deposit, a meme-funded one by its worth at the far end of its range. `PikaOrderDeployer` appends the quote's
  decimals as the clone's 41st immutable byte; a clone with the old 40-byte arguments is refused.
- **v12.8.0, router admits before `permit` (T-6):** `swap` and `swapWithPermit` share `_admit`, which checks the
  parameters, the hub's `isLaunch`, the token's `routerContext`, `tradingStarted` and the pinned router before the
  token is called at all. `IPikaHub.isLaunch` documents that it also holds for clones initialized outside Core and
  never admits a swap by itself.
- **v12.9.0, cancelling a filled order (N-4):** `PikaOrderManager._close` reports whether the position came back
  without any of the input asset. `cancelOrder` on an order that has already converted in full settles and claims
  it exactly as `settle` + `claim` would, leaving it `Settled` with no `OrderCancelled`; only an order with input
  still in its range is recorded `Cancelled`. Payouts and fees are unchanged.
- **v12.9.0, `PoolGraduated` documentation (O-2):** the event's `memeAmount` is documented as every token the vault
  handed over (the burned unsold remainder included); the pool's share is `GraduationPositionBurned.memeUsed`. No ABI
  change.

No storage layout, interface or template version changes beyond the order manager's immutable arguments, which only
affect clones deployed after this release. Existing non-upgradeable hubs, tokens and order managers do not change when
this source is published.

## v12.7.0 changes since v12.6.1 and upgrade compatibility

- **Dividend template v14:** existing shares no longer bypass platform-account eligibility checks. Claims refresh
  the holder's eligibility too. Previously accrued earnings are preserved. **Before accepting a new treasury**, the
  operator must pre-exclude that address on every affected launch and verify zero shares, using bounded batches.
  Lazy checks cannot reconstruct a treasury change's historical time on an older hub. New launches should be paused
  while fixing the rotation's launch list; the old treasury can be refreshed after the switch.
- **Burn template v3 / liquidity template v4:** `buybackLimited` and `addLiquidityLimited` and their batch variants
  restrict dispatches to explicit budgets. Unselected funds and fees received after preparation stay pending.
  Liquidity spending is checked against both budgets and launch books remain separate even when they share quote.
- **Real swap preview:** `previewSwap` calls an authenticated self-only `simulateSwap`, executes the router swap,
  and catches its deliberate revert. Transfers, approvals, pool state and fee booking are all rolled back. Even
  an on-chain preview transaction cannot spend the app's funds.
- **Minimum output:** an actual swap requires a nonzero minimum. Balanced liquidity that needs no swap may use zero.
  Existing dispatch entry points are retained; new keepers can select bounded entry points by on-chain template version.
- **Supply admission:** small supplies that can be sold out immediately or graduate far below target are refused
  before launch creation. OpenFour's sold-out rule and migration execution are unchanged.

Compared with main-repository v12.6.1, compiler-generated layouts of all three templates are unchanged. These template updates add **no storage fields**: new structs are memory/calldata budgets. Upgrades follow the existing
registry/UUPS authority checks. Existing non-upgradeable hubs/tokens do not change when this source is published.
A keeper remains trusted to choose honest price protections: the contracts have no independent price oracle. Server-side
price-impact and historical-price checks are outside this repository and do not protect against a malicious keeper key.

Other behavior already present in this snapshot: small dividend bookings join the current release window; excluded
contracts retain accrued dividends and may claim them, with owner reclamation only after **180 days**; partial swap
reservation refunds credit the swap caller's vault delta; treasury and creator fee-recipient changes use two-step acceptance.

## Trust and permissions

- The hub owner controls admission/defaults and future components; it cannot mint tokens or withdraw burned LP.
  Creation and graduation admission are separate so stopping new launches need not strand existing ones.
- Clones initialized outside Core can register but cannot graduate without a trusted Core record.
- Pika module implementations pin `(hub, core)` immutably. OpenFour governance retains beacon/Core/Registry powers.
  Do not upgrade an existing beacon to an implementation wired to another hub/Core: its existing launches follow
  that beacon too. Incompatible wiring or storage needs new module keys and a separately reviewed composition.
- The platform's separate upgrade authority can upgrade shared App proxies, including for existing launches.
  A faulty holder-book upgrade can block transfers; pausing a sink does not bypass holder accounting or stop claims.
- Guardian powers only tighten: stop creation, revoke a keeper, disable a template or pause its trading entries.
- Mainnet deployment scripts currently specify **zero owner and upgrade delay**, with Safe threshold checks.
  This is a governance choice, not an enforced response window. Live permissions must be checked separately.

## Build and validation

Use Node **>=22.13** (validated with Node 24), npm and Foundry. Run via-IR compilations one at a time.

```bash
git clone https://github.com/pika-meme/pika-contracts.git
cd pika-contracts
git submodule update --init
git -C lib/pancake-infinity-periphery submodule update --init lib/permit2
git -C lib/pancake-infinity-core submodule update --init lib/solmate
npm ci
npx hardhat compile --concurrency 1
FOUNDRY_PROFILE=lite forge test
forge test
```

| Source | Release compiler |
| --- | --- |
| Token, token module, migrate module, hub | Hardhat solc **0.8.24**, optimizer **200**, **viaIR**, **paris** |
| Outer market and apps | solc **0.8.26**, optimizer **200**, **viaIR**, **cancun** |

The default Foundry tests deploy the four reviewed contracts from Hardhat artifacts through `PikaRelease`; build
Hardhat first. The lite profile uses its own build of all contracts. The four reviewed contracts never import outer
implementation code or use transient storage.

Real-chain forks (local simulation only; nothing is broadcast):

```bash
RUN_PIKA_FORK=true RPC_URL=<BSC-mainnet-RPC> forge test --match-path 'test/fork/*'
RUN_PIKA_OPENFOUR_FORK=true TESTNET_RPC_URL=<BSC-testnet-RPC> \
  OPENFOUR_REGISTRY=<developer-owned-fork-registry> PRIVATE_KEY=<its-owner-and-Core-signer> \
  PONS_QUOTE=<test-quote> forge test --match-path 'test/openfour-fork/*' --isolate -vv
```

| Tests | Coverage |
| --- | --- |
| `test/openfour/PikaOpenFourLaunch.t.sol` | Creation, validation, registration, inner trades, migration, fake clones, Core/preset changes |
| `test/fork/DeployPikaMainnet.t.sol` | Real mainnet Core and Infinity, full deployment, role handover and both quote assets |
| `test/fork/OpenFourBondingCurve.t.sol`, `OpenFourSimpleTrade.t.sol` | Local curve/trade stand-ins against registered mainnet implementations |
| `test/openfour-fork/PikaOpenFourTestnetFork.t.sol` | Real testnet Core lifecycle, signatures, fees and per-step gas |
| `test/pika-launch/PikaInfinityFlow.t.sol` | End-to-end graduation and outer trades |
| Project fee, cut, pending fee, auto-push and fee-push tests | Fee accounting, destinations, atomic notifications and claims |
| Guardian and timelock tests | Admission, pause, emergency and ownership boundaries |
| `test/pika-market/PikaOpenLiquidity.t.sol` | Burned NFT, third-party liquidity, withdrawal ownership and shared app accounting |
| `test/pika-launch/PikaTreasurySupplySafety.t.sol` | Treasury eligibility, pre-exclusion preserving earnings, minimum-supply boundary and graduation |
| `test/pika-apps/PikaDispatchSafety.t.sol` | Preview rollback, self-call authentication, bounded balances, separate launches, zero minimum rejection and batch isolation |

`test/helpers` contains local OpenFour stand-ins and real Infinity artifact deployment helpers. Local mocks are not
an audit of OpenFour's closed-source internals. Gas depends on the selected apps and holder state; use
`test_GasOnRealCore --isolate` for this release rather than gas figures from earlier releases.

## Validation of this snapshot

On 2026-11-07, a fresh clone with the pinned submodules passed:

- Hardhat dual-compiler build (`--concurrency 1`).
- Lite profile: **101 passed**.
- Default release profile: **108 passed, 3 skipped**; real-chain suites were then enabled separately.
- BSC mainnet fork: **7 passed** (Core, deployment and the curve/trade modules).
- BSC testnet real-Core fork: **7 passed**, with `--isolate`.
- Compiler-generated storage layouts of burn, dividend and liquidity templates match main-repository v12.6.1.

The testnet fork's `test_GasOnRealCore --isolate` measured these transaction gas costs. They are a reproducible test
scenario, not a bound for arbitrary apps, balances, calldata or network state.

| Step | Gas |
| --- | ---: |
| Create with dividend app, no first buy | 3,278,723 |
| Create without apps | 3,054,216 |
| Budget buy, new holder | 1,028,851 |
| Amount buy, new holder | 517,060 |
| Amount buy, existing holder | 482,860 |
| Sell | 454,170 |
| Budget buy that graduates | 1,722,832 |
| Amount buy without apps, new holder | 484,535 |
