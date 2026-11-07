# OpenFour 公开接口（拷贝）

来源：`four-meme-community/openfour-docs` 的 `developer/startup/contracts/`（接口、`OpenFourTypes`、`OpenFourToken`，MIT），2026-11-05 拷贝；`oz/` 是 `OpenFourToken` 依赖的 OpenZeppelin 4.9.6 文件（MIT），导入路径改成了本目录的相对路径。OpenFour 的 Core、Registry、FeeRouter、Tools 不开源，不在这里。

`modules/StandardVault.sol` 是同一来源的官方 vault（`developer/startup/contracts/modules/vault/`），Pika 组合的 vault 槽直接用 OpenFour 已登记的 `module.vault.standard`（2026-11-05 起，替换原来的 `PikaVault`）。链上用的是 OpenFour 自己的实现，这份拷贝只给模拟 Core 的测试和 ABI 导出用；`Initializable` 指向 `oz/` 的 4.9.6 版（和链上一样发 `Initialized(uint8)`），`IERC20`/`SafeERC20` 用仓库的 OpenZeppelin。和链上实现核对过：主网 `0x9daf13aC…2F4c`、测试网开发环境 `0x024E84Bc…AAfb` 字节码相同，`isSoldOut()` 在剩余 ≤ `1e18` 时为真。

不要改这些文件的逻辑；OpenFour 更新接口时整体替换并重跑测试。
