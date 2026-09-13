# 社团管理工具 · 服务端构建脚本
#
# 编译路径（已在 HANDOFF §2 / qingzhou-tls-verification.md §1.2 实测过）：
#   cjc 1.1.3 + stdx 1.1.3.1（静态）+ 轻舟源码，**同一次调用、同一个包**。
#
# 为什么不用 cjpm：轻舟自己的 examples/*.cj 都写 `package qingzhou`，
# 框架既定用法就是与框架源码一起编译（build.sh 也是这么做的）。
#
# 用法：
#   .\build.ps1                 编译 + 复制依赖 DLL 到 build\
#   .\build.ps1 -NoDll          只编译（本机已装好 DLL 时更快）

param(
    [string]$Cjc        = "D:\Cangjie\bin\cjc.exe",
    [string]$Stdx       = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx",
    [string]$QingZhou   = "E:\cangjie\qingzhou",
    [string]$RuntimeDir = "D:\Cangjie\runtime\lib\windows_x86_64_cjnative",
    [switch]$NoDll
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$src  = Join-Path $root "src"
$out  = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $out | Out-Null

if (-not (Test-Path $Cjc))  { throw "找不到编译器：$Cjc" }
if (-not (Test-Path $Stdx)) { throw "找不到 stdx：$Stdx" }
if (-not (Test-Path $QingZhou)) { throw "找不到轻舟源码：$QingZhou" }

$libs = (Get-ChildItem "$Stdx\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })

# 排除框架自己的入口与测试：main.cj 有 main()、unit_tests.cj / manual_runner.cj 是框架自测，
# 我们的 main.cj 提供入口。这与 qingzhou-tls-verification.md 里编译 examples/https.cj 的命令一致。
$fw = Get-ChildItem "$QingZhou\src\*.cj" |
      Where-Object { $_.Name -notin @('main.cj', 'unit_tests.cj', 'manual_runner.cj') } |
      ForEach-Object { $_.FullName }

$app = Get-ChildItem "$src\*.cj" | ForEach-Object { $_.FullName }
if ($app.Count -eq 0) { throw "没有找到服务端源码：$src" }

$exe = Join-Path $out "club-server.exe"
Write-Host "[build] 轻舟 $($fw.Count) 个文件 + 服务端 $($app.Count) 个文件 -> $exe"

& $Cjc @fw @app --import-path $Stdx -L $Stdx @libs -lcrypt32 -Woff unused -o $exe
if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }
Write-Host "[build] 编译通过"

if (-not $NoDll) {
    # 部署文件集（deploy-windows-verify.md §2）：exe + 4 个 DLL。
    # 缺 libcangjie-runtime.dll 会启动即失败；缺两个 OpenSSL 3 DLL 则 crypto 运行时才报错。
    $dlls = @(
        @{ n = "libcangjie-runtime.dll"; d = $RuntimeDir },
        @{ n = "libboundscheck.dll";     d = $RuntimeDir },
        @{ n = "libcrypto-3-x64.dll";    d = "$QingZhou\deps\openssl" },
        @{ n = "libssl-3-x64.dll";       d = "$QingZhou\deps\openssl" }
    )
    foreach ($x in $dlls) {
        $p = Join-Path $x.d $x.n
        if (-not (Test-Path $p)) { throw "缺少依赖 DLL：$p" }
        Copy-Item $p $out -Force
    }
    Write-Host "[build] 已复制 4 个依赖 DLL 到 build\"
}
