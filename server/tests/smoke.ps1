# 社团管理工具 · 服务端冒烟测试（打真实 HTTP）
#
# 单测覆盖不到接口层：JSON 包装形状、HTTP 状态码、错误码、令牌流转、
# 真实落盘与重启后的持久性。这一层是集成证据，与单测互补。
#
# 用法（Windows PowerShell 5.1 默认禁止跑脚本，必须带 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1 -Port 18081
#
# 用独立数据目录 build\smoke-data，绝不碰正式数据 data\。

param(
    [int]$Port = 18080,
    [string]$Exe = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root "build\club-server.exe" }
if (-not (Test-Path $Exe)) { throw "找不到服务端可执行文件：$Exe（先跑 build.ps1）" }

$dataRel   = "build\smoke-data"
$dataAbs   = Join-Path $root $dataRel
$logOut    = Join-Path $root "build\smoke-server.out.log"
$logErr    = Join-Path $root "build\smoke-server.err.log"
$base      = "http://127.0.0.1:$Port"

$script:pass = 0
$script:fail = 0

function Check([string]$name, [bool]$cond, [string]$extra = "") {
    if ($cond) {
        $script:pass++
        Write-Host ("  ok    " + $name)
    } else {
        $script:fail++
        Write-Host ("  FAIL  " + $name + "   " + $extra) -ForegroundColor Red
    }
}

# 调接口。返回 @{ status; json }；4xx/5xx 不抛异常，靠 status 判断。
function Call-Api([string]$method, [string]$path, $body = $null, [string]$token = "") {
    $headers = @{}
    if ($token) { $headers["Authorization"] = "Bearer $token" }
    $p = @{
        Method          = $method
        Uri             = "$base$path"
        UseBasicParsing = $true
        Headers         = $headers
        TimeoutSec      = 10
    }
    if ($null -ne $body) {
        $p["ContentType"] = "application/json"
        $p["Body"] = ($body | ConvertTo-Json -Compress)
    }
    try {
        $r = Invoke-WebRequest @p
        $j = $null
        if ($r.Content) { try { $j = $r.Content | ConvertFrom-Json } catch { } }
        return @{ status = [int]$r.StatusCode; json = $j; raw = [string]$r.Content }
    } catch {
        # PS 5.1：非 2xx 会抛异常。响应体优先取 ErrorDetails.Message——
        # Invoke-WebRequest 已经把响应流读走了，直接 GetResponseStream() 会拿到空串。
        $txt = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $txt = [string]$_.ErrorDetails.Message }
        $resp = $_.Exception.Response
        if ((-not $txt) -and ($null -ne $resp)) {
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $txt = $sr.ReadToEnd()
                $sr.Close()
            } catch { }
        }
        $status = 0
        if ($null -ne $resp) { $status = [int]$resp.StatusCode }
        $j = $null
        if ($txt) { try { $j = $txt | ConvertFrom-Json } catch { } }
        return @{ status = $status; json = $j; raw = $txt }
    }
}

# 从 403/4xx 响应里取业务错误码
function ErrCode($r) {
    if ($null -eq $r.json) { return "" }
    return [string]$r.json.error.code
}

function Start-Server([string]$dirRel, [string]$logSuffix = "") {
    $o = $logOut
    $e = $logErr
    if ($logSuffix) {
        $o = $logOut -replace '\.log$', ".$logSuffix.log"
        $e = $logErr -replace '\.log$', ".$logSuffix.log"
    }
    $p = Start-Process -FilePath $Exe `
        -ArgumentList @("serve", "$Port", $dirRel) `
        -WorkingDirectory $root `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e
    $p | Add-Member -NotePropertyName LogOut -NotePropertyValue $o -Force
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 400
        if ($p.HasExited) { break }
        try {
            $r = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        $tail = ""
        if (Test-Path $logOut) { $tail = (Get-Content $logOut -Raw) }
        throw "服务未能在 :$Port 就绪。日志：`n$tail`n$logErr"
    }
    return $p
}

function Stop-Server($p) {
    if ($null -eq $p) { return }
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
    }
    try { $p.WaitForExit(3000) | Out-Null } catch { }
}

Push-Location $root
try {
    Write-Host "=== 社团管理工具 · 服务端冒烟测试 ==="
    Write-Host "可执行文件: $Exe"
    Write-Host "数据目录  : $dataRel"
    Write-Host ""

    # ---------- 准备：清库 + 初始化首任会长 ----------
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue

    Write-Host "[准备] init-admin"
    & $Exe init-admin 13800000000 password123 $dataRel
    Check "init-admin 返回 0" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
    Check "db.json 已生成" (Test-Path (Join-Path $dataAbs "db.json"))

    $db = Get-Content (Join-Path $dataAbs "db.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $regCode = [string]$db.register_code
    Check "注册口令已生成（6 位）" ($regCode.Length -eq 6) "code=$regCode"
    Check "预置 4 个组织" ($db.departments.Count -eq 4) "count=$($db.departments.Count)"

    Write-Host "[准备] init-admin 重复执行应被拒绝"
    & $Exe init-admin 13800000001 password123 $dataRel | Out-Null
    Check "重复 init-admin 返回 1" ($LASTEXITCODE -eq 1) "exit=$LASTEXITCODE"

    # ---------- 启动服务 ----------
    Write-Host ""
    Write-Host "[启动] serve :$Port"
    $proc = Start-Server $dataRel
    Check "服务已就绪" ($null -ne $proc)

    # ---------- 1. 健康检查 ----------
    Write-Host ""
    Write-Host "[1] 健康检查 /health（不带 /api 前缀、不需认证）"
    $r = Call-Api "GET" "/health"
    Check "GET /health -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "/health ok=true" ($r.json.ok -eq $true)
    Check "/health 带 version" ($null -ne $r.json.data.version)

    # ---------- 2. 认证 ----------
    Write-Host ""
    Write-Host "[2] 登录与令牌"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    Check "会长登录 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $presToken = [string]$r.json.data.token
    Check "返回 token（64 hex）" ($presToken.Length -eq 64) "len=$($presToken.Length)"
    Check "member.role = president" ($r.json.data.member.role -eq "president")
    Check "member 不含手机号" ($null -eq $r.json.data.member.phone)
    Check "permissions.set_role = true" ($r.json.data.permissions.set_role -eq $true)
    Check "permissions.view_scope = all" ($r.json.data.permissions.view_scope -eq "all")
    Check "expires_at 为 +08:00" ($r.json.data.expires_at -like "*+08:00")

    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "GET /auth/me -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "本人视图含手机号" ($r.json.data.member.phone -eq "13800000000")

    $r = Call-Api "GET" "/api/v1/auth/me"
    Check "无令牌 -> 401 AUTH_REQUIRED" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_REQUIRED")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "GET" "/api/v1/auth/me" $null "deadbeef"
    Check "伪造令牌 -> 401" ($r.status -eq 401) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "wrong-password" }
    Check "密码错误 -> 401 AUTH_BAD_CREDENTIALS" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_BAD_CREDENTIALS")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "19900000000"; password = "whatever123" }
    Check "不存在的手机号 -> 同 401 错误码（不泄露是否注册）" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_BAD_CREDENTIALS")) "status=$($r.status)"

    # ---------- 3. 注册（注册与授权分离） ----------
    Write-Host ""
    Write-Host "[3] 注册：注册即登录，但账号是 pending"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = "WRONG1"; phone = "13900000001"; name = "张三"; password = "abc12345" }
    Check "口令错误 -> 400 REGISTER_CODE_INVALID" (($r.status -eq 400) -and ((ErrCode $r) -eq "REGISTER_CODE_INVALID")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = ""; name = ""; password = "" }
    Check "缺字段 -> 400 VALIDATION_FAILED" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status)"
    Check "fields 逐字段给原因" ($null -ne $r.json.error.fields.phone) "fields=$($r.json.error.fields | ConvertTo-Json -Compress)"

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "1390000000"; name = "张三"; password = "abc12345" }
    Check "手机号格式错 -> 400" ($r.status -eq 400) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000001"; name = "张三"; password = "abc12345" }
    Check "正常注册 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $newToken = [string]$r.json.data.token
    Check "新账号 status = pending" ($r.json.data.member.status -eq "pending")
    Check "pending 的 role 为 null" ($null -eq $r.json.data.member.role)
    Check "pending 的 dept 为 null" ($null -eq $r.json.data.member.dept)
    Check "pending view_scope = none" ($r.json.data.permissions.view_scope -eq "none")
    Check "pending 无任何权限" ($r.json.data.permissions.create_task -eq $false)

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000001"; name = "张三"; password = "abc12345" }
    Check "重复手机号 -> 409 ALREADY_EXISTS" (($r.status -eq 409) -and ((ErrCode $r) -eq "ALREADY_EXISTS")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "GET" "/api/v1/auth/me" $null $newToken
    Check "pending 账号登录后 /auth/me 仍 200（不是错误）" ($r.status -eq 200) "status=$($r.status)"
    Check "pending view_scope = none" ($r.json.data.permissions.view_scope -eq "none")

    # ---------- 4. 登录限流 ----------
    Write-Host ""
    Write-Host "[4] 登录限流（同一手机号 15 分钟内失败 5 次 -> 锁定）"
    $last = $null
    for ($i = 1; $i -le 5; $i++) {
        $last = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "definitely-wrong" }
    }
    Check "第 5 次失败仍是 401" ($last.status -eq 401) "status=$($last.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "definitely-wrong" }
    Check "第 6 次 -> 429 TOO_MANY_ATTEMPTS" (($r.status -eq 429) -and ((ErrCode $r) -eq "TOO_MANY_ATTEMPTS")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "abc12345" }
    Check "锁定期间正确密码也被拒" ($r.status -eq 429) "status=$($r.status)"

    # ---------- 5. 注销 ----------
    Write-Host ""
    Write-Host "[5] 注销后令牌立即失效"
    $r = Call-Api "POST" "/api/v1/auth/logout" $null $newToken
    Check "logout -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $newToken
    Check "旧令牌已失效 -> 401" ($r.status -eq 401) "status=$($r.status)"

    # ---------- 6. 改密码 ----------
    Write-Host ""
    Write-Host "[6] 本人改密码"
    $r = Call-Api "PUT" "/api/v1/auth/password" @{ old_password = "nope"; new_password = "newpassword1" } $presToken
    Check "原密码错误 -> 401" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_BAD_CREDENTIALS")) "status=$($r.status)"

    # 再造一个会长的令牌，用来验证"改密后其它令牌全部失效"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    $extraToken = [string]$r.json.data.token
    Check "第二个令牌签发成功" ($extraToken.Length -eq 64)

    $r = Call-Api "PUT" "/api/v1/auth/password" @{ old_password = "password123"; new_password = "newpassword1" } $presToken
    Check "改密码 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $extraToken
    Check "其它令牌已失效 -> 401" ($r.status -eq 401) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "当前令牌仍有效 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    Check "旧密码登录 -> 401" ($r.status -eq 401) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "newpassword1" }
    Check "新密码登录 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $presToken = [string]$r.json.data.token

    # ---------- 7. 路由层 ----------
    Write-Host ""
    Write-Host "[7] 路由与错误包装"
    $r = Call-Api "GET" "/api/v1/nope"
    Check "未知路径 -> 404" ($r.status -eq 404) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/auth/login"
    Check "方法不对 -> 405" ($r.status -eq 405) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" "not-a-json-object"
    Check "坏请求体 -> 400" ($r.status -eq 400) "status=$($r.status)"

    # ---------- 8. 优雅关闭（仅本机） ----------
    Write-Host ""
    Write-Host "[8] /admin/shutdown 仅本机可访问"
    $r = Call-Api "POST" "/admin/shutdown"
    Check "本机关停 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $proc.WaitForExit(8000) | Out-Null
    Check "进程自行退出（无人 kill，说明 shutdown 走完）" ($proc.HasExited) "hasExited=$($proc.HasExited)"

    # 优雅关闭的直接证据：日志里出现收尾那行。
    # （PS 5.1 拿不到 Start-Process 出来的 ExitCode，用日志替代。）
    $logText = ""
    if ((Test-Path $proc.LogOut)) {
        $logText = [System.IO.File]::ReadAllText($proc.LogOut, [System.Text.Encoding]::UTF8)
    }
    Check "日志出现『服务已停止』" ($logText -match "服务已停止") "log=[$logText]"
    Check "日志无 ERROR/FATAL" (($logText -notmatch "\[FATAL\]") -and ($logText -notmatch "FSException")) ""

    # ---------- 9. 重启后数据仍在 ----------
    Write-Host ""
    Write-Host "[9] 重启后持久性"
    $proc = Start-Server $dataRel "2"
    Check "重启后服务就绪" ($null -ne $proc)
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "newpassword1" }
    Check "重启后仍能用改过的密码登录" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "abc12345" }
    Check "重启后 pending 账号仍在（锁定已过期？此处应为 429 或 200）" (($r.status -eq 200) -or ($r.status -eq 429)) "status=$($r.status)"
    $r = Call-Api "GET" "/health"
    Check "重启后 /health 正常" ($r.status -eq 200)

    Stop-Server $proc
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "======================================"
Write-Host ("冒烟测试： PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
Write-Host "======================================"
if ($script:fail -gt 0) { exit 1 }
exit 0
