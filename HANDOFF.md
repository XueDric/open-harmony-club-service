# 项目交接说明 · 社团管理工具

> **下个对话从这里开始。** 本文自包含——读完它 + 第 3 节列的 3 份文档，即可直接写代码。

- 生成时间：2026-09-13
- 工作区：`E:\harmonyOS\cangjie_web`
- 设计阶段状态：**已完成，接口冻结**

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
| `frontend-brief.md` | 前端对接精简版 | 客户端同事看 |
| `deploy-windows-verify.md` | 部署与验证、目标配置基线 | 部署时看 |
| `qingzhou-tls-verification.md` | 轻舟 TLS 实测与缺陷清单 | 遇到 TLS 问题时看 |
| **`server/README.md`** | **服务端**：构建/初始化/运行/测试、进度表、两条实现纪律 | **写服务端时先看** |
| **`server/API-NOTES.md`** | **服务端**：编译期 API 事实清单 + 15 条踩坑记录 | 加新函数前先查（避让框架同名符号） |

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

- **副会长 = 除「移交会长」外与会长同权**
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
| **单测全绿** | PASS **109** / FAIL 0 |
| **部署文件集** | **6 个文件 / 约 18.5 MB**：`main.exe` + `libcangjie-runtime.dll` + `libboundscheck.dll` + `libcrypto-3-x64.dll` + `libssl-3-x64.dll` + 配置/证书 |
| **运行时只需 2 个 DLL** | runtime 目录有 51 个，只需 `libcangjie-runtime.dll` 与 `libboundscheck.dll` |

### ⚠️ 必须知道的坑

| 坑 | 表现 / 解法 |
| --- | --- |
| **轻舟当前版本编译不过**（DEF-1） | `PrivateKey.decodeFromPem` 未实现 → 已打本地补丁，见下 |
| **块注释里不能出现 `/*`** | 仓颉块注释可嵌套 → 会吞到文件末尾，报 `unterminated block comment` |
| **服务 `cwd` 必须是项目根** | 配置与证书按相对路径读；`cwd` 不对会出现**假失败 + 假通过** |
| **crypto 缺 OpenSSL 3 时** | **编译期无警告**，运行时才 500；两个 DLL 必须与 exe 同目录 |
| **项目路径保持纯 ASCII** | 否则 `cjpm` 报 `Invalid utf8 byte sequence` |
| **`manual_runner` 的 "All 114"** | 是**写死的字符串**，真实用例数 **109** |
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

已反馈轻舟团队（`qingzhou-tls-verification.md`）。**上游修复后可撤销。**

---

## 7. 未决事项

| # | 事项 | 影响 |
| --- | --- | --- |
| 1 | **服务器步骤 0 未跑** | 需确认：架构是否 x64、防火墙+安全组、端口占用。见 `deploy-windows-verify.md` |
| 2 | 轻舟 DEF-1 上游未修 | 本地补丁顶着；上游修好后要重新验证 TLS |
| 3 | 给轻舟的需求文档已更正（去掉 Linux） | **需补发一份更正**给轻舟团队 |
| 4 | 忘记密码：v1 由会长重置，不做自助找回 | 已定 |
| 5 | 服务器可用期限、备份交接人 | 需向老师确认 |

---

## 8. 开工建议顺序

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

## 9. 可以立刻问用户的

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

### 11.1 M1 骨架已完成并验证

代码在 `server/`（13 个源文件 / 2524 行），详见 `server/README.md`。

| 验证 | 结果 |
| --- | --- |
| 从零构建 | ✅ 通过 |
| 单测 `club-server.exe test` | ✅ **PASS 130 / FAIL 0** |
| 冒烟测试（真实 HTTP，`tests/smoke.ps1`） | ✅ **PASS 58 / FAIL 0** |
| 部署文件集 | exe 10.65 MB + 4 个 DLL ≈ **18.4 MB**（与 §2 的 18.5 MB 吻合） |

已落地：构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区（自实现历法，与 .NET 独立对拍）·
**`can(member, action, target)`** · Part 2 认证 5 接口 · `/health` · `/admin/shutdown`（限本机）。

**测试自己抓到的两个真 bug**（不是预置的）：
`Directory.create(recursive:true)` 在目录已存在时照样抛异常（会让第二次落盘直接崩）；
副会长被误允许更换注册口令。

### 11.2 本轮文档修订（先改文档再改代码）

| # | 修订 | 文档位置 |
| --- | --- | --- |
| 1 | **部门增删改改为会长独占**（原 §3.8/矩阵写副会长 ✅，与 §3.1/§6.1「DELETE 限会长」冲突） | `api-design` §3.1/§3.8/§6.1/§6.4 · `v1-scope` §3.4.3 |
| 2 | **会长只能由「移交会长」产生**：`assign` 与 `PATCH /members` 拒绝 `role=president` | `api-design` §3.3/§3.4 · `v1-scope` 规则 11 |
| 3 | `Member` 新增 **`dept_hint`** 字段（招募链接的部门预填） | `v1-scope` §5 · `api-design` §3.3 |
| 4 | 密码长度**按字节**校验的口径说明 | `api-design` §2.3 注 5 |
| 5 | `client_token` 幂等的落地范围：注册靠手机号唯一性挡住重复；幂等落在任务/课题创建类接口（M3/M4） | `api-design` §1.9 · `v1-scope` v0.11 说明 |

`v1-scope.md` 顶部修订记录已加 **v0.11**。

### 11.3 下一步

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| M2 | Part 3 组织与成员 19 个接口（含**批量分配**、**会长移交原子性**、最后一个会长保护、注册口令、招募链接） | 待开工 |
| M3 | Part 4 任务 8 个接口 | 待排 |
| M4 | Part 5 课题 6 个接口（环形校验、深度 6、删除上提、O(n) 聚合） | 待排 |
| M5 | 打包部署 · 带 SAN 自签证书 · TLS 关卡 | **卡在服务器步骤 0**（架构 / 公网 IP / 端口） |

### 11.4 仍未决

| # | 事项 | 影响 |
| --- | --- | --- |
| 1 | **服务器步骤 0 未跑** | 卡 M5：需确认架构是否 x64、公网 IP、端口、防火墙+安全组 |
| 2 | 轻舟 DEF-1 上游未修 | 本地补丁顶着；补丁已记录在 `server/build.ps1` 与 `API-NOTES.md` |
| 3 | 工作区原先**不是 git 仓库** | 2026-09-13 已建 GitHub 仓库 `XueDric/open-harmony-club-service` 并上传 |
| 4 | 忘记密码：v1 由会长重置 | 已定 |
| 5 | 服务器可用期限、备份交接人 | 需向老师确认 |
