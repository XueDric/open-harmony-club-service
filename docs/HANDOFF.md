# 项目交接说明 · 社团管理工具

> **下个对话从这里开始。** 本文自包含——读完它 + 第 3 节的文档，即可直接接手。

- 更新时间：**2026-09-14**
- 工作区：`E:\harmonyOS\cangjie_web`
- 设计阶段：**已完成，接口冻结**（39 / 39）
- **当前阶段：服务端全部完成并验证**（M1–M8，含三轮独立代码评审修复）；**客户端仍是 DevEco 初始模板，待开工**
- 三套测试基线：**单测 300 / 冒烟 347 / TLS 22 全绿**（跑法见 `README.md` 顶部）

> §8、§9 是**设计阶段**给出的开工建议与待问问题，现已全部执行完，保留作方法论参考；
> §11 记录服务端从 M1 到 M8 的实际进展，**数字以那里的最新一条为准**。

---

## 1. 项目一句话

社团内部管理工具。解决两个问题：**① 社团里有哪些人 ② 每件事由谁负责、做到什么程度。**

- 客户端：鸿蒙 App（仓颉）
- 服务端：仓颉 1.1.3 + 轻舟框架，部署在 Windows 云服务器
- 第一版（v1）目标：社团内部试用 2 周

---

## 2. 技术栈（全部已冻结，不要再改）

| 项 | 决定 |
| --- | --- |
| 客户端 | 鸿蒙 App，**仓颉** |
| 服务端 | **仓颉 1.1.3 + 轻舟（QingZhou）框架** |
| 服务器 | **Windows**（与开发机同平台） |
| 部署 | **本机编译 → 拷制品**，服务器不装编译器 |
| 持久化 | **文件存储**（内存 Store + 写时原子落盘 JSON），**不用数据库** |
| HTTPS | **轻舟原生 TLS**（不使用 Nginx） |
| 提醒 | 系统日历（**客户端本地机制**，服务端不存日历字段） |

### 实测环境事实（可直接用）

| 项 | 位置 / 值 |
| --- | --- |
| 编译器 | `D:\Cangjie\bin\cjc.exe` — **1.1.3** (cjnative) |
| stdx | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` — **1.1.3.1** |
| 轻舟源码 | `E:\cangjie\qingzhou` — commit **`1cad35b` + 本地 2 行补丁** |
| OpenSSL 3 | `E:\cangjie\qingzhou\deps\openssl\` 下两个 DLL |
| 仓颉运行时 | `D:\Cangjie\runtime\lib\windows_x86_64_cjnative` |

### 本机验证过的编译命令

```powershell
$CJC  = "D:\Cangjie\bin\cjc.exe"
$STDX = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx"
$ROOT = "E:\cangjie\qingzhou"
$libs = (Get-ChildItem "$STDX\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
$fw   = Get-ChildItem "$ROOT\src\*.cj" |
        Where-Object { $_.Name -notin @('unit_tests.cj') } |
        ForEach-Object { $_.FullName }

& $CJC @fw --import-path $STDX -L $STDX @libs -lcrypt32 -Woff unused -o "$ROOT\build\main.exe"
```

---

## 3. 文档地图（写代码时按需查）

| 文档 | 用途 | 什么时候看 |
| --- | --- | --- |
| `v1-scope.md` | **范围基准** v0.10：11 页面、6 张表、19 条业务规则、权限矩阵 | 想知道"这个要不要做" |
| `api-design.md` | **完整接口设计** Part 1–6，39 个接口逐条定义 | **写服务端时全程对照** |
| `frontend-brief.md` | **前端对接精简版**：页面清单、通用约定、错误码、**5 件必知事项** | **客户端同事先看这个** |
| `deploy-windows-verify.md` | 部署与验证、目标配置基线 | 部署时看 |
| **`code-review.md`** | **代码评审报告（三轮）**：24 + 9 + 4 条，全部已修，附回退实测证据 | 想知道"哪些坑已经踩过、为什么这样写" |
| `README.md` | 仓库唯一入口：进度、目录结构、六条最容易踩的坑 | 第一次打开这个仓库时 |
| *（对外材料已移出仓库）* | 轻舟 TLS 实测与缺陷清单、仓颉运行时缺陷报告 —— 见上层 `cangjie-upstream\` | 追溯上游问题时看 |
| **`server-guide.md`** | **服务端**：构建/初始化/运行/测试、进度表、两条实现纪律 | **写服务端时先看** |
| **`API-NOTES.md`** | **服务端**：编译期 API 事实清单 + **28 条**踩坑记录 | 加新函数前先查（避让框架同名符号） |

---

## 4. 已冻结的设计（摘要）

### 4.1 页面（11 个）

登录页 · **我的任务（首页）** · 任务列表 · 任务详情 · 课题列表（树） · 课题详情 · 成员名录 · 加入流程 · 待分配审批 · 管理 · 我的/个人设置

### 4.2 数据模型（6 张表）

| 表 | 关键字段 |
| --- | --- |
| `Department` | id / name / sort（**无 lead_id**） |
| `Member` | name / **phone（登录账号）** / password_hash / role / dept_id / **status**（`pending`/`active`/`disabled`） |
| `Plan` 课题 | title / **parent_id（自引用，多级）** / **owner_id 必填** / **dept_id 仅顶层** / due_at |
| `Task` | title / **owner_id 必填且唯一** / plan_id / status（4 档）/ **blocker** / due_at / **updated_at** / **deleted_at** |
| `RegisterConfig` | **code（明文）** / updated_by |
| `DeptInviteLink` | token / dept_id / enabled |

### 4.3 角色（固定 5 档，不可自定义）

`president` 会长 · `vice_president` 副会长 · `lead` 部长 · `vice_lead` 副部长 · `member` 成员

- **副会长 = 与会长同权**，但有明确例外（2026-09-14 定稿）：
  - 不能「移交会长」；
  - **不能更换注册口令**（仅可查看）、**不能部门增删改**（会长独占）；
  - **不能作用于与自己同权或更高权的人** —— 会长 / 副会长 / 部长一律适用
    （对会长而言"同权"只剩自己，所以会长也不能重置自己）。
    ⚠️ 覆盖 **重置密码 / 调部门改角色 / 移出社团 / 编辑姓名 / 审批分配（`assign`、`assign-batch`）** 五类动作；
    其中"重置密码"连**自己**也禁（该操作会作废目标全部令牌，对本人执行＝"响应 200、自己当场掉线"）。
    ⚠️ **客户端要能处理这类 `403 FORBIDDEN_ROLE`**（不是界面 bug，是同权保护）——
    具体见 `frontend-brief.md`。
- 组织固定 4 个：主席团 · 课题部 · 运营部 · 宣传部

### 4.4 接口（39 个）

按模块：认证 5 · 组织与成员 19 · 任务 8 · 课题 6 · 运维 1。**完整定义见 `api-design.md`。**

### 4.5 19 条业务规则中最关键的 8 条

1. **一个任务只能有一个负责人**（必填，不可置空）
2. **任务状态只有 4 档**（todo/doing/blocked/done），**不做进度百分比**
3. **进入 `blocked` 必须填 `blocker`** → 否则 `BLOCKER_REQUIRED`
4. **课题不设 status**，进度由整棵子树**递归聚合**
5. **删除课题 = 子节点上提一级**，绝不级联删除
6. **系统必须始终至少有一个 `president`**
7. **课题树禁止环形引用**（移动时校验，否则递归会拖垮服务）
8. **注册与授权分离**：注册只建账号（`pending`），角色全部由会长授予

---

## 5. 贯穿全项目的设计原则（**违反会导致返工**）

> 这五条是从设计过程中反复修正出来的，写代码时请自觉遵守。

| 原则 | 具体体现 |
| --- | --- |
| **同一事实只存一份** | 删了 `Department.lead_id`；课题不设 status；逾期不设状态；`Plan.dept_id` 只在顶层 |
| **能从事实推导的就不存** | 逾期由 `due_at` 算；课题进度由任务聚合 |
| **绝不级联删除** | 删课题上提；任务软删除 |
| **权限判定收敛到一个函数** | `can(member, action, target)`；**禁止在每个 handler 里手写 if** |
| **服务端权威** | `updated_at` 服务端生成；逾期/分组服务端算；客户端读 `permissions` 只用于画界面 |

---

## 6. 已验证的技术事实（**不要重复踩坑**）

| 事实 | 说明 |
| --- | --- |
| **TLS 可用** | TLS 1.2/1.3 握手成功；TLS 1.0/1.1 **被服务端拒绝**（alert 70）；HTTPS 请求返回 200 |
| **三套测试全绿** | 单测 **300** / 冒烟 **347** / TLS **22**（2026-09-14；跑法见 `README.md`） |
| **部署文件集** | **5 个文件 / 约 18.8 MB**：`club-server.exe` + `libcangjie-runtime.dll` + `libboundscheck.dll` + `libcrypto-3-x64.dll` + `libssl-3-x64.dll`（证书、启动脚本与说明另计）；由 `server/build-package.ps1` 生成 |
| **运行时只需 2 个 DLL** | runtime 目录有 51 个，只需 `libcangjie-runtime.dll` 与 `libboundscheck.dll` |

### ⚠️ 必须知道的坑

| 坑 | 表现 / 解法 |
| --- | --- |
| **轻舟当前版本编译不过**（DEF-1） | `PrivateKey.decodeFromPem` 未实现 → 已打本地补丁，见下 |
| **块注释里不能出现 `/*`** | 仓颉块注释可嵌套 → 会吞到文件末尾，报 `unterminated block comment` |
| **服务 `cwd` 必须是 exe 所在目录** | 数据目录与证书按相对路径读；`cwd` 不对会出现**假失败 + 假通过** |
| **crypto 缺 OpenSSL 3 时** | **编译期无警告**，运行时才 500；两个 DLL 必须与 exe 同目录 |
| **项目路径保持纯 ASCII** | 否则 `cjpm` 报 `Invalid utf8 byte sequence` |
| **用工具局部编辑 `.ps1` 会丢 BOM** | PS 5.1 按 ANSI 解析中文注释，报 `MissingEndCurlyBrace` / `意外的标记` 这类**看起来像手写语法错**的解析失败。改完 `.ps1` 必须确认 BOM 仍在（2026-09-14 已实证 3 次：`smoke.ps1` ×2、`build.ps1` ×1） |
| **Windows 无 `std.runtime.Signal`** | 优雅关闭靠 `POST /admin/shutdown`，**该端点必须限制为本机可访问** |
| **部署别只拷 2 个 OpenSSL DLL** | 会启动即失败——还缺 `libcangjie-runtime.dll` |

### 本地补丁（DEF-1，必须保留）

`E:\cangjie\qingzhou\src\app.cj` 已改 2 处：

```diff
@@ import 区
+import stdx.crypto.keys.*
+import stdx.crypto.common.*
@@ serveTls()
-        let key = PrivateKey.decodeFromPem(keyPem)
+        let key: PrivateKey = GeneralPrivateKey.decodeFromPem(keyPem)
```

已反馈轻舟团队（见上层 `cangjie-upstream\qingzhou-tls-verification.md`）。**上游修复后可撤销。**

---

## 7. 未决事项

> **以 §11.4 的现行清单为准**（本节原表已合并过去，避免两处各写一份而逐渐不一致）。
> 仍未解决的仍是那几项：**服务器步骤 0**（架构 / 公网 IP / 端口 / 防火墙 + 云安全组）、
> **轻舟 DEF-1 上游未修**、**服务器可用期限与备份交接人**，以及**本机直连 github.com 需走代理**。
> 已定：忘记密码不做自助找回（由管理员重置；会长也一样，见 §4.3 的口径）。

---

## 8. 开工建议顺序（设计阶段的历史建议，**已全部执行完**）

> 服务端与客户端可以并行，但**服务端先跑通全链路**能最快排除风险。

### 第 0 步（30 分钟，先做）：验证全链路
在 `E:\cangjie\qingzhou` 起一个最小服务 → 本机访问 → 打包 6 个文件 → 确认能跑。
**目的是把"编译→运行→部署"这条链路先打通**，再往里塞业务逻辑。

### 第 1 步：服务端骨架
- `Store` 接口 + 文件落盘实现（原子写：先写 `.tmp` 再 `rename`）
- 统一响应包装（`{ok, data}` / `{ok, error:{code,message,fields}}`）
- 错误码表（`api-design.md` §1.3）
- **权限函数 `can(member, action, target)`**（Part 1 §1.6）★ 先写它
- 认证中间件

### 第 2 步：按 Part 顺序实现接口
`Part 2 认证` → `Part 3 组织与成员` → `Part 4 任务` → `Part 5 课题`

### 第 3 步：客户端
按 `frontend-brief.md`。**注意两项需单独排期的客户端工作**：
- 日历同步机制（本地映射 + `POST /tasks/lookup` 比对）
- 自签证书信任配置（证书**必须带 SAN**，写 `IP:<公网IP>`）

---

## 9. 设计阶段列出的待问问题（**均已确认，保留备查**）

1. 从**服务端**还是**客户端**先写？
2. 服务器信息（架构 / 公网 IP / 可用端口）能否现在提供？
3. 是否需要我先搭出服务端骨架（Store + 权限函数 + 一个能跑通的最小端点）？

---

## 10. 一句话提醒

**接口已冻结**，`api-design.md` 是唯一权威。若实现中发现设计问题，**先改文档再改代码**，不要只改代码——否则前后端会各按各的记忆实现。

---

## 11. 服务端进展（2026-09-13 更新）

> 客户端由小组其他成员并行推进；本工作区当前只做服务端。轻舟上游更新没等到，
> 继续使用 **`1cad35b` + 本地 DEF-1 补丁**（补丁**不能撤**，撤了就编译不过）。

### 11.1 已完成并验证：M1 骨架 + M2 组织与成员

> 下表数字是 **M2 完成当时（2026-09-13）的快照**，保留用于对照；**当前基线见 §11.3 与 `README.md`**。

代码在 `server/src/`（**现为 21 个源文件**），详见 `server-guide.md`。
**接口进度（当时）24 / 39**（认证 5 + 组织与成员 19）；其余为任务 8、课题 6、运维 1（`/health` 已做）。

| 验证（2026-09-13 快照） | 结果 |
| --- | --- |
| 从零构建 | ✅ 通过 |
| 单测 `club-server.exe test` | ✅ **PASS 164 / FAIL 0** |
| 冒烟测试（真实 HTTP，`tests/smoke.ps1`） | ✅ **PASS 165 / FAIL 0** |
| 部署文件集 | exe 10.65 MB + 4 个 DLL ≈ **18.4 MB** |

- **M1**：构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区（自实现历法，与 .NET 独立对拍）·
  **`can(member, action, target)`** · Part 2 认证 5 接口 · `/health` · `/admin/shutdown`（限本机）。
- **M2**：部门增删改（会长独占）· 成员名录/详情/编辑 · 移出社团 · 待分配与**批量分配**（逐条报告、部分成功）·
  **会长移交原子性**与「最后一个会长」保护 · 重置密码（含审计日志）· 注册口令查看/更换/轮换 · 招募链接。

**测试自己抓到的真 bug**（不是预置的，都是会真出事的那种）：
`Directory.create(recursive:true)` 在目录已存在时照样抛异常（会让第二次落盘直接崩）；
副会长被误允许更换注册口令；空目录 `remove` 抛异常导致单测中断。

### 11.2 本轮文档修订（先改文档再改代码）

| # | 修订 | 文档位置 |
| --- | --- | --- |
| 1 | **部门增删改改为会长独占**（原 §3.8/矩阵写副会长 ✅，与 §3.1/§6.1「DELETE 限会长」冲突） | `api-design` §3.1/§3.8/§6.1/§6.4 · `v1-scope` §3.4.3 |
| 2 | **会长只能由「移交会长」产生**：`assign` 与 `PATCH /members` 拒绝 `role=president` | `api-design` §3.3/§3.4 · `v1-scope` 规则 11 |
| 3 | `Member` 新增 **`dept_hint`** 字段（招募链接的部门预填） | `v1-scope` §5 · `api-design` §3.3 |
| 4 | 密码长度**按字节**校验的口径说明 | `api-design` §2.3 注 5 |
| 5 | `client_token` 幂等的落地范围：注册靠手机号唯一性挡住重复；幂等落在任务/课题创建类接口（M3/M4） | `api-design` §1.9 · `v1-scope` v0.11 说明 |
| 6 | `MEMBER_HAS_OPEN_TASKS` 的任务清单放 **`error.fields.tasks`**；该接口幂等 | `api-design` §3.2 |
| 7 | `DELETE /depts/{id}` 的 `DEPT_NOT_EMPTY` **也检查顶层课题**；已退出成员/历史任务的 `dept_id` 置 0 | `api-design` §3.1 |
| 8 | `DELETE /dept-invite-links/{token}` 是**停用**（`enabled=false`，记录保留）且**幂等** | `api-design` §3.7 |
| 9 | `PATCH /members/{id}` 字段级权限；待分配成员只接受 `name` | `api-design` §3.2 |
| 10 | `assign` 对 `disabled` 成员即"恢复"，成功后清空 `dept_hint` | `api-design` §3.3 |
| 11 | `GET /plans` 的 `depth` 上限统一为 **6**（原 §5.2 写 10，与 §5.1 及树的硬上限矛盾） | `api-design` §5.2 |
| 12 | M4 的 9 条实现口径（`include_progress` 语义、`move` 提升顶层时的部门、移动深度校验、跨部门错误码、写接口响应形状、删除计数…） | `api-design` §5.11（新增） |

`v1-scope.md` 顶部修订记录已加 **v0.11**。

### 11.3 下一步

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| ~~M2~~ | ~~Part 3 组织与成员 19 个接口~~ | ✅ **已完成** |
| M3 | Part 4 任务 8 个接口（`/tasks/mine` 服务端分组、`BLOCKER_REQUIRED`、软删除、`/tasks/lookup`、`client_token` 幂等） | ✅ **已完成并验证**（单测 197 / 冒烟 220 全绿） |
| M4 | Part 5 课题 6 个接口（环形校验、深度 6、删除上提、O(n) 聚合） | ✅ **已完成并验证**（单测 233 / 冒烟 280 全绿） |
| M5 | 打包部署 · 带 SAN 自签证书 · TLS 关卡 | 🟡 **本机部分已完成**（TLS 22 项全绿 + 部署包 18.8 MB 端到端跑通）；公网部署**卡在服务器步骤 0**（架构 / 公网 IP / 端口 / 防火墙） |
| M6 | 按 `docs/code-review.md` **第一轮**修缺陷（3 个 P0 权限漏洞 + 8 个 P1 + 13 个 P2，共 24 条） | ✅ **已完成并验证**（单测 273 / 冒烟 325 / TLS 22 全绿，2026-09-14） |
| M7 | `docs/code-review.md` **第二轮**：独立复验第一轮 24 条（全部确认修复）+ **9 条新发现**（N-1…N-9） | ✅ **已完成**——9 条全部处理（N-8 按约定不改）：N-1（落地页 HTML 转义）/ N-2 / N-3 / N-4 / N-5（`idem` 补 `checkLoaded`）/ **N-6（注册节流改为按客户端 IP + 递增退避，因此未新增接口，接口计数仍是 39 / 39）** / **N-7（不可作用于同权或更高权的人，已从"重置密码"推广到改名 / 改角色 / 禁用）** / N-9（CSP），每条都带"回退即变红"的回归断言。当前基线 **单测 300 / 冒烟 347 / TLS 22 全绿** |
| M8 | `docs/code-review.md` **第三轮复验**：复验第二轮 9 条 + **4 条新发现**（N-10…N-13） | ✅ **已完成**——第二轮 9 条全部确认修复；**N-10**（`assign` / `assign-batch` 漏在同权保护之外：副会长可降级同权者，甚至用 `assign` 推翻会长对同权者的移出决定）已修，批量改为逐条判定；N-11 文档限定词、N-12 裸 IPv6 退化注释、N-13 分布式局限说明均已处理 |

**接口进度 39 / 39**：认证 5 · 组织与成员 19 · 任务 8 · 课题 6（= 38 个业务接口）+ 运维 `/health`。
（早期写「38 / 39」是把 `/health` 漏算了；另有一个不在接口清单里的公开落地页 `GET /join/{token}`。）

#### ✅ 环境故障已定位并已规避（2026-09-13 晚）

当晚本机**所有仓颉 exe 启动即崩**（`0xC0000005`；故障模块恒为 `msvcrt.dll`、偏移 `0x62f1e`，
自行解析 PE 导出表得知落在 **`wcslen`**）：本项目 exe、轻舟框架 exe、`cjenv.exe`，
连 1.0.5 与 1.1.3 两套 SDK 的产物都一样；用"进 `main` 就写文件"的探针确认 **`main()` 根本没执行**。

**根因**：事件日志显示 **21:40:35「2026-09 预览更新 (KB5124010) 安装成功」**，紧随 21:40:13 的开机；
当日 13:58 时 M2 的 165 项冒烟测试还是全绿的。

**受控验证**：**22:18 卸载 KB5124010 并重启后立即恢复**（UBR 26300.9539 → 26300.9445）：
最小 hello world 正常、单测 **197/0**、冒烟 **220/0**。
卸载前后**唯一版本变化的已加载模块是 `ntdll.dll`（9539 → 9278）**，
`msvcrt`/`ucrtbase`/`msvcp_win`/`KERNEL32`/`KERNELBASE` 全未变
——这也解释了"`msvcrt!wcslen` 机器码一字未改却崩在那里"。

完整证据链与复现源码见：
上层的 `cangjie-upstream\cangjie-runtime-startup-crash.md`（**已提交给仓颉团队**）、
`API-NOTES.md` §5、以及同目录的 `cangjie-upstream\repro.cj`。
（当时的证据 zip 是一次性产物，已按需删除；结论都固化在上述文档里。）


同一时段还发现：`build.ps1` 原先依赖环境里的 `CANGJIE_HOME`，而 **cjenv 把它切到了 1.0.5**，
造成"前端 1.1.3 + 后端 LLVM 1.0.5"串台、编译器直接崩。已在 `build.ps1` 里显式钉死工具链。

### 11.4 仍未决

| # | 事项 | 影响 |
| --- | --- | --- |
| 1 | **服务器步骤 0 未跑** | 卡 M5：需确认架构是否 x64、公网 IP、端口、防火墙+安全组 |
| 2 | 轻舟 DEF-1 上游未修 | 本地补丁顶着；补丁已记录在 `server/build.ps1` 与 `API-NOTES.md` |
| 3 | 工作区原先**不是 git 仓库** | 2026-09-13 已建 GitHub 仓库 `XueDric/open-harmony-club-service` 并上传；提交作者为 `XueDric <318242380+XueDric@users.noreply.github.com>`。**2026-09-14 已把三轮评审修复 + 仓库整理全部推送**，远端 `main` 与本地 HEAD 一致 |
| 3b | **推送 github 的网络** | 2026-09-14 实测**直连可用**（`git push origin main` 直接成功，此前记录的"直连不通"已不适用）。若哪天直连超时（约 20s），改走本地代理：<br>`git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin main`<br>（直连超时**别误判成权限问题**） |
| 4 | 忘记密码：v1 由会长重置 | 已定 |
| 5 | 服务器可用期限、备份交接人 | 需向老师确认 |

---

### 11.5 客户端交接要点（**客户端同事从这里开始**）

**现状：`entry/` 仍是 DevEco 初始模板，未接任何接口。** 服务端已全部就绪（39 / 39），可直接对接。

1. **开工前先替换模板值**：`AppScope/app.json5` 的 `bundleName`、应用名与图标、首页占位文案。
   发布前若忘掉，装到手机上会显示 DevEco 的示例名（README「未决事项」#7 有记录）。
2. **接口与错误码**：精简版看 `frontend-brief.md`（页面清单 / 通用约定 / 错误码 / **5 件必知事项**），
   完整定义看 `api-design.md`。**接口已冻结，要改先提出来。**
3. **页面 11 个，首页必须是「我的任务」**，不是组织架构图。
4. **两项客户端自己的工作要单独排期**：日历同步机制（本地映射 + `POST /tasks/lookup` 比对）、
   自签证书信任配置（证书**必须带 SAN**，写 `IP:<公网IP>`）。
5. **本机联调起服务**：

   ```powershell
   cd server
   powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1      # 编译（并拷 4 个依赖 DLL）
   cd build
   .\club-server.exe init-admin 13800000000 你的密码123 dev-data       # 预置首任会长 + 4 个组织
   .\club-server.exe serve 8080 dev-data                               # HTTP
   # HTTPS： .\club-server.exe serve-tls 8443 dev-data ..\certs\cert.pem ..\certs\key.pem
   ```

   ⚠️ **`cwd` 必须是 exe 所在目录**（数据目录与证书按相对路径读）；冒烟脚本用独立数据目录
   `build\smoke-data`，不会碰你的联调数据。
6. **要能处理这几类"看起来像 bug 的 403 / 429"**（都属于服务端设计，不是缺陷）：
   - **同权保护**：副会长试图降级 / 禁用 / 重置另一位副会长 → `403 FORBIDDEN_ROLE`（见 §4.3）；
   - **最后一个会长**：`403/409 FORBIDDEN_LAST_PRESIDENT`；
   - **注册被节流**：`429 TOO_MANY_ATTEMPTS` —— 节流**按客户端 IP**（2026-09-14 起），
     只影响注册、不影响登录与其它接口；
   - **`pending` 账号**：能登录但 `permissions` 全 false、`view_scope = none`，
     客户端应跳「等待管理员分配」页，**不进主界面**。

---

### 11.6 仓库结构（2026-09-14 整理后）

| 变动 | 说明 |
| --- | --- |
| **对外材料移出仓库** | 仓颉运行时缺陷报告 + Issue 稿件 + 最小复现 `repro.cj`、轻舟 TLS 需求与实测 → 上层 `E:\harmonyOS\cangjie-upstream\`（5 个文件）。仓库内 17 处引用已改写为指向那里 |
| **删除** | `entry/src/test`、`entry/src/ohosTest` 的 DevEco 模板示例（8 个文件）；已核对 `build-profile.json5` 不引用这两个目录，不影响主构建 |
| **入库文件** | **63 个**（整理前 76）：`server` 25 · `entry` 17 · `docs` 8 · `AppScope` 5 · 根配置 8 |
| **`server/build/` 已清空** | 构建产物、冒烟/TLS 测试数据、日志都删了（释放 38.22 MB）。**下次跑测试前先执行 `build.ps1`** |
| **保留** | `server/dist/`（完整部署包，可直接部署）· `server/certs/`（证书 + 私钥）· `oh_modules/`（鸿蒙依赖，重装需联网）· `.idea/`、`local.properties` |
