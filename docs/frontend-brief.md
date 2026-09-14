# 社团管理工具 · 前端对接说明

- 面向：鸿蒙客户端 / 前端开发
- 版本：v1.0（接口已冻结）
- **本文是精简版。** 完整设计见 `api-design.md`（39 个接口逐条定义）；范围与业务规则见 `v1-scope.md`

---

## 1. 这个产品要解决什么

两个问题：

1. 社团里有哪些人
2. **每件事由谁负责、做到什么程度**

**首页必须是「我的任务」，不是组织架构图。** 名录只是任务的目录——真正让人每天打开 App 的是"我负责什么"。

客户端形式：鸿蒙 App，服务端自建（HTTPS）。

---

## 2. 页面清单（11 个）

| # | 页面 | 关键点 |
| --- | --- | --- |
| 1 | **登录页** | 手机号 + 密码；注册入口；忘密码引导联系会长 |
| 2 | **我的任务**（首页） | 按截止排序；逾期红色高亮；阻塞项单独一组 |
| 3 | 任务列表 | 按部门 / 人 / 状态 / 课题筛选；新建任务入口 |
| 4 | 任务详情 | 改状态、填阻塞原因、加入日历 |
| 5 | 课题列表 | **树形**，可展开折叠；显示 `已完成 n / 共 m`（含整棵子树） |
| 6 | 课题详情 | 面包屑 + 子课题 + 本级任务 + 递归进度 |
| 7 | 成员名录 | 按 4 个组织分组；点进去看某人负责的事 |
| 8 | 加入流程 | 注册口令 + 手机号/姓名/密码 → 变 `pending` |
| 9 | 待分配审批 | 待分配列表；**多选批量分配** |
| 10 | 管理 | 部门、角色、注册口令、招募链接、重置密码、会长移交 |
| 11 | **我的 / 个人设置** | 本人信息、改密码、退出登录 |

---

## 3. 通用约定

| 项 | 约定 |
| --- | --- |
| 基地址 | `/api/v1`（健康检查 `GET /health` 无前缀） |
| 编码 | UTF-8，`application/json` |
| 认证 | `Authorization: Bearer <token>`，有效期 **30 天**，滑动续期 |
| 时间 | ISO 8601 带时区：`2026-09-20T18:00:00+08:00`；可空用 `null` |
| 分页 | `?page=1&size=50`（**page 从 1 开始**）→ `{ items, total, page, size }` |
| 幂等 | 创建类接口传可选 `client_token`（UUID），24h 内重复提交返回首次结果 |

### 响应格式

**成功**

```json
{ "ok": true, "data": { } }
```

**失败**

```json
{ "ok": false, "error": { "code": "TASK_NOT_FOUND", "message": "任务不存在", "fields": { } } }
```

### 错误处理（网络层按状态码，业务层按 code）

| 状态码 | 客户端动作 |
| --- | --- |
| 401 | **统一跳登录页**（token 失效），不需要解析 body |
| 403 | 提示无权限 |
| 400 / 409 | 按 `error.code` 显示文案；`fields` 做表单逐字段提示 |
| 429 | 提示"尝试过于频繁" |
| 500 | 通用错误提示，**不要展示后端内容** |

**常用 code**：`VALIDATION_FAILED` / `REGISTER_CODE_INVALID` / `AUTH_BAD_CREDENTIALS` / `MEMBER_PENDING` / `MEMBER_DISABLED` / `FORBIDDEN_ROLE` / `FORBIDDEN_NOT_IN_DEPT` / `FORBIDDEN_LAST_PRESIDENT` / `BLOCKER_REQUIRED` / `PLAN_CYCLE_DETECTED` / `PLAN_DEPTH_EXCEEDED` / `DEPT_NOT_EMPTY` / `MEMBER_HAS_OPEN_TASKS` / `TOO_MANY_ATTEMPTS` / `ALREADY_EXISTS` / `*_NOT_FOUND`

---

## 4. 接口清单（39 个）

### 认证（5）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/auth/register` | 注册（产 `pending` 账号，**即可登录**） |
| POST | `/auth/login` | 登录 |
| POST | `/auth/logout` | 注销 |
| GET | `/auth/me` | **启动必调**：校验 token + 拿权限摘要 |
| PUT | `/auth/password` | 本人改密 |

### 组织与成员（19）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET / POST | `/depts` | 组织列表 / 新建 |
| PATCH / DELETE | `/depts/{id}` | 改名排序 / 删除（非空拒绝） |
| GET | `/members` | 成员名录（**全社团可见**） |
| GET / PATCH | `/members/{id}` | 成员详情 / 编辑 |
| POST | `/members/{id}/disable` | 移出社团（有未完成任务会拒绝） |
| GET | `/members/pending` | 待分配列表 |
| POST | `/members/{id}/assign` | 单个分配部门+角色 |
| POST | `/members/assign-batch` | **批量分配**（逐条报告，可部分成功） |
| POST | `/members/{id}/transfer-presidency` | 会长移交（原子操作） |
| POST | `/members/{id}/reset-password` | 重置密码（返回一次性临时密码） |
| GET | `/register-config` | 查看注册口令 |
| PUT | `/register-config/code` | 更换口令 |
| POST | `/register-config/rotate` | 随机轮换口令 |
| GET / POST | `/dept-invite-links` | 招募链接列表 / 生成 |
| DELETE | `/dept-invite-links/{token}` | 停用链接 |

### 任务（8）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/tasks/mine` | **首页**：服务端已分好组 |
| GET | `/tasks` | 列表（筛选 / 分页） |
| GET / POST | `/tasks/{id}` | 详情 / 创建 |
| PATCH | `/tasks/{id}` | 编辑（改 `owner_id` 即转交） |
| PUT | `/tasks/{id}/status` | 改状态 + 填阻塞原因 |
| DELETE | `/tasks/{id}` | 删除（软删除） |
| POST | `/tasks/lookup` | **日历同步用**：批量查任务是否还在 |

### 课题（6）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/plans` | **整棵树**（不分页，含 `children` 与递归进度） |
| GET | `/plans/{id}` | 详情（面包屑 + 子课题 + 本级任务） |
| POST | `/plans` | 新建课题 / 子课题 |
| PATCH | `/plans/{id}` | 编辑 |
| POST | `/plans/{id}/move` | 移动（换父节点） |
| DELETE | `/plans/{id}` | 删除（子节点**上提一级**，不级联删） |

---

## 5. 核心数据结构

### MemberBrief

```json
{ "id": 12, "name": "张三", "role": "member",
  "dept": { "id": 2, "name": "运营部" },
  "status": "active", "joined_at": "…" }
```

`role`：`president` / `vice_president` / `lead` / `vice_lead` / `member`（`pending` 时 `role`、`dept` 均为 `null`）
`status`：`pending` / `active` / `disabled`
**注意：不含手机号**（隐私最小化）。

### Permissions（由 `GET /auth/me` 返回）

```json
{ "view_scope": "dept", "manage_members": false, "set_role": false,
  "create_plan": false, "create_task": false, "update_any_task": false }
```

`view_scope`：`all` / `dept` / `self` / **`none`**（pending 账号）

> ⚠️ **客户端读它只是为了画界面，绝不能用它替代服务端校验。**

### TaskBrief / TaskDetail

`TaskBrief`：`id` / `title` / `status` / `owner` / `dept` / `plan` / `due_at` / **`is_overdue`** / `blocked` / `updated_at`
`TaskDetail` = `TaskBrief` + `desc` / `blocker` / `plan_path`（面包屑）/ `created_by` / `created_at` / `completed_at`

`status`：`todo` / `doing` / `blocked` / `done`（**只有 4 档**）

### PlanBrief

`id` / `title` / `owner` / `dept`（**仅顶层有值**）/ `due_at` / **`progress: { done, total }`** / `task_count`（本级）/ `child_count` / `children`

> `progress` 是**递归值**，含整棵子树的所有任务。

---

## 6. 客户端必须知道的 4 件事

### ① 注册后是 `pending`，没有权限

注册成功即返回 token，但账号**没有任何权限**。客户端应跳转「等待管理员分配」页，**而不是主界面**。
`pending` 账号可以正常登录，只是 `permissions` 全为 `false`、`view_scope` 为 `none`。

### ② 「逾期」是服务端算好的，客户端不要自己算

`TaskBrief.is_overdue` 直接使用。分组（逾期 / 今天 / 本周 / 以后 / 无截止）也由 `GET /tasks/mine` 返回，**客户端不重复实现**——否则跨设备口径会不一致。

### ③ 日历同步在客户端本地完成（**这是客户端的活，不是服务端**）

服务端**不存**任何日历字段。客户端本地维护映射：

```
task_id → { event_id, cached_due_at, cached_status }
```

拉取任务时比对：

| 差异 | 动作 |
| --- | --- |
| `due_at` 变了 | **更新**日历事件（不得新建） |
| `status` 变为 `done` | **删除**日历事件 |
| 任务不在服务器返回中 | **删除**日历事件 |
| 日历权限被拒绝 | 降级为导出 `.ics` + 应用内高亮 |

用 `POST /tasks/lookup` 批量确认"我加过日历的任务现在还在不在"，返回的 `missing` 数组即需清理的。

> ⚠️ 不做"更新与删除"，日历里会堆积错误的过期提醒，两周后成员就不再相信它。**这项需单独排期。**

### ④ 自签证书需要在 App 内配置信任

服务端用自签 HTTPS。**鸿蒙默认不信任自签证书**，需要在 `resources/base/profile/` 下配置网络安全配置并内置 CA 证书。

⚠️ 两个待确认项（会影响此处实现）：

- 证书**必须带 SAN**（我们的服务是 IP 访问，SAN 需写 `IP:<公网IP>`）。轻舟示例自带的证书没有 SAN，**不能直接用**
- 鸿蒙对**明文 HTTP** 也有限制，需实测确认默认行为

---

## 7. 客户端额外工作量（需单独排期）

| 项 | 说明 |
| --- | --- |
| **日历同步机制** | 见 6.③，含本地映射表、比对逻辑、权限被拒降级 |
| **自签证书信任** | 见 6.④，含网络安全配置与内置证书 |
| 幂等处理 | 创建类接口生成并带上 `client_token` |
| 分页与筛选 | `GET /tasks`、`GET /members` |

---

## 8. 参考文档

| 文档 | 内容 |
| --- | --- |
| `api-design.md` | **完整接口设计**：每个接口的请求/响应/错误码/权限 |
| `v1-scope.md` | 范围基准：11 个页面、6 张表、19 条业务规则 |
| *（已移出仓库）* | 服务端 TLS 实测结果（协议版本、自签证书注意事项）→ 上层 `cangjie-upstream\qingzhou-tls-verification.md` |

**接口已冻结。** 如需变更，请先提出来——改动会同时影响服务端与本文档。
