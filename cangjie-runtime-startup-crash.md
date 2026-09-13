# 仓颉运行时启动即崩（Windows 10 26300.9539 + KB5124010）· 缺陷报告

- 报告方：社团管理工具项目组
- 接收方：仓颉（Cangjie）团队
- 报告日期：2026-09-13（+08:00）
- 严重级别：**阻塞级** —— 本机**所有**仓颉可执行文件均无法启动
- 涉及版本：cjc **1.1.3**（cjnative, x86_64-w64-mingw32）· stdx 1.1.3.1
  （**1.0.5 同样复现**，见 §5.1）

---

## 0. 结论摘要

| 维度 | 结论 |
| --- | --- |
| **现象** | 仓颉编译出的 exe **启动即崩**，退出码 `-1073741819`（`0xC0000005` 访问违例） |
| **崩溃时机** | **进 `main()` 之前**（已用探针证明，见 §2.3）；stdout 全空 |
| **故障模块** | 恒为 `C:\WINDOWS\System32\msvcrt.dll`（7.0.26100.9444），偏移恒为 **`0x62f1e`** |
| **崩溃指令位置** | 落在导出函数 **`wcslen`** 内（RVA `0x62ED0`，函数内 `+0x4E`）；两个仓颉运行时 DLL 都从 msvcrt 导入 `wcslen` |
| **触发条件** | 2026-09-13 **21:40:35 安装成功「2026-09 预览更新 (KB5124010)」**（build 26300.xxxx）；同一台机器当日 13:58 一切正常 |
| **同一份 msvcrt 的 `wcslen` 机器码** | 更新前后**完全相同**（旧 10.0.26100.8875 vs 新 .9444，同 RVA、288 字节全同）→ **不是 msvcrt 这段代码被改坏** |
| **是否 CRT 通病** | 否。`curl.exe` / `certutil.exe` / `where.exe` 等同样使用 msvcrt/ucrt 的程序**全部正常** |
| **我们的判断** | 仓颉原生运行时（DLL 构建于 **2025/7/30**）在 **Windows build 26300.9539** 这一补丁级别上，于 `main()` 之前发生非法内存访问；具体机制需要你们的符号与调试能力定位 |
| **影响** | 本机**无法编译验证、无法运行、无法测试任何仓颉程序**；我们的服务端项目（仓颉 1.1.3 + 轻舟框架）被完全阻塞 |
| **我们的临时处置** | 卸载 KB5124010（预览更新），或换机器；同时提交本报告 |

---

## 1. 环境

### 1.1 操作系统

| 项 | 值 |
| --- | --- |
| 产品 | Windows 10 Pro |
| DisplayVersion | **26H2** |
| CurrentBuild / UBR | **26300 / 9539** |
| 系统区域 / 代码页 | 中文（简体，中国）· ACP = **936**（**未**启用 UTF-8 beta） |
| 虚拟化安全 | VBS **运行中**（`VirtualizationBasedSecurityStatus=2`，`SecurityServicesRunning={2,3,4}`，`CodeIntegrityPolicyEnforcementStatus=2`） |
| 触发更新的安装时间 | **2026-09-13 21:40:35**（`WindowsUpdateClient` ID 19，KB5124010） |
| 本次开机时间 | **2026-09-13 21:40:13** |
| **最后一次一切正常** | **2026-09-13 13:58**（当时同一 exe 的 165 项 HTTP 冒烟测试全绿） |

### 1.2 仓颉工具链

| 项 | 值 |
| --- | --- |
| 编译器 | `D:\Cangjie\bin\cjc.exe`，`Cangjie Compiler: 1.1.3 (cjnative)`，`Target: x86_64-w64-mingw32` |
| 运行时 | `D:\Cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll`、`libboundscheck.dll`（**文件时间 2025-07-30**） |
| stdx | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx`（1.1.3.1，静态链接） |
| 编译命令 | `cjc <src...> --import-path <stdx> -L <stdx> <libstdx*.a> -lcrypt32 -Woff unused -o app.exe` |

### 1.3 相关系统 DLL（更新后）

| DLL | 版本 | 文件时间 |
| --- | --- | --- |
| `msvcrt.dll` | **7.0.26100.9444** | 2026-09-09 |
| `ucrtbase.dll` | 10.0.26100.9444 | 2026-09-09 |
| `msvcp_win.dll` | 10.0.26100.9444 | 2026-09-09 |
| `ntdll.dll` | 10.0.26100.9539 | 2026-09-11 |
| `KERNEL32.DLL` / `KERNELBASE.dll` | 10.0.26100.9278 | 2026-09-11 |

> WinSxS 中同时保留更新前的 `msvcrt.dll` **10.0.26100.8875**（2026-07-16），
> 本报告 §4.3 的字节对比用的就是这两份。

---

## 2. 现象与最小复现

### 2.1 现象

任何仓颉原生 exe 运行后：
- **没有任何输出**（stdout/stderr 均为空）
- 退出码 `-1073741819` = **`0xC0000005`（访问违例）**
- 长驻服务同样起不来：`serve` 之后端口未监听，HTTP 请求「无法连接到远程服务器」

### 2.2 最小复现（hello world 即复现）

`hello.cj`：

```cangjie
main(): Int64 {
    println("hello from Cangjie")
    return 0
}
```

```powershell
& "D:\Cangjie\bin\cjc.exe" hello.cj -o hello.exe
.\hello.exe
# 实际：无输出，$LASTEXITCODE = -1073741819
```

**注意**：`println` 是带缓冲的，崩溃时不会 flush，因此"没有输出"不等于"没跑"。
我们用下面的探针证明 **`main()` 根本没执行**。

### 2.3 关键探针：`main()` 从未执行

`marker.cj`（写文件是 open/write/close，立即落盘，不受 stdout 缓冲影响）：

```cangjie
import std.fs.*

main(): Int64 {
    File.writeTo("marker.txt", "main-ran".toArray())
    println("stdout line (buffered)")
    return 0
}
```

结果：**`marker.txt` 从未生成** → 崩溃发生在**运行时初始化阶段、`main()` 之前**。

---

## 3. 事件日志证据

### 3.1 触发更新（决定性时间点）

```
日志：System
Provider：Microsoft-Windows-WindowsUpdateClient
Event ID：19
时间：2026-09-13 21:40:35
内容：Installation Successful: Windows successfully installed the following update:
      2026-09 预览更新 (KB5124010) (26300.xxxx)
```

紧随 21:40:13 的系统启动事件（`Kernel-General` ID 12）。**当日 13:58 同一批 exe 仍完全正常。**

### 3.2 应用程序错误（崩溃签名）

```
日志：Application
Provider：Application Error
Event ID：1000
Faulting application name: hello.exe
Faulting module name: msvcrt.dll, version: 7.0.26100.9444
Exception code: 0xc0000005
Fault offset: 0x0000000000062f1e
Faulting module path: C:\WINDOWS\System32\msvcrt.dll
```

**该偏移在多次、多种 exe 上完全一致**（我们自己项目的 exe、轻舟框架的 exe、空 hello world、
以及 1.0.5 SDK 编译出的 exe）——说明是**确定性**的代码路径，不是随机内存问题。

### 3.3 WER 报告的已加载模块（排除注入）

`C:\ProgramData\Microsoft\Windows\WER\ReportArchive\...\Report.wer` 中的 `LoadedModule` 列表：
**只有系统 DLL + 仓颉运行时**（`libcangjie-runtime.dll`、`libboundscheck.dll`），
**没有任何第三方模块**（无杀软、无注入 DLL）。`AppInit_DLLs` 为空，`LoadAppInit_DLLs=0`。

---

## 4. 定位过程

> 说明：本机**没有** WinDbg / cdb / procdump，且当前会话**不是管理员**
> （无法启用 WER LocalDumps），因此我们**没能拿到调用栈**。以下结论靠事件日志 + 自行解析 PE 得到。
> 如你们需要 dump，请告知在无管理员权限下可用的取 dump 方式，我们可以立刻配合采集。

### 4.1 崩溃偏移落在 `wcslen` 内

我们自行解析了 `msvcrt.dll` 的 PE 导出表（DOS→PE→可选头→导出目录→按 RVA 排序）：

| 导出函数 | RVA |
| --- | --- |
| `wcscspn` | 0x62E60 |
| **`wcslen`** | **0x62ED0** ← 崩溃偏移 `0x62F1E` 落在其内（**+0x4E**） |
| `wcsncat` | 0x62FF0 |

即崩溃指令位于 `wcslen` 的代码区间（或在紧接其后的非导出函数中——仅凭导出表无法完全区分，
这点需要你们的符号辅助）。

**旁证**：对两个仓颉运行时 DLL 做二进制字符串扫描，二者**都从 `msvcrt.dll` 导入 `wcslen`**：

| DLL | 命中的导入名 |
| --- | --- |
| `libcangjie-runtime.dll` | `wcslen`、`msvcrt.dll`、`ucrtbase.dll` |
| `libboundscheck.dll` | `wcslen`、`msvcrt.dll` |

`wcslen` 读的是**宽字符串指针**。在 `wcslen` 内发生 `0xC0000005`，通常意味着传入的指针无效，
或字符串在映射页边界处没有终止符。

### 4.2 不是环境变量 / 路径 / 环境配置问题

| 实验 | 结果 |
| --- | --- |
| 用**全新默认环境**启动（`Start-Process -UseNewEnvironment`） | 仍崩 |
| 清空 `CANGJIE_HOME` 后启动 | 仍崩 |
| 清空 `PATH` 后启动 | 仍崩 |
| 放到极短路径 `C:\cjtest\` 运行 | 仍崩 |
| 放到全新临时目录、只带 exe + 2 个运行时 DLL | 仍崩 |
| 把运行时目录里**全部 51 个 DLL** 都拷到 exe 同目录 | 仍崩 |

### 4.3 关键反证：`msvcrt!wcslen` 的机器码**没有被更新改动**

WinSxS 里同时存在更新前后两份 `msvcrt.dll`，我们对 `wcslen` 逐字节对比：

```
A（更新前）：...\WinSxS\amd64_microsoft-windows-msvcrt_..._10.0.26100.8875_...\msvcrt.dll
             版本 7.0.26100.8875    wcslen RVA = 0x62ED0
B（更新后）：C:\Windows\System32\msvcrt.dll
             版本 7.0.26100.9444    wcslen RVA = 0x62ED0
对比 288 字节：**完全相同**（无一个字节差异）
```

**推论**：崩溃点所在的代码在更新前后一字未改，且该代码在更新前是可用的
（当日 13:58 一切正常）。所以问题**不在 msvcrt 这段实现**，而在于
**仓颉运行时在这个新的系统补丁级别下，走到了会传入非法指针的路径**。

### 4.4 不是 msvcrt/CRT 的普遍性问题

同一台机器、同一时刻：

| 程序 | 结果 |
| --- | --- |
| `curl.exe --version` | ✅ exit 0 |
| `certutil.exe` | ✅ exit 0 |
| `where.exe` | ✅ exit 0 |
| 任意仓颉 exe | ❌ `0xC0000005` |

说明 msvcrt / ucrt 本身工作正常，**只有仓颉运行时的启动路径踩中**。

---

## 5. 已排除的可能（避免重复排查）

### 5.1 与仓颉版本无关

| 试验 | 结果 |
| --- | --- |
| 1.1.3 SDK 编译的 exe + 1.1.3 运行时 | ❌ 崩 |
| **1.0.5 SDK 编译的 exe + 1.0.5 自带的 52 个运行时 DLL** | ❌ **同样崩** |

### 5.2 与项目代码无关

最小 `hello.cj`、以及完全不带业务逻辑的探针程序，**同样崩**。
我们自己的项目为此已排除（同一 exe 在 13:58 还跑通过全部 165 项测试）。

### 5.3 与以下因素无关

- 目录 / 路径长度 / 工作目录 / 驱动器
- `PATH`、`CANGJIE_HOME` 等环境变量（含全新默认环境）
- 第三方安全软件或 DLL 注入（WER 模块列表已证实无注入；`AppInit_DLLs` 为空）
- 兼容性 shim（`HKLM/HKCU ...\AppCompatFlags\Layers` 中没有针对我们 exe 的条目）
- 代码页 / 区域设置（ACP = 936，未开 UTF-8 beta）
- 在 exe 同目录放 `msvcrt.dll`（**无效**：msvcrt 是 **KnownDLL**，系统强制使用 `System32` 那份）

---

## 6. 影响

- 本机**无法编译验证、无法运行、无法测试任何仓颉程序**。
- 我们的项目（社团内部管理工具，服务端 = 仓颉 1.1.3 + 轻舟框架，Windows 部署）
  **完全阻塞**：能编译出 exe，但一跑就崩，因此无法做任何运行时验证。
- 值得注意的是：**编译（cjc）本身正常**，崩的是**运行**。所以这个问题在"只编译不运行"的
  CI 里不会被发现——建议你们的 CI 至少包含一条"编译产物能在目标 Windows 上启动"的冒烟。

---

## 7. 我们的临时处置

1. **优先卸载 KB5124010**（它是**预览更新**，属可选更新，卸载成本低）：
   设置 → Windows 更新 → 更新历史记录 → 卸载更新；或管理员执行
   `wusa /uninstall /kb:5124010`，然后重启。
2. 若必须保留该更新：**换一台机器**开发与验证，同时等待你们的结论。
3. 我们也评估了官方下载中心：当前 **LTS = 1.0.5、STS = 1.1.3**，
   **1.1.3 已是最新稳定版**，没有更新的稳定版可供升级规避。

---

## 8. 希望你们确认 / 提供的

1. **能否在 Windows build 26300.9539（+ KB5124010）上复现**？如果你们的测试机没有这个补丁级别，
   我们可以提供更完整的环境清单，或配合采集任何你们需要的诊断数据。
2. **`msvcrt!wcslen` 里那次访问是如何发生的**：是传入指针无效，还是字符串在页边界缺少终止符？
   如果是后者，很可能是运行时的某个初始化步骤（例如取路径 / 环境 / 模块信息）在返回长度变化后
   没有正确处理，属于**可以修**的问题。
3. **这个补丁级别下是否有已知的 API 行为变更**会影响 `libcangjie-runtime.dll` 的初始化
   （尤其涉及字符串 / 路径 / 区域设置 / 模块枚举的调用）。
4. **无管理员权限下取崩溃转储的推荐做法**（我们这边没有 cdb/WinDbg/procdump，
   也没有 LocalDumps 必需的 HKLM 写权限）。若你们给出方式，我们可立即回传 dump。
5. **Nightly Builds 是否已包含相关修复**；若有，请告知版本号，我们可以验证。

---

## 附 A · 复现脚本（可直接粘贴）

```powershell
# 1) 编译一个最小仓颉程序
@'
main(): Int64 {
    println("hello from Cangjie")
    return 0
}
'@ | Set-Content -Encoding UTF8 .\hello.cj

& "D:\Cangjie\bin\cjc.exe" .\hello.cj -o .\hello.exe

# 2) 运行：无输出，退出码 -1073741819
.\hello.exe
"exit = $LASTEXITCODE"

# 3) 查崩溃签名
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'} -MaxEvents 3 |
  ForEach-Object { $_.Message -split "`n" | Select-Object -First 10 }

# 4) 查触发更新
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'} -MaxEvents 5 |
  Where-Object { $_.Id -eq 19 } | ForEach-Object { "$($_.TimeCreated)  $($_.Message)" }
```

## 附 B · 崩溃时进程内已加载的模块（摘自 WER 报告，节选）

```
LoadedModule[0]=<我们的 exe>
LoadedModule[1]=C:\WINDOWS\SYSTEM32\ntdll.dll
LoadedModule[2]=C:\WINDOWS\System32\KERNEL32.DLL
LoadedModule[3]=C:\WINDOWS\System32\KERNELBASE.dll
LoadedModule[4]=C:\WINDOWS\System32\msvcrt.dll              ← 故障模块
LoadedModule[9]=<exe 同目录>\libcangjie-runtime.dll
LoadedModule[12]=<exe 同目录>\libboundscheck.dll
LoadedModule[*]=... SHELL32 / USER32 / GDI32 / WS2_32 / RPCRT4 / CRYPT32 / combase / OLEAUT32 / ucrtbase / msvcp_win
（无任何第三方模块）
```

## 附 C · 与本次问题无关、但顺带反馈的一条工程建议

我们在同一台机器上还遇到：只要 `CANGJIE_HOME` 指向 A 版本的 SDK、而 `PATH` 里的 `cjc` 是 B 版本，
编译器就会因**前端与后端 LLVM 版本不一致**而直接崩溃：

```
Intrinsic has incorrect argument type!  @llvm.cj.get.vtable.func
LLVM ERROR: Broken module found, compilation aborted!
（opt.exe 来自另一份 SDK 的 third_party\llvm\bin）
```

这看起来像编译器 bug，实际只是环境串台（我们用 cjenv 之类的版本管理器切换 SDK 时触发）。
建议 `cjc` 在启动时校验前置/后端工具链版本，或至少给出明确报错，而不是 LLVM 层的崩溃。

---

*报告方联系方式：可通过本仓库 issue 或项目组直接联系（XueDric / open-harmony-club-service）。*
*我们随时可以配合补充日志、抓 dump 或在你们的复现环境上验证修复版本。*
