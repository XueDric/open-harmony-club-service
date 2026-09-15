# 社团管理工具 · 服务端容量基准
#
# 目的：给 docs/capacity-baseline.md 里的"改造前/改造后"数字一个**可复现**的来源。
# 这里打的是真实 HTTP，量的是客户端能感知的端到端耗时（含序列化与网络）。
#
# 用法（Windows PowerShell 5.1 默认禁止跑脚本，必须带 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1 -Members 3000 -Tasks 3000
#
# 对比历史版本（用 git worktree 在旧提交上编译，数据形状完全一致）：
#   git worktree add ..\bench-old HEAD
#   (cd ..\bench-old\server; powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1)
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1 -Exe ..\bench-old\server\build\club-server.exe
#   git worktree remove ..\bench-old
#
# 造数据：init-admin 生成一个带**真实口令哈希**的库，再把首任会长那条成员记录克隆成 N 条
#        （共用同一份 pw_salt/pw_hash，于是所有人都是 password123）；
#        任务也先建 1 条真记录，再克隆成 M 条 —— 不手写 JSON 模板，避免 schema 漂移。
#        不走接口慢慢造 1000 个账号/任务：那要几分钟，而且造数本身就被待测代码拖慢。
#
# 指标（各取 Rounds 次的中位数）：
#   login   POST /api/v1/auth/login          PBKDF2-SHA256 10 万次迭代（动作 2：哈希移出锁）
#   tasks   GET  /api/v1/tasks               列表 + 排序（动作 1：插入排序 -> 堆排序）
#   members GET  /api/v1/members?size=50     列表 + 排序（同上，成员表本身）
#   write   POST /api/v1/tasks               改内存 + 落盘（动作 4：整库 IO 移出锁）
# 并发项（4 个请求同时发）：
#   动作 2/4 不降低**单个**请求的耗时，它们降低的是"锁被占住时别人在门外排队"的时间，
#   所以只有并发才看得见。串行因子 = 并发墙钟 / (4 × 单发中位数)，≈1 即被完全串行化。
#
# 用独立数据目录 build\bench-data，绝不碰正式数据 data\。

param(
    [int]$Members = 1000,
    [int]$Tasks = 1000,
    [int]$Rounds = 10,
    [int]$Port = 18090,
    [string]$Exe = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root "build\club-server.exe" }
if (-not (Test-Path $Exe)) { throw "找不到服务端可执行文件：$Exe（先跑 build.ps1）" }

$dataRel = "build\bench-data"
$dataAbs = Join-Path $root $dataRel
$dbPath  = Join-Path $dataAbs "db.json"
$logOut  = Join-Path $root "build\bench-server.out.log"
$logErr  = Join-Path $root "build\bench-server.err.log"
$base    = "http://127.0.0.1:$Port"

# 调接口。返回 @{ status; json; raw }；非 2xx 不抛异常，靠 status 判断。
function Call-Api([string]$method, [string]$path, $body = $null, [string]$token = "") {
    $headers = @{}
    if ($token) { $headers["Authorization"] = "Bearer $token" }
    $p = @{
        Method          = $method
        Uri             = "$base$path"
        UseBasicParsing = $true
        Headers         = $headers
        TimeoutSec      = 120
    }
    if ($null -ne $body) {
        # PS 5.1 的坑：Body 传字符串会按 ANSI 发送，中文到达服务端就是乱码。
        $json = if ($body -is [string]) { $body } else { $body | ConvertTo-Json -Compress }
        $p["ContentType"] = "application/json; charset=utf-8"
        $p["Body"] = [System.Text.Encoding]::UTF8.GetBytes($json)
    }
    try {
        $r = Invoke-WebRequest @p
        $j = $null
        if ($r.Content) { try { $j = $r.Content | ConvertFrom-Json } catch { } }
        return @{ status = [int]$r.StatusCode; json = $j; raw = [string]$r.Content }
    } catch {
        $txt = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $txt = [string]$_.ErrorDetails.Message }
        $code = 0
        $resp = $_.Exception.Response
        if ($null -ne $resp) { $code = [int]$resp.StatusCode }
        return @{ status = $code; json = $null; raw = $txt }
    }
}

# 取 JSON 里某个数组的第一个对象（按花括号配平，跳过字符串里的括号）。
function Get-FirstObject([string]$text, [string]$key) {
    $i = $text.IndexOf('"' + $key + '":[')
    if ($i -lt 0) { throw "db.json 里找不到 $key 数组" }
    $start = $text.IndexOf('{', $i)
    if ($start -lt 0) { throw "$key 数组里没有对象" }
    $depth = 0; $inStr = $false; $esc = $false
    for ($j = $start; $j -lt $text.Length; $j++) {
        $c = $text[$j]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
        } else {
            if ($c -eq '"') { $inStr = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    return @{ Text = $text.Substring($start, $j - $start + 1); Start = $start; End = $j }
                }
            }
        }
    }
    throw "$key 的对象没有闭合"
}

# 把 db.json 里某个数组的第一个对象克隆成 $Count 份（成员改 phone/name/role，任务改 title）。
function Expand-Array([string]$text, [string]$key, [int]$Count, [string]$prefix, [bool]$isMember) {
    $o = Get-FirstObject $text $key
    $one = $o.Text
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($one)
    if ($isMember) { $orig = [regex]::Match($one, '"name":"([^"]*)"').Groups[1].Value }
    else           { $orig = [regex]::Match($one, '"title":"([^"]*)"').Groups[1].Value }
    if (-not $orig) { throw "$key 模板里找不到要替换的字段" }

    for ($i = 2; $i -le $Count; $i++) {
        $c = $one.Replace('"id":1,', '"id":' + $i + ',')
        if ($isMember) {
            $c = $c.Replace('"phone":"13800000000"', '"phone":"139' + ("{0:D8}" -f $i) + '"')
            $c = $c.Replace('"name":"' + $orig + '"', '"name":"' + $prefix + ("{0:D5}" -f $i) + '"')
            $c = $c.Replace('"role":"president"', '"role":"member"')
        } else {
            $c = $c.Replace('"title":"' + $orig + '"', '"title":"' + $prefix + ("{0:D5}" -f $i) + '"')
            # 截止时间必须**打散**：GET /tasks 按 due_at 排序（store.cj 的 sortedTasksByDue），
            # 而数组来自 HashMap 迭代（id 大致升序）。若克隆时留 due_at=0，
            # 键就退化成 "常量+id"，插入排序恰好走 O(n) 最好情况 —— 那就测不出排序改动的价值了。
            # $i * 7919 mod 一年 是确定性的乱序（7919 与模数互质）。
            $due = 1789000000 + (($i * 7919) % 31536000)
            $c = $c.Replace('"due_at":0', '"due_at":' + $due)
        }
        [void]$sb.Append(',').Append($c)
    }
    return $text.Substring(0, $o.Start) + $sb.ToString() + $text.Substring($o.End + 1)
}

function Read-Db { return [System.IO.File]::ReadAllText($dbPath, [System.Text.Encoding]::UTF8) }
function Write-Db([string]$t) {
    [System.IO.File]::WriteAllText($dbPath, $t, (New-Object System.Text.UTF8Encoding($false)))
}

function Start-Server {
    $p = Start-Process -FilePath $Exe `
        -ArgumentList @("serve", "$Port", $dataRel) `
        -WorkingDirectory $root `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    for ($i = 0; $i -lt 600; $i++) {
        Start-Sleep -Milliseconds 50
        if ($p.HasExited) { break }
        try {
            $r = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    $sw.Stop()
    if (-not $ready) {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        $tail = ""
        if (Test-Path $logOut) { $tail = (Get-Content $logOut -Raw) }
        throw "服务未能在 :$Port 就绪（$Members 人档）。日志：`n$tail`n$logErr"
    }
    $p | Add-Member -NotePropertyName StartupMs -NotePropertyValue $sw.ElapsedMilliseconds -Force
    return $p
}

function Stop-Server($p) {
    if ($null -eq $p) { return }
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    try { $p.WaitForExit(5000) | Out-Null } catch { }
}

# 量 Rounds 次，返回中位数/最小/最大（毫秒）。先热身一次，避免把连接建立算进去。
function Measure-Call([string]$name, [scriptblock]$body, [int]$Rounds) {
    & $body 0 | Out-Null
    $times = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Rounds; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $body $i | Out-Null
        $sw.Stop()
        [void]$times.Add([int]$sw.ElapsedMilliseconds)
    }
    $sorted = @($times | Sort-Object)
    $med = $sorted[[int][Math]::Floor($sorted.Count / 2)]
    $line = "{0,-8} median={1,6} ms   min={2,6}   max={3,6}" -f $name, $med, $sorted[0], $sorted[-1]
    Write-Host "[bench] $line"
    return @{ name = $name; median = $med; min = $sorted[0]; max = $sorted[-1] }
}

# 并发墙钟：N 个请求**同时**发出，量最后一个回来的时间。
# 用 .NET HttpClient 的 Task 做真并发（Start-Job 起进程太重，会把测量本身污染掉）。
function Measure-Concurrent([string]$name, [int]$N, [scriptblock]$makeTask, [int]$SingleMedian) {
    # PS 5.1 默认没加载 System.Net.Http（.NET 4.x 把它放在独立程序集里）
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    # 热身，避免把连接建立算进去
    $warm = & $makeTask $client -1
    $warm.GetAwaiter().GetResult() | Out-Null

    $tasks = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $N; $i++) {
        [void]$tasks.Add((& $makeTask $client $i))
    }
    [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks.ToArray())
    $sw.Stop()

    $wall = [int]$sw.ElapsedMilliseconds
    $serial = 1.0
    if ($SingleMedian -gt 0) { $serial = [Math]::Round($wall / ($N * $SingleMedian), 2) }
    $bad = 0
    foreach ($t in $tasks) {
        $code = [int]$t.Result.StatusCode
        if ($code -ne 200 -and $code -ne 201) { $bad++ }
    }
    $client.Dispose()
    $line = "{0,-10} N={1}  并发墙钟={2,6} ms  平均={3,5} ms/个  串行因子={4}  非2xx={5}" -f `
        $name, $N, $wall, [int]($wall / $N), $serial, $bad
    Write-Host "[bench] $line"
    return @{ name = $name; wall = $wall; serial = $serial; bad = $bad }
}

Push-Location $root
$srv = $null
try {
    Write-Host "=== 社团管理工具 · 服务端容量基准 ==="
    Write-Host "可执行文件: $Exe"
    Write-Host "规模      : $Members 名成员 / $Tasks 个任务 / $Rounds 轮"
    Write-Host ""

    # ---------- 1. 造库：克隆成员 ----------
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue
    & $Exe init-admin 13800000000 password123 $dataRel | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "init-admin 失败（exit=$LASTEXITCODE）" }

    $text = Read-Db
    $text = Expand-Array $text "members" $Members "Member-" $true
    # next_member 必须跟上，否则新注册会和克隆出来的 id 撞车
    $text = [regex]::Replace($text, '"next_member":\d+', '"next_member":' + ($Members + 1))
    Write-Db $text
    Write-Host "[bench] 成员档 db.json = $([Math]::Round((Get-Item $dbPath).Length / 1MB, 2)) MB"

    # ---------- 2. 造库：先建 1 个真任务，再克隆成 $Tasks 个 ----------
    $srv = Start-Server
    $login = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    if ($login.status -ne 200) { throw "登录失败：status=$($login.status) body=$($login.raw)" }
    $token = $login.json.data.token
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "模板任务"; owner_id = 1 } $token
    if ($r.status -ne 201 -and $r.status -ne 200) { throw "模板任务失败：status=$($r.status) body=$($r.raw)" }
    Stop-Server $srv
    $srv = $null

    $text = Read-Db
    $text = Expand-Array $text "tasks" $Tasks "Task-" $false
    $text = [regex]::Replace($text, '"next_task":\d+', '"next_task":' + ($Tasks + 1))
    Write-Db $text

    $dbMB = [Math]::Round((Get-Item $dbPath).Length / 1MB, 2)
    Write-Host "[bench] 完整库 db.json = $dbMB MB（$Members 成员 + $Tasks 任务）"

    # ---------- 3. 起服务、登录 ----------
    $srv = Start-Server
    $startupMs = $srv.StartupMs
    Write-Host "[bench] 启动就绪 = $startupMs ms"
    $login = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    if ($login.status -ne 200) { throw "登录失败：status=$($login.status) body=$($login.raw)" }
    $token = $login.json.data.token
    Write-Host ""

    # ---------- 4. 单发打点 ----------
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add((Measure-Call "login"   { Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" } } $Rounds))
    [void]$rows.Add((Measure-Call "tasks"   { Call-Api "GET"  "/api/v1/tasks" $null $token } $Rounds))
    [void]$rows.Add((Measure-Call "members" { Call-Api "GET"  "/api/v1/members?page=1&size=50" $null $token } $Rounds))
    [void]$rows.Add((Measure-Call "write"   { param($i) Call-Api "POST" "/api/v1/tasks" @{ title = "基准任务 $i-$([guid]::NewGuid().ToString('N').Substring(0,8))"; owner_id = 1 } $token } $Rounds))

    # ---------- 5. 并发打点（动作 2/4 的真正考场） ----------
    $loginMedian = 0; $writeMedian = 0
    foreach ($r in $rows) {
        if ($r.name -eq "login") { $loginMedian = $r.median }
        if ($r.name -eq "write") { $writeMedian = $r.median }
    }
    Write-Host ""
    $b = '{"phone":"13800000000","password":"password123"}'
    $crow = New-Object System.Collections.ArrayList
    [void]$crow.Add((Measure-Concurrent "login并发" 4 {
        param($c, $i)
        $ct = New-Object System.Net.Http.StringContent($b, [Text.Encoding]::UTF8, "application/json")
        return $c.PostAsync("$base/api/v1/auth/login", $ct)
    } $loginMedian))
    [void]$crow.Add((Measure-Concurrent "write并发" 4 {
        param($c, $i)
        $j = '{"title":"并发任务 ' + $i + '","owner_id":1}'
        $ct = New-Object System.Net.Http.StringContent($j, [Text.Encoding]::UTF8, "application/json")
        $req = New-Object System.Net.Http.HttpRequestMessage("POST", "$base/api/v1/tasks")
        $req.Content = $ct
        $req.Headers.Add("Authorization", "Bearer $token")
        return $c.SendAsync($req)
    } $writeMedian))

    Write-Host ""
    # 机器可读的一行，方便往文档里贴
    $cells = @()
    foreach ($r in $rows) { $cells += ("{0}={1}" -f $r.name, $r.median) }
    Write-Host ("[bench] RESULT members=$Members tasks=$Tasks db=${dbMB}MB startup=$startupMs " + ($cells -join " "))
    foreach ($r in $crow) { Write-Host ("[bench] CONC {0} wall={1} serial={2} bad={3}" -f $r.name, $r.wall, $r.serial, $r.bad) }
} finally {
    Stop-Server $srv
    Pop-Location
}
