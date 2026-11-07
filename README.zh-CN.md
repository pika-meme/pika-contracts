# Pika 合约（OpenFour）

[English](README.md)

Pika 是基于 [OpenFour](https://four.meme) 的发射平台。发射由 OpenFour Core 按 Pika 组合创建，在 OpenFour 的
bonding 曲线上交易（内盘）；售罄后毕业进带 Pika Hook 的 Pancake Infinity 集中流动性池（外盘）。

本仓库是提交 OpenFour 审核的合约和测试。协议版本 12；合约版本见 `package.json`，每个版本打 tag（`v12.2.0`）。

## v12.2.0 的改动（相对 v12.0.0）

- **毕业的流动性按标准方式销毁。** 开盘仓位经 Pancake 官方 `CLPositionManager` 铸成全区间 LP NFT，所有者 `0x…dEaD`，相当于 V2 把 LP 代币转给死地址。这个合约没有 owner、不能升级，减仓和销毁只认 NFT 所有者或其授权，所以流动性永远撤不出池子。删除 `PikaLocker`。
- **流动性开放。** 任何人都能经 Pancake 仓位合约或任何 vault 持锁方在发射池加减仓，不收费。删除 `PikaLpManager`。Hook 只要求碰到可用 tick 两端的仓位必须正好是全区间。
- **余数。** 铸完后中枢把剩下的 meme（曲线未售零头、取整）转给 `0x…dEaD`，剩下的报价币记给金库，由金库从中枢领取（`claimTreasuryQuote`）。中枢新事件：`GraduationPositionBurned`、`TreasuryQuoteAccrued`、`TreasuryQuoteClaimed`。中枢组件改为 `(router, orderDeployer, hook, positionManager)`。
- **代币。** 去掉 `locker()`、`lpManager()`；仓位合约算平台账户（不参与分红）。
- **tick 间距 50。** 发射池的 tick 间距从 1 改为 50：仓位和限价单的边界按约 0.5% 一档，全区间是 ±887250（`TickMath.minUsableTick` / `maxUsableTick`）。价格仍连续变化。
- **审核合约中改动的：** 中枢和代币。`PikaTokenModule`、`PikaMigrateModule` 没改。

## 审核范围

| 合约 | 在组合中的角色 | 标签 | 源码 |
| --- | --- | --- | --- |
| `PikaToken` | 代币实现（Core 按 EIP-1167 克隆） | `token.pika` | `src/pika-launch/PikaToken.sol` |
| `PikaTokenModule` | token 模块 | `module.token.pika` | `src/pika-launch/openfour/PikaTokenModule.sol` |
| `PikaMigrateModule` | migrate 模块 | `module.migrate.pika_infinity` | `src/pika-launch/openfour/PikaMigrateModule.sol` |
| `PikaLaunchFactory`（中枢） | 组合校验器、发射登记、毕业 | — | `src/pika-launch/PikaLaunchFactory.sol` |

其余槽位用 OpenFour 已登记的模块：

| 槽位 | 模块 | 标签 | Registry 键 |
| --- | --- | --- | --- |
| vault | `StandardVault` | `module.vault.standard` | `VAULT_BASIC` |
| curve | `BondingCurveModule` | `module.curve.bonding` | `CURVE_BONDING` |
| trade | `SimpleTradeModule` | `module.trade.simple` | `TRADE_SIMPLE` |
| customData | 无 | — | `customDataId = 0` |

`src/` 里的其余合约是外盘：迁移的去向，以及代币会调用的合约。收录它们是为了让审核能看清这四个合约的每一个外部调用，也为了测试能编译。它们都不在 OpenFour 登记。

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/pika-launch/` | 中枢、代币、两个 OpenFour 模块（`openfour/`）、路由、报价合约、限价单部署器 |
| `src/pika-market/` | 外盘：`PikaHook` 和 `PikaOrderManager`（限价单） |
| `src/pika-apps/` | 应用登记表和三个默认手续费应用（销毁、持有者分红、加流动性） |
| `src/common/` | Guardian 席位（`PikaGuard`）、手续费计算，以及 `PikaBurnedLiquidity`：铸全区间 Pancake LP NFT 给销毁地址（中枢毕业、加流动性应用共用） |
| `src/openfour/` | OpenFour 公开的接口、`OpenFourTypes`、`OpenFourToken`、`StandardVault`，以及 `OpenFourToken` 用到的 OpenZeppelin 4.9.6 文件，原样拷自 `four-meme-community/openfour-docs`（MIT）。`StandardVault` 拷贝只给本地测试用 |
| `src/mocks/` | 测试网部署用的模拟 USDT |
| `test/` | 测试（见下） |
| `script/` | 测试网、主网部署脚本（分叉测试会运行它们） |
| `lib/` | git 子模块：forge-std 1.12.0、OpenZeppelin 5.4.0（含 upgradeable）、Pancake `infinity-core` 与 `infinity-periphery`，外加测试部署真实 `CLPositionManager` 需要的两个依赖自带子模块：`infinity-periphery/lib/permit2`、`infinity-core/lib/solmate` |

## 生命周期

1. **创建。** 创建者调 `Core.createToken(createArgs, signature)`。
   - Core 先问校验器：中枢的 `validate` 检查整个组合（见下）。
   - Core 部署模块代理，克隆 `PikaToken`。代币地址是 `CREATE2(CreateDeployer, tokenSalt, 克隆代码)`。
   - token 模块初始化代币。代币初始化时调 `hub.registerLaunch`：中枢只接受已允许的 Pika 代币实现的克隆，经应用登记表绑定该发射的应用，并把当前的外盘组件固定到代币里。
   - 全部供应铸给 OpenFour 的托管合约。
2. **内盘。** 买卖都经 Core（`buy`、`buyByBudget`、`sell`），走 OpenFour 的 bonding 曲线：80% 的供应正好卖满募集目标。内盘手续费由 OpenFour FeeRouter 收。没有单地址限购。
3. **毕业。** 发生在使待售剩余 ≤ 1 枚的那笔买入里（官方 vault 的售罄规则）。
   - Core 调 `PikaMigrateModule`，它把托管合约的报价币和代币转给中枢，并调 `hub.graduate`。
   - 中枢核对 Core 对该代币的记录：代币存在、按允许的组合和 Core 创建、调用者是该发射的 migrate 模块、已售罄。
   - 中枢在 `PikaHook` 登记池子，按曲线终价初始化。
   - 部署该发射的限价单合约。
   - 把 1% 募集额记给创建者收费钱包，从代币里领取。
   - 用曲线留下的 20% 供应加 98% 募集额，经 Pancake `CLPositionManager` 铸全区间（±887250）仓位，LP NFT 的所有者是 `0x…dEaD`，谁都撤不走。
   - 剩下的 meme 转给 `0x…dEaD`，其余报价币记给金库。
   - 开放外盘。
   - 模块返回 `abi.encode(bytes32 poolId)`（迁移数据版本 1）。
4. **外盘。** 发射池是带 `PikaHook` 的 Pancake Infinity CL 池，LP 费为 0，tick 间距 50。
   - Hook 在 swap 内收费：0.3% 平台费，加上每个发射自己的买入费、卖出费，每个方向合计不超过 30%；平台抽项目费的 10%。
   - 任何路由或持锁方都能交易，Hook 没有白名单。
   - 任何人都能加减仓，不收费。碰到可用 tick 两端的仓位必须正好是全区间：否则几 wei 的窄区间就能占满端点 tick 的流动性上限，挡住之后的全区间仓位。撤仓不回调 Hook。拒绝捐赠。
   - 交易只在代币里记账，之后由 `pushFees` 付给金库、创建者钱包和应用。

## 中枢作为校验器

`validate`（`IOpenFourPresetValidator`）只在以下条件全部满足时放行创建：

- `maxSupply` 等于中枢的 `defaultSupply`（10 亿枚，18 位精度）。
- `raiseAmount` 不低于该报价币的最低目标，也不低于 `MIN_TARGET_FLOOR`（`1e15`）。
- `saleAmount` 等于 `sizing(supply, target).saleAmount`，即供应的 80%（`SALE_BPS`）。
- 报价币是已启用的 ERC20（BNB 发射用 WBNB，Core 收发原生 BNB）。
- 代币参数（`PikaTokenParams`：创建者收费钱包、买卖费率、应用）在范围内，且应用登记表接受所选应用。
- 除 `tokenParams` 外的模块参数全部为空：vault、curve、trade、migrate、customData。

创建和毕业分开允许：

- 停用组合（`setPreset(id, false)`）或更换 Core（`setCore`）只停新发射。
- 已在内盘的项目仍按创建时的组合和 Core 毕业。
- owner 要撤销毕业，需单独调 `setGraduationPreset` 或 `setGraduationCore`。

## 信任与权限

- **模块。** 实现以 `(hub, core)` 为不可变量；实例只在 `hub.core()` 仍是这个 Core 时才能初始化。
- **任何人都能在 Core 之外克隆代币代码。** 这样的代币能在中枢登记，但永远不能毕业，因为毕业需要 Core 的记录。
- **owner**（在 timelock 后面，不能放弃所有权）：中枢的默认值、报价币、Core、允许的代币实现和组合，以及之后发射使用的外盘组件。
- **Guardian**（`PikaGuard`）：只能收紧，立即生效。可以停止新发射、撤销 keeper、停用或暂停应用模板。
- **OpenFour 治理**：保留对 Core、Registry（含 beacon 后的模块升级）和 FeeRouter 的通常权限。
- **已发射的代币**没有管理入口；外盘组件保持登记时固定的版本。

## 编译环境

| 合约 | 编译器 | 构建 |
| --- | --- | --- |
| `PikaToken`、`PikaTokenModule`、`PikaMigrateModule`、`PikaLaunchFactory` | OpenFour 的环境：solc 0.8.24、optimizer 200、viaIR、EVM paris（Hardhat 对 0.8.24 的默认值，与 `developer/startup` 相同） | Hardhat 2.29.1（`hardhat.config.js`） |
| 其余（外盘） | solc 0.8.26、optimizer 200、viaIR、EVM cancun | Hardhat，设置与 Foundry 相同 |

- **外盘为什么保留 0.8.26：** 它用 transient 存储（EIP-1153），包括防重入锁、路由的交易者记录、Hook 每笔 swap 的费率缓存，paris 没有这个功能。
- **审核的四个合约不用 transient 存储，也没有 PUSH0。**
- **它们只经接口调用外盘，不 import 外盘源码，** 所以两组可以各用各的设置编译。
- **中枢唯一的防重入锁是 OpenZeppelin 的存储版 `ReentrancyGuard`，** 用在 `graduate` 和 `claimTreasuryQuote` 上。
- **中枢一起编译几个库：** `src/common/libraries/PikaBurnedLiquidity.sol` 和 Pancake 的数学库（`TickMath`、`LiquidityAmounts`、`CLPoolParametersHelper`）；它经接口调用仓位合约。
- **发布字节码来自 Hardhat。** Foundry 用 0.8.26 编译整棵树，只用于类型和测试；部署脚本和默认配置的测试从 Hardhat 产物创建这四个合约（`script/PikaRelease.sol`），所以跑的是发布字节码。

## 与标准 OpenFour 组合的不同

- **两个自写模块**（token、migrate）和自写的代币实现。vault、curve、trade 用 OpenFour 的。
- **模块依赖中枢。** 代币初始化时向中枢登记；中枢是校验器；migrate 模块把全部资金交给中枢。所以中枢的状态影响创建和毕业。
- **迁移去向是带 Hook 的 Pancake Infinity 池，** 不是普通的 V2/V4 池。开盘流动性按标准方式销毁：Pancake 官方仓位合约的 LP NFT，所有者 `0x…dEaD`。
- **代币继承 `OpenFourToken` 并有扩展：**
  - 每次转账把双方余额报给该发射的分红簿（如果有）；分红簿回滚则转账回滚。
  - 记外盘手续费。
  - 实现 permit，并用 `eip712Domain()`（ERC-5267）报出签名域。
- **外盘用了不同的编译器**（见上）。

## 构建与测试

```bash
git clone https://github.com/pika-meme/pika-contracts.git && cd pika-contracts
git submodule update --init          # 不要 --recursive：依赖自己的子模块只需要下面两个
git -C lib/pancake-infinity-periphery submodule update --init lib/permit2
git -C lib/pancake-infinity-core submodule update --init lib/solmate
npm ci                               # Node 20 或 22
npx hardhat compile                  # 发布产物
FOUNDRY_PROFILE=lite forge test      # 本地快速用例（所有合约都用 Foundry 自己编的）
forge test                           # via-IR；审核的四个合约从 Hardhat 产物部署
```

默认配置要先 `npx hardhat compile`。完整的 via-IR 编译约 20 分钟，单个 solc 进程最多约用 9 GB 内存。

分叉测试默认跳过，变量见 `.env.example`：

```bash
RUN_PIKA_FORK=true RPC_URL=<BSC 主网 RPC> forge test --match-path "test/fork/*"
RUN_PIKA_OPENFOUR_FORK=true OPENFOUR_REGISTRY=<fork 的 Registry> PRIVATE_KEY=<其 owner> PONS_QUOTE=<模拟 USDT> \
  forge test --match-path "test/openfour-fork/*" --isolate -vv
```

## 测试

| 文件 | 内容 |
| --- | --- |
| `test/openfour/PikaOpenFourLaunch.t.sol`（31） | 在本地 Core 替身上跑完整生命周期：创建与登记、曲线、内盘卖出、毕业与开盘价、校验规则、模块参数与版本、伪造克隆、组合和 Core 的“可创建”与“可毕业” |
| `test/openfour-fork/PikaOpenFourTestnetFork.t.sol`（7） | BSC 测试网分叉上的 OpenFour 真实 Core：用 `DeployPikaTestnet` 部署后创建、交易、毕业；另有错误签名与参数、官方 vault 下的手续费去向、没有限购、由盐值决定代币地址、每步 gas |
| `test/fork/DeployPikaMainnet.t.sol`（4） | 在 BSC 主网分叉上，用 OpenFour 真实主网 Core 和 Pancake Infinity 跑主网部署脚本：整套部署、两种报价币的发射、timelock 交接 |
| `test/fork/OpenFourBondingCurve.t.sol`、`OpenFourSimpleTrade.t.sol`（3） | 本地对 OpenFour 闭源曲线和交易模块的替身，与主网上线的模块一致 |
| `test/pika-launch/PikaInfinityFlow.t.sol`（9） | 毕业进 Infinity 池和外盘交易的端到端流程 |
| `test/pika-launch/PikaProjectFees.t.sol`、`PikaFeeCut.t.sol`、`PikaAutoPush.t.sol`、`PikaPendingFees.t.sol`、`PikaFeePushReview.t.sol`（23） | 代币的手续费记账与推送：项目费、平台抽成、应用槽、创建者钱包 |
| `test/pika-launch/PikaGuardian.t.sol`、`PikaTimelock.t.sol`（13） | Guardian 与 timelock 对中枢的控制 |
| `test/pika-launch/PikaAudit.t.sol`、`PikaAuditV10.t.sol`（6） | 回归：合约创建者无法阻止毕业（两种报价币、两种代币排序）；每条收费路径上手续费账本与代币余额一致；新持有人只按持有时长分红 |
| `test/pika-market/PikaOpenLiquidity.t.sol`（6） | 毕业铸一个全区间（±887250）LP NFT 给销毁地址；别人留在仓位合约里的币挡不住毕业；任何人免费加减仓；只有 NFT 所有者能撤；金库从中枢领毕业余款；加流动性应用的账始终有币覆盖 |

`test/helpers/` 里是本地替身：
- `MockOpenFourCore`：Core、Registry、Tools、FeeRouter。
- `OpenFourBondingCurve`、`OpenFourSimpleTrade`：官方的曲线和交易模块。
- `InfinityArtifacts`：编出测试要部署的真实 Pancake Infinity `Vault`、`CLPoolManager` 和 `CLPositionManager`。
- `PikaLpHelpers`：像钱包一样经仓位合约提供第三方流动性。

OpenFour 真实 Core 上的 gas（BSC 测试网分叉，`test_GasOnRealCore --isolate`）：

| 步骤 | gas |
| --- | --- |
| 创建（带分红应用） | 324 万 |
| 创建（无应用） | 301 万 |
| 按数量买（新持有人） | 52.2 万 |
| 按数量买（老持有人） | 48.1 万 |
| 卖 | 45.2 万 |
| 买空并毕业 | 176 万（多出的是铸 LP NFT；v12.0.0 为 156 万） |
