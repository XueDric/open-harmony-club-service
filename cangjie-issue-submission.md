# 仓颉 Issue 提交稿 · 按表单字段逐块复制

> **表单**：Issues → 缺陷报告 | Bug Report
> **请先上传附件**：`cangjie-runtime-crash-report-2026-09-13.zip`（15 个文件 / 60 KB，含完整报告、WER 崩溃报告、事件日志、A/B 对照、复现与取证脚本）
> 下面的内容按表单字段分块；每块的正文可直接复制粘贴。**附件里是完整证据，各字段只放"能让人快速判断问题"的内容。**

---

## 字段 1 · 添加标题

> 直接复制下面这一行（约 105 字符，未超 200 上限）

```
[BUG] 仓颉 1.1.3 原生 exe 在 Windows 26300.9539（KB5124010）上启动即崩：main() 之前 0xC0000005 @ msvcrt!wcslen+0x4E
```

---

## 字段 2 · 系统环境 | System Environment

````
**操作系统**
- Windows 10 Pro / DisplayVersion 26H2 / build 26300
- 故障时 UBR = **9539**（已安装 2026-09 预览更新 **KB5124010**，2026-09-13 21:40:35 安装成功）
- 现已被我们回退至 UBR = **9445**（卸载该更新后问题消失，见"问题描述"）
- 区域/代码页：zh-CN，ACP = 936（**未**启用 UTF-8 beta）
- CPU 架构：x64

**仓颉工具链**
- 编译器：`D:\Cangjie\bin\cjc.exe`，`Cangjie Compiler: 1.1.3 (cjnative)`，`Target: x86_64-w64-mingw32`
- stdx：1.1.3.1（static）
- 运行时：`D:\Cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll`、`libboundscheck.dll`（文件时间 **2025-07-30**）
- 编译命令：`cjc hello.cj -o hello.exe`（无额外选项；`--version` 输出见附件）

**故障时的关键系统模块版本**
| DLL | 故障时(UBR 9539) | 卸载更新后(UBR 9445) | 是否变化 |
| --- | --- | --- | --- |
| ntdll.dll | 10.0.26100.9539 | 10.0.26100.9278 | **是** |
| msvcrt.dll | 7.0.26100.9444 | 7.0.26100.9444 | 否 |
| ucrtbase.dll / msvcp_win.dll | 10.0.26100.9444 | 10.0.26100.9444 | 否 |
| KERNEL32.DLL / KERNELBASE.dll | 10.0.26100.9278 | 10.0.26100.9278 | 否 |

**其他环境事实**
- **1.0.5 SDK 编译的 exe 同样崩溃**（不是 1.1.3 独有）
- 同机 `curl.exe` / `certutil.exe` / `where.exe`（同样使用 msvcrt/ucrt）**全部正常**
- 当前稳定版：官方下载中心 LTS = 1.0.5、STS = 1.1.3（**1.1.3 已是最新稳定版**，无更新版本可升级规避）
````

---

## 字段 3 · 问题描述 | Bug Description

````
## 现象

在 **Windows build 26300.9539（安装了 2026-09 预览更新 KB5124010）** 上，
**任何**仓颉编译出的原生 exe **启动即崩**：无任何输出，退出码 `-1073741819`（`0xC0000005` 访问违例）。

用探针确认崩溃发生在 **`main()` 之前**（运行时初始化阶段）：

- 写一个 `main()` 里第一件事就是"写文件"的程序：**文件从未生成**
- `println` 的输出为空只是因为 stdout 带缓冲、崩溃时未 flush，容易误判成"崩在别处"
- 长驻服务同样起不来（`serve` 后端口未监听）

## 崩溃签名

Windows 事件日志（Application Error，多个不同 exe 完全一致）：

```
Faulting module name: msvcrt.dll, version: 7.0.26100.9444
Exception code: 0xc0000005
Fault offset: 0x0000000000062f1e
Faulting module path: C:\WINDOWS\System32\msvcrt.dll
```

自行解析 `msvcrt.dll` 的 PE 导出表，该偏移落在 **`wcslen`**：

```
落在       : wcslen   (导出起始 0x62ED0，函数内偏移 +0x4E)
下一个导出 : wcsncat   (0x62FF0)
```

而 `libcangjie-runtime.dll` 与 `libboundscheck.dll` **都从 msvcrt 导入 `wcslen`**（二进制字符串扫描可见）。

## 一个反常点：这段 msvcrt 代码并没有被更新改动

WinSxS 中同时保留更新前后的两份 `msvcrt.dll`，我们逐字节对比了 `wcslen`：

```
A（更新前）7.0.26100.8875   wcslen RVA = 0x62ED0
B（更新后）7.0.26100.9444   wcslen RVA = 0x62ED0
对比 288 字节：完全相同（无一个字节差异）
```

即：**崩溃点所在代码一字未改，且更新前可用**。这提示问题不在 msvcrt 这段实现本身。

## 受控 A/B：卸载该更新后立即恢复

同一台机器、同一套仓颉 1.1.3、**同一份 msvcrt.dll**，仅回退 KB5124010 并重启后：

| 指标 | 故障时（UBR 26300.9539） | 卸载后（UBR 26300.9445） |
| --- | --- | --- |
| 最小 hello world | ❌ 0xC0000005，无输出 | ✅ exit 0，正常输出 |
| 我们项目的 exe（约 3900 行仓颉） | ❌ main() 未执行 | ✅ 单测 197 项全绿 |
| 真实 HTTP 冒烟测试 | ❌ 服务起不来 | ✅ 220 项全绿 |

## 已收窄：唯一变化的已加载模块是 ntdll.dll

卸载前后逐项对比崩溃进程加载的系统 DLL（见上表）：
**只有 `ntdll.dll` 从 10.0.26100.9539 变为 10.0.26100.9278**，
`msvcrt` / `ucrtbase` / `msvcp_win` / `KERNEL32` / `KERNELBASE` **全部未变**。

因此我们判断：问题很可能位于 **ntdll（Windows 加载器）9539 与仓颉运行时启动路径的交互**，
而不是 msvcrt。这也解释了上面"msvcrt 代码未改却崩在那里"的反常。

## 已排除（避免重复排查）

- 与本项目代码无关：空 hello world 同样崩
- 与 SDK 版本无关：1.1.3 与 1.0.5 都崩（各自配套运行时 DLL）
- 与环境变量/PATH/工作目录无关：全新默认环境、清空 `CANGJIE_HOME`、清空 `PATH`、极短路径、全新临时目录，均崩
- 无第三方 DLL 注入：WER 报告的 LoadedModule 列表里只有系统 DLL + 仓颉运行时；`AppInit_DLLs` 为空
- 无兼容性 shim：`HKCU/HKLM ...\AppCompatFlags\Layers` 中没有针对我们 exe 的条目
- `msvcrt` 是 **KnownDLL**，在 exe 同目录放同名 DLL 无效；把运行时目录全部 51 个 DLL 拷到 exe 同目录也无效

## 完整证据

见附件 `cangjie-runtime-crash-report-2026-09-13.zip`：
4 份完整 WER 崩溃报告、事件日志摘录、PE 定位与字节对比输出、系统信息、
以及我们自写的 **通用取证脚本**（`pe-func.ps1` 定位 RVA 属于哪个导出函数、
`pe-compare.ps1` 对比两个 DLL 同名导出的机器码）与**一键复现脚本**（`repro-hello.ps1`）。
````

---

## 字段 4 · 复现步骤 | Reproduction Steps

````
1. 准备环境：Windows 10 build **26300.9539**（已安装 2026-09 预览更新 **KB5124010**），
   Cangjie 1.1.3 (cjnative, x86_64-w64-mingw32)。

2. 新建 `hello.cj`（**注意：不要只打印，同时写一个文件**——`println` 有缓冲，
   崩溃时输出会丢失，容易误判）：

   ```cangjie
   import std.fs.*

   main(): Int64 {
       File.writeTo("marker.txt", "main-ran".toArray())
       println("hello from Cangjie")
       return 0
   }
   ```

3. 编译（请确保 `CANGJIE_HOME` 与 `cjc` 来自**同一个** SDK，否则会先撞上另一个
   前端/后端 LLVM 版本不一致的编译期崩溃）：

   ```powershell
   $env:CANGJIE_HOME = "D:\Cangjie"
   $env:PATH = "D:\Cangjie\bin;D:\Cangjie\third_party\llvm\bin;" + $env:PATH
   & "D:\Cangjie\bin\cjc.exe" hello.cj -o hello.exe
   ```

4. 运行：

   ```powershell
   .\hello.exe
   "exit = $LASTEXITCODE"     # 实际：无输出，exit = -1073741819 (0xC0000005)
   Test-Path .\marker.txt     # 实际：False —— 说明 main() 根本没执行
   ```

5. 查看崩溃签名（可见故障模块恒为 msvcrt.dll、偏移恒为 0x62f1e）：

   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'} -MaxEvents 3 |
     ForEach-Object { $_.Message -split "`n" | Select-Object -First 10 }
   ```

6. （可选）对照实验：卸载 KB5124010 并重启后，重复步骤 4 —— 程序**正常运行**。
   建议恢复该更新后再复现一次，以确认可重复性。

> 附：一键复现脚本见附件 `tools\repro-hello.ps1`（已内置工具链钉死与崩溃时机判断），
> 用法：`powershell -NoProfile -ExecutionPolicy Bypass -File .\repro-hello.ps1`
````

---

## 字段 5 · 期望效果 | Expected Behavior

````
1. 仓颉编译出的 exe 在上述 Windows 补丁级别上应能**正常启动并执行 `main()`**，
   输出 `hello from Cangjie`、生成 `marker.txt`、退出码为 0；
   而不是在运行时初始化阶段以 `0xC0000005` 崩溃。

2. 希望得到以下任一确认或结论：
   - 该问题是否可在你们的 **Windows 26300.9539 / KB5124010** 环境上复现；
   - 是否已知与 **ntdll 9539**（Windows 加载器）相关的行为变更会影响运行时初始化；
   - 1.1.3 是否有可用的修复版本，或 Nightly Builds 中是否已修复（如有，请告知版本号，我们来验证）；
   - 官方建议的规避方式（我们目前的规避是卸载 KB5124010，但这只对能控制更新的用户有效）。

3. 另建议：`cjc` 在启动时校验前端与后端（LLVM）工具链版本是否匹配。
   我们在用版本管理器切换 SDK 时遇到过 `CANGJIE_HOME` 与 `PATH` 中 `cjc` 来自不同 SDK 的情况，
   表现为 LLVM 层崩溃（`LLVM ERROR: Broken module found`），看起来像编译器缺陷，实际只是环境串台。
````

---

## 字段 6 · 源码/附件 | Code & Attachments

````
**附件（请上传）**：`cangjie-runtime-crash-report-2026-09-13.zip`
内容：
- `cangjie-runtime-startup-crash.md`　完整缺陷报告（含证据链与受控 A/B）
- `README.md`　包内导航与"三步自查"（对方可先按它快速复核结论）
- `evidence/ab-comparison.md`　故障态 vs 卸载后的逐项对照（含 ntdll 收窄表）
- `evidence/wer-reports/`　4 份完整 WER 崩溃报告
  （hello.exe 最小复现 / marker.exe 证明 main 未执行 / club-server.exe 我们的真实项目 / cjenv.exe 第三方仓颉程序）
- `evidence/event-log-crash-signature.txt`、`evidence/event-log-update-history.txt`　事件日志
- `evidence/pe-export-locate-wcslen.txt`、`evidence/pe-compare-wcslen-old-vs-new.txt`　PE 定位与字节对比
- `evidence/system-and-toolchain-AFTER-ROLLBACK.txt`　系统与工具链信息
- `tools/repro-hello.ps1`　一键复现
- `tools/pe-func.ps1`、`tools/pe-compare.ps1`　通用取证脚本（可自行复核我们的结论）

**最小复现代码**（与"复现步骤"一致）：

```cangjie
import std.fs.*

main(): Int64 {
    File.writeTo("marker.txt", "main-ran".toArray())
    println("hello from Cangjie")
    return 0
}
```

**可复现该问题的项目**（可选参考，规模约 3900 行仓颉）：
https://github.com/XueDric/open-harmony-club-service （`server/` 目录）
该项目的单测与 HTTP 冒烟测试在故障态下全部无法运行、卸载更新后全部通过，
可作为"影响面"的佐证。

**联系方式**：2318248319@qq.com
````

---

## 提交前检查

- [ ] 标题已粘贴（第 1 块）
- [ ] 附件 `cangjie-runtime-crash-report-2026-09-13.zip` 已上传（第 6 块）
- [ ] 六个字段中的必填项（带 `*`）都已填：系统环境、问题描述、复现步骤、期望效果
- [ ] 已在 Issues 里搜索过是否重复（表单第一条勾选项）
