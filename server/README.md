# 社团管理工具 · 服务端

> 仓颉 1.1.3 + [轻舟 QingZhou](https://gitcode.com/BIT-FSSLab/QingZhou) · 文件存储 · Windows 部署
> 接口权威：`../api-design.md`（39 个接口）· 范围权威：`../v1-scope.md`

## 这个服务端解决什么

第 1 节的两个问题：**① 社团里有哪些人 ② 每件事由谁负责、做到什么程度**。

首页接口是 `GET /tasks/mine`（我的任务），不是组织架构图。

---

## 快速开始

```powershell
# 1. 编译（并复制 4 个依赖 DLL 到 build\）
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 2. 到 exe 所在目录操作（与部署形态一致：一切按相对路径）
cd build

# 3. 初始化首任会长（同时预置 4 个组织与一个随机注册口令）
.\club-server.exe init-admin 13800000000 你的密码123 data

# 4. 起服务
.\club-server.exe serve 8080 data
```

> ⚠️ **`cwd` 必须是 exe 所在目录**（数据目录与证书按相对路径读）。部署时同理。
> 数据落在 `build\data\db.json`。

### 命令行

| 命令 | 说明 |
| --- | --- |
| `club-server serve [端口] [数据目录]` | 启动服务（默认 `8080` / `data`） |
| `club-server init-admin <手机号> <初始密码> [数据目录]` | 预置首任会长 + 4 个组织（仅空库可执行） |
| `club-server test` | 运行单测 |
| `POST /admin/shutdown` | 优雅关闭（**仅本机可访问**；Windows 无信号机制） |

---

## 当前进度

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **M1 骨架** | 构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区 · `can()` 权限函数 · 认证 5 接口 · `/health` · 单测 + 冒烟测试 | ✅ **已完成** |
| **M2 组织与成员** | Part 3 的 **19 个接口**：部门增删改（会长独占）· 成员名录/详情/编辑 · 移出社团 · 待分配与**批量分配** · **会长移交（原子）** · 重置密码 · 注册口令 · 招募链接 | ✅ **已完成** |
| **M3 任务** | Part 4 的 **8 个接口**：我的任务（服务端分组）· 列表筛选 · 详情 · 创建（含 `client_token` 幂等）· 编辑/转交 · 状态流转与阻塞原因 · 软删除 · 日历同步 `lookup` | ⚠️ **代码完成、编译通过；运行验证被本机环境阻塞**（见 `API-NOTES.md` §5） |
| M4 | Part 5 课题（6 个接口） | 待排 |
| M5 | 打包部署 · 自签证书（带 SAN）· TLS 关卡 | 待排 |

**接口进度：32 / 39**（认证 5 + 组织与成员 19 + 任务 8；M3 待环境恢复后跑验证）。

---

## 代码结构

```
server/
  build.ps1               构建脚本（cjc + stdx + 轻舟同包编译）
  src/
    main.cj               入口：serve / init-admin / test + 全部路由注册
    store.cj              6 张表的数据模型 + 内存 Store + 原子落盘 + 查询/排序辅助
    errors.cj             错误码表（api-design §1.3 的代码化）
    jsonw.cj              响应包装 {ok,data}/{ok,error} + 取参 + 字段校验器
    views.cj              对外 JSON 视图（MemberBrief、部门、待分配、链接、注册配置）
    perms.cj              ★ can(member, action, target) —— 全项目唯一权限判定点
    auth.cj               口令哈希（PBKDF2-HMAC-SHA256）、令牌、认证辅助
    timex.cj              时间与时区（ISO8601 +08:00、逾期判定、历法换算）
    ids.cj                ID / 令牌 / 易读口令
    strx.cj               字节级字符串工具
    paging.cj             分页与 query 取参（page/size，pathId）
    audit.cj              敏感操作审计日志（重置密码、换口令、删除部门…）
    h_auth.cj             Part 2 认证（5）
    h_dept.cj             Part 3.1 部门（4）
    h_member.cj           Part 3.2–3.4 名录/授权/会长移交（8）
    h_secret.cj           Part 3.5–3.6 重置密码与注册配置（4）
    h_link.cj             Part 3.7 招募链接（3）
    h_ops.cj              健康检查、本机判定
    tests.cj              单测（main.exe test）
  tests/smoke.ps1         冒烟测试（打真实 HTTP）
  API-NOTES.md            ★ 编译期 API 事实清单与踩坑记录
```

---

## 测试

```powershell
# 单测：时间/历法、口令哈希、权限矩阵、落盘往返、视图与分页（164 项）
.\build\club-server.exe test

# 冒烟测试：真实 HTTP、状态码、错误码、令牌流转、权限边界、重启持久性（165 项）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
```

两者互补：单测覆盖纯逻辑（脱离 HTTP），冒烟测试覆盖接口层行为。
冒烟测试用独立数据目录 `build\smoke-data`，**不会碰正式数据**。

---

## 设计约定（改代码前先读）

HANDOFF §5 的五条原则在这里的落点：

| 原则 | 落点 |
| --- | --- |
| **同一事实只存一份** | 口令拆成 `pw_salt/pw_hash/pw_iter` 字段，不存复合字符串；`Plan.dept_id` 只顶层 |
| **能推导的就不存** | 逾期由 `due_at` 算（`isOverdue`）；课题进度由任务聚合（M4） |
| **绝不级联删除** | 任务软删除 `deleted_at`；删课题子节点上提（M4） |
| **权限收敛到一个函数** | `perms.cj` 的 `checkAccess` / `requireAccess`；**禁止在 handler 里手写权限 if** |
| **服务端权威** | `updated_at`、逾期、分组、`is_overdue` 全部服务端生成 |

### 两条实现纪律

1. **锁纪律**：`requireMember` / `requireActive` **内部会加 `s.lock`**，调用它们时绝不能已持有该锁
   （Mutex 不可重入，会死锁）。handler 的统一形状是：**先认证拿 Member，再单独加锁做修改**。
2. **空值约定**：`Int64` 用 `0` 表示"无"（`parent_id=0` 顶层、`plan_id=0` 独立、时间 `0` 为 null）。
   1970 年不会成为真实业务值。

---

## 已知待确认项

见 `../HANDOFF.md` §7 与本次 M1 报告；其中一项是**文档内部冲突**：

- `api-design.md` §3.1 / §6.1 写 `DELETE /depts/{id}` **限会长**，§3.8 汇总表写「部门增删改 ✅✅（含副会长）」。
  当前实现按**更严格**的一侧（会长独占），代码里已标注待确认。
