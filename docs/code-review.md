# 代码检查报告 · 社团管理工具

> 检查对象：本仓库全部手写源码（服务端 `server/`、客户端 `entry/`、构建配置）
> 检查方式：静态阅读 + 本机实跑复现（**所有"实测"结论都在本机跑过，不是推断**）
> 检查结论：**未修改任何源文件**，`git status` 全程干净

---

## 一、检查范围与方法

| 范围 | 内容 |
| --- | --- |
| 服务端 | `server/src/` 21 个仓颉文件（约 5.2k 行）+ `server/tests/` 两个 PS 脚本 |
| 客户端 | `entry/src/`、`AppScope/`、`build-profile.json5`、`cjpm.toml`、`oh-package.json5` |
| 框架侧 | `E:\cangjie\qingzhou\src`（与轻舟**同包编译**，中间件语义直接决定本项目行为，因此必须读） |
| 基线实测 | `club-server.exe test` → **PASS 233 / FAIL 0**；`tests/smoke.ps1` → **PASS 280 / FAIL 0** |
| 缺陷复现 | 另起 6 轮独立实例（独立数据目录 / 独立端口），逐一复现下表结论 |
| 其它验证 | 用 `cjc` 编译探针验证 `std.random` 播种；查轻舟 `compose.cj`/`router.cj`/`timeout.cj`/`cors.cj` 语义 |

**基线是可信的**：README 声明的 233 项单测与 280 项冒烟确实全绿。但本报告 P0 级缺陷**就在这套全绿测试的覆盖之下**——第 H-1 条尤其如此（测试写了断言，却因为数据摆错位置而假通过）。这是本次检查最值得注意的一点。

### 本次检查发现的缺陷分布

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| P0 高 | 3 | 权限可绕过 / 越权读数据，导致账号接管或跨部门越界 |
| P1 中 | 8 | 数据失真、可被爆破、可被持久化打挂、测试假绿灯 |
| P2 低 | 13 | 一致性、健壮性、文档与客户端工程 |
| 已排除 | 4 | 有正向证据的怀疑（见第五节） |

---

## 二、修复进度总表

> 修完一条把 `[ ]` 改成 `[x]`，并在「状态」处补一句结论。
>
> **2026-09-14 修复完成**：24 条全部处理（23 条改代码 + 1 条仅记录）。
> 回归证据：单测 **273 / 0**（原 233）、HTTP 冒烟 **325 / 0**（原 280）、TLS **22 / 0**。
> 新增的断言都是**会真的失败**的那种——H-1 的用例特意把部长放到会长所在部门，
> 这样 403 只能来自角色维度，不会再被 `FORBIDDEN_NOT_IN_DEPT` 顶替成假绿灯。

- [x] H-1 部长可接管会长账号（权限提升） —— `perms.cj` 加 `roleRank`/`outranks`，部长/副部长只能动**档位更低**的人；测试补同部门会长/副会长目标
- [x] H-2 幂等重放绕过权限判定（越权读） —— 幂等键改为 `(kind, actorId, token)`，命中回放前再按本次操作者判一次读权限
- [x] H-3 部长可把课题移出本部门 —— 提升为顶层那条路补判目标部门权限 + 跨部门一致性检查
- [x] M-1 `PATCH /plans/{id}` 返回假进度 —— 新增 `planStatsOf()`，详情/创建/编辑/回放四处统一取真实聚合值
- [x] M-2 注册口令可无限爆破 —— 下限 4→6 位；注册失败全局节流（15 分钟错 10 次锁 15 分钟）
- [x] M-3 `login_fail` 无界增长 + 每次失败全库落盘 —— 失败不再落盘（改为纯内存短时效状态）、加手机号形态校验、超 500 条清理过期项
- [x] M-4 已移出社团的成员被静默复活并可升职 —— 采用报告建议 3：行为保留（文档写明可恢复），审计按 `restore-member` 单独记账并在 `api-design` 成文
- [x] M-5 `timeout(15000)` 中间件实际不生效 —— 移到 `router.middleware()` **之前**（外层），并注明它只能事后软超时
- [x] M-6 时间格式不接受小数秒（与标准客户端不兼容） —— `parseIso` 接受并截断小数秒；正反用例各 4 条
- [x] M-7 `storeLoad` 逐行静默丢弃坏数据 —— 装载后逐表比对条数，不等则拒绝启动（与文件级解析失败同口径）
- [x] M-8 未校验的 `sort` 溢出，可持久化打挂 `GET /depts` —— 写入侧校验 `0..10000`，读取侧 `sortKeyClamp` 兜底旧数据
- [x] L-1 `permissions.set_role` 与真实权限不符 —— 改为从 `can()` 推导（副会长也返回 true）
- [x] L-2 `/join/{token}` 无落地页（招募链接是死链） —— 新增公开落地页路由（只暴露部门名）；Host 头污染作为已知取舍记录在案
- [x] L-3 `DELETE /dept-invite-links/{token}` 同一接口两种响应形状 —— 不存在时也返回完整视图（token 回显、enabled=false）
- [x] L-4 `ResetPassword` self 分支死代码 + 文档三处矛盾 —— 删除死分支；口径统一为「管理员救济动作，不含本人」并同步 `api-design` §3.5/§3.8 与 `v1-scope` §3.4.3
- [x] L-5 无效日历日期被静默顺延 —— 加 `daysInMonth`/`isLeapYear`，`2026-02-30`、平年 `02-29` 一律 400
- [x] L-6 摘要比对与口令比对缺少常数时间实现 —— 新增 `constantTimeEq`，用于口令摘要与注册口令比对
- [x] L-7 全局锁横跨网络写出 —— v1 保持现状（换取"200 即已落盘"的强语义），在 `storeSave` 写明取舍与 v2 方向
- [x] L-8 `MEMBER_PENDING` 被复用于 `disabled` 目标 —— 任务创建/转交、课题创建/编辑四条路径拆成 `MEMBER_PENDING` / `MEMBER_DISABLED`
- [x] L-9 审计日志可注入换行/制表符 —— 在 `audit()` 写入口统一清洗 CR/LF/TAB 与控制字符
- [x] L-10 排序键的隐含前提与 guard 不一致 —— `views.cj` 的 `planPath` 改用 `PLAN_WALK_GUARD`
- [x] L-11 README 接口计数 `38 / 39` 口径 —— 更正为 **39 / 39** 并写明口径（38 业务接口 + `/health`）
- [x] L-12 客户端实为未改动的 DevEco 模板 —— README 顶部、进度表、未决事项三处如实说明；发布前清单加一条
- [x] L-13 `freshLinkToken` 仅 32 bit（记录备查） —— **不改**，按报告结论保留记录（链接不免除注册口令，不构成凭证风险）

### 修复中额外发现并处理的问题（报告未列）

| # | 问题 | 处理 |
| --- | --- | --- |
| 1 | **L-8 不止报告列的两处**：`PATCH /plans/{id}` 换负责人那条路径也把 `disabled` 报成 `MEMBER_PENDING`（`h_plan.cj` 的 owner 分支） | 一并拆成两个错误码，现在四条路径（任务创建/转交、课题创建/编辑）口径一致 |
| 2 | **M-1 不止 `PATCH`**：`POST /plans` 的**创建响应**与**幂等回放**也都传了 `None`，同样是 `total:0/done:0` | 统一走 `planStatsOf()`，凡是返回课题对象的地方都取真实聚合值 |
| 3 | 局部编辑 `tests/smoke.ps1` 会**丢掉 UTF-8 BOM**：PS 5.1 按 ANSI 读取，整个脚本变乱码并报"意外的标记" | 编辑后必须确认 BOM 仍在；已在 `docs/API-NOTES.md` 记录（这类故障看起来像脚本写错了，实际是编码问题） |

---

## 三、P0 · 高危

### H-1 部长可接管会长账号（权限提升）

**状态**：已修（2026-09-14）。`perms.cj` 新增 `roleRank` / `outranks`：部长与副部长只能作用于**档位低于自己**的成员；`smoke.ps1` 补同部门会长/副会长目标的用例（403 只能来自角色维度）。
oleRank / outranks，部长与副部长只能作用于**档位低于自己**的成员；smoke.ps1 补同部门会长/副会长目标的用例（403 只能来自角色维度）。

**现象**：`docs/v1-scope.md:152` 与 `docs/api-design.md:844` 都把「不能改动会长本人」写成硬约束，但这条约束只在**副会长**这一档实现了。会长所在部门（主席团）的**部长/副部长**可以改会长姓名、重置会长密码，并用返回的临时密码登录会长账号，拿到 `view_scope=all / set_role=true` 的完整权限。

**证据**

- `perms.cj:84-87` —— 只有 `vice_president` 分支带会长保护：
  ```cangjie
  if (role == "vice_president") {
      case EditMemberName => return t.target_role != "president"   // 有保护
      case ResetPassword  => return t.target_role != "president"   // 有保护
  ```
- `perms.cj:91-107` —— `lead / vice_lead` 分支按动作白名单放行，**没有任何 `target_role` 判定**：
  ```cangjie
  if (role == "lead" || role == "vice_lead") {
      match (a) {
          case EditMemberName => return true      // ← 对会长本人也 true
          case ResetPassword  => return true      // ← 对会长本人也 true
  ```
- `perms.cj:121-160` —— `scopeAllows` 只要求同部门（`t.dept_id == m.dept_id`），会长与主席团部长同部门，条件成立。
- `h_secret.cj:20-46`（重置密码）、`h_member.cj:134-214`（改姓名）都只调 `requireAccess`，无额外保护。

**实测**（会长 id=1 / 部门=主席团；把部长也分配到主席团）

```
1) 改会长姓名        -> HTTP 200
2) 重置会长密码      -> HTTP 200   临时密码 = 7TGTVEAC
3) 用临时密码登录会长 -> HTTP 200   身份=会长 role=president
                                    权限={"view_scope":"all","manage_members":true,
                                          "set_role":true,"create_plan":true,
                                          "create_task":true,"update_any_task":true}
```

**测试为何没拦住（重点）**

`smoke.ps1:481-482` 确实写了这条断言：

```powershell
$r = Call-Api "POST" "/api/v1/members/$presId/reset-password" $null $leadToken
Check "部长重置会长密码 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
```

但 `smoke.ps1:345` 把该部长分配到 `$deptOps`（运营部），而会长在主席团。**403 来自 `FORBIDDEN_NOT_IN_DEPT`（部门不匹配），不是来自"会长受保护"**。断言通过，漏洞留存 —— 这是一个典型的"通过理由错了"的假绿灯用例。

**影响**：最低一级管理员即可完全接管最高权限账号；拿到会长令牌后可改部门、移交会长、重置任何人。设计文档中"系统必须始终保留至少一位会长"（规则 10）与"不能改动会长本人"的意图被实质绕过。

**建议修法**

1. `perms.cj` 的 `lead / vice_lead` 分支补上同款守卫，并考虑更一般的规则（不能作用于同档或更高档）：
   ```cangjie
   case EditMemberName => return t.target_role != "president"
   case ResetPassword  => return t.target_role != "president"
   ```
2. `smoke.ps1` 增加一条专门的"同部门"用例：把部长分配到**会长所在部门**再断言 403；现有那条保留（它覆盖的是另一个维度）。
3. `tests.cj` 的 `testPerms` 补 `can(lead, Action.ResetPassword, presTarget) == false` 的纯逻辑断言（`presTarget` 已存在，`tests.cj:325-328`）。

---

### H-2 幂等重放绕过权限判定（越权读）

**状态**：已修（2026-09-14）。幂等键改为 `(kind, actorId, token)`，且命中回放前按**本次操作者**重判一次读权限；单测与冒烟各补一条跨用户重放。

**现象**：`client_token` 幂等命中后，代码在**未做任何权限判定**的情况下直接返回该资源详情。命中记录是全局的（不含操作者维度），因此换个用户拿着同一个 token 重放，就能读到别人的任务/课题。

**证据**

- `h_task.cj:250-264` —— `idemHit` 在 `requireAccess`（在 `h_task.cj:281`）**之前**，命中即 `sendOk` 并 `return`：
  ```cangjie
  if (clientToken.size > 0) {
      match (idemHit(s, "task", clientToken, now)) {
          case Some(rid) =>
              match (activeTaskById(s, rid)) {
                  case Some(existing) =>
                      jPutObj(data, "task", taskDetail(s, existing, now))  // ← 无权限判定
                      sendOk(ctx, data)
                      return
  ```
- `h_plan.cj:159-173` —— 完全同构，`requireAccess` 在 `h_plan.cj:216`。
- `store.cj:830-832` —— 幂等键是 `"${kind}:${token}"`，**不含 actor id**。

**实测**（会长的 `client_token` 被 dept2 的一个普通成员重放）

```
dept2 成员 POST /tasks/lookup {task_ids:[1]}      -> {"items":[],"missing":[1]}   ← 正常看不到
dept2 成员用会长的 client_token 再 POST /tasks     -> HTTP 200  duplicated:true
body = {"task":{"id":3,"title":"SECRET-dept1-task",
                "owner":{"id":1,"name":"会长","role":"president","dept":{"id":1,...}},
                "dept":{"id":1,"name":"主席团"}, ... }}
```

**影响**：跨部门越权读取任务/课题全文（含负责人、部门、描述）。利用前提是 `client_token` 可猜——移动端常见做法是用时间戳、自增序号或固定字符串，风险不低。

**建议修法**：命中后先取到资源，**再对该资源调用 `requireAccess`**，不通过则按"未命中"处理（创建新资源）或直接 403：

```cangjie
case Some(existing) =>
    requireAccess(actor, Action.ViewTasks, targetOfTask(actor, existing))
    ...
```

课题同理用 `Action.ViewTasks` + `targetOfPlan`。另可考虑把幂等键加上 `actor.id`（`idemKey` 加一维），但这只解决同人重放，不能替代权限判定。

**补充测试**：`smoke.ps1` 第 15 节的幂等用例目前只有"同人重复提交"，建议补"换人重放"。

---

### H-3 部长可把课题移出本部门

**状态**：已修（2026-09-14）。提升为顶层那条路补判目标部门权限，并与换父节点那条路统一「禁止跨部门」。

**现象**：`POST /plans/{id}/move` 的「挂到新父节点」分支对目标部门做了权限判定，但「提升为顶层」分支拿到 `bodyDept` 后**直接赋值**，没有再判一次权限 —— 部长因此可以把本部门课题搬到任意部门，而且之后再也移不回来。

**证据**

- `h_plan.cj:362-371` —— 挂到新父节点时有目标部门判定 + 跨部门禁止：
  ```cangjie
  let newDept = planDeptOf(s, newParent)
  let tgt2 = Target()
  tgt2.dept_id = newDept
  requireAccess(actor, Action.MovePlan, tgt2)          // ← 有判定
  if (newDept != curDept) { throw ... "v1 不允许跨部门移动课题" }
  ```
- `h_plan.cj:377-393` —— 提升为顶层分支**没有对应判定**：
  ```cangjie
  } else {
      var d = curDept
      if (bodyDept > 0) { d = bodyDept }               // ← 直接采用调用方给的部门
      match (s.departments.get(d)) { ... }              // ← 只判"部门存在"
      p.parent_id = 0
      p.dept_id = d                                     // ← 写入，无权限判定
  }
  ```

**实测**（部长 dept=1）

```
POST /plans/{子课题}/move {new_parent_id: null, dept_id: 2}  -> HTTP 200
结果: parent_id=0  dept={"id":2,"name":"课题部"}
POST /plans/{同一课题}/move {new_parent_id: null, dept_id: 1} -> HTTP 403   ← 已被踢出自己的范围
```

**影响**

1. 部门边界可被部长单方面打破，与「v1 不允许跨部门移动课题」的既定决策直接冲突。
2. 副作用：整棵子树换了部门，但子树内任务的 `dept_id` 仍跟随原负责人（`h_task.cj:297` 建任务时定死），造成 `Plan` 与 `Task` 的部门口径不一致。
3. 自锁：移出后部长对自己搬走的课题失去全部管理权。

**建议修法**：提升为顶层时对最终 `d` 再调一次权限判定，并与移动分支保持同一口径：

```cangjie
let tgt3 = Target()
tgt3.dept_id = d
requireAccess(actor, Action.MovePlan, tgt3)
if (d != curDept) { throw apiErrMsg("VALIDATION_FAILED", "v1 不允许跨部门移动课题（部门由根课题决定）") }
```

**补充测试**：`smoke.ps1:785` 只覆盖了「提升为顶层 + 传入**同一个**部门」，正好漏掉这条路径。

---

## 四、P1 · 中危

### M-1 `PATCH /plans/{id}` 返回假进度

**状态**：已修（2026-09-14）。新增 `planStatsOf()`，详情/创建/编辑/幂等回放四处统一取真实聚合值（比报告多修两处，见第二节补充表）。

**现象**：编辑课题（哪怕只改个名字）后，响应里的 `progress`、`task_count`、`child_count` 全部归零，与真实值不符。客户端拿这个响应刷新界面就会把进度画成 0%。

**证据**

- `h_plan.cj:308` —— `planDetailView(s, p, None)`：第三个参数传了 `None`
- `h_plan.cj:165` —— 幂等重放分支同样传 `None`
- `h_plan.cj:237` —— 创建分支传 `None`（新建时恰好正确，但属于"碰巧对"）
- `views.cj:353-362` —— `st == None` 分支硬编码 0：
  ```cangjie
  case None =>
      if (includeProgress) {
          let pr = JsonObject()
          jPutInt(pr, "done", 0)      // ← 恒为 0
          jPutInt(pr, "total", 0)     // ← 恒为 0
          jPutObj(o, "progress", pr)
      }
      jPutInt(o, "task_count", 0)
      jPutInt(o, "child_count", 0)
  ```

**实测**（该课题下 2 个任务、其中 1 个已完成、1 个子课题）

```
GET   /api/v1/plans/1  -> 200  progress={"done":1,"total":2}  task_count=2  child_count=1
PATCH /api/v1/plans/1  -> 200  progress={"done":0,"total":0}  task_count=0  child_count=0
```

**影响**：`PATCH /plans/{id}` 是"课题详情页改名"的必经路径，前端会拿到错误数据。属于接口契约层面的错误，不是显示瑕疵。

**建议修法**：`handlePlanUpdate` 的响应改成先算真实统计再传：

```cangjie
let sub = HashSet<Int64>()
planSubtreeInto(s, id, sub)
let stats = planStatsAll(s, sub)
jPutObj(data, "plan", planDetailView(s, p, stats.get(id)))
```

`h_plan.cj:165`（幂等重放）同样处理。创建分支（新建课题必然为 0）可以保留，但建议加注释说明"此处 0 是事实而非占位"，避免后人误改。

**补充测试**：`smoke.ps1:793-796` 只断言了 `title`/`desc`，没有断言 `progress` —— 建议补一条。

---

### M-2 注册口令可无限次爆破

**状态**：已修（2026-09-14）。下限 4→6 位，并给注册失败加全局节流（15 分钟错 10 次锁 15 分钟，状态只在内存）。

**现象**：登录接口有失败锁定（`h_auth.cj:103-138`），注册接口**没有任何节流**：口令错就报 400，不计数、不延迟、不锁定。而口令最短允许 4 位。

**证据**

- `h_auth.cj:56-61` —— 只做等值比较，错误直接抛：
  ```cangjie
  if (rc != s.register_code) {
      throw apiErr("REGISTER_CODE_INVALID")
  }
  ```
- `h_secret.cj:71` —— 允许最短 4 位：`v.check("code", code.size >= 4, "注册口令至少 4 位")`
- `ids.cj:61` —— 字母表 26 个字符：`"ACDEFGHJKLMNPQRTUVWXY34679"`
- 对照：`h_auth.cj:128-136` 登录失败有 `login_fail` 计数与 900 秒锁定

**实测**

```
连续 12 次错误注册口令 -> 全部 HTTP 400 REGISTER_CODE_INVALID，无 429、无锁定
```

**影响**：4 位口令空间 = 26⁴ ≈ 45.7 万；按每秒几十次估算，几小时可穷举（默认 6 位则安全得多，但**下限是 4**）。爆破成功后攻击者可以让任意人注册进社团（仍需会长审批才能获得权限，但已可污染待分配列表、占用手机号）。

**建议修法**：任一即可，建议前两条都做

1. 把 `h_secret.cj:71` 的下限从 4 提到 6（与 `newRegisterCode()` 的默认长度一致）。
2. 复用 `login_fail` 机制对"注册口令错误"按来源 IP 或全局计数 + 锁定（`TOO_MANY_ATTEMPTS` 错误码与 429 状态码在 `errors.cj:92-94` 已存在，可直接用）。
3. 比较改为常数时间实现（见 L-6）。

---

### M-3 `login_fail` 无界增长 + 每次失败全库落盘

**状态**：已修（2026-09-14）。失败路径不再落盘、加手机号形态校验、超阈值清理过期项。

**现象**：登录失败时，即使手机号**根本不存在**，也会新建一条 `login_fail` 记录并触发一次**整库落盘**。这张表没有任何清理逻辑，也不校验手机号格式，因此可以用任意字符串堆满内存、并持续放大磁盘写入。

**证据**

- `h_auth.cj:106` —— 直接用原始 `phone` 字符串取表（可能不存在）：
  ```cangjie
  var lf = s.login_fail.get(phone) ?? LoginFail()
  ```
- `h_auth.cj:99-101` —— `handleLogin` **只做非空校验，不做 `isPhone` 校验**（对照 `handleRegister` 在 `h_auth.cj:44-46` 做了）：
  ```cangjie
  let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
  ```
- `h_auth.cj:128-136` —— 无论手机号是否存在都会写表 + `storeSave`：
  ```cangjie
  if (bad) {
      lf.count += 1
      ...
      s.login_fail[phone] = lf
      storeSave(s)            // ← 全库落盘
  ```
- `store.cj:591-600` —— `storeSave` 会把整张 `login_fail` 表序列化进 `db.json`
- 对照：`store.cj:853-864` 的 `idemPut` 有"超过 200 条就清理过期项"的逻辑，`login_fail` **没有对应机制**

**实测**

```
30 次「不存在的手机号 + 错误密码」登录
-> db.json 中 login_fail 条目数 = 30
```

**影响**

1. 内存与 `db.json` 无界增长（攻击者可用随机字符串做键）。
2. 每条失败请求都触发一次**全库读写**（`store.cj:608-619`：序列化 + 写 tmp + 复制 .bak + rename），磁盘放大明显；且这些都发生在 `s.lock` 内，会阻塞所有其他请求。

**建议修法**

1. `handleLogin` 补 `isPhone(phone)` 校验（格式不对直接 400，不必进失败计数）。
2. 只对**已存在的手机号**累计失败次数（不存在直接返回 `AUTH_BAD_CREDENTIALS`，不落表；这也不破坏"不泄露号码是否注册过"的性质）。
3. 给 `login_fail` 加清理：在 `storeSave` 前或定期清理 `locked_until` 已过期且 `first_at` 超窗口的条目（可照抄 `idemPut` 的写法，`store.cj:853-864`）。

---

### M-4 已移出社团的成员被静默复活并可升职

**状态**：已处理（2026-09-14），采用报告建议 3。行为保留（文档写明可恢复），但审计按 `restore-member` 与普通 `assign-member` 分开记账，并在 `api-design` §3.3 成文；若日后要做独立恢复入口（建议 2），属接口清单的范围扩展，需先确认。
estore-member 与普通 ssign-member 分开记账，并在 pi-design §3.3 成文；若日后要做独立恢复入口（建议 2），属接口清单的范围扩展，需先确认。

**现象**：`POST /members/{id}/assign` 与 `/members/assign-batch` 无条件把目标置为 `active`。对**已被移出社团（`disabled`）**的成员再调一次 assign，会把账号静默复活，甚至可以顺便提升为部长。

**证据**

- `h_member.cj:286-289`（单条）：
  ```cangjie
  tgt.dept_id = deptId
  tgt.role = role
  tgt.status = "active"     // ← 无条件，不看原 status
  tgt.dept_hint = 0
  ```
- `h_member.cj:356-360`（批量）同样无条件。
- 对照：`h_member.cj:172-174` 的 `PATCH /members/{id}` 明确拒绝待分配成员走这条路（"那属于 assign 的职责"），但 `assign` 自己既不看 `pending` 也不看 `disabled`。

**实测**

```
assign  -> status=active
disable -> HTTP 200, status=disabled      ← 已移出社团
再 assign {role: lead}  -> HTTP 200
结果 status=active  role=lead             ← 被静默复活并升为部长
assign-batch 同样 -> HTTP 200 {"succeeded":[2],"failed":[]}
```

**影响**：`api-design.md` 说移出社团"账号与历史记录全部保留，日后可恢复"，所以"能恢复"可能是预期内的；但**当前实现把恢复与普通分配混成同一个语义**：没有专门的恢复接口、没有额外确认、审计日志也只记成普通的 `assign-member`（`h_member.cj:291`）。批量接口还能一次复活多人。这属于"设计未拍板、实现先跑"的空白区。

**建议修法**（三选一，需产品决策）

1. **拒绝**：目标 `status == "disabled"` 时返回专用错误码（需在 `errors.cj` 新增，如 `MEMBER_DISABLED_CANNOT_ASSIGN`）。
2. **显式恢复**：新增独立语义（如请求体带 `restore: true`），并写独立的审计动作名。
3. **保持现状但补全**：至少在审计日志里区分"复活"与"分配"，并在 `api-design.md` 写明该行为。

无论选哪个，`smoke.ps1` 都应补一条 `disabled -> assign` 的用例把语义钉住。

---

### M-5 `timeout(15000)` 中间件实际不生效

**状态**：已修（2026-09-14）。移到 `router.middleware()` **之前**（外层）才会真正执行；注释同时写明它只能事后软超时、无法中断 handler。
outer.middleware() **之前**（外层）才会真正执行；注释同时写明它只能事后软超时、无法中断 handler。

**现象**：`main.cj:308` 注册了 15 秒超时，但它排在 `router.middleware()` **之后**，而本项目的所有路由 handler 都忽略 `next` 参数。洋葱模型需要 handler 调用 `next()` 才能走到后续中间件，因此**匹配到路由的请求永远不会执行 timeout 逻辑**。

**证据**

- `main.cj:302-309` —— 注册顺序：
  ```cangjie
  return QingZhouApp()
      .use(requestId())
      .use(logger())
      .use(bodyParser())
      .use(cors())
      .use(router.middleware())     // ← 索引 4
      .use(timeout(15000))          // ← 索引 5，永远到不了
      .onError(errHandler)
  ```
- 轻舟 `compose.cj:36-42` —— 按 `index` 顺序推进，只有当前中间件调 `next()` 才会推进：
  ```cangjie
  func next(): Unit {
      index += 1
      if (index < stack.size) {
          let mw = stack[index]
          mw(ctx, { => this.next() })
      }
  }
  ```
- 轻舟 `router.cj:151-156` —— 命中路由时把 `next` 透传给 handler：`case DispatchResult.Matched(h) => h(ctx, next)`
- `main.cj:160-165` 等所有路由注册都形如 `{ ctx: Context, _: () -> Unit => handleHealth(ctx) }` —— 第二个参数被丢弃，`next` 从不调用。

**影响**：这是一个**看起来有、实际没有**的保护。当前所有 handler 都是内存操作，慢不到 15 秒；但一旦未来加导出、批量落盘或数据量增长，缺的这道闸门不会有任何提示。同时它也会误导后续维护者（"我们有超时保护"）。

**建议修法**（二选一）

1. 把 `timeout(15000)` 移到 `router.middleware()` **之前**（索引 4 之前），并按 `timeout.cj:69-82` 的语义理解它只是"事后注释 + 未响应时兜底 408"，不是真正的中断。
2. 若确实需要中断能力，轻舟当前同步模型下做不到（`timeout.cj:12-31` 已说明需要 Future/Promise），那就**删掉这行**，避免虚假安全感；改为在文档中记录"无超时保护"。

推荐第 1 条（改动一行，至少让慢请求被标记 `x-timeout-ms`）。

---

### M-6 时间格式不接受小数秒，与标准客户端不兼容

**状态**：已修（2026-09-14）。`parseIso` 接受小数秒并截断到秒；正反用例 4 条。

**现象**：`parseIso` 不接受带毫秒的 ISO 8601。而 ArkTS/JS 里最自然的 `new Date().toISOString()` 输出形如 `2026-09-14T15:24:08.307Z`，会被直接判为 `VALIDATION_FAILED`。

**证据**

- `timex.cj:179-197` —— 解析完 `hh:mm:ss` 后 `pos = 19`
- `timex.cj:200-221` —— `pos < b.size` 时只接受 `Z`(90)、`+`(43)、`-`(45)，其它一律 `None`：
  ```cangjie
  } else {
      return None          // ← '.'（46）落在这里
  }
  ```
- `timex.cj:143` —— 调用方把 `None` 转成 `VALIDATION_FAILED`

**实测**（`PATCH /tasks/{id}` 的 `due_at`）

```
2026-09-14T15:24:08.307Z   -> HTTP 400     ← new Date().toISOString() 的原样输出
2026-09-14T15:24:08Z       -> HTTP 200
```

**测试为何没拦住**：`smoke.ps1:554` 用的正是无毫秒格式：

```powershell
$pastDue = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:sszzz")
```

于是"服务端只认自己习惯的格式"这件事从未被检验。

**影响**：客户端只要用标准 API 生成时间就会 400，且错误信息是逐字段的"时间格式不正确"，排查成本不低。`due_at` 是任务的核心字段。

**建议修法**

1. `timex.cj:200` 前先跳过可选的小数部分：`if (b[pos] == 46) { pos += 1; while (pos < b.size && b[pos] >= 48 && b[pos] <= 57) { pos += 1 } }`（毫秒精度对本工具足够，可直接截断）。
2. 顺带放宽 `timex.cj:196` 后对 `pos` 的处理，保留"结尾必须正好用完"的严格性。
3. `tests.cj:testTime` 补一组带小数秒的向量（`.307Z`、`.5+08:00`、`.123456Z`）。
4. `smoke.ps1:554` 改用 `"yyyy-MM-ddTHH:mm:ss.fffzzz"`，让冒烟测试覆盖标准客户端形态。

---

### M-7 `storeLoad` 逐行静默丢弃坏数据

**状态**：已修（2026-09-14）。逐表比对「JSON 数组条数 vs 解析成功条数」，不等即拒绝启动（与文件级解析失败同口径）。

**现象**：文件**整体**解析失败会正确抛错（`store.cj:340-343`），但**单个数组元素**解析失败会被空 `catch` 吞掉，该条记录从内存中消失。下一次 `storeSave` 会把少了记录的全库写回 —— 真实数据被永久覆盖。这与 `store.cj:12-13` 自述的"解析失败**绝不静默降级为空库**"是同一类风险，只是粒度从"文件"变成了"行"。

**证据**

- `store.cj:362-367`（部门）、`store.cj:383-389`（成员）、`store.cj:404-410`（课题）、`store.cj:425-433`（任务）、`store.cj:446-452`（链接）、`store.cj:465-476`（令牌）、`store.cj:490-503`（登录失败）、`store.cj:518-531`（幂等）—— 8 处全是同一个形状：
  ```cangjie
  try {
      let d = deptFromJson(v.asObject())
      m[d.id] = d
  } catch (e: Exception) {
      ()                     // ← 静默丢弃
  }
  ```
- `store.cj:340-343` —— 文件级失败是抛异常的，说明作者知道"不能静默降级"，只是没把同一原则推到行级。
- `main.cj:43-50` —— 启动失败会 `[FATAL]` 退出，说明"宁可退出也不要带着坏数据跑"是本项目的既定取向。

**影响**：一次手工编辑失误、一次磁盘写入截断、一次版本字段变更，都可能让某几条记录在下一次保存时永久消失，而且**没有任何日志**。对"任务承载人的工作量记录"这一核心价值（`v1-scope` 规则 17）来说风险偏高。

**建议修法**：把空 `catch` 换成"收集 + 报告"：

1. 在 `catch` 里累加计数并记录 `println("[WARN] departments[${i}] 解析失败，已跳过：${e.message}")`。
2. 全部解析完后，若跳过条数 > 0，**抛异常阻止启动**（与文件级失败一致），让人先修文件；或至少在启动横幅里显著打印"N 条记录被跳过，请立即备份"。
3. 把 8 处重复逻辑抽成一个泛型辅助（现在每张表的 `*ArrFromJson` 是近乎复制的代码，`store.cj:354-536` 共 180 行里有大量结构重复）。

**补充测试**：`tests.cj:283-291` 只测了"整个文件坏"，建议补一条"文件可解析、但某条记录缺字段"的用例。

---

### M-8 未校验的 `sort` 溢出，可持久化打挂 `GET /depts`

**状态**：已修（2026-09-14）。写入侧校验 `0..10000`；读取侧用 `sortKeyClamp` 兜底磁盘上可能已有的旧越界值。

**现象**：`PATCH /depts/{id}` 的 `sort` 接受任意 `Int64`，而 `sortedDepartments` 用 `d.sort * 1000000 + d.id` 当排序键。传一个接近 `Int64` 上限的值就会溢出（本项目 `ids.cj:36` 注释明确说"Cangjie 溢出会抛异常"），此后 **`GET /depts` 持续返回 500**，且坏值已经落盘，重启也不会恢复。

**证据**

- `h_dept.cj:96-100` —— 无范围校验：
  ```cangjie
  match (jsonGetInt64(body, "sort")) {
      case Some(sv) =>
          d.sort = sv          // ← 无上下界
          touched = true
  ```
- `h_dept.cj:47` —— 新建时同样：`let sort = reqIntOr(body, "sort", s.departments.size)`
- `store.cj:695` —— 排序键：
  ```cangjie
  sortByKey<Department>(arr, { d: Department => d.sort * 1000000 + d.id })
  ```

**实测**

```
GET /depts 正常                                  -> 200
PATCH /depts/{id} {sort: 9223372036854775807}    -> 200（落盘）
之后 GET /depts                                  -> 500
之后 GET /members                                -> 200（只有 1 人，排序键未被调用，侥幸）
PATCH /depts/{id} {sort: -9223372036854775807}   -> 同上，GET /depts -> 500
```

（`GET /members` 侥幸通过的原因：`store.cj:673-686` 的 `sortByKey` 只在 `i >= 1` 时调用 key 函数，单元素数组不会触发溢出。数据一多就会一起挂。）

**影响**：`api-design.md:1468-1480` 的页面映射里，名录、任务列表、待办几乎都依赖 `GET /depts`；一旦被污染，多个页面同时不可用。触发需要会长权限，所以更现实的场景是**客户端传错值或会长手滑**，而不是外部攻击。恢复需要再调一次 `PATCH` 传合法 `sort`（`PATCH` 本身不排序，所以能自救），但普通用户不会知道。

**建议修法**

1. `h_dept.cj` 给 `sort` 加范围校验，例如 `0 <= sort <= 10000`，超范围返回 `VALIDATION_FAILED`。
2. `store.cj:695` 的排序键改为不依赖乘法，例如先按 `(sort, id)` 二级比较，或直接 `d.sort * 1000000` 前做 `Math` 安全校验。
3. 同类隐患一并检查：`store.cj:794`（`t.due_at * 1000`，`due_at` 来自 `parseIso`，年份限 4 位所以目前安全）、`store.cj:1085`（内部计算）、`h_link.cj:49`（`l.created_at * 1000`，内部生成）—— 只有 `sort` 是外部可控的。

---

## 五、P2 · 低危与代码质量

### L-1 `permissions.set_role` 与真实权限不符

**状态**：已修（2026-09-14）。`set_role` 改为从 `can()` 推导（副会长也返回 `true`，原实现把副会长的角色入口整个藏掉了）。

`views.cj:71` 只把 `president` 标为可设角色：

```cangjie
jPutBool(p, "set_role", active && m.role == "president")
```

但 `perms.cj:84-87` 明确允许副会长改动非会长成员的角色。实测：

```
副会长 permissions = {"view_scope":"all","manage_members":true,"set_role":false, ...}
副会长实际 PATCH /members/{id} {role:"lead"}  -> HTTP 200
```

文档自己说"客户端读它**只为画界面**"（`views.cj:54-57`），那这个不一致的后果就是**副会长看不到自己本可使用的入口**。建议把 `views.cj:71` 改为与 `perms.cj` 同源（例如直接调 `can(m, Action.SetRole, otherTarget)`），避免两处口径各自演化。

---

### L-2 `/join/{token}` 无落地页（招募链接是死链）

**状态**：已修（2026-09-14）。补上公开落地页路由（只暴露部门名）；`Host` 头污染作为已知取舍记录在 `api-design` §3.7 与 `h_link.cj` 注释里。

`h_link.cj:19-22` 生成并返回 `https://<host>/join/<token>`：

```cangjie
func linkUrl(ctx: Context, token: String): String {
    let host = ctx.requestHeader("host") ?? "localhost"
    return "https://${host}/join/${token}"
}
```

但 `main.cj:157-285` 的路由表里**没有 `/join/` 路由**。实测：

```
生成 url = https://127.0.0.1:18098/join/324cd8cf
GET /join/324cd8cf -> HTTP 404
```

`api-design.md:1478` 的页面 7「加入流程」依赖该链接带入 `dept_id`（即 `m.dept_hint`，`h_auth.cj:77-79`），所以这条链路目前是断的。需要二选一：服务端补一个落地路由（返回引导页或 302 到 App scheme），或在文档里明确"链接仅供 App 内解析，不通过 HTTP 打开"。

另注：`linkUrl` 用请求的 `Host` 头拼 URL，存在 Host 头注入的余地（影响有限，因为 URL 只回给刚发请求的管理员）；建议改为从配置读固定基址。

---

### L-3 `DELETE /dept-invite-links/{token}` 同一接口两种响应形状

**状态**：已修（2026-09-14）。两种结果返回同一形状（token 回显、`enabled=false`、`dept` 空对象、`created_at` 为 null）。

`h_link.cj:113-122`：命中返回链接对象，未命中返回空对象：

```cangjie
case Some(l) => ... sendOk(ctx, inviteLinkView(s, l, linkUrl(ctx, token)))
case None    =>     sendOk(ctx, JsonObject())        // ← 形状不同
```

实测：

```
首次停用   -> 200  {"ok":true,"data":{"token":"4d24b9ba","url":"...","dept":{...},"enabled":false,...}}
重复停用   -> 200  同上
不存在token-> 200  {"ok":true,"data":{}}
```

幂等语义（都返回 200）是对的，但响应体形状应当统一 —— 否则客户端读 `data.token` 时会在最后一种情况崩。建议未命中时也返回 `{"token": "...", "enabled": false}`（"该 token 当前不生效"），或统一改为只返回 `{"token": "...", "enabled": false}`。

---

### L-4 `ResetPassword` self 分支死代码 + 文档三处矛盾

**状态**：已修（2026-09-14）。删除 `scopeAllows` 里的死分支；口径统一为「管理员救济动作，不含本人」，`api-design` §3.5/§3.8 与 `v1-scope` §3.4.3 四处已一致，并加冒烟用例钉住。

`perms.cj:131-137` 有一段永远不可达的分支：

```cangjie
if (t.is_self) {
    match (a) {
        case UpdateTaskStatus => return true
        case ResetPassword => return true      // ← 永远到不了
        case _ => ()
    }
}
```

因为 `roleAllows` 对 `member` 的动作白名单（`perms.cj:108-115`）里没有 `ResetPassword`，第 170-172 行先返回 `FORBIDDEN_ROLE`。实测：普通成员重置自己的密码 → **HTTP 403**。

而文档三处口径不一致：

| 位置 | 说法 |
| --- | --- |
| `api-design.md:735`（§3.5 正文） | 会长 / 副会长 / （本部门）部长 / 副部长 —— **不含本人** |
| `api-design.md:1430`（§6.1 清单） | 同上，**不含本人** |
| `api-design.md:838`（§3.8 汇总表） | 成员列写「**仅本人**」 |
| `v1-scope.md:130` | 成员列写「**仅本人**」 |
| `h_secret.cj:17`（代码注释） | 「权限：会长 / 副会长（任意成员）、部长 / 副部长（本部门）、**本人**」 |

实现与 §3.5/§6.1 一致（不允许）。请**先决定**普通成员能否自助重置（若允许，需在 `roleAllows` 的 `member` 分支加 `case ResetPassword => return t.is_self`，并删掉 `scopeAllows` 里那段死代码；若不允许，则删死代码并统一 §3.8、§3.9、`v1-scope.md` 与 `h_secret.cj` 的注释）。顺带：无论哪种口径，`perms.cj:133-134` 都建议删除或加注释指明其前提，避免后人误读为"已实现"。

---

### L-5 无效日历日期被静默顺延

**状态**：已修（2026-09-14）。加 `isLeapYear` / `daysInMonth`：`2026-02-30`、平年 `02-29`、`04-31`、`00` 日一律 400。

`timex.cj:226` 只校验 `1..31`，不校验月份天数：

```cangjie
if (mo < 1 || mo > 12 || d < 1 || d > 31) {
    return None
}
```

`daysFromCivil`（`timex.cj:56-72`）会把越界日期正常化成下个月。实测：

```
2026-02-31T00:00:00+08:00  -> 200   回读 2026-03-03T00:00:00+08:00
2026-04-31T00:00:00+08:00  -> 200   回读 2026-05-01T00:00:00+08:00
2026-02-30T10:00:00+08:00  -> 200   回读 2026-03-02T10:00:00+08:00
```

客户端的日期选择器通常不会产出这种值，但手填/拼接出错时会得到一个**看着成功、实际是另一个日子**的截止时间 —— 静默错误比报错更难查。建议在 `parseIso` 里补月份天数校验（含闰年判断，可复用 `daysFromCivil`/`civilFromDays` 做往返校验：解析后再格式化回去，与原串比对）。

---

### L-6 摘要比对与口令比对缺少常数时间实现

**状态**：已修（2026-09-14）。新增 `constantTimeEq`，用于口令摘要与注册口令比对。

- `auth.cj:89` —— `return toHexString(dk) == hashHex`，按字节短路比较。
- `h_auth.cj:59` —— `if (rc != s.register_code)`，明文口令同样短路比较。

局域网 + 有限次尝试下利用难度高，但本项目已经有 `containsAscii`/`startsWithAscii` 这类自写字节工具（`strx.cj`），加一个 `constantTimeEq` 成本很低。建议至少给注册口令比较加上（它与 M-2 的"无限尝试"叠加后风险会放大）。

---

### L-7 全局锁横跨网络写出

**状态**：不改，按报告建议记录取舍（2026-09-14）。`storeSave` 注释写明：v1 用「一次磁盘写出横跨互斥区」换「响应 200 即已落盘」的强语义，异步写盘属 v2 取舍。

几乎所有 handler 都在持有 `s.lock` 的情况下调用 `sendOk`/`sendCreated`，也就是**在全局互斥锁内做 JSON 序列化 + 写 socket**。例如：

- `h_auth.cj:54-88`（`handleRegister`：锁内 `storeSave` + `respondLogin`）
- `h_auth.cj:103-153`（`handleLogin`：锁内 `storeSave` + 响应）
- `h_task.cj:117-136`（`handleTasksMine`：锁内构造响应）
- `h_member.cj:67-90`、`h_plan.cj:49-81` 等同构

这与 `store.cj:15-16`「所有对 Store 的读写都在 store.lock 下进行」的本意（保护数据）不完全一致 —— 保护范围被扩大到了 I/O。一个读取缓慢的客户端就能长时间占住全库锁。结合 M-5（超时实际不生效），当前没有兜底。

社团规模（几十~几百条）下不会出问题，属于可接受的取舍；但建议在 `store.cj` 顶部注释里把这条**明确写成已知取舍**，而不是让它作为隐含事实存在。

---

### L-8 `MEMBER_PENDING` 被复用于 `disabled` 目标

**状态**：已修（2026-09-14）。实际修了**三处**（报告列两处）：任务创建路径本来就对，补的是任务转交、课题创建、课题编辑。

- `h_task.cj:361-363`：
  ```cangjie
  if (owner.status != "active") {
      throw apiErrMsg("MEMBER_PENDING", "目标成员尚未被分配，不能接任务")   // disabled 也报这个
  }
  ```
- `h_plan.cj:289-291` 同样。

客户端无法区分"还没审批"与"已退出社团"，只能给出错误文案。建议 `h_task.cj:361` 拆成 `pending` / 其它两个分支，分别用 `MEMBER_PENDING` 与 `MEMBER_DISABLED`（两个错误码在 `errors.cj:53-58` 都已存在）。

---

### L-9 审计日志可注入换行/制表符

**状态**：已修（2026-09-14）。在 `audit()` 这个唯一写入口清洗 CR/LF/TAB 与控制字符。

`h_link.cj:117` 把 URL 路径里的 token 直接拼进审计 note：

```cangjie
audit(s, actor.id, "disable-invite-link", l.dept_id, "token=${token}")
```

`audit.cj:24` 用制表符分隔、换行结尾：

```cangjie
let line = "${isoLocal(nowEpoch())}\tactor=${actorId}\t${action}\ttarget=${targetId}\t${note}\n"
```

token 来自 `ctx.paramOr("token", "")`（`h_link.cj:107`），未做字符白名单，含 `\n`/`\t` 时可伪造日志行。需要会长/副会长权限，影响有限，但审计日志的价值正在于可信。建议对拼入 note 的外部输入做一次白名单过滤（token 本来就该是十六进制）。

---

### L-10 排序键的隐含前提与 guard 不一致

**状态**：已修（2026-09-14）。`views.cj` 的 `planPath` 改用 `PLAN_WALK_GUARD`，与 `store.cj` 的遍历保护同一常量。

- `store.cj:695`、`store.cj:794`、`store.cj:1085` 都依赖"乘 1000000 不会溢出"这一隐含前提（M-8 是它被打破的一次实例）。
- `store.cj:873` 定义 `PLAN_WALK_GUARD = 64`，但 `views.cj:246` 的 `planPath` 用了独立的 `guard < 32`。虽然 32 层面包屑远超业务上限（6 层），不会出问题，但两处魔数分头维护容易漂移。建议 `planPath` 复用 `PLAN_WALK_GUARD`。

---

### L-11 README 接口计数口径

**状态**：已修（2026-09-14）。README 更正为 **39 / 39** 并写明口径（38 个业务接口 + `/health`）。

`README.md:28`：

> **接口进度 38 / 39**（认证 5 · 组织与成员 19 · 任务 8 · 课题 6；另 `/health` 已可用）

它自己的分解 5+19+8+6 = 38，第 39 个正是 `/health`（`api-design.md:1462-1466`「运维（1）」），而且括号里已经写了"已可用"。所以按 `api-design.md:1402` 的口径应该是 **39 / 39**。现状会让读者（尤其是接手的人）以为还差一个接口没做。建议改为 `39 / 39` 或 `38 / 38（业务接口）+ /health`。

---

### L-12 客户端实为未改动的 DevEco 模板

**状态**：已处理（2026-09-14）。README 顶部、进度表、未决事项三处如实说明「仍是 DevEco 初始模板」，并列为发布前必改项；客户端开发仍由小组其他成员推进。

`README.md:26` 的进度表把客户端标为"进行中"，但仓库内的客户端就是模板本身：

- `entry/src/main/cangjie/index.cj:18-36` —— `EntryView` 是 Hello World，点一下把文案从 `"Hello World"` 改成 `"Hello Cangjie"`；
- `entry/src/main/resources/base/profile/main_pages.json` —— 内容为空 `{}`；
- `entry/cjpm.toml` 的 `[profile.customized-option]` —— debug 与 release 都带 `-Woff all`，即关掉全部告警；
- `AppScope/app.json5` —— `bundleName` 仍是 `com.example.cangjie_web`，`label` 是 `cangjie_web`；
- `entry/src/main/resources/base/element/string.json` —— `module_desc`/`EntryAbility_desc`/`EntryAbility_label` 全是占位文案（`"description"`/`"label"`）。

`main_pages.json` 为空是否影响运行，需要实际构建一次客户端才能确认（本机未跑 DevEco 构建）。建议 README 改成"仓库内仅脚手架，实际客户端开发在队友的分支/仓库"，并把 `bundleName`、应用名、`string.json` 占位文案列入上架前检查项（README 未决事项第 6 条提到 AGC 分发流程耗时，这些是其中的前置项）。

---

### L-13 `freshLinkToken` 仅 32 bit（记录备查）

**状态**：暂不改，记录（2026-09-14 复核结论不变）。链接不免除注册口令，不构成凭证风险。

`h_link.cj:24-36` 用 `randHex(4)` 生成 8 位十六进制 token（32 bit），冲突时重试最多 64 次，最后退化为 `randHex(16)`：

```cangjie
let t = randHex(4)
if (!s.invite_links.contains(t)) { return t }
```

32 bit 空间（约 43 亿）对"社团级链接数量"足够，且链接只做部门预填、**不免除注册口令**（`h_link.cj:9-12`），所以不构成凭证风险。另外注意本仓库的 `freshLinkToken` 走的是 `s.invite_links.contains`，而实测中生成的 token 是 `324cd8cf` 这种 8 位十六进制，与 `api-design.md:803` 的示例一致。**无需修改**，仅记录在案以免后人误判为漏洞。

---

## 六、已排除的怀疑（有正向证据，不要重复投入）

### V-1 `Random()` 播种不退化

`ids.cj:22-27` 与 `ids.cj:38-50` 每次都新建 `Random()` 实例，这是可疑写法（若默认播种依赖秒级时间戳，同秒内会产出相同序列，令牌就完全可预测）。我用 `cjc` 编译了独立探针实测：

```
同进程连续 6 个 Random 实例        -> 6 个互不相同的输出
同时创建两个实例后分别取数          -> A != B
同一实例连续取两次                  -> 不同
跨 3 次进程启动的 seq0             -> 每次都不同
```

结论：**未发现缺陷**。但需要说明：这只证明"不退化"，不等于 `std.random` 是密码学安全随机源。令牌（`newToken()`，`ids.cj:52-55`）与会话安全依赖它，建议在 `HANDOFF.md` 里把这条不确定性记一笔，或改用更明确的熵源。

### V-2 请求体有 1 MiB 上限

曾怀疑"任务 desc 无长度校验 → 可无限落盘"。查轻舟 `bodyparser.cj` 的 `BodyParserOptions.maxBytes` 默认值为 `1024 * 1024`，且超限会直接短路响应。**不构成无界问题**，无需为本项目单独加长度校验（加也可以，属于产品选择）。

### V-3 全局锁不会自死锁

`store.cj:16` 明确写了"Mutex 不可重入，因此 handler 只在最外层加一次锁"，我逐文件核对了所有 handler：都是"先认证（`requireMember`/`requireActive` 内部加锁）→ 再单独加锁"，且 `requireAccess`/`can`/`checkAccess`/`audit`/`storeSave` 均不加锁。**未发现嵌套加锁路径**。

### V-4 无遗留标记、忽略规则正确

- `server/src/` 全目录 grep `TODO|FIXME|XXX|HACK|待办|临时方案` → **无匹配**。
- `.gitignore` 正确挡住了私钥与运行数据：`/server/certs`、`/server/dist`、`/server/data`、`**/*.cj.macrocall`；`git status --ignored` 复核无遗漏。

---

## 七、做得好的地方（改动时请勿破坏）

这些是本次检查中确认有效的设计，建议在重构时保留：

1. **权限判定收敛到 `perms.cj` 单一入口**（`perms.cj:163-189`）。本次三个 P0 里有两个是这一个文件的遗漏/顺序问题 —— 定位成本极低，修复也就是十几行。这个决策的价值在这次检查中被直接验证了。
2. **PBKDF2 有独立对拍**：RFC 7914 §11 公开测试向量 + .NET `Rfc2898DeriveBytes` 双向验证（`tests.cj:163-169`），不是"自己实现自己测"。
3. **历法有外部锚点对拍**：400 天连续往返 + 与本项目无共享逻辑的锚点（`tests.cj:87-100`），这类代码最容易错且最难发现。
4. **隐私最小化有断言**：`MemberBrief` 不含手机号并在测试里断言（`views.cj:9-11`、`tests.cj:432`）。
5. **错误码表单一权威**：`errors.cj` 与文档一一对应，默认落到 500 且不泄露内部细节（`errors.cj:30-96`、`main.cj:292-300`）。
6. **删除课题不级联，且有守卫遍历**：`planDeletePromote`（`store.cj:1117-1150`）把"上提"做成纯函数便于单测；`PLAN_WALK_GUARD` 保证脏数据成环时读取路径也不死循环（`store.cj:879-986`）。
7. **派生量不落盘**：逾期由 `due_at` 算（`store.cj:782-787`）、课题进度由子树聚合（`store.cj:1027-1101`）、`updated_at` 全部服务端生成 —— `README.md` 的"设计原则"表在代码里是真实成立的。
8. **安全默认值**：证书读不到直接退出、绝不回退明文（`main.cj:338-340`）；`/admin/shutdown` 限制本机（`h_ops.cj:38-52`）；令牌无状态化以便"移出社团即踢下线"（`auth.cj:14-15`、`h_member.cj:245-247`）。

---

## 八、建议的修复顺序

分三批，每批改完跑一次三套测试（`test` / `smoke.ps1` / `tls-check.ps1`）。

**第 1 批 —— 权限（必须最先，涉及数据安全）**

1. H-1 `perms.cj:91-107` 给 `lead/vice_lead` 补会长保护；同时修 `smoke.ps1:345` 的部门设置，让该用例真正测到"同部门"
2. H-2 `h_task.cj:250-264`、`h_plan.cj:159-173` 把权限判定提到幂等命中之前
3. H-3 `h_plan.cj:377-393` 提升为顶层时补目标部门判定

**第 2 批 —— 可用性（客户端对接前必须修）**

4. M-6 `timex.cj` 接受小数秒（不改这条，ArkTS 客户端第一天就会踩 400）
5. M-1 `h_plan.cj:308/165` 传真实 `PlanStats`
6. M-8 `h_dept.cj` 给 `sort` 加范围校验
7. M-5 `main.cj:308` 调整 `timeout` 位置（或删除并记录）
8. L-5 `timex.cj:226` 补月份天数校验

**第 3 批 —— 安全加固与一致性**

9. M-2 注册口令下限提到 6 位 + 加节流
10. M-3 `login_fail` 加 `isPhone` 校验与清理
11. M-7 `storeLoad` 逐行失败改为"报告 + 阻止启动"
12. M-4 `assign` 对 `disabled` 目标的语义（**需先产品决策**）
13. L-4 `ResetPassword` 口径统一（**需先产品决策**）
14. L-2 `/join/{token}` 落地页方案
15. L-1、L-3、L-8、L-9、L-11、L-12 等一致性修整

---

## 附录 A · 复现环境与命令

```powershell
# 基线（两条都应全绿）
cd server
.\build\club-server.exe test                                             # PASS 233 / FAIL 0
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1    # PASS 280 / FAIL 0

# 独立实例复现（每次用全新数据目录，绝不碰 server\data）
cd server\build
.\club-server.exe init-admin 13800000000 password123 review-data
.\club-server.exe serve 18099 review-data
# 之后用任意 HTTP 客户端按各条"实测"里的请求复现
```

复现时注意两条环境约束（`README.md:127-128`）：`cwd` 必须是 exe 所在目录；4 个 DLL 必须与 exe 同目录，缺 OpenSSL 两个时**编译期无警告、运行时才报错**。

## 附录 B · 本次检查的方法学说明

- 所有"实测"结论均在本机跑过，未使用推断。数字（233 / 280 / 30 条 `login_fail` / 500 等）均为实际观测值。
- 涉及框架语义的结论（M-5 的中间件顺序、V-2 的 body 上限、H-1 的 compose 行为）都读了轻舟源码 `E:\cangjie\qingzhou\src\` 对应文件，未凭印象。
- 未覆盖：客户端 DevEco 构建（本机未跑）、`tls-check.ps1`（本次未跑，TLS 场景与本次改动无关）、并发/压力场景（未做多客户端并发验证，L-7 是基于代码结构的判断而非实测）。
- 检查过程产生的临时数据与日志均落在 `server/build/`（已被 `.gitignore` 覆盖）或 `%TEMP%`，已清理；仓库工作区未做任何改动。

---

## 附录 C · 修复后的回归证据（2026-09-14）

| 项 | 修复前 | 修复后 |
| --- | --- | --- |
| 单测 `club-server.exe test` | PASS 233 / FAIL 0 | **PASS 273 / FAIL 0** |
| HTTP 冒烟 `tests/smoke.ps1` | PASS 280 / FAIL 0 | **PASS 325 / FAIL 0** |
| TLS `tests/tls-check.ps1` | 本次未跑 | **PASS 22 / FAIL 0** |

新增断言（都是"改坏就会红"的那种，不是凑数）：

| 用例 | 钉住的缺陷 |
| --- | --- |
| 部长临时调进主席团后，重置会长密码 / 改会长姓名 / 重置副会长密码 → 403 `FORBIDDEN_ROLE` | H-1（原来的 403 是 `FORBIDDEN_NOT_IN_DEPT`，属于假绿灯） |
| 部长改自己的姓名 → 200 | H-1 的例外条款（改名不构成提权） |
| 换个人重放同一 `client_token` → 201 且资源 id 不同 | H-2 |
| 部长把课题提升到别的部门 → 403，且父节点未被改动 | H-3 |
| `PATCH /plans/{id}` 的 `progress` 与 `GET` 一致且非零 | M-1 |
| 口令 5 位 → 400 / 6 位 → 200 | M-2 |
| 恢复已退出成员后审计日志出现 `restore-member` | M-4 |
| `due_at` 带毫秒 → 201；`2026-02-30` → 400 | M-6 / L-5 |
| 单条坏记录（数组里混字符串）→ 拒绝启动；`db.json` 里不出现 `login_fail` | M-7 / M-3 |
| `sort = Int64 最大值` → 400，且 `GET /depts` 仍 200 | M-8 |
| `GET /join/{token}` → 200 HTML；失效链接也是 200 | L-2 |
| 不存在的链接 → 同一响应形状 | L-3 |
| 成员对自己重置密码 → 403 | L-4（把口径钉死，防止文档再次漂移） |
| 给已退出成员建任务 / 转交 / 建课题 → `MEMBER_DISABLED` | L-8 |

> 客户端 DevEco 构建仍未跑（本仓库内客户端仍是模板，见 L-12）；并发/压力场景仍未做（L-7 保持"代码结构判断"的性质）。

