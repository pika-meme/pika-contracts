# Pika 的 OpenFour 合约

[English](README.md)

协议版本 **12**，合约版本 **v12.9.0**，来自主仓库 `johnyjt/pika` 提交 `1d2bdc6`。
本仓库只包含 OpenFour 审核所需的源码和测试，不含生产凭证、部署记录、服务端或运维工具。
以下描述针对这份源码，不代表线上合约已经升级。

## 审核范围

| 合约 | 职责 | 源码 |
| --- | --- | --- |
| `PikaToken` | Core 克隆的固定供应量代币（EIP-1167），tag `token.pika` | `src/pika-launch/PikaToken.sol` |
| `PikaTokenModule` | 初始化代币，tag `module.token.pika` | `src/pika-launch/openfour/PikaTokenModule.sol` |
| `PikaMigrateModule` | 售罄后迁移至 Infinity，tag `module.migrate.pika_infinity` | `src/pika-launch/openfour/PikaMigrateModule.sol` |
| `PikaLaunchFactory` | 组合校验、项目登记、毕业中枢 | `src/pika-launch/PikaLaunchFactory.sol` |

其他槽使用 OpenFour 已登记的标准模块：`module.vault.standard`（`VAULT_BASIC`）、
`module.curve.bonding`（`CURVE_BONDING`）、`module.trade.simple`（`TRADE_SIMPLE`），没有 custom-data 模块。
Core、Registry、Tools、FeeRouter、生产曲线和交易模块是外部依赖，并非本仓库可审计源码。
`src/openfour/` 收录其公开接口和标准 Vault 参考实现。

同时收录外盘源码，供审核跟踪四个合约的完整调用路径：

- `src/pika-market/`：Infinity hook、限价单管理器。
- `src/pika-apps/`：App registry、销毁、分红、流动性模板。
- `src/common/`：guardian、费用数学、销毁 LP 的铸造逻辑。
- `src/pika-launch/`：中枢、代币、模块、路由、订单部署器、交易 lens。
- `script/`：分叉测试会用到的部署脚本及 helper。
- `lib/`：固定提交的 git 子模块。Pika 使用 OpenZeppelin **5.4.0**，OpenFour 代币基类使用其配套的 **4.9.6**。

`OpenFourToken._beforeTokenTransfer` 加了 virtual，使 Pika 能覆盖标准的已登记池限制。
Pika 不锁交易场所，迁移模块也不填该池名单。标准 Vault 源码副本用于本地测试，真实项目使用 OpenFour 已登记的实现。

## 生命周期与资金流

1. 创建者调用 OpenFour `Core.createToken(createArgs, signature)`。中枢校验组合、供应量、报价资产、目标、费率和参数形状；Core 在同一交易部署代币和模块。
2. 代币初始化时向中枢登记、绑定应用、固定外盘组件。中枢只接受允许实现的 EIP-1167 克隆。全部供应量铸给 OpenFour Vault。
3. Core 执行曲线内盘买卖，销售份额为总量的 **80%**，内盘费用由 OpenFour FeeRouter 处理。Pika 不设单地址购买上限。
4. 标准 Vault 在剩余待售不超过 **一整枚** 时判定售罄。迁移模块把 Vault 的两种资产转给中枢；中枢核对受信任 Core 的实际记录、组合、迁移调用者、售罄状态、到账余额和 Infinity Vault 未上锁。
5. 中枢初始化池、部署订单管理器，将**实际募集额的 1%**记入创建者待领报价币费用。
   **供应量的 20% + 实际募集额的 98%** 经 Pancake 官方 `CLPositionManager` 铸成全区间 NFT，所有者直接为 `0x000000000000000000000000000000000000dEaD`。
6. 未售余量与舍入剩余代币转给销毁地址；剩余报价币（含 Vault 额外收入）记为 `pendingTreasuryQuote`，任何人可触发付给 treasury。随后开放外盘。

Pika 没有取回毕业 LP 的入口；安全性依赖配置的官方 position manager 和 Infinity 合约。
池的 tick spacing 为 **50**，全区间为 **[-887250, 887250]**，**LP 费率为零**。

## 准入与费用

- 默认供应量为 **十亿枚**、18 位精度。管理员可配置范围为 `MIN_SUPPLY = 1_000_000 ether` 到 `1e36` 最小单位。
  一百万枚下限将最多一枚未售余量造成的募集偏差约束在约 **5 ppm** 以内，另计报价币最小单位舍入。
- 创建时核对供应量和 80/20 分配。报价资产须启用，记录精度为 6～18；这份快照的全局目标下限为
  `MIN_TARGET_FLOOR = 1e15` 报价币最小单位，各资产可另设更高门槛；同时检查开池价格和流动性可表示。
- 报价币记账假定普通 ERC20 转账，不支持转账税或余额重定基；报价币的准入选择由 owner 负责。
- 只有 `tokenParams` 带创建者配置；vault、curve、trade、migrate、custom-data 参数均为空。
- 外盘每方向收 **0.3% 平台费**及固定项目费，配置费率之和最多 **10%**。平台费始终为报价币；买入项目费从代币输出扣，卖出项目费从报价币输出扣。
- 平台抽取项目费的 **10%**，其余分给应用槽位及创建者。交易仅记账，`pushFees` 后续原子转账并通知应用；任一环节失败则整次回滚。自动推送失败不阻止领取此前已经记入创建者账本的费用。
- 任意路由/locker 在发射池交易均经过 hook；代币仍可在其他池交易。第三方可提供全区间流动性，其他区间只准由项目订单管理器创建，订单领取时收费。
  订单即使已完全换币，`settle` 移除仓位之前仍可能随价格反转而换回。

## v12.9.0 相对 v12.7.0 的改动

- **v12.8.0，Core 记为平台账户（T-4）**：`PikaToken._initPika` 把中枢当前的 Core 记为项目自己的账户，Core 在一笔交易内持有的代币不计分红份额，也不能被提名为创建者费钱包。
- **v12.8.0，挂单下限按报价币计（T-5）**：`PikaOrderManager` 固定的 `MIN_INPUT = 1e6` 改为 `minQuoteInput()` = 报价币单位的 1/100（`MIN_INPUT_DIVISOR`）；买单按存入的报价币、卖单按 meme 在区间远端的折算。`PikaOrderDeployer` 把报价币精度作为克隆的第 41 个不可变字节带入，旧的 40 字节参数被拒绝。
- **v12.8.0，路由先准入再调 `permit`（T-6）**：`swap` 与 `swapWithPermit` 共用 `_admit`，先检查参数、中枢 `isLaunch`、代币的 `routerContext`、`tradingStarted` 和钉死的路由，才会调用代币。`IPikaHub.isLaunch` 注明它对 Core 外初始化的克隆也成立，自身不授予任何交易资格。
- **v12.9.0，撤销已成交挂单（N-4）**：`PikaOrderManager._close` 返回仓位是否已不含任何输入资产。对已全部转换的单调 `cancelOrder` 等同于 `settle` + `claim`，保留 `Settled`、不发 `OrderCancelled`；只有区间里还有本金的单才记 `Cancelled`。付款和费用不变。
- **v12.9.0，`PoolGraduated` 注释（O-2）**：事件的 `memeAmount` 注明是 vault 搬来的全部代币（含随后烧掉的未售零头），入池量见 `GraduationPositionBurned.memeUsed`。ABI 不变。

除挂单合约克隆的不可变参数外，没有存储布局、接口或模板版本变化，且只影响本版本之后部署的克隆。发布源码不会改变已部署的不可升级中枢、代币和挂单合约。

## v12.7.0 相对 v12.6.1 的改动与升级兼容

- **分红模板 v14**：已有份额也重新检查平台账户资格，领取同样同步资格，保留已赚收益。
  **新 treasury 接任前**，运营必须在所有相关项目中预先排除新地址、验证份额为零，分批处理。
  按调用同步不能重建旧中枢历史上变更 treasury 的时间。固定轮换清单期间应暂停新建项目，切换后再刷新旧 treasury 的资格。
- **销毁模板 v3 / 流动性模板 v4**：新增 `buybackLimited`、`addLiquidityLimited` 及批量入口，按显式预算派发。
  未选资金和准备后新到的费用仍留在 pending；添加流动性的实际支出不得超过两侧预算，同一报价币的不同项目账本相互独立。
- **真实交换预览**：`previewSwap` 通过仅限自身调用的 `simulateSwap` 执行路由交易，再捕获其主动回滚。
  转账、授权、池状态和费用记账全部撤销；即使把预览作为链上交易发送也不能花掉 App 资金。
- **最低输出**：实际交换必须给非零最低输出；已平衡、无需交换的加流动性允许零。
  原派发接口保留，keeper 按链上模板版本选择限额入口。
- **供应量准入**：在创建前拒绝会立即售罄或明显提前毕业的小供应量，不改变 OpenFour 的售罄条件或迁移执行。

已对照主仓库 v12.6.1 比较三个模板的编译器存储布局，结果一致。这些模板升级**没有新增存储字段**，新增结构体仅用于 memory/calldata 预算。升级继续受原 registry/UUPS 权限约束。
发布源码不会改变已部署的不可升级中枢和代币。Keeper 仍需诚实选择价格保护；合约没有独立价格预言机，服务端的价格冲击/历史价格检查不在本仓库内，也不能据此宣称已防恶意 keeper 密钥。

本快照还包含此前已有行为：小额分红记账加入当前释放窗口；排除的合约保留可领收益，管理员只能在 **180 天**后回收未领部分；
部分成交的费用预留退款记入交换调用者的 Vault delta；treasury 和创建者费用接收人均通过两步接任变更。

## 信任与权限

- 中枢 owner 控制新项目准入、默认值和未来组件，不能增发代币或取走销毁 LP。创建和毕业的准入分开，停止新创建不必阻断旧项目毕业。
- Core 之外初始化的克隆可登记，但没有受信任 Core 记录不能毕业。
- Pika 模块实现将 `(hub, core)` 固定为不可变量；OpenFour 治理保留 beacon、Core、Registry 等权限。已有项目也跟随 beacon，不能把旧 beacon 升级成绑定另一中枢/Core 的实现；不兼容的接线或存储应使用新模块键和单独审核的组合。
- 平台的独立升级权限可升级共享 App，影响存量项目。错误的 holder-book 升级可能阻断转账；暂停 sink 不绕过持仓记账，也不暂停分红领取。
- Guardian 只能收紧：停创建、撤销 keeper、禁用模板或暂停其交易入口。
- 主网部署脚本当前的 owner 和升级延时均为 **零**，并检查 Safe 门槛。这是治理选择，不提供强制响应窗口；线上实际权限需要单独核对。

## 构建与验证

使用 Node **≥22.13**（验证环境为 Node 24）、npm 和 Foundry。via-IR 编译一次只跑一路。

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

| 源码 | 发布编译器 |
| --- | --- |
| 代币、代币模块、迁移模块、中枢 | Hardhat solc **0.8.24**、optimizer **200**、**viaIR**、**paris** |
| 外盘与 App | solc **0.8.26**、optimizer **200**、**viaIR**、**cancun** |

默认 Foundry 测试通过 `PikaRelease` 从 Hardhat 产物部署四个审核合约，所以必须先构建 Hardhat。
lite 配置使用自己的全部合约产物。四个审核合约不 import 外盘实现，也不使用 transient storage。

真实链分叉（仅本地模拟，不广播）：

```bash
RUN_PIKA_FORK=true RPC_URL=<BSC-mainnet-RPC> forge test --match-path 'test/fork/*'
RUN_PIKA_OPENFOUR_FORK=true TESTNET_RPC_URL=<BSC-testnet-RPC> \
  OPENFOUR_REGISTRY=<developer-owned-fork-registry> PRIVATE_KEY=<its-owner-and-Core-signer> \
  PONS_QUOTE=<test-quote> forge test --match-path 'test/openfour-fork/*' --isolate -vv
```

| 测试 | 覆盖 |
| --- | --- |
| `test/openfour/PikaOpenFourLaunch.t.sol` | 创建、校验、登记、内盘、迁移、假克隆、Core/组合切换 |
| `test/fork/DeployPikaMainnet.t.sol` | 真实主网 Core 与 Infinity、整套部署、权限交接、两种报价币 |
| `test/fork/OpenFourBondingCurve.t.sol`、`OpenFourSimpleTrade.t.sol` | 本地替身与已登记主网实现的对照 |
| `test/openfour-fork/PikaOpenFourTestnetFork.t.sol` | 真实测试网 Core 生命周期、签名、费用、分步 gas |
| `test/pika-launch/PikaInfinityFlow.t.sol` | 毕业与外盘完整路径 |
| Project fee、cut、pending fee、auto-push、fee-push 测试 | 费用记账、去向、原子通知和领取 |
| Guardian、timelock 测试 | 准入、暂停、紧急与管理权限 |
| `test/pika-market/PikaOpenLiquidity.t.sol` | 销毁 NFT、第三方流动性、提现权限、共享 App 账本 |
| `test/pika-launch/PikaTreasurySupplySafety.t.sol` | Treasury 资格、预排除保留收益、最低供应量边界与毕业 |
| `test/pika-apps/PikaDispatchSafety.t.sol` | 预览回滚、自调用鉴权、预算、项目隔离、零最低输出拒绝、批量失败隔离 |

`test/helpers` 包含本地 OpenFour 替身和真实 Infinity 产物部署 helper。本地 mock 不能替代对 OpenFour 闭源内部实现的审计。
Gas 随应用和持仓状态变化，请用本版本 `test_GasOnRealCore --isolate` 重测，不沿用旧版本数字。

## 本快照验证结果

2026-11-07，在全新克隆及固定依赖上完成：

- Hardhat 双编译器构建（`--concurrency 1`）通过。
- lite 配置：**101 项通过**。
- 默认发布配置：**108 项通过、3 项跳过**；随后单独启用真实链分叉测试。
- BSC 主网分叉：**7 项通过**，覆盖 Core、部署和曲线/交易模块。
- BSC 测试网真实 Core 分叉：**7 项通过**，使用 `--isolate`。
- 销毁、分红、流动性模板的编译器存储布局与主仓库 v12.6.1 一致。

测试网分叉的 `test_GasOnRealCore --isolate` 得到以下交易 gas。这是可复现的测试场景，不是任意应用、余额、calldata 或链状态的 gas 上限。

| 步骤 | Gas |
| --- | ---: |
| 带分红应用创建，不首买 | 3,278,723 |
| 无应用创建 | 3,054,216 |
| 按预算买，新持有人 | 1,028,851 |
| 按数量买，新持有人 | 517,060 |
| 按数量买，已有持有人 | 482,860 |
| 卖出 | 454,170 |
| 按预算买并毕业 | 1,722,832 |
| 无应用按数量买，新持有人 | 484,535 |
