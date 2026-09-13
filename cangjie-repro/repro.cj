// 最小复现程序：仓颉原生 exe 在 Windows 11 build 26300.9539 上启动即崩
//
// 环境
//   操作系统：Windows 11 专业版 x64，DisplayVersion 26H2，build 26300，UBR 9539
//             已安装 2026-09 预览更新 KB5124010，安装成功时间 2026-09-13 21:40:35
//   编译器  ：cjc 1.1.3 cjnative，Target 为 x86_64-w64-mingw32
//   运行时  ：D:\Cangjie\runtime\lib\windows_x86_64_cjnative
//             libcangjie-runtime.dll 与 libboundscheck.dll，文件时间 2025-07-30
//
// 现象
//   编译成功，但运行本程序时无任何输出，退出码为 1073741819 的相反数，即 0xC0000005 访问违例。
//
// 为什么程序里要写一个文件
//   println 是带缓冲的，进程崩溃时缓冲区不会 flush，所以没有输出并不能说明 main 没有执行。
//   这里在 main 的第一行写文件，open、write、close，立即落盘，用 marker.txt 是否存在
//   来判断崩溃位置：
//     marker.txt 不存在  ->  崩溃发生在 main 之前，即运行时初始化阶段
//     marker.txt 存在    ->  崩溃发生在 main 之内，或在其返回时
//   实测：marker.txt 从未生成，说明 main 根本没有被执行。
//
// 编译与运行，Windows PowerShell
//   请确保 CANGJIE_HOME 与所用的 cjc 来自同一个 SDK，否则会先撞上另一个
//   前端与后端 LLVM 版本不一致的编译期崩溃，与本问题无关。
//
//   $env:CANGJIE_HOME = "D:\Cangjie"
//   $env:PATH = "D:\Cangjie\bin;D:\Cangjie\third_party\llvm\bin;" + $env:PATH
//   & "D:\Cangjie\bin\cjc.exe" repro.cj -o repro.exe
//   .\repro.exe
//   "exit = $LASTEXITCODE"      期望 0，故障环境下为 -1073741819
//   Test-Path .\marker.txt      期望 True，故障环境下为 False
//
// 崩溃签名，取自 Windows 事件日志 Application Error，多个不同程序完全一致
//   Faulting module name: msvcrt.dll, version: 7.0.26100.9444
//   Exception code      : 0xc0000005
//   Fault offset        : 0x0000000000062f1e
//   该偏移落在 msvcrt 的导出函数 wcslen 内，起始 RVA 为 0x62ED0，函数内偏移 0x4E；
//   而 libcangjie-runtime.dll 与 libboundscheck.dll 都从 msvcrt 导入 wcslen。
//
// 附
//   1. 同一环境下 1.0.5 SDK 编译的程序同样崩溃。
//   2. 同机 curl.exe、certutil.exe、where.exe 等同样使用 msvcrt 的程序全部正常。
//   3. 卸载 KB5124010 并重启后，本程序正常运行。

import std.fs.*

main(): Int64 {
    File.writeTo("marker.txt", "main-ran".toArray())
    println("hello from Cangjie")
    return 0
}
