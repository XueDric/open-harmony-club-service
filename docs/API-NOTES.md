# 服务端 API 事实清单（探针实测）

> 环境：cjc **1.1.3** (cjnative, x86_64-w64-mingw32) + stdx **1.1.3.1** + 轻舟 `1cad35b`（含 DEF-1 本地补丁）
> 方法：`.probe/` 下写了 8 轮最小探针逐个编译验证，**只采用实测通过的签名**。
> 这份清单是为了让后续开发不用重复试错——写代码前先查这里。

---

## 1. 标准库确切签名（实测通过）

### std.fs

```cangjie
File.readFrom(path: String): Array<UInt8>
File.writeTo(path: String, buffer: Array<UInt8>): Unit
File.create(path: String): File            // 用完要 close()
File.appendTo(path: String, buffer: Array<UInt8>): Unit
exists(path: String): Bool                  // 顶层函数，**不是 File.exists**
remove(path: String, recursive!: Bool): Unit
rename(from: String, to!: String, overwrite!: Bool): Unit   // 必须具名传参
Directory.create(path: String, recursive!: Bool): Unit
```

### std.time

```cangjie
DateTime.now().toUnixTimeStamp().toSeconds(): Int64     // 返回 Duration，不是 Int64
DateTime.now().toUnixTimeStamp().toMilliseconds(): Int64
MonoTime.now(); (t1 - t0).toMilliseconds(): Int64
```

- `now.month` 是枚举 `Month`，**不是 Int64**。本项目一律不用本地字段，自己按 epoch 算历法（见 `timex.cj`）。
- 轻舟 `docs/API.md` 已注明：std.time **没有 UTC 工厂方法**。

### std.random

```cangjie
let r = Random()
r.nextBytes(buf: Array<UInt8>): Unit     // ⚠️ 是"填充缓冲区"，不是 nextBytes(n) 取返回值
r.nextUInt64()                            // 未验证，本项目未使用
let buf = Array<UInt8>(n, repeat: 0)
```

### stdx.encoding.hex

```cangjie
toHexString(Array<UInt8>): String
fromHexString(String): ?Array<UInt8>      // 注意返回 Option
```

### stdx.crypto.digest

```cangjie
let md = SHA256(); md.write(bytes); md.finish(): Array<UInt8>
let mac = HMAC(key, { => SHA256() })      // ⚠️ 第二个参数是**工厂 lambda**，不是 SHA256() 实例
mac.write(bytes); mac.finish(): Array<UInt8>
```

- **没有现成的 PBKDF2**：本项目在 `auth.cj` 自行实现（RFC 2898），
  并用 RFC 7914 §11 公开向量 + .NET `Rfc2898DeriveBytes` 双向对拍。
- 100000 次迭代实测 **约 340 ms**（本机）。

### stdx.encoding.json

```cangjie
JsonObject(): 无参构造；o.put(k, JsonValue)；o.get(k): ?JsonValue
JsonArray():  a.add(v)；a.size(): Int64（**方法**）；a.get(i): ?JsonValue
JsonValue.fromStr(s): JsonValue          // 解析失败**抛异常**，不是返回 Option
v.asObject() / v.asString() / v.asInt() / v.asBool()   // 类型不符抛异常
JsonValue.toString()                     // 序列化
JsonString(s) / JsonInt(i) / JsonBool(b) / JsonFloat(f) / JsonNull()
```

- ⚠️ `JsonObject` / `JsonArray` **都不实现 Iterator**，不能 `for (v in arr)`。
  数组按下标 `while` 遍历；本项目落盘用**数组 + 下标**，避免需要枚举 JSON 对象的键。

### std.sort / 集合 / 字符串

```cangjie
sort(arr)                                   // 基础类型默认排序
sort(arr, by!: (T, T) -> Ordering)          // ⚠️ 具名参数是 by，不是 comparator
HashMap<K,V>: m[k]=v；m.get(k): ?V；m.contains(k)；for ((k,v) in m) 元组遍历
HashSet<T>: add / contains
String: .size（**字节数**）、toArray(): Array<UInt8>、String.fromUtf8(bytes)、
        trimAscii()、toAsciiLower()、String.join(arr, delimiter:)、StringBuilder
Int64.parse / UInt16.parse                   // UInt16.parse 需 import std.convert.*
Array: .size 属性、arr[a..b] 切片、arr.clone()
```

### 异常

```cangjie
public class X <: Exception {
    public init(...) {
        super(msg)          // ⚠️ super() 必须是构造函数里**第一条语句**
        ...
    }
}
```
- `Option` **没有 `getOrElse`**，用 `??` 运算符：`opt ?? 默认值`。
- **枚举不支持 `==`**，一律用 `match`（本项目 `perms.cj` 全部如此）。

---

## 2. 轻舟（QingZhou）用法要点

```cangjie
QingZhouApp().use(requestId()).use(logger()).use(bodyParser()).use(cors())
            .use(router.middleware()).use(timeout(15000)).onError(errHandler)
Router().get/post/put/patch/delete/add("/a/:id", { ctx: Context, _: () -> Unit => ... })
ctx.paramOr("id", "")   ctx.requestHeader("authorization")   ctx.bodyJson(): ?JsonValue
ctx.status(200).json(s) / .body(s) / .header(k, v)
ctx.err(): ?Exception                    // onError 链里读
ctx.http → h.request.remoteAddr          // 取客户端地址；⚠️ 实测文本形如 "IP:端口"（例 127.0.0.1:14764），
                                         //    按 IP 用必须先剥端口（见 h_ops.cj 的 clientIpOf）
app.serve(port): ServerHandle            // 非阻塞；handle.wait() 阻塞；handle.shutdown() 优雅关闭
```

- 错误链（`compose.cj`）：业务链抛异常 → `ctx.throw_err(e)` → 执行 `onError` 注册的中间件 → 最后 `ctx.commit()`。
- `serveTls(port, certPem, keyPem)` 收的是 **PEM 字符串**（不是路径），且内部用 `GeneralPrivateKey`
  （上游修好 DEF-1 后即可去掉本地补丁）。

---

## 3. 踩过的坑（**不要再踩**）

| # | 坑 | 现象 / 解法 |
| --- | --- | --- |
| 1 | **crypto 的两个 DLL 必须与 exe 同目录** | 缺失时**编译期无警告**，运行时才 `CryptoException: Can not load openssl library or function SHA256_Init` |
| 2 | **同包编译会撞名字** | 我们与轻舟同一 `package qingzhou`。框架已占用 `pad2`、`verifyPassword`、`hashPassword`、`randomHex`、`randomId`、`sha256Hex`、`bodyStr`、`jsonGetStr`、`exists`、`size`、`get` 等。新增顶层函数前**先 grep 框架源码** |
| 3 | `Directory.create(recursive: true)` 目录已存在**照样抛异常** | 必须先 `exists()` 判断。这个坑会让"第二次落盘"直接崩 |
| 4 | `rename` 的 `to` / `overwrite` 是具名参数 | `rename(a, b)` 编译不过 |
| 5 | `ArrayList` 要 `import std.collection.*` | 忘了就 `undeclared identifier 'ArrayList'` |
| 6 | 源码里出现 `⚠️`（U+26A0 + **U+FE0F**） | 编译器报 `warning: unsecure character:\u{FE0F}`。**去掉变体选择符**即可 |
| 7 | 块注释里不能出现 `/*`（HANDOFF 已记） | 仓颉块注释可嵌套，会吞到文件末尾 |
| 8 | 服务 `cwd` 必须是 exe 所在目录 | 数据目录按相对路径读；`cwd` 不对会出现**假失败 + 假通过** |
| 9 | Windows 无 `std.runtime.Signal` | 优雅关闭只能靠 `POST /admin/shutdown`，**必须限本机** |
| 10 | 在请求线程里直接 `handle.shutdown()` | 会等待本请求自己结束 → **死锁**。要 `spawn` 到后台线程 |

### PowerShell 脚本（Windows PS 5.1）

| # | 坑 | 解法 |
| --- | --- | --- |
| 11 | 无 BOM 的 UTF-8 `.ps1` 按 **ANSI** 解析 | 中文注释会导致 `Missing closing '}'` 之类的**假语法错**。脚本必须存为 **UTF-8 with BOM** |
| 12 | 执行策略默认禁止跑脚本 | `powershell -NoProfile -ExecutionPolicy Bypass -File xxx.ps1` |
| 13 | 非 2xx 响应读不到 body | `Invoke-WebRequest` 已把流读走，`GetResponseStream()` 拿到空串。用 `$_.ErrorDetails.Message` |
| 14 | `Start-Process -PassThru` 拿不到 `ExitCode` | 用"进程自行退出 + 日志收尾行"作为优雅关闭的证据 |
| 15 | `$args` 是自动变量 | 函数里不要用 `$args` 做局部变量名 |
| 16 | **`-Body` 传字符串会按 ANSI 发送** | 中文请求体到达服务端就是乱码（表现为"改名字成功了但名字没变"）。必须 `[System.Text.Encoding]::UTF8.GetBytes($json)` + `Content-Type: application/json; charset=utf-8` |
| 17 | 响应里的中文比较 | 配合上一条：请求体乱码时，返回的中文自然也对不上，容易被误判成服务端 bug |
| 18 | `ConvertFrom-Json` 单元素数组会退化成对象 | 断言 `.Count` 在 PS 5.1 下对单对象返回 1，可用但要心里有数 |
| 19 | **cjenv 切换 SDK 会打断本项目的构建** | 它会改写 `CANGJIE_HOME` 并把 shims 塞进 PATH。若 `CANGJIE_HOME` 指向别的 SDK（如 1.0.5）而 PATH 里的 `cjc` 仍是 `D:\Cangjie` 的 1.1.3，就会出现**前端 1.1.3 + 后端 LLVM 1.0.5** 串台：`LLVM ERROR: Broken module found … @llvm.cj.get.vtable.func … opt.exe 崩溃`。看起来像编译器 bug，实际是环境串台。`build.ps1` 已显式钉死 `CANGJIE_HOME` 与 PATH |
| 20 | **`.`NET 正则替换里 `$_` 是特殊记号** | `[regex]::Replace($t, 模式, "...$_.Exception.Message...")` 中的 `$_` 会被替换成**整个输入串**，把文件写坏（本次真把 `tls-check.ps1` 写坏了）。改用字面量 `.Replace()`，或避开 `$_` |
| 21 | **`curl` 是 `Invoke-WebRequest` 的内置别名** | 自定义函数取名 `Curl` 会被别名覆盖（PowerShell 解析顺序：别名 > 函数 > cmdlet > 外部程序），于是悄悄调用到了 `Invoke-WebRequest`。改名 `CurlReq` |
| 22 | **PS 5.1 的 `Invoke-WebRequest` 在自签 HTTPS 上会失败** | 报「基础连接已经关闭: 发送时发生错误」，而**同一时刻** curl、`openssl s_client`、`.NET HttpWebRequest`、原始 `SslStream` 全部正常（HTTP 下 `Invoke-WebRequest` 也正常）。因此 TLS 校验统一改用 curl + openssl，避免把客户端怪癖误判成服务端缺陷 |
| 23 | **原生命令参数里的双引号会被吃掉** | `curl -d '{"a":"b"}'` 里的引号在 PS 5.1 传参时被剥离，服务端收到非法 JSON（表现为 400）。改用 `--data-binary @临时文件` |
| 24 | **openssl / curl 往 stderr 写日志** | 脚本若用 `$ErrorActionPreference = "Stop"`，会把「原生命令写了 stderr」当成致命错误直接中断。用 `Continue` + 显式断言 |
| 25 | **部署包里带着私钥** | `server/dist/club-server/certs/key.pem` 与 `server/certs/key.pem` 都必须在 `.gitignore` 里；`git check-ignore -v <路径>` 自检 |
| 26 | **局部编辑会让 `.ps1` 丢掉 BOM** | 第 11 条讲的是"新脚本要带 BOM"，这里补上更隐蔽的一半：**已经正常的脚本被局部改写后 BOM 会消失**（多数工具默认写无 BOM 的 UTF-8）。下一次运行时整个文件按 ANSI 解析，中文变乱码，报出 `意外的标记"build\smoke-data"`、`表达式或语句中包含意外的标记` 这类**看起来像手写语法错误**的解析失败——很容易误判成"脚本改坏了"。判定：`[System.IO.File]::ReadAllBytes($p)[0..2]` 是否为 `EF BB BF`。改完 `.ps1` 必须确认 BOM 仍在。**2026-09-14 实测补充**：用**文件编辑工具**（不是 shell）对 `smoke.ps1` 做局部编辑，BOM **同样会丢**（编辑前 `EF BB BF`、编辑后没有），已手动补回 —— 所以"只要不用 shell 处理就没事"是错的，**任何局部编辑之后都要查一遍** |
| 27 | **不要用 PowerShell 双引号字符串处理 `.md` / `.cj` / `.ps1` 的内容** | 双引号里反引号是转义引导符：反引号 + `r` → CR、+ `a` → BEL、+ `t` → TAB、+ `n` → LF。markdown 里的代码跨度（如 `` `restore-member` ``、`` `router.middleware()` ``）**正好全部命中**，于是反引号与首字母被静默吃掉，行被拆断或塞进不可见控制字符——本次真把 `docs/code-review.md` 写坏（2 个裸 BEL 字节 + 3 行残缺重复片段）。改用文件编辑工具，或用**单引号**字符串（单引号里反引号不是转义符）。改完自检非法控制字符（脚本见 `docs/code-review.md` 的 N-2 条） |
| 28 | **`Get-Content` 读 UTF-8 无 BOM 的中文文件会丢行** | PS 5.1 不带 `-Encoding UTF8` 时按 **ANSI** 解码：某些 UTF-8 中文字节落在 GBK **前导字节**区间（0x81–0xFE），会把紧跟其后的 `0x0A` 当成第二字节**吞掉**，两行被并成一行 —— 于是**行数统计与内容都不可信**。实测：`docs\HANDOFF.md` 真实 **371** 行，`(Get-Content).Count` 只报 **283**；`docs\frontend-brief.md` 真实 **256** 行，只报 **222**。读文本一律用 `Get-Content -Encoding UTF8`，或直接用文件工具；字节级检查（`[System.IO.File]::ReadAllBytes`）不受影响 |

---

## 5. 环境级故障：本机仓颉 exe 启动即崩（2026-09-13 晚，**已定位到具体更新**）

**现象**：**所有**仓颉可执行文件启动即崩——本项目 exe、轻舟框架 exe、`cjenv.exe`，
以及 1.0.5 / 1.1.3 两套 SDK 的产物，一律 `exit=-1073741819`（`0xC0000005` 访问违例）。
用一个"进 `main` 就写文件"的探针确认：**`main()` 根本没执行**；stdout 全空（缓冲未 flush，
所以短命令"没有输出"是假象）。长驻服务同样起不来（`/health` 连不上）。

### 5.1 根因（证据链）

| 环节 | 证据 |
| --- | --- |
| **触发点** | 事件日志 `Microsoft-Windows-WindowsUpdateClient` ID 19：**21:40:35 "Installation Successful: 2026-09 预览更新 (KB5124010) (26300.xxxx)"**，紧随 21:40:13 的开机 |
| **时间对照** | 当日 13:58 时 M2 的 165 项冒烟测试**全绿**；21:40 重启 + 该更新之后全崩 |
| **崩溃位置** | 事件日志中故障模块恒为 `C:\WINDOWS\System32\msvcrt.dll`，偏移恒为 `0x62f1e`；自行解析 PE 导出表得知该偏移落在 **`wcslen`**（起始 `0x62ED0`，函数内 +0x4E） |
| **关键反证** | 用 WinSxS 里更新前的 `msvcrt 10.0.26100.8875` 与更新后的 `10.0.26100.9444` 逐字节对比：**`wcslen` 的机器码完全相同**（同 RVA、288 字节全同）。所以**不是 msvcrt 自身被改坏**，而是运行时所处的环境变了 |
| **不是 CRT 通病** | `curl.exe` / `certutil.exe` / `where.exe` 等同样用 msvcrt/ucrt 的程序**全部正常** → 只有仓颉运行时的启动路径踩中 |
| **没有第三方干扰** | WER 的 `LoadedModule` 列表里只有系统 DLL + 仓颉运行时，无注入；`AppInit_DLLs` 为空；无 AppCompat shim |

**已排除**：与本项目代码无关（空 hello world 同样崩）· 与 SDK 版本无关（1.0.5 与 1.1.3 都崩）·
与目录 / 路径长度 / PATH / `CANGJIE_HOME` / 干净环境无关 · `msvcrt` 是 **KnownDLL**
（同目录放同名 DLL 无效；拷全 51 个运行时 DLL 也无效）。

**没有可升级的仓颉版本**：官方下载中心当前 **LTS = 1.0.5、STS = 1.1.3**，
**1.1.3 已是最新稳定版**（仅有 Nightly Builds 可试）。

### 5.2 结论

**这是 Windows 更新 KB5124010（2026-09 预览更新）与仓颉 1.1.3 原生运行时的兼容性问题**，
不是本项目代码问题。仓颉运行时（DLL 构建于 2025/7/30）在这个新的 Windows 补丁级别上
在 `main` 之前就走到了非法内存访问。

### 5.3 处置建议与**验证结果**

1. ✅ **实测有效：卸载 KB5124010**（预览更新，属可选更新）：设置 → Windows 更新 → 更新历史记录 →
   卸载更新，重启即可恢复。**我们已在 2026-09-13 22:18 按此恢复开发。**
2. 若必须保留该更新：**换一台机器**验证/开发；同时把本页的证据反馈给仓颉团队
   （[UsersForum](https://gitcode.com/Cangjie/UsersForum/overview)），附上 `msvcrt!wcslen+0x4E`、
   KB 编号，以及下面"唯一变化的是 ntdll"这一收窄结论。
3. 也可以试 **Nightly Builds** 的 SDK（`gitcode.com/Cangjie/nightly_build/releases`），
   但那是非稳定通道，本项目基线是 1.1.3。

### 5.4 受控 A/B：卸载更新后立即恢复

**同一台机器、同一套仓颉 1.1.3、同一份 `msvcrt.dll`**，卸载 KB5124010 并重启后完全反转：

| 指标 | 故障时（UBR 26300.9539） | 卸载后（UBR 26300.9445） |
| --- | --- | --- |
| 最小 hello world | ❌ `0xC0000005`，无输出 | ✅ `exit 0`，正常输出 |
| `club-server.exe test`（单测） | ❌ 崩（`main()` 未执行） | ✅ **PASS 197 / FAIL 0** |
| `tests\smoke.ps1`（真实 HTTP） | ❌ 服务起不来 | ✅ **PASS 220 / FAIL 0** |

**唯一版本发生变化的已加载模块是 `ntdll.dll`**：

| DLL | 故障时 | 卸载后 | 变化 |
| --- | --- | --- | --- |
| **`ntdll.dll`** | **10.0.26100.9539** | **10.0.26100.9278** | ✅ |
| `msvcrt.dll` | 7.0.26100.9444 | 7.0.26100.9444 | — |
| `ucrtbase.dll` / `msvcp_win.dll` | 10.0.26100.9444 | 10.0.26100.9444 | — |
| `KERNEL32.DLL` / `KERNELBASE.dll` | 10.0.26100.9278 | 10.0.26100.9278 | — |

→ 这解释了"`msvcrt!wcslen` 机器码一字未改却崩在那里"的反常：**变的是 ntdll（加载器）**。
怀疑范围应收窄到**加载器与该版本仓颉运行时的交互**。

> **更正**：早前我们把"`PendingFileRenameOperations` 非空"当作"系统更新未收尾"的证据。
> 卸载后**运行正常时该项依然非空**，该判据不成立，特此更正。

> 完整缺陷报告（可直接提交给仓颉团队）**已移出仓库**，见上层
> `cangjie-upstream\cangjie-runtime-startup-crash.md`；
> 当时的证据包（4 份 WER 崩溃报告、事件日志、PE 对照输出）是一次性产物，已按需删除；
> 结论都固化在本文档里。

---

## 4. 重新探针的方法

需要验证新 API 时，照这个模式做（**不要盲写**）：

```powershell
$CJC  = "D:\Cangjie\bin\cjc.exe"
$STDX = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx"
$libs = (Get-ChildItem "$STDX\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
& $CJC probe.cj --import-path $STDX -L $STDX @libs -lcrypt32 -Woff unused -o probe.exe
```

探针验证过的事实请**回写进本文档**，并把探针文件删掉（一次性）。
