# cjenv 下载、安装、配置与版本切换测试 —— 分析报告

- **报告日期**：2026-09-13
- **工具**：cjenv — 仓颉 SDK 版本管理与开发环境治理工具（v0.1.0，MPL-2.0）
- **上游仓库**：<https://gitcode.com/xuguowei/cjenv>
- **本机环境**：Windows / AMD64，仓颉 SDK 1.1.3（`D:\Cangjie`）
- **测试目标**：本机 1.1.3 ↔ 新下载 1.0.5 的双向切换
- **结论**：**任务达成**。工具已安装并完成配置，1.1.3 与 1.0.5 可双向切换、回退、校验、编译，全部验证通过。过程中发现并修复了上游一个 **导致首次安装必然失败的真实缺陷**（大文件校验 OOM）。

---

## 1. 执行摘要

| 项目 | 结果 |
|------|------|
| 获取方式 | 上游**无任何 Release / Tag**，`install.ps1` 无法工作 → 改为**源码构建** |
| 构建 | `cjpm build` 成功（本机 cjc 1.1.3，无需降级到工程声明的 1.0.5） |
| 安装位置 | `C:\Users\ASUS\.cjenv`（可执行文件 + 源码 + shim） |
| 环境配置 | 用户 PATH 前置 shim 目录；`cjenv shim init` / `shim add-path --user` |
| SDK 注册 | 1.1.3 → 外部注册（`D:\Cangjie`，kind=external，不搬移原安装） |
| SDK 安装 | 1.0.5 → 官方源下载 283.5MB，SHA-256 校验通过，kind=managed |
| 切换测试 | 1.1.3 ↔ 1.0.5 双向多次切换、rollback 回退，**全部通过** |
| 实编译验证 | `cjc` 与 `cjpm` 在两个 SDK 下均编译并运行成功 |
| 上游测试套件 | 仓颉单元测试 + PowerShell 集成测试（约 120 项断言）**全部通过** |
| 发现缺陷 | **1 个 P0**（大包校验 OOM，阻断安装）、1 个同类隐患、若干可用性问题 |
| 交付物 | 修复补丁 `cjenv-big-archive-install-fix.patch` |

---

## 2. 环境勘察

| 项 | 值 |
|---|---|
| 操作系统 | Windows（PowerShell 5.1 / 26200 系列） |
| 架构 | AMD64 |
| 已有仓颉 SDK | `D:\Cangjie`，`cjc 1.1.3 (cjnative)`，target `x86_64-w64-mingw32` |
| `CANGJIE_HOME` | `D:\Cangjie`（**Machine 级**） |
| `PATH` 中的仓颉项 | `D:\Cangjie\bin`、`D:\Cangjie\tools\bin`、`D:\Cangjie\tools\lib`、`D:\Cangjie\runtime\lib\windows_x86_64_cjnative`（均在 **Machine PATH**） |
| 依赖工具 | `curl 8.21.0`、`git 2.55.0`、`System32\tar.exe`(bsdtar)、`unzip` |
| 工作区 | `E:\harmonyOS\cangjie_web`（工具安装在 `C:\Users\ASUS\.cjenv`） |

> 关键点：原 SDK 直接路径位于 **Machine PATH**，而 cjenv 的 shim 只能写入 **User PATH**。Windows 拼接顺序为 `User;Machine`，因此 shim 默认天然优先于 `D:\Cangjie\bin`——这是本机 `cjenv use` 能真正生效的前提。若原 SDK 位于 Machine PATH 且 shim 未能前置，官方建议用管理员终端执行 `cjenv shim add-path --system`。

---

## 3. 获取与安装

### 3.1 为什么不是"一键安装"

仓库 README 提供：

```powershell
irm 'https://api.gitcode.com/api/v5/repos/xuguowei/cjenv/raw/install.ps1?ref=main' | iex
```

但实测：

```
GET /api/v5/repos/xuguowei/cjenv/releases      → []
GET /api/v5/repos/xuguowei/cjenv/releases/latest → 400 "未找到 release"
GET /api/v5/repos/xuguowei/cjenv/tags          → []
```

**该仓库没有发布任何 Release 或 Tag**，而 `install.ps1` 的逻辑强依赖 `releases/latest` 查找 `cjenv-*-windows-x64` 资产并 `Expand-Archive`。因此一键安装脚本在本仓库当前状态下**必然失败**（`Die "failed to query release latest"`）。

→ 采用 README 中记录的**源码构建**路径。

### 3.2 实际安装步骤

```powershell
git clone --depth 1 https://gitcode.com/xuguowei/cjenv.git E:\harmonyOS\cangjie_web\cjenv
cd E:\harmonyOS\cangjie_web\cjenv
cjpm build                       # -> target\release\bin\main.exe
```

安装到 `C:\Users\ASUS\.cjenv`：

```
.cjenv\
├── bin\cjenv.exe        # 构建产物（4.87 MB）
├── cjenv.cmd            # 启动器（仿上游 cjenv.cmd，指向 bin\cjenv.exe）
├── src\                 # 完整源码副本，便于复现/升级
├── shims\               # cjc.cmd / cjpm.cmd / cjfmt.cmd / cjenv.cmd
├── sdks\1.0.5\cangjie\  # 受管 SDK
├── cache\downloads\     # 下载缓存（283.5 MB）
├── versions.tsv         # 版本注册表
└── current              # 当前版本
```

环境配置：

1. `cjenv shim init` → 生成 4 个 shim；shim 内部调用 `cjenv.exe exec <tool>`
2. `cjenv shim add-path --user` → 把 `C:\Users\ASUS\.cjenv\shims` **置于用户 PATH 首位**
3. 用户 PATH 追加 `C:\Users\ASUS\.cjenv`（让 `cjenv` 命令本身全局可用）

> 说明：本机原始 shell 进程继承的是修改前的环境，需**新开终端**才生效；报告中的所有测试均按 Windows 规则重建 PATH（`User;Machine`）以模拟真实新终端。

### 3.3 工具链可用性

```
cjenv version   → cjenv 0.1.0
cjenv home      → C:\Users\ASUS\.cjenv
cjenv doctor    → 路径/注册表/官方源/平台 全部 [ok]，无待修项
```

---

## 4. 发现的缺陷（核心内容）

### 4.1 P0：大体积 SDK 包校验内存溢出，导致安装必然失败

**现象**：`cjenv install 1.0.5` 完成 283.5MB 下载后崩溃：

```
100 283.5M  100 283.5M ... 100 283.5M
An exception has occurred:
    Out of memory
downloaded 1.0.5 -> ...\1.0.5-windows-x64.zip
EXIT=1
```

安装未完成：`sdks\` 为空、注册表没有 1.0.5、无失败日志。

**定位过程**（按证据链推进，而非猜测）：

1. 校验下载包 SHA-256 与官方值 `08c6c1dd…cb2e` **完全一致** → 下载与官方源解析都是好的，故障在校验环节。
2. 最小复现程序显示：**峰值工作集仅 9.4 MB 就抛 OOM**。若真是内存不足，峰值应逼近上限；9.4 MB 说明是"分配规模"问题，而非物理内存不足。
3. 定位到根因代码 `src/installer.cj`：

```cangjie
func verifyFileSha256(path: String, expected: String): Unit {
    ...
    let actual = sha256HexString(File.readFrom(normalized))   // ← 全量读入内存
```

`File.readFrom()` 一次性把 283.5MB 读入内存；`sha256()` 内部还会把数据整体复制进 `ArrayList<Byte>`（逐元素装箱）再填充补位，峰值内存被放大数倍。

4. 同类隐患：`src/mirror.cj` 的 `mirror generate` 与 `mirror verify` 也使用 `File.readFrom` 全量读取整包（第 370、470 行），同样会在大型 SDK 归档上失败。

**影响面**：这不是环境特例——**任何 >百 MB 的官方 SDK 包（1.0.x / 1.1.x 全系）在 Windows 上都装不上**，而"安装"正是该工具的首要功能。属于 P0 阻断级缺陷。

**修复方案**：新增 `src/sha256_stream.cj`，以固定 64KB 分块读取文件、增量累积摘要，内存占用与文件大小无关；并把 `installer.cj`（2 处）与 `mirror.cj`（2 处，其中 `mirror verify` 改用 `FileInfo(...).size` 取文件大小而非内存数据）切换到流式实现。

修复后验证：

| 验证项 | 结果 |
|---|---|
| 283.5MB 官方包摘要 | `08c6c1dd…cb2e`，与官方值**逐字节一致** |
| 与一次性实现对比 | 0/1/55/56/57/63/64/65/127/128/129/1000/65535/65536/65537/200000 字节共 16 组**全部一致** |
| NIST 向量 | 空串、`"abc"` **通过** |
| 缓存复用判定 | `fileSha256Matches` 正确/错误摘要分别返回 true/false |
| 上游仓颉单元测试 | **全部通过**（含新增流式回归测试） |
| 上游 PowerShell 集成测试 | **全部通过**（约 120 项断言） |
| 端到端 | `cjenv install 1.0.5` EXIT=0，安装成功 |

**顺带发现的语义陷阱（值得上游注意）**：`sha256HexString(data)` 的语义是"**对 data 求摘要再转十六进制**"，而不是"把字节数组转成 hex 字符串"。调用方若拿它去格式化一个已有的 32 字节摘要，会得到"摘要的摘要"。原代码 `sha256HexString(File.readFrom(path))` 是正确的（传入的是原像），但该命名极易误用——修复中已新增语义明确的 `sha256DigestHex(摘要字节)`，并在注释中标注两者区别。排查过程中我曾因误用该函数得出过错误结论，特此记录，也说明这一命名确实有改进空间。

### 4.2 次要问题

| 级别 | 问题 | 说明 |
|---|---|---|
| 低 | 无 Release / Tag | 使 README 的"一键安装"完全不可用；建议至少发布一个带 `cjenv-<ver>-windows-x64` 资产的 Release |
| 低 | `cjenv update <version>` 不支持外部注册版本 | `updateOfficial`/`updateRemoteFromSource` 对 `kind != "managed"` 直接报错，提示先 `unregister`。这是有意的安全设计，但对已把官方 SDK 纳入管理的用户不友好 |
| 低 | 纯仓颉 SHA-256 速度 | 283.5MB 约需 **1 分 7 秒**。因缓存复用也要重新校验，重复安装会再等一次；大包场景建议改用 `std.crypto.digest` 或并行分块 |
| 提示 | 首次安装的整体时延 | 下载约 20 秒（~14 MB/s）+ 校验约 67 秒 + 解压，合计约 2 分钟，属预期 |

---

## 5. 版本切换测试

测试脚本：`switch-test.ps1`（切换/回退/校验）与 `build-test.ps1`（实编译）。

### 5.1 切换与回退

| 步骤 | 命令 | `cjenv current` | `cjc -v`（经 shim） | `cjpm -v` | 结果 |
|---|---|---|---|---|---|
| T0 | 初始（新终端） | 1.0.5 | 1.0.5 | 1.0.5 | ✅ |
| T1 | `cjenv use 1.1.3 --persist --user` | 1.1.3 | **1.1.3** | **1.1.3** | ✅ |
| T2 | `cjenv use 1.0.5 --persist --user` | 1.0.5 | **1.0.5** | **1.0.5** | ✅ |
| T3 | `cjenv use 1.1.3 --persist --user` | 1.1.3 | **1.1.3** | **1.1.3** | ✅ |
| T4 | `cjenv use 1.0.5` + `verify` | 1.0.5 | **1.0.5** | **1.0.5** | ✅ |
| T5 | `cjenv rollback` | 1.1.3 | **1.1.3** | **1.1.3** | ✅ |

- `cjc`/`cjpm`/`cjfmt` 三个入口均由 shim 正确接管（`Get-Command cjc` → `…\.cjenv\shims\cjc.cmd`）。
- `cjenv which cjc` 能准确解析到所选 SDK 的绝对路径。
- `cjenv rollback` 按 history 正确回退到上一个版本。
- 切换历史（`history`）与注册表（`versions.tsv`）均正确记录，`kind` 区分 `external` / `managed`。

### 5.2 完整性校验

```
cjenv verify 1.0.5  → kind: managed,  checking cjc/cjpm/cjfmt … verify ok: 1.0.5
cjenv verify 1.1.3  → kind: external, checking cjc/cjpm/cjfmt … verify ok: 1.1.3
```

### 5.3 实编译验证（关键：证明切换不只是"改个文件"）

在两个 SDK 下分别用 `cjc` 与 `cjpm` 编译同一份含类/方法调用的仓颉程序并运行：

| SDK | `cjc` 直接编译 | 运行输出 | `cjpm build` | 运行输出 |
|---|---|---|---|---|
| 1.1.3 | exit 0 | `hello, cangjie` / `sdk = 1.1.3` | success | `hello, cangjie` / `sdk = 1.1.3` |
| 1.0.5 | exit 0 | `hello, cangjie` / `sdk = 1.0.5` | success | `hello, cangjie` / `sdk = 1.0.5` |

两套 SDK 的编译产物行为正确、互不串扰，**版本切换对编译器与包管理器同时生效**。

### 5.4 环境一致性

- `cjenv env <version>` 输出该 SDK 的 `envsetup.ps1` 加载命令（供当前终端激活）。
- `cjenv run <version> cjc --version` 逐个验证：`run 1.0.5` → 1.0.5，`run 1.1.3` → 1.1.3。
- `cjenv use --persist --user` 会把 **User `CANGJIE_HOME`** 指向所选 SDK。

> **已知边界（环境性质，非缺陷）**：`use` 只修改**新终端**可见的持久化变量，当前已运行的 shell 进程内 `CANGJIE_HOME` 不会自动改变；工具据此在 `use` 输出中给出 `[warn]` 与 `[next]` 指引。进一步地，本机 **Machine 级 `CANGJIE_HOME`** 仍为 `D:\Cangjie`（由原 SDK 安装程序写入），与所选 1.0.5 不一致——由于 `D:\Cangjie` 下的工具链在通过 shim 启动时以可执行文件位置解析自身资源，本次实测**未影响 1.0.5 的编译运行**。若希望彻底消除该不一致，可用管理员终端执行 `cjenv use <ver> --persist --system`，或 `cjenv migrate official --apply --set-cangjie-home`。

### 5.5 项目级版本锁定

用临时工程验证（已清理，未污染用户工程）：

- `cjenv local 1.0.5 --project <dir>` → 生成 `.cjenv-version`
- 从嵌套子目录 `cjenv sync` → 正确向上查找 `.cjenv-version`，判定 `current SDK 1.0.5 matches .cjenv-version`
- `cjenv lock 1.0.5` → 生成 `.cjenv-lock`（含 version/source/platform/lockedAt）
- `cjenv doctor project <dir>` → `[ok] version source: .cjenv-version`、`[ok] current SDK 1.0.5 matches project requirement`

### 5.6 维护与安全

- `cjenv cache list` → `complete 1.0.5-windows-x64.zip 297274602 bytes`
- `cjenv safety` → active locks 0、staging 0、backups 0、logs 0、partial 0（**无残留锁、无残留 staging**，说明原子提交与失败回滚走的是干净路径）

---

## 6. 产物清单

### 6.1 安装产物（本机）

| 路径 | 说明 |
|---|---|
| `C:\Users\ASUS\.cjenv\bin\cjenv.exe` | 修复后构建的 cjenv 可执行文件 |
| `C:\Users\ASUS\.cjenv\cjenv.cmd` | 启动器 |
| `C:\Users\ASUS\.cjenv\shims\` | `cjenv` / `cjc` / `cjpm` / `cjfmt` shim（已置于用户 PATH 首位） |
| `C:\Users\ASUS\.cjenv\sdks\1.0.5\cangjie\` | 受管 SDK 1.0.5（875.7 MB） |
| `C:\Users\ASUS\.cjenv\cache\downloads\1.0.5-windows-x64.zip` | 下载缓存（283.5 MB） |
| `C:\Users\ASUS\.cjenv\src\` | 源码副本（含修复） |

### 6.2 仓库改动（`E:\harmonyOS\cangjie_web\cjenv`）

```
 M CONTRIBUTING.md          补入新源文件与回归测试命令
 M README.md                目录结构与测试命令补入 sha256_stream.cj
 M src/installer.cj         verifyFileSha256 / fileSha256Matches 改流式
 M src/mirror.cj            mirror generate / verify 改流式
 M tests/unit_test.cj       新增 testSha256Stream 回归测试（含 std.fs 导入）
?? src/sha256_stream.cj     新增：流式 SHA-256 与文件摘要
?? tests/sha_stream_check.cj 新增：独立流式校验回归（16 组尺寸 + NIST 向量）
?? switch-test.ps1          新增：切换/回退/校验验证脚本
?? build-test.ps1           新增：双 SDK 实编译验证脚本
```

- 补丁文件：`cjenv-big-archive-install-fix.patch`（9 个文件，+480 / −9）
- 改动已 `git add` 生成补丁后**取消暂存**，未提交、未推送，交由用户决定。

---

## 7. 结论与建议

### 7.1 结论

1. **cjenv 设计扎实、功能完整**。shim 代理、双向切换、回退、完整性校验、项目级锁定、环境诊断、缓存复用、原子安装与失败回滚均按文档工作；上游自带的单元测试与约 120 项集成断言**全部通过**。
2. **但当前版本在 Windows 上无法完成官方 SDK 安装**——大包校验 OOM 属 P0 阻断缺陷，且必然触发（官方包 283.5MB）。这使得"下载并安装"这一首要场景开箱即不可用。
3. 修复后，**1.1.3 与 1.0.5 的双向切换完整跑通**，并且经 `cjc`/`cjpm` 真实编译运行验证，切换对编译器与包管理器同时生效。

### 7.2 对上游的建议

1. **优先**：修复大包校验（本报告补丁已可直接采用），并考虑把 `sha256HexString` 更名为 `sha256Of`/`sha256HexOf`，避免"格式化摘要"的误用。
2. 发布至少一个带 `cjenv-<ver>-windows-x64` 资产的 Release，使 README 的一键安装真正可用。
3. 大包校验提速：改用 `std.crypto.digest` 或分块并行；或在安装路径上对"刚下载完的文件"跳过第二次重复校验（当前 `installFrom` 会再校验一次）。
4. 补充 `update` 对外部注册版本的支持，或在 README 明确该限制与迁移路径。

### 7.3 对本机的建议

- 新开终端即可使用 `cjenv` / `cjc` / `cjpm` / `cjfmt`；当前所选为 **1.0.5**。
- 如需让系统级 `CANGJIE_HOME` 与所选版本一致，用管理员终端执行 `cjenv use <ver> --persist --system`。
- 缓存中保留着 283.5MB 安装包，若磁盘紧张可执行 `cjenv cache clean`。

---

## 附录 A：关键命令速查

```powershell
cjenv list                      # 已注册 SDK（* 为当前）
cjenv current                   # 当前版本与路径
cjenv use 1.1.3 --persist --user  # 切换并持久化
cjenv use 1.0.5                 # 仅切换
cjenv rollback                  # 回退到上一版本
cjenv verify 1.0.5              # 完整性校验
cjenv which cjc                 # 解析实际使用的 cjc
cjenv run 1.0.5 cjc --version   # 以指定 SDK 运行工具
cjenv doctor                    # 环境诊断
cjenv cache list                # 缓存状态
cjenv safety                    # 安装安全状态（锁/staging/备份/日志）
```

## 附录 B：复现实验

```powershell
# 回归测试（独立）
cjc -o sha_stream_check.exe src/core.cj src/installer.cj src/source.cj src/mirror.cj `
  src/project.cj src/project_commands.cj src/doctor.cj src/migrate.cj src/platform.cj `
  src/shell_platform.cj src/shell_profile.cj src/completion.cj src/sha256.cj `
  src/sha256_stream.cj src/official.cj tests/sha_stream_check.cj
.\sha_stream_check.exe

# 上游单元测试
cjc -o unit_test.exe src/main.cj src/core.cj src/installer.cj src/source.cj src/mirror.cj `
  src/project.cj src/project_commands.cj src/doctor.cj src/migrate.cj src/platform.cj `
  src/shell_platform.cj src/shell_profile.cj src/completion.cj src/sha256.cj `
  src/sha256_stream.cj src/official.cj tests/unit_test.cj
.\unit_test.exe

# 上游集成测试（约 120 项断言）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1

# 本项目验证脚本
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\switch-test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-test.ps1
```

## 附录 C：环境注意事项（Windows）

1. **PowerShell 5.1 的脚本编码**：无 BOM 的 UTF-8 `.ps1` 会被按系统 ANSI 代码页（中文环境为 GBK）解析，中文字符与引号会破坏语法。本报告中的 `.ps1` 均以 **UTF-8 with BOM** 保存。
2. **写入 `.cj` 源文件时勿加 BOM**：BOM 会被计入源码文件名，导致 `cjpm` 报 `the package name ... is wrong`。请使用无 BOM 的 ASCII/UTF-8。
3. **`cjpm` 工程约定**：`cjpm.toml` 的 `[package].name` 必须与工程目录名一致，源文件需在开头声明 `package <name>`，且需包含 `[dependencies]` 段（即使为空）；构建产物为 `target\release\bin\main.exe`。
4. **`use` 的作用域**：只影响**新终端**；当前 shell 需按 `cjenv env <ver>` 输出激活，或 `use --persist --user/--system` 后重开终端。
