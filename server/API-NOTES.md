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
ctx.http → h.request.remoteAddr          // 取客户端地址（本项目转成字符串后判断）
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
