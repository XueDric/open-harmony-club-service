# 社团管理工具

社团内部管理工具，解决两个问题：**① 社团里有哪些人 ② 每件事由谁负责、做到什么程度。**

首页是「我的任务」，不是组织架构图。名录只是任务的目录——真正让人每天打开 App 的是"我负责什么"。

| 项 | 值 |
| --- | --- |
| 客户端 | 鸿蒙 App（仓颉）—— 见 `entry/`、`AppScope/`。**注意：本仓库里的客户端目前仍只是 DevEco 初始模板**（见下方「未完成」） |
| 服务端 | 仓颉 **1.1.3** + [轻舟 QingZhou](https://gitcode.com/BIT-FSSLab/QingZhou) 框架，Windows 部署 |
| 持久化 | 文件存储（内存 Store + 写时原子落盘 JSON），不用数据库 |
| 传输 | **框架原生 TLS**（不用 Nginx），自签证书必须带 SAN |
| 第一版目标 | 社团内部试用 2 周 |

---

## 当前进度

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| **服务端 M1 骨架** | 构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区 · **`can()` 权限函数** · 认证 5 接口 | ✅ 完成并验证 |
| **服务端 M2 组织与成员** | 部门增删改（会长独占）· 名录/详情/编辑 · 移出社团 · 待分配与**批量分配** · **会长移交（原子）** · 重置密码 · 注册口令 · 招募链接 | ✅ 完成并验证 |
| **服务端 M3 任务** | 我的任务（服务端分组）· 列表筛选 · 详情 · 创建（`client_token` 幂等）· 编辑/转交 · 状态流转与阻塞原因 · 软删除 · 日历同步 `lookup` | ✅ 完成并验证 |
| **服务端 M4 课题** | 课题树（递归进度）· 详情（面包屑）· 创建 · 编辑 · 移动（**环形校验** + 深度 6 + 禁止跨部门）· 删除（**子节点上提，绝不级联**） | ✅ 完成并验证 |
| **服务端 M5 部署** | 带 SAN 自签证书 · TLS 1.2/1.3 通过、1.0/1.1 被拒 · 部署包 18.8 MB · 从部署目录端到端跑通 | 🟡 本机完成；**公网部署待服务器信息** |
| **服务端代码评审修复（第一轮）** | 按 `docs/code-review.md` 修完 3 个 P0 权限漏洞 + 8 个 P1 + 13 个 P2，并补上会真正失败的回归测试 | ✅ 完成并验证 |
| **服务端代码评审（第二轮）** | `docs/code-review.md` 的 9 条新发现：文档类 N-2 / N-3 / N-4 · **N-1**（落地页 HTML 转义）+ **N-9**（CSP）· **N-7**（不可作用于同权/更高权的人，已从"重置密码"推广到改角色 / 禁用 / 改名）· **N-5**（`idem` 补校验）· **N-6**（注册节流改**按客户端 IP + 递增退避**，因此无需新增接口）—— **全部处理完毕**（N-8 按约定不改），每条都补了会因回退而变红的断言 | ✅ 完成并验证 |
| 客户端 | 由小组其他成员推进；**本仓库内仍是 DevEco 初始模板**（`entry/` 未接任何接口） | 进行中 |

**接口进度 39 / 39**（认证 5 · 组织与成员 19 · 任务 8 · 课题 6 = 38 个业务接口，另加运维 `/health` 1 个）。
> 口径说明：早期写「38 / 39」是把 `docs/api-design.md` §6.1「接口总清单（39 个）」里的 `/health` 漏算了。
> 逐条核对后为 **39 / 39**。此外还有一个不在接口清单里的公开页面 `GET /join/{token}`（招募链接落地页）。

**三套测试全部通过**（每次改动都要跑）：

```powershell
cd server
.\build\club-server.exe test                                              # 单测 297 项
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1     # HTTP 冒烟 343 项
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\tls-check.ps1 # TLS 22 项
```

---

## 目录结构

```
README.md                    本文件：唯一入口，看这一个就能了解项目状态
docs/                        所有文档（设计、验证、报告、指南）
server/                      服务端（仓颉）
  build.ps1                  编译（cjc + stdx + 轻舟同包编译）
  build-package.ps1          生成部署包 dist\club-server\（exe + 4 DLL + 证书 + 说明）
  src/                       21 个源文件，按职责分层（见下）
  tests/                     冒烟测试与 TLS 验证脚本
  build/                     构建输出（每次编译重建，不入库）
  dist/                      部署包（含私钥，不入库）
  certs/                     自签证书与私钥（不入库）
cangjie-repro/repro.cj       给仓颉团队的最小复现源码
entry/  AppScope/  hvigor/   鸿蒙客户端工程（DevEco 要求这些在根目录）
docs/                        见下方「文档索引」
```

### 服务端源码分层（`server/src/`）

| 文件 | 职责 |
| --- | --- |
| `main.cj` | 入口：`serve` / `serve-tls` / `init-admin` / `test` + 全部路由注册 |
| `store.cj` | 6 张表的数据模型 + 内存 Store + 原子落盘 + 查询/排序/课题树辅助 |
| **`perms.cj`** | ★ **`can(member, action, target)`——全项目唯一的权限判定点** |
| `auth.cj` | 口令哈希（PBKDF2-HMAC-SHA256）· 令牌 · 认证辅助 |
| `errors.cj` / `jsonw.cj` / `views.cj` | 错误码表 · 响应包装与取参 · 对外 JSON 视图 |
| `timex.cj` / `ids.cj` / `strx.cj` / `paging.cj` / `audit.cj` | 时间与时区 · ID 与随机口令 · 字符串工具 · 分页 · 敏感操作审计 |
| `h_auth.cj` `h_dept.cj` `h_member.cj` `h_secret.cj` `h_link.cj` `h_task.cj` `h_plan.cj` `h_ops.cj` | 各模块的 HTTP handler（按 api-design 的 Part 分组） |
| `tests.cj` | 单测（`club-server.exe test`） |

---

## 5 分钟上手（服务端）

```powershell
cd server

# 1. 编译（并把 4 个依赖 DLL 复制到 build\）
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 2. 到 exe 所在目录操作（与部署形态一致：一切按相对路径）
cd build
.\club-server.exe init-admin 13800000000 你的密码123 data   # 预置首任会长 + 4 个组织
.\club-server.exe serve 8080 data                           # HTTP 起服务
# 或者 HTTPS（先用 openssl 生成带 SAN 的证书，见 docs\server-guide.md）
.\club-server.exe serve-tls 8443 data ..\certs\cert.pem ..\certs\key.pem
```

> **`cwd` 必须是 exe 所在目录**——数据目录与证书都按相对路径读。
> 部署包里的 `start-https.cmd` 已经做了 `cd /d "%~dp0"`。

---

## 文档索引（全部在 `docs/`）

| 文档 | 用途 | 什么时候看 |
| --- | --- | --- |
| **`docs/HANDOFF.md`** | **交接说明**：项目现状、已冻结设计、验证过的技术事实、未决事项 | **接手项目先看这个** |
| `docs/server-guide.md` | 服务端指南：构建/运行/测试、进度、两条实现纪律 | 动服务端代码前看 |
| **`docs/API-NOTES.md`** | 编译期 API 事实清单 + **26 条踩坑记录** | 加新函数前先查（避让框架同名符号） |
| `docs/api-design.md` | **接口设计的唯一权威**：39 个接口逐条定义 | 写服务端时全程对照 |
| **`docs/code-review.md`** | **代码评审报告（两轮）**：第一轮 24 条（3 个 P0 权限漏洞 + 8 个 P1 + 13 个 P2）已全部修复并独立复验；第二轮记录复验证据与 9 条新发现 | 想了解"哪些坑已经踩过" |
| `docs/v1-scope.md` | 范围基准：11 页面、6 张表、19 条业务规则、权限矩阵 | 想知道"这个要不要做" |
| `docs/frontend-brief.md` | 前端对接精简版 | 客户端同事看 |
| `docs/deploy-windows-verify.md` | 部署与验证步骤、目标配置基线 | 部署时看 |
| `docs/qingzhou-tls-requirement.md` | 我们给轻舟团队提的 TLS 需求 | 追溯 TLS 需求来源 |
| `docs/qingzhou-tls-verification.md` | 轻舟 TLS 实测与缺陷清单（DEF-1…5） | 遇到 TLS 问题时看 |
| `docs/cangjie-runtime-startup-crash.md` | 仓颉运行时启动即崩的缺陷报告（已提交上游） | 需要了解那次故障时看 |
| `docs/cangjie-issue-submission.txt` | 提交给仓颉团队的 Issue 稿件存档 | 同上 |
| `cangjie-repro/repro.cj` | 最小可复现源码（零依赖） | 上游要复现代码时给这个 |

---

## 环境事实（本机已验证）

| 项 | 位置 / 值 |
| --- | --- |
| 编译器 | `D:\Cangjie\bin\cjc.exe` —— **1.1.3** (cjnative, x86_64-w64-mingw32) |
| stdx | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` —— **1.1.3.1** |
| 轻舟源码 | `E:\cangjie\qingzhou` —— commit `1cad35b` **+ 本地 2 行补丁（DEF-1）** |
| OpenSSL 3 | `E:\cangjie\qingzhou\deps\openssl\` 下两个 DLL |
| 仓颉运行时 | `D:\Cangjie\runtime\lib\windows_x86_64_cjnative` |
| openssl CLI | `D:\Program Files\Git\usr\bin\openssl.exe`（生成证书、TLS 验证用） |

### 六条最容易踩的坑

1. **4 个 DLL 必须与 exe 同目录**：`libcangjie-runtime.dll`、`libboundscheck.dll`、`libcrypto-3-x64.dll`、`libssl-3-x64.dll`。缺 OpenSSL 两个时**编译期无警告**，运行时才报错。
2. **`cwd` 必须是 exe 所在目录**，否则配置与证书读不到，会出现"假失败 + 假通过"。
3. **同包编译会撞名字**：我们与轻舟同一个 `package qingzhou`，框架已占用 `pad2`、`verifyPassword`、`randomHex`、`bodyStr` 等。加顶层函数前先查 `docs/API-NOTES.md`。
4. **轻舟当前版本编译不过**（DEF-1），本地补丁必须保留；上游修复后要重跑 TLS 关卡。
5. **证书必须带 SAN**：现代客户端完全忽略 CN，只看 `subjectAltName`。按真实公网 IP 重签后再部署。
6. **私钥绝不入库**：`server/certs` 与 `server/dist` 都已在 `.gitignore`；用 `git check-ignore -v <路径>` 自检。

> 完整的 26 条踩坑记录（含 PowerShell 5.1 的六个坑、cjenv 切换 SDK 打断构建等）见 **`docs/API-NOTES.md` 第 3 节**。

---

## 未决事项

| # | 事项 | 卡住什么 |
| --- | --- | --- |
| 1 | **服务器步骤 0 未跑**：架构是否 x64、公网 IP、可用端口、防火墙 + 云安全组 | 卡 M5 的公网部署验证 |
| 2 | 轻舟 DEF-1 上游未修 | 本地补丁顶着；修好后要重新验证 TLS |
| 3 | 给轻舟的需求文档已更正（去掉 Linux 前提） | 需补发一份更正 |
| 4 | 忘记密码：v1 由会长重置，不做自助找回 | 已定 |
| 5 | 服务器可用期限、备份交接人（至少两人） | 需向老师确认 |
| 6 | 鸿蒙侧载分发（AGC 内部测试轨道、签名证书） | 流程耗时可能超过开发本身，**建议尽早启动** |
| 7 | **客户端仍是 DevEco 初始模板**：`entry/` 未接任何接口，`bundleName` 与首页占位文案还是模板值 | 客户端同学开工前要先替换；发布前必须确认已改 |

---

## 设计原则（违反会导致返工）

| 原则 | 具体体现 |
| --- | --- |
| **同一事实只存一份** | 删了 `Department.lead_id`；课题不设 status；逾期不设状态；`Plan.dept_id` 只在顶层 |
| **能从事实推导的就不存** | 逾期由 `due_at` 算；课题进度由整棵子树的任务聚合 |
| **绝不级联删除** | 删课题子节点上提；任务软删除 |
| **权限判定收敛到一个函数** | `can(member, action, target)`；**禁止在每个 handler 里手写 if** |
| **服务端权威** | `updated_at`、逾期、分组、`is_overdue` 全部服务端生成 |
