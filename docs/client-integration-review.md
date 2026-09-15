# 客户端接入适配检查（PR #2 · 基建层与认证模块）

> **被检提交**：`99c6d7e`（PR #2 `pyf-sys/feature/auth-infra`，提交 `a2cba67`）
> **检查方**：服务端侧 · 2026-09-15
> **一句话结论**：**代码能编译**（`hvigorw assembleHap` → `BUILD SUCCESSFUL`，产出 `entry-default-unsigned.hap` 0.53 MB），
> 但按现状装到设备上**一个接口都调不通** —— 3 条拦路问题 + 10 处接口路径/方法对不上 + 错误形状对不上。
>
> 本文是一份**待办清单**，给写客户端的同学按条改。改完请把对应条目标 ✅。
> 接口的**唯一权威是 `docs/api-design.md`**（39 个接口逐条定义）；字段形状看 `server/src/views.cj`；
> 响应信封与错误形状看 `server/src/jsonw.cj`。本文所有"实测"列都是**真起服务端打出来的**，不是静态推断。

---

## 0. 改完怎么自查（照这个跑）

```powershell
# 1) 编译（必须用 DevEco 自带 JBR + SDK，否则报 UnsupportedClassVersionError，见 docs/client-build.md）
$ds = "D:\DevEco Studio"
$env:DEVECO_SDK_HOME = "$ds\sdk"; $env:JAVA_HOME = "$ds\jbr"; $env:PATH = "$ds\jbr\bin;$env:PATH"
& "$ds\tools\hvigor\bin\hvigorw.bat" assembleHap --no-daemon

# 2) 起一个真服务端（联调期用 HTTP，省掉自签证书信任的麻烦）
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
cd build
.\club-server.exe init-admin 13800000000 你的口令 dev-data
.\club-server.exe serve 8080 dev-data
```

再按 §3 的表逐条打一遍（`Invoke-WebRequest` 或直接跑 App）。

---

## 1. 🔴 P0：三条拦路问题（不修 = 白屏或永远登不上）

### 1.1 没有申请网络权限

**位置**：`entry/src/main/module.json5` —— 全文没有 `requestPermissions`。
**证据**：编译器自己就报了（构建输出里的原话）：

```
ArkTS:WARN File: E:/harmonyOS/cangjie_web/entry/src/main/ets/api/HttpClient.ets:119:38
 To use this API, you need to apply for the permissions: ohos.permission.INTERNET
```

**改法**：在 `"module": { ... }` 里加

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" }
],
```

`ohos.permission.INTERNET` 是 normal 级权限，声明即可，不需要运行时弹窗申请。

### 1.2 baseUrl 是相对路径，而且 `setBaseUrl()` 没有任何调用点

**位置**：`entry/src/main/ets/api/HttpClient.ets:76` —— `this.baseUrl = '/api/v1';`
**事实**：`http.request` 只接受**绝对 URL**；`setBaseUrl()` 在 `:86` 只有定义。我把 `entry/src/main/ets`
下所有文件 grep 了一遍，**没有任何调用点**（只有 `HttpClient.ets` 自己出现 `baseUrl`）。
所以现在每个请求都会在传输层就失败。

**改法**（推荐 ①）：

1. 新建 `entry/src/main/ets/config/Env.ets`，导出 `export const BASE_URL: string = 'http://10.0.2.2:8080/api/v1';`
   在 `EntryAbility.onCreate` 里 `HttpClient.getInstance().setBaseUrl(BASE_URL);`
2. 或直接把 `HttpClient` 构造里的默认值改成绝对地址；
3. 或存进 `AppStorage`，设置页可改（联调期最省事，换机器不用重新打包）。

**地址怎么填**：

| 场景 | 地址 |
| --- | --- |
| 模拟器 | `http://10.0.2.2:8080/api/v1`（模拟器里 `127.0.0.1` 是它自己，连不到开发机） |
| 真机（同一局域网） | `http://<开发机局域网IP>:8080/api/v1` |
| HTTPS（服务端 `serve-tls`） | `https://<host>:8443/api/v1` —— 自签证书需要**在 App 里内置 CA** 才能过校验，联调期建议先用 HTTP |

**用 HTTP 明文时**：HarmonyOS 默认可能拦明文流量，需要在 `module.json5` 里加
`"cleartextTraffic": true`（已在本机 SDK 的 `configSchema_rich.json` 里确认这个键存在；
若同时声明了 `securityConfig`，则以 `cleartextPermitted` 为准）。正式发布改回 HTTPS 并去掉它。

### 1.3 响应信封少剥一层 ← 最隐蔽的一条（表现是"登录成功但没登上"）

**服务端成功响应**（`server/src/jsonw.cj:73-78`）：

```json
{ "ok": true, "data": { "token": "...", "member": {...}, "permissions": {...} } }
```

**客户端现状**：`HttpClient.ets:129-144` 把 `resp.result`（**整个信封**）当成 `data` 返回：

```ts
resultData = rawResult as Record<string, Object>;   // ← 这是 {ok, data}，不是 data
return { ok: true, data: resultData as T } as ApiResponse<T>;
```

**后果**：下面 4 处读到的全是 `undefined`。登录**不会报错**，只是 token 存成了空 —— 之后所有请求 401，
表现为"登录成功但没登上"：

| 读取点 | 现状 | 修好后应可直接用 |
| --- | --- | --- |
| `LoginPage.ets:247-251` | `resp.data.token` / `.member` / `.permissions` | ✓ |
| `RegisterPage.ets:326-330` | 同上 | ✓ |
| `SplashPage.ets:157-163` | `resp.data.permissions.view_scope` | ✓ |
| `PendingWaitPage.ets:65-68` | `resp.data.member` / `.permissions` | ✓ |

**改法**（`HttpClient.request` 的成功分支）：

```ts
const env = resultData as Record<string, Object>;
if (env['ok'] !== true) {
  return this.handleError<T>(env, statusCode);   // 防御：200 但 ok=false
}
return { ok: true, data: env['data'] as T } as ApiResponse<T>;
```

---

## 2. 🔴 错误响应形状对不上（错误码与表单提示全丢）

**服务端的失败响应**（`server/src/jsonw.cj:88-101`）：

```json
{ "ok": false,
  "error": { "code": "VALIDATION_FAILED",
             "message": "参数校验失败",
             "fields": { "name": "姓名不能为空" } } }
```

要点：`code` / `message` / `fields` **都在 `error` 里面**；`fields` 是**对象**（键 = 字段名，值 = 提示），
**不是数组**（`jsonw.cj` 的 `oneField(k, msg)` / `V` 收集器生成的就是对象）。

**客户端现状**（`HttpClient.ets:160-177`）：读**顶层** `result['error']`（当字符串用）、顶层 `message`、
顶层 `fields`（当 `[{field,message}]` 数组遍历）。
**后果**：所有错误码都变成 `UNKNOWN_ERROR`，`message` 退化成"请求失败"，表单逐字段提示永远不显示；
另外 401 那行 `code !== 'AUTH_BAD_CREDENTIALS'` 因为 code 恒为 `UNKNOWN_ERROR` 而**恒真** → 口令错误也会触发跳登录页。

**改法**：

```ts
const errObj = result?.['error'] as Record<string, Object> | undefined;
const code = (errObj?.['code'] as string) ?? 'UNKNOWN_ERROR';
const message = (errObj?.['message'] as string) ?? '请求失败';
// fields 直接就是 { 字段名: 提示 }，不再需要数组遍历
const fields = errObj?.['fields'] as Record<string, string> | undefined;
```

**HTTP 状态码对照**：400 参数/业务校验 · 401 未登录或凭据错误 · 403 权限不足 · 404 不存在 ·
409 冲突（重名）· 429 限流。完整错误码表在 `server/src/errors.cj`。

---

## 3. 🔴 接口路径 / 方法对不上（10 处，逐条实测）

实测方式：真起服务端（HTTP 8080），用 `Invoke-WebRequest` 打客户端代码里**每一条**路径。
`401` 表示"路由存在、只是需要登录"（对照组）；`404/405` 表示"客户端路径写错了"。

| 客户端现在写的 | 服务端实际（`docs/api-design.md`） | 客户端实测 | 正确路径实测 |
| --- | --- | --- | --- |
| `PATCH /auth/password` | `PUT /auth/password` | **405** | `PUT` → 401 |
| `PATCH /auth/profile` | 无此接口；改资料 = `PATCH /members/{id}` | **404** | `PATCH /members/1` → 401 |
| `GET /auth/register-code` | `GET /register-config` | **404** | → 401 |
| `POST /auth/register-code` | `PUT /register-config/code`（改口令）· `POST /register-config/rotate`（随机轮换） | **404** | 两条都 → 401 |
| `GET /depts/{id}/links` | `GET /dept-invite-links`（全局列表，非按部门） | **404** | → 401 |
| `POST /depts/{id}/links` | `POST /dept-invite-links`，body `{ "dept_id": 3 }` | **404** | → 401 |
| `PATCH /links/{token}/toggle` | `DELETE /dept-invite-links/{token}`（停用即 toggle，幂等） | **404** | → 401 |
| `POST /plans/{id}/delete` | `DELETE /plans/{id}` | **404** | `DELETE` → 401 |
| `POST /tasks/{id}/status` | `PUT /tasks/{id}/status` | **405** | `PUT` → 401 |
| `POST /tasks/{id}/delete` | `DELETE /tasks/{id}`（软删除） | **404** | `DELETE` → 401 |

**字段级**：注册请求体的口令字段服务端叫 **`register_code`**，客户端用的是 `code`
（`AuthApi.ets:56-61`）→ 会 400。服务端还接受可选的 `dept_id`（招募链接预填用）。

**动手时的对表建议**：打开 `docs/api-design.md`，按 Part 2（认证 5）/ Part 3（组织与成员 19）/
Part 4（任务 8）/ Part 5（课题 6）逐条核对方法 + 路径 + 请求体字段名，一次改完再跑 §0 的自查。

---

## 4. 🟡 字段与类型（不致命，但会显示错）

1. **时间字段是 ISO 字符串或 `null`，不是数字。** 服务端所有时间字段都走 `jPutTime`
   （`jsonw.cj:54-62`），输出形如 `"2026-09-20T18:00:00+08:00"`，无值时是 `null`。
   客户端多处声明成 `number`（例如 `AuthApi.ets:25` 的 `joined_at: number`）→ 当时间戳算会得 `NaN`。
   建议改成 `string | null`，显示时 `Date.parse()` 或直接展示字符串。
   涉及：`joined_at` / `due_at` / `created_at` / `updated_at` / `completed_at`。
2. **`role` 与 `dept` 可能是 `null`**（未分配的 pending 成员）。客户端接口签名已经写了 `| null` ✓，
   但取值处要判空（尤其是列表渲染）。
3. **分页形状 ✓ 是对的**：服务端返回 `{ items, total, page, size }`（`paging.cj:61-87`），
   客户端 `PagedResponse<T> = { items, total }` 兼容。

---

## 5. ✅ 已经对得上的部分（**不要改**，免得白干）

- **权限字段逐字段一致**：服务端 `permissionsOf`（`server/src/views.cj:58-85`）产出的
  `{ view_scope, manage_members, set_role, create_plan, create_task, update_any_task }`
  与客户端 `UserPermissions` 接口**一字不差** ✓
- **`MemberBrief` 结构一致** ✓：`{ id, name, role|null, dept:{id,name}|null, status, joined_at }`
- **登录/注册成功响应形状一致** ✓：`{ token, member, permissions }`
- **路由目标全部已登记** `main_pages.json` ✓；服务端这边的 4 个页面
  （`MemberListPage` / `MemberDetailPage` / `PendingApprovalPage` / `ManagePage`）是被 `Index.ets`
  `import` 后当**组件**用的（`MemberListPage(...)`），**不需要**登记路由 —— 这不是问题
  （建议：以后若要用 `router.pushUrl` 打开它们，再补登记）
- **大多数路径是对的** ✓：`/auth/login|register|logout|me`、`/depts`(+`/{id}`)、
  `/members`(+`/pending`、`/{id}`、`/{id}/assign`、`/assign-batch`、`/{id}/transfer-presidency`)、
  `/plans`(+`/{id}`、`/{id}/move`)、`/tasks`(+`/mine`、`/{id}`、`/lookup`)
- `EntryAbility` 改成加载 `pages/SplashPage` 做启动守卫 ✓ 这个设计没问题

---

## 6. 🧹 仓库卫生

- **`_commit_msg.txt` 被误提交**到仓库根（7 行，内容就是本次提交信息本身）→ 请删掉。
- 建议提交前 `git status` 看一眼，或 `git add <具体文件>` 而不是 `git add -A`
  （服务端这边也踩过同样的坑，见 `docs/API-NOTES.md`）。

---

## 7. 🟡 非阻塞，但建议排期

| 项 | 位置 | 说明 |
| --- | --- | --- |
| `router` API 已 deprecated | `utils/RouterUtils.ets:9,14,18` | `replaceUrl` / `pushUrl` / `back` 在 API 24 都标了 deprecated（编译期警告）。后续迁移到 `Navigation` + `NavPathStack` |
| 死代码 | `store/TokenStore.ets:33` | `const dataDir = context.preferencesDir;` 声明后未使用 |
| `Preferences` 旧签名 | `store/TokenStore.ets:34` | `getPreferences(context, 'app_preferences')` 是旧签名（新 API 用 options 对象）；当前能编过 |
| 未捕获异常 | `TokenStore.ets:65,76,77`、`RouterUtils.ets:9,14` | 编译警告 "Function may throw exceptions. Special handling is required."，建议包 `try/catch` |
| 仍是不签名 HAP | 构建配置 | 产出 `entry-default-unsigned.hap`，装不上真机；配置步骤见 `docs/client-build.md` §2 |

---

## 8. 改完的验收标准

1. 编译 `BUILD SUCCESSFUL`，且**不再出现** `ohos.permission.INTERNET` 那条警告；
2. 起真服务端（HTTP 8080）+ 模拟器或真机，走一遍：
   启动 → 登录（用你 `init-admin` 时设的口令）→ 拿到 token → **杀掉 App 重开仍保持登录** →
   首页显示 → 退出登录；
3. 负例：错口令时提示来自服务端（不是"请求失败"）；未登录访问受保护接口应跳登录页；
4. §3 表的 10 条逐条打一遍，状态码应为 `200/201/401/403`，而不是 `404/405`；
5. `entry/src/main/module.json5` 里能看到 `ohos.permission.INTERNET`。

---

## 附：本次检查的方法与环境

| 项 | 值 |
| --- | --- |
| 被检提交 | `99c6d7e`（PR #2，合并 `a2cba67`）；服务端侧代码同为 `99c6d7e`，未改动 |
| 构建 | DevEco **6.1.1.300** 自带 JBR 21 + SDK API 24，`hvigorw assembleHap --no-daemon` → `BUILD SUCCESSFUL in 10.7 s` |
| 接口实测 | 真起服务端（HTTP 8080，临时数据目录），`Invoke-WebRequest` 打客户端代码里的每一条路径 |
| 对照依据 | `docs/api-design.md`（接口权威）· `server/src/views.cj`（字段形状）· `server/src/jsonw.cj`（信封/错误）· `server/src/paging.cj`（分页） |
| 未覆盖 | 没在设备/模拟器上跑过 App（无设备），所以"运行时行为"结论均来自代码 + 实测状态码 + 编译警告；§1.3 的表现推断请以真机实测为准 |

---

## 9. 复验结果（2026-09-15 · 针对 PR #3 `f5b4af7`）

队友按本清单改完并推了 PR #3（`9fb94a2 fix(client): 对齐后端 P0 接口契约`）。
复验方式：重新编译 + **把 §3 那张表做成脚本自动跑**（`server/tests/client-contract-check.ps1`，随本次复验新增）。

| 清单条目 | 复验结果 | 证据 |
| --- | --- | --- |
| §1.1 INTERNET 权限 | ✅ 已修 | `module.json5` 加了 `requestPermissions`；重新编译后**不再出现**那条 INTERNET 警告 |
| §1.2 baseUrl / setBaseUrl | ✅ 已修 | 新增 `config/Env.ets`（`http://10.0.2.2:8080/api/v1`），`EntryAbility.onCreate` 里调 `setBaseUrl(BASE_URL)` |
| §1.3 响应信封 | ✅ 已修 | `HttpClient.ets:140-144` 改成 `data: resultData['data']` |
| §2 错误形状 | ✅ 已修 | `HttpClient.ets:160-170` 读 `error.code` / `error.message`，`fields` 按对象取 |
| §3 十处路径/方法 | ✅ **全部已修** | 契约回归 **PASS 30 / FAIL 0**（客户端声明的 30 条调用，服务端全认得） |
| §3 字段 `register_code` | ✅ 已修 | `AuthApi.ets:57` + `RegisterPage.ets:319` |
| §4 时间字段建为 ISO 字符串 | ✅ 已修 | 各 API 接口里已是 `string \| null` |
| §6 `_commit_msg.txt` | ⚠️ **仍在仓库根** | 7 行文件，建议删掉 |
| §7 非阻塞项 | ⏳ 未动 | router deprecated 等，按排期处理即可 |

**唯一需要再确认的一条：明文 HTTP 的开关位置。**

PR #3 新增了 `resources/base/profile/network_config.json`，并在 `module.json5` 里用
`metadata: network_security_config` 引用它，键名是 `network-security-config` / `base-config` /
`cleartext-traffic-permitted`。但这套键名在**本机 DevEco 里搜不到**；hvigor 自己的类型定义
（`tools/hvigor/hvigor-ohos-plugin/src/options/configure/config-json-options.d.ts` 的 `NetworkObj`）
与 SDK 的两份 `configSchema_rich.json` 只认 **app 级**的写法：

```json5
// AppScope/app.json5
"app": {
  "network": {
    "cleartextTraffic": true      // 或 securityConfig.domainSettings.cleartextPermitted（按域名）
  }
}
```

当前 `AppScope/app.json5` **没有 `network` 字段**，所以那份独立配置文件**很可能被忽略**。
后果取决于运行时对明文流量的默认值（这一点从 SDK schema 里看不出来）：

- 若默认允许 → 现在就能连通，那份文件只是无效负担；
- 若默认禁止 → HTTP 请求会失败，App 连不上服务端。

**建议**：把开关写到 `AppScope/app.json5` 的 `app.network`（无论默认值如何都明确生效），
再在真机/模拟器上实测一次 HTTP 是否通；确认后那个 `network_config.json` + `metadata` 可以删掉。

### 怎么重跑这份复验

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\client-contract-check.ps1
```

脚本会自己：从 `entry/src/main/ets/api/*.ets` 抽出 (方法, 路径) → 起一个临时服务端 →
逐条打过去 → 断言**没有 404（路径写错）也没有 405（方法写错）**
（不带令牌时的正确响应是 401＝路由存在但需登录）。客户端再改接口时跑一次即可。
