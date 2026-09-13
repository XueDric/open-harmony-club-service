# 轻舟 TLS 支持 · 验证报告与缺陷清单

- 报告方：社团管理工具项目组
- 接收方：轻舟（QingZhou）框架团队
- 关联文档：`qingzhou-tls-requirement.md`（我们提出的 TLS 需求）
- 被测版本：`1cad35b`（`docs/API.md：补 listenTls 完整用法示例`）
- 验证日期：2026-09-13

---

## 0. 结论摘要

| 维度 | 结论 |
| --- | --- |
| **TLS 功能正确性** | ✅ **通过**（协议版本、握手、真实 HTTPS 请求全部符合预期） |
| **发布版本可编译性** | ❌ **失败（阻塞级）** |
| 示例可直接使用 | ⚠️ 部分可用（样例证书缺 SAN，客户端会拒绝） |
| TLS 测试覆盖 | ❌ 无 |

**一句话**：**功能实现本身是正确的，但当前提交编译不过，另有示例缺陷与测试空白。**

TLS 相关工作（`d0f11ef`）与我们提出的安全要求（见需求文档第 4 节）**逐条对照后基本达标**——尤其是"仅允许 TLS 1.2+"和"握手失败不致命"两条，实测确认。问题都集中在工程完整性上，不在设计上。

---

## 1. 验证环境与方法

### 1.1 环境

| 项 | 值 |
| --- | --- |
| 编译器 | `cjc 1.1.3 (cjnative)`，target `x86_64-w64-mingw32` |
| stdx | **1.1.3.1**（`cjc_version: 1.1.3`，版本与编译器对齐） |
| OpenSSL | 3.x，`deps/openssl/` 下的 `libcrypto-3-x64.dll` / `libssl-3-x64.dll` |
| 操作系统 | Windows |
| 测试客户端 | `openssl s_client`（OpenSSL 3.5.7） |

### 1.2 复核用的编译命令

```powershell
$CJC  = "D:\Cangjie\bin\cjc.exe"
$STDX = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx"
$ROOT = "E:\cangjie\qingzhou"
$libs = (Get-ChildItem "$STDX\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
$fw   = Get-ChildItem "$ROOT\src\*.cj" |
        Where-Object { $_.Name -notin @('main.cj','unit_tests.cj','manual_runner.cj') } |
        ForEach-Object { $_.FullName }

& $CJC @fw "$ROOT\examples\https.cj" --import-path $STDX -L $STDX @libs `
       -lcrypt32 -Woff unused -o "$ROOT\build\https.exe"
```

**开箱即用状态下，上面这条命令失败**（见 DEF-1）。

---

## 2. 缺陷清单

### DEF-1【阻塞】`src/app.cj` 无法编译：`PrivateKey.decodeFromPem` 不可用

**位置**：`src/app.cj` 的 `serveTls()`，`let key = PrivateKey.decodeFromPem(keyPem)`
（我们检出时为第 67 行；补上缺失的 import 后为第 68 行）

**现象**：开箱 `cjc` 编译直接失败，`examples/https.cj` 与任何使用 `serveTls` / `listenTls` 的代码都无法构建。

```
error: undeclared identifier 'PrivateKey'
 ==> src/app.cj:67:19:
   |
67 |         let key = PrivateKey.decodeFromPem(keyPem)
   |                   ^
1 error generated, 1 error printed.
```

**根因（两阶段，需分别修正）**

**① 缺少 import。** 新代码只引入了 `stdx.crypto.x509.*`，而 `PrivateKey` 并不由该包导出。

**② 即使补上正确的 import，该静态方法在 stdx 1.1.3.1 中仍未实现。**

我们逐个包做了探针编译，结果如下：

| 引入的包 | 编译结果 |
| --- | --- |
| `stdx.crypto.keys` | `undeclared identifier 'PrivateKey'` |
| **`stdx.crypto.common`** | **`static invocation contains unimplemented static function 'decodeFromPem'`** |
| `stdx.crypto.x509` | `undeclared identifier 'PrivateKey'` |
| `stdx.crypto.crypto` | `undeclared identifier 'PrivateKey'` |
| `stdx.crypto.kit` | `undeclared identifier 'PrivateKey'` |

即：`stdx.crypto.common.PrivateKey` 是一个**接口**，其静态工厂 `decodeFromPem` 在 **stdx 1.1.3.1 中没有实现**——这是**编译期**错误，不是运行期。

同一文件里的 `X509Certificate.decodeFromPem(certPem)` 则是正常的，所以问题只出在私钥这一侧。

**可用的替代 API**（从 stdx 静态库符号表提取，均已实现）：

| 包 | 可用的 PEM 解码入口 |
| --- | --- |
| `stdx.crypto.keys` | `RSAPrivateKey.decodeFromPem(String)` |
| | `ECDSAPrivateKey.decodeFromPem(String)` |
| | `SM2PrivateKey.decodeFromPem(String)` |
| | **`GeneralPrivateKey.decodeFromPem(String)`**（自动识别算法，推荐） |
| `stdx.crypto.x509` | `X509Certificate.decodeFromPem(String)` |

`TlsServerConfig` 接受的是 `stdx.crypto.common.PrivateKey` 接口，因此传具体实现即可。

**已验证的修复**（我们本地应用后编译通过、TLS 实测正常）：

```diff
--- a/src/app.cj
+++ b/src/app.cj
@@ -5,6 +5,8 @@ import std.env.*
 import stdx.net.http.*
 import stdx.net.tls.*
 import stdx.crypto.x509.*
+import stdx.crypto.keys.*
+import stdx.crypto.common.*
 import stdx.log.*
 import stdx.logger.*
 
@@ -64,7 +66,7 @@ public class QingZhouApp {
      * the X.509 certificate chain and its matching private key. */
     public func serveTls(port: UInt16, certPem: String, keyPem: String): ServerHandle {
         let certs = X509Certificate.decodeFromPem(certPem)
-        let key = PrivateKey.decodeFromPem(keyPem)
+        let key: PrivateKey = GeneralPrivateKey.decodeFromPem(keyPem)
         bootServer(port, Some(TlsServerConfig(certs, key)))
     }
```

**建议**

1. 采用上面的修复（`GeneralPrivateKey` 自动识别 RSA / ECDSA / SM2，兼容性最好）
2. 若你们的目标 stdx 版本中 `PrivateKey.decodeFromPem` 已实现，请**在提交信息或 README 中写明所需的最低 stdx 版本**——否则使用 1.1.3.1 的人会直接撞上这个错误
3. 建议 CI 至少保证「框架能在匹配的 stdx 上编译通过」这一条

---

### DEF-2【中】`examples/cert.pem` 缺少 SAN 扩展

**现象**

```
$ openssl x509 -in examples/cert.pem -noout -subject -issuer -dates -ext subjectAltName
subject=CN=localhost
issuer=CN=localhost
notBefore=Sep 12 15:44:23 2026 GMT
notAfter=Sep  9 15:44:23 2036 GMT
No extensions in certificate
```

证书**只有 CN，没有任何 SAN 扩展**。

**影响**

示例注释里的验证方式是 `curl -k`，`-k` 会跳过全部证书校验，所以看不出问题。但**任何做正规主机名校验的客户端都会拒绝这张证书**——包括我们要用的鸿蒙 App。而且现代 TLS 客户端**完全忽略 CN，只看 SAN**，所以这张证书在真实使用中等同于无效。

这对我们尤其致命：我们的客户端需要**内置信任该证书**再连接 `https://<公网IP>:8443`，没有 SAN 必然报名称不匹配。

**建议**

把示例中的重生成命令补上 SAN：

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout examples/key.pem -out examples/cert.pem \
    -days 3650 -subj "/CN=localhost" \
    -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

并建议在 `examples/https.cj` 的注释里**显式提醒"没有 SAN 的证书无法被正规客户端接受"**——这是个非常容易踩的坑，我们自己也差点按 `-k` 的验证方式以为示例是可用的。

---

### DEF-3【中】TLS 代码没有任何测试覆盖

现有测试套件共 **109 个场景**（我们自己数的：`PASS 109 / FAIL 0`），其中**没有一个涉及 TLS**。

TLS 是安全关键组件，建议至少补以下用例（对应需求文档第 4 节）：

| 建议用例 | 对应要求 |
| --- | --- |
| 证书路径/PEM 非法时，`serveTls` **抛错而非静默降级为明文** | 4.4（最重要） |
| 私钥与证书不匹配时启动失败 | 4.4 |
| 正常握手成功、能收发一个请求 | 基本功能 |
| TLS 1.0 / 1.1 被拒绝 | 4.1 |
| 畸形 ClientHello 不导致进程崩溃 | 4.7 |
| `shutdown()` 能排空 TLS 通道上的在途请求 | 优雅关闭 |

**DEF-1 恰好说明为什么这类测试必要**：一个"从未在匹配 stdx 上编译过"的提交，如果有编译或单测门禁，在提交时就会被拦下。

---

### DEF-4【低】`docs/API.md` 对协议版本描述不准确

`docs/API.md` 第 65 行写：

```cangjie
app.listenTls(8443, certPem, keyPem)   // 一行启用 TLS（TLSv1.3）
```

实测**TLS 1.2 同样可用**：

| 客户端参数 | 结果 |
| --- | --- |
| `-tls1_3` | ✅ `TLSv1.3` / `TLS_AES_256_GCM_SHA384` |
| `-tls1_2` | ✅ `TLSv1.2` / `ECDHE-RSA-AES256-GCM-SHA384` |

**实际行为是对的**（我们要求的正是"允许 1.2 + 1.3"），只是注释容易让人误以为 1.2 被关闭。建议改为"启用 TLS（最低 TLSv1.2）"。

---

### DEF-5【低】`manual_runner.cj` 的通过计数仍是写死的

输出 `All 114 unit-test scenarios PASSED`，而实际用例数为 **109**。这是已知的历史问题，仅提示一句：在补 DEF-3 的 TLS 用例时，建议顺手改成动态计数，否则数字会越飘越远。

---

## 3. 与需求文档的接口形态差异

我们在 `qingzhou-tls-requirement.md` 第 3 节建议的是 `certPath` / `keyPath`（文件路径），**实际实现收的是 PEM 字符串**：

```cangjie
public func serveTls(port: UInt16, certPem: String, keyPem: String): ServerHandle
public func listenTls(port: UInt16, certPem: String, keyPem: String): Unit
```

**这个设计我们可以接受**，甚至更灵活（便于从配置中心或内存加载）。但它有一个**责任转移**需要明确：

| 需求文档条目 | 原期望 | 实际归属 |
| --- | --- | --- |
| 4.4 禁止静默降级 | 框架负责 | **改为调用方负责**（读文件、异常处理都在我们这边） |
| 4.3 私钥格式兼容 | 框架负责 | 由 stdx 的 `decodeFromPem` 决定 |
| 4.1 仅允许 TLS 1.2+ | 框架负责 | ✅ 实测达标 |

我们接受 4.4 的责任转移，但**请在文档里明确写出**：「`serveTls` 在 PEM 无法解析时会抛异常，调用方不得捕获后回退到明文 `serve()`」。这条不写清楚，很容易被误用成静默降级。

另外，`TlsOptions` 式的可配置入口（`minVersion` / `maxVersion` 等）**本次未提供**。鉴于默认行为已经满足要求，我们不作为阻塞项，仅列为后续可选项。

---

## 4. 通过的验证项（正面对照）

修复 DEF-1 后，以下均为**实测结果**：

| # | 验证项 | 结果 |
| --- | --- | --- |
| 1 | `-tls1_3` 握手 | ✅ `TLSv1.3` / `TLS_AES_256_GCM_SHA384` |
| 2 | `-tls1_2` 握手 | ✅ `TLSv1.2` / `ECDHE-RSA-AES256-GCM-SHA384` |
| 3 | `-tls1_1`（客户端 `@SECLEVEL=0`） | ✅ **服务端拒绝**，`tlsv1 alert protocol version`（alert 70） |
| 4 | `-tls1`（客户端 `@SECLEVEL=0`） | ✅ **服务端拒绝**，同上 |
| 5 | 真实 HTTPS 请求 | ✅ `HTTP/1.1 200 OK` + `hello, QingZhou over HTTPS` |
| 6 | 原有 109 个测试场景 | ✅ **PASS 109 / FAIL 0**，无回归 |
| 7 | 明文 `listen` / `serve` 回归 | ✅ 行为未变 |

> 关于第 3、4 项：**首次测试时 `-tls1_1` 显示"失败"是假阴性**——那是 OpenSSL 客户端自身拒绝发起（`no protocols available`），不能证明服务端行为。加上 `-cipher "DEFAULT@SECLEVEL=0"` 降低客户端安全级别后重测，才拿到真正的**服务端 alert**。特此说明，避免你们用同样的方式误判。

**对照需求文档第 4 节的达标情况**：

| 要求 | 结论 |
| --- | --- |
| 4.1 仅允许 TLS 1.2 / 1.3 | ✅ **达标** |
| 4.2 证书链完整加载 | ⚠️ 未单独验证（示例为单证书链） |
| 4.3 私钥格式兼容 | ⚠️ 未单独验证（`GeneralPrivateKey` 预期兼容 PKCS#8/PKCS#1） |
| 4.4 禁止静默降级 | ⛔ **未验证**，且责任已转移到调用方（见第 3 节） |
| 4.5 私钥不进日志 | ⚠️ 未验证 |
| 4.6 证书只读一次 | ✅ 由 PEM 字符串入参天然满足 |
| 4.7 握手失败不致命 | ✅ 反复用错误协议连接，进程存活 |

---

## 5. 我们的处理与后续

1. **我们已在本地工作区应用 DEF-1 的补丁**（仅 `src/app.cj` 两处），用于完成上述验证。**该修改未提交**，我们不会把它当成长期 fork。
2. 期望 **DEF-1 由上游修复**；修复后我们会撤销本地补丁并重新验证。
3. 在 DEF-1 修复前，我们的开发用法是：**本地打补丁 + 记录补丁内容**，不修改任何其他框架文件。
4. **DEF-2 影响我们的正式使用**（客户端要内置证书）。我们会自行生成带 SAN 的证书，但建议示例同步修正，以免后续使用者踩同一个坑。
5. 我们**不阻塞**在这个问题上——已准备好 Nginx 反向代理 Fallback 方案，不采用框架 TLS 也能按期交付。但框架 TLS 一旦可用，我们会优先切过去，去掉一层运维组件。

---

## 附：我们的验证意图说明

这份报告的目的不是挑错，而是**把 TLS 这个安全组件的可用性钉死**。

我们的项目是社团内部工具，客户端要装到几十位成员的手机上、服务端放在公网，登录密码和 token 都会经过这条链路。所以我们宁可花时间把"证书加载失败会不会静默降级""TLS 1.1 到底有没有关掉"这类问题逐个实测，也不愿上线后才发现。

DEF-1 是个好消息式的发现：**功能是对的，只是没有在匹配的 stdx 上编译过。** 修掉它，这个特性就可以直接用了。
