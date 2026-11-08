# Pika contracts on OpenFour

[中文](README.zh-CN.md)

Protocol **12**, contracts **v12.12.1**, exported from `johnyjt/pika` commit `f03837d`.
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
6. Treasury debt already owed in either asset is reserved throughout graduation, including when the launch token
   is itself another launch's quote. Only unreserved unsold/rounding meme is sent to the burn address. Remaining
   unreserved quote, including extra vault receipts, is booked
   as `pendingTreasuryQuote`. Anyone may trigger its payment to the treasury. The pool then opens for trading.

The NFT owner cannot be recovered; Pika has no entry to withdraw the graduation liquidity. This relies on the
configured official position manager and Infinity contracts. The pool uses tick spacing **50**, full range
**[-887250, 887250]**, and **zero LP fee**.

## Admission and fees

- Default supply is **1,000,000,000 tokens**, with 18 decimals. An owner-configured supply must be between
  `MIN_SUPPLY = 1_000_000 ether` and `1e36` smallest units. The lower bound limits the one-token sale remainder's
  missing raise to approximately **5 ppm**, apart from quote-unit rounding.
- Supply and the 80/20 allocation are checked at creation. The quote must be enabled, with recorded decimals
  between 6 and 18. The configured target floor is `targetFloor(decimals) = 10 ** decimals / 1000`
  (0.001 quote units; `1e15` for 18 decimals and `1e3` for 6 decimals); the per-quote minimum can be higher.
  Creation checks representable liquidity and an opening sqrt price at least 20,000 times away from either
  protocol edge, matching the graduation mint's 99.99% minimum utilization check.
- Quote accounting assumes plain, non-rebasing ERC20 transfers without transfer taxes; quote admission is an owner responsibility.
- Only `tokenParams` carries creator configuration. Vault, curve, trade, migrate and custom-data parameters are empty.
- Each outer direction charges a **0.3% platform fee** plus a fixed project fee; the sum of configured rates is at
  most **10%**. Platform fees are always quote. Buy project fees are meme output; sell project fees are quote output.
- The platform receives **10% of the project fee**. The rest goes to bound app slots and the creator's remainder.
  Trading only books fees. `pushFees` transfers and notifies apps atomically; a failed transfer/notification rolls
  the entire push back. Already-accrued creator claims can survive a failed automatic push. `pushPlatformFees`
  (v12.12.0) pays only the platform fee and the platform's cut to the treasury, calls no app and does not move
  `lastPushAt`, so a reverting app template cannot hold the platform's part back.
- The hook charges any router/locker using the launch pool. Other pools and venues remain available to the token.
  Full-range liquidity is open to third parties; other ranges must be created by the launch's order manager, which
  charges order fees on claim. A fully converted order can convert back until `settle` removes its position.

## v12.12.1 changes since v12.12.0

- Graduation treats both assets as `balance - pendingTreasuryQuote[asset]`. A Pika token used as another launch's
  quote keeps that launch's treasury funds when it later graduates; its opening position and dust burn cannot
  consume them. A balance below the reserved debt is rejected with `InvalidConfiguration`.
- Regressions cover multiple launches sharing the token as quote, both currency orderings, unsolicited donations,
  treasury claims before/after graduation, and insufficient unreserved pool funding. Mainnet and testnet real-Core
  fork suites both cover the cross-launch quote lifecycle.

No public interface, storage layout or app template version changes. This implementation correction applies to new
hub deployments; publishing the source does not change existing hubs or restore assets previously burned.

## v12.12.0 changes since v12.11.0

Fixes from the independent audit of 2026-11-08c (`docs/audit-2026-11-08c-fresh-audit.md` in the main repository):

- **Migration prices the pool on the vault's actual quote (D-1).** `PikaMigrateModule.executeMigration` no longer
  reverts when the vault's quote balance is below `totalRaised`; it hands the hub `min(totalRaised, balance)` as the
  priced amount and the rest as the treasury's extra. The vault's books and balance agree in normal operation (the
  anti-sniper surcharge is kept outside the raise); the change only removes a way for a sold-out launch to stay on a
  closed curve for good. The hub still checks the funds it is told about and the price margin.
- **Platform-only fee push (F-1).** `PikaToken.pushPlatformFees()` pays the platform fee and the project-fee cut of
  both books to the treasury without notifying any app; the project part stays booked for `pushFees`, which is
  unchanged. Emits `FeesPushed(asset, platform, cut, 0)`.
- **Unreachable mint fallback removed (O-1).** The v12.10.0 "derive again from one unit less" branch in
  `PikaBurnedLiquidity.mint` could never run: the liquidity `LiquidityAmounts` derives from an amount never costs
  more than that amount under the pool's rounded-up charge (algebra in the library's comments; two 50,000-run
  fuzzes in `test/audit-2026-11-08c/FreshAudit.t.sol`). `mint` now uses the derived liquidity directly.

Storage layouts are unchanged (the token gains functions only; the module and the library change code only). Of the
four reviewed contracts, `PikaToken` and `PikaMigrateModule` changed; `PikaTokenModule` and `PikaLaunchFactory` only
in a comment. Regressions: `test/audit-2026-11-08c/FreshAuditFixes.t.sol`.

## v12.11.0 changes since v12.10.0

- Quote admission scales the minimum target with the quote's decimals. The constant getter `MIN_TARGET_FLOOR()`
  is replaced by `TARGET_FLOOR_DIVISOR()` and `targetFloor(uint8)`; ABI consumers must use the new interface.
- The opening-price margin increases from 4 to 20,000 at both protocol edges, aligning admission with the
  full-range graduation position's minimum asset utilization. Existing supply/liquidity bounds remain enforced.
- Admission regressions cover 6/18-decimal targets and the current `MIN_SUPPLY`/maximum-supply corners. The export
  also includes the independent liquidity-rounding, keeper-slippage and gas probes from 2026-11-08c.

No storage layout or app template version changes. The hub is not upgradeable: these admission rules require a new
hub deployment to take effect and do not change existing launches by publishing this source.

## v12.10.0 changes since v12.9.0

- **Dividend template v15, stranded-fee fallback (audit 2026-11-08b, M-1):** release only runs while someone holds
  shares, so a launch whose minimum holding no account ever reaches kept every fee pushed to the dividend slot in
  `unreleased` for good. v15 adds `sharesZeroSince(token)` (set at registration, cleared by the first holder, set
  again when the last holder's shares go to zero; written only when the total crosses zero) and
  `redirectStranded(token)`: once a launch has had no shares for `STRANDED_DELAY` (30 days), anyone may pay the
  unreleased fees in both assets to the launch's creator fee wallet (which takes a project fee's remainder when no
  slot does), emitting `StrandedFeesRedirected`. Holders' accrued `owed` amounts are untouched. For a launch
  registered before v15 the first call only starts the clock. `IPikaAppToken` gains `creatorFeeRecipient()`, which
  the token already exposed.
- **Rounding fallback in the burned-position mint (L-3):** `PikaBurnedLiquidity.mint` derives the liquidity from the
  hub's holdings as before, then checks what the pool will charge with the pool's own arithmetic
  (`SqrtPriceMath.getAmount0Delta` / `getAmount1Delta`, rounded up); only when that exceeds the maxima handed to the
  position manager does it derive once more from `max − 1` (a charge is at most one unit above the amount it was
  derived from, so the second derivation always fits). Launches that round cleanly keep exactly the liquidity of
  before. Both the hub's graduation and the liquidity template's dispatches go through it.

Storage layout: the dividend template appends one mapping, `sharesZeroSince`; the other templates are unchanged, and
interfaces only gain members. The hub's bytecode changes through the library, so a full redeployment is needed for it
to take effect; deployed non-upgradeable contracts do not change when this source is published.

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
| `test/fork/DeployPikaMainnet.t.sol` | Real mainnet Core and Infinity, full deployment, role handover, both quote assets and treasury reserves in a Pika quote |
| `test/fork/OpenFourBondingCurve.t.sol`, `OpenFourSimpleTrade.t.sol` | Local curve/trade stand-ins against registered mainnet implementations |
| `test/openfour-fork/PikaOpenFourTestnetFork.t.sol` | Real testnet Core lifecycle, signatures, fees, Pika-quote treasury reserves and per-step gas |
| `test/pika-launch/PikaInfinityFlow.t.sol` | End-to-end graduation and outer trades |
| Project fee, cut, pending fee, auto-push and fee-push tests | Fee accounting, destinations, atomic notifications and claims |
| Guardian and timelock tests | Admission, pause, emergency and ownership boundaries |
| `test/pika-market/PikaOpenLiquidity.t.sol` | Burned NFT, third-party liquidity, withdrawal ownership and shared app accounting |
| `test/pika-launch/PikaTreasurySupplySafety.t.sol` | Treasury eligibility, minimum supply, cross-launch quote reserves, donations, funding shortages and claim ordering |
| `test/pika-apps/PikaDispatchSafety.t.sol` | Preview rollback, self-call authentication, bounded balances, separate launches, zero minimum rejection and batch isolation |
| `test/audit-2026-11-07b/IndependentReview.t.sol` | Quote-decimal and supply/target boundaries, migration authorization, partial-fill refunds and dividend exclusions |
| `test/audit-2026-11-08c/FreshAudit.t.sol`, `GasProbe.t.sol` | Two 50,000-run liquidity-rounding fuzz tests, keeper slippage, order price protection and hot-path gas |
| `test/audit-2026-11-08c/FreshAuditFixes.t.sol` | Graduation on a vault quote shortfall, platform-only fee push while an app reverts, composition of both pushes |

`test/helpers` contains local OpenFour stand-ins and real Infinity artifact deployment helpers. Local mocks are not
an audit of OpenFour's closed-source internals. Gas depends on the selected apps and holder state; use
`test_GasOnRealCore --isolate` for this release rather than gas figures from earlier releases.

## Validation of this snapshot

On 2026-11-08 (v12.12.1), a fresh clone with pinned submodules and all 97 exported files verified against
main-repository `f03837d` passed:

- Hardhat dual-compiler build (`--concurrency 1`): **124 files**.
- Lite profile: **121 passed**.
- Default release profile: **129 passed, 3 skipped**; the real-chain suites were then enabled separately.
- BSC mainnet fork: **8 passed**. The new treasury-reserve lifecycle passed against the real Core at block
  **132332298**.
- BSC testnet real-Core fork: **8 passed** with `--isolate`, including the same cross-launch quote lifecycle and
  successful treasury payment. These runs only changed local fork state; nothing was broadcast.
- The cross-launch reserve fuzz regression passed **256 runs** in each profile, covering both currency orderings,
  one to three quote-funded launches and extra donations. A separate regression refuses to fund a position with
  reserved treasury assets; another covers treasury payment before the quote token graduates.
- The release factory artifact uses **solc 0.8.24 / paris / viaIR / optimizer 200** and matches the committed source.
  Its ABI is identical to v12.12.0 and its deployed bytecode is **21,697 bytes**. No storage declarations changed.

On 2026-11-08 (v12.12.0), a fresh clone populated from the `638c7b0` export with pinned submodules passed:

- Hardhat dual-compiler build (`--concurrency 1`): 124 files.
- Lite profile: **118 passed** (the three regressions of this release included).
- Default release profile: **125 passed, 3 skipped**.
- BSC mainnet fork: **7 passed** (Core, deployment and the curve/trade modules).
- The BSC testnet real-Core fork was not run for this release: the verifying environment had no testnet registry,
  signer or test-quote variables set. The creation path it covers is unchanged since v12.11.0 (below); this release
  changes migration and fee pushing, which the local suites cover.
- Storage layouts are unchanged. `PikaToken` gains `pushPlatformFees` (and a private helper); `PikaMigrateModule`
  and `PikaBurnedLiquidity` change code only; `PikaLaunchFactory` changes a comment.

On 2026-11-08 (v12.11.0), a fresh clone populated from the `ad23ca8` export with pinned submodules passed:

- Hardhat dual-compiler build (`--concurrency 1`).
- Lite profile: **115 passed**.
- Default release profile: **122 passed, 3 skipped**; real-chain suites were then enabled separately.
- BSC mainnet fork: **7 passed** (Core, deployment and the curve/trade modules).
- BSC testnet real-Core fork: **7 passed** with `--isolate`, using the developer-owned registry and test quote.
  The working endpoint was `https://bsc-testnet-dataseed.bnbchain.org`; the PublicNode endpoint returned HTTP 403.
- No app source or storage declarations changed from v12.10.0. The hub changes constants, validation and getter
  functions only; its storage declarations are unchanged.

The table below is the v12.12.1 (2026-11-08) testnet fork's `test_GasOnRealCore --isolate` measurement.
It is a reproducible test scenario, not a bound for arbitrary apps, balances, calldata or network state.

| Step | Gas |
| --- | ---: |
| Create with dividend app, no first buy | 3,324,926 |
| Create without apps | 3,078,189 |
| Budget buy, new holder | 1,029,333 |
| Amount buy, new holder | 517,255 |
| Amount buy, existing holder | 483,055 |
| Sell | 454,343 |
| Budget buy that graduates | 1,729,203 |
| Amount buy without apps, new holder | 484,557 |
