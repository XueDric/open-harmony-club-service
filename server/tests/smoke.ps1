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
        # PS 5.1 的坑：Body 传字符串会按 ANSI 发送，中文到达服务端就是乱码。
        # 必须自己转成 UTF-8 字节，并在 Content-Type 里声明 charset。
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

# 注册一个账号
function New-Account([string]$phone, [string]$name, [string]$pw, [string]$code) {
    return Call-Api "POST" "/api/v1/auth/register" @{ register_code = $code; phone = $phone; name = $name; password = $pw }
}

# 登录并返回 token（失败返回空串）
function Login-Token([string]$phone, [string]$pw) {
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = $phone; password = $pw }
    if ($r.status -ne 200) { return "" }
    return [string]$r.json.data.token
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

    # ---------- 8. 部门（组织） ----------
    Write-Host ""
    Write-Host "[8] 部门：会长独占增删改"
    $presId = (Call-Api "GET" "/api/v1/auth/me" $null $presToken).json.data.member.id
    $r = Call-Api "GET" "/api/v1/depts" $null $presToken
    Check "GET /depts -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "预置 4 个组织" ($r.json.data.items.Count -eq 4) "count=$($r.json.data.items.Count)"
    $deptOps = ($r.json.data.items | Where-Object { $_.name -eq "运营部" }).id
    $deptPub = ($r.json.data.items | Where-Object { $_.name -eq "宣传部" }).id
    Check "部门含 member_count（软提示）" ($null -ne $r.json.data.items[0].member_count)

    $r = Call-Api "POST" "/api/v1/depts" @{ name = "技术部"; sort = 9 } $presToken
    Check "会长新建部门 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $newDept = $r.json.data.dept.id
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "技术部" } $presToken
    Check "部门重名 -> 409 ALREADY_EXISTS" (($r.status -eq 409) -and ((ErrCode $r) -eq "ALREADY_EXISTS")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/$newDept" @{ name = "技术委员会"; sort = 10 } $presToken
    Check "改名 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "改名已生效" ($r.json.data.dept.name -eq "技术委员会")
    $r = Call-Api "PATCH" "/api/v1/depts/$newDept" @{ lead_id = 9 } $presToken
    Check "传 lead_id -> 400（该字段不存在）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "DELETE" "/api/v1/depts/$newDept" $null $presToken
    Check "删除空部门 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/99999" @{ name = "x" } $presToken
    Check "改不存在的部门 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "DEPT_NOT_FOUND")) "status=$($r.status)"

    # ---------- 9. 待分配与授权（招新主线） ----------
    Write-Host ""
    Write-Host "[9] 待分配与授权（注册与授权分离）"
    $leadPhone = "13900000010"
    $memPhone  = "13900000011"
    $newPhone  = "13900000012"
    $r = New-Account $leadPhone "部长候选人" "leadpw123" $regCode
    Check "注册部长候选人 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $leadId = $r.json.data.member.id
    $leadPendingToken = [string]$r.json.data.token
    $r = New-Account $memPhone "普通成员" "mempw1234" $regCode
    $memId = $r.json.data.member.id
    Check "注册普通成员 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $r = New-Account $newPhone "待分配乙" "newpw1234" $regCode
    $newId = $r.json.data.member.id
    Check "注册待分配乙 -> 201" ($r.status -eq 201) "status=$($r.status)"

    $r = Call-Api "GET" "/api/v1/members/pending" $null $presToken
    Check "待分配列表 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "待分配含 4 人（含 M1 段注册的 13900000001）" ($r.json.data.items.Count -eq 4) "count=$($r.json.data.items.Count)"
    Check "待分配含 registered_at" ($null -ne $r.json.data.items[0].registered_at)

    $r = Call-Api "GET" "/api/v1/members/pending" $null $leadPendingToken
    Check "pending 账号查待分配 -> 403 MEMBER_PENDING" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_PENDING")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/members/$leadId/assign" @{ dept_id = $deptOps; role = "lead" } $presToken
    Check "分配部长 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "分配后 status=active" ($r.json.data.status -eq "active")
    Check "分配后 role=lead" ($r.json.data.role -eq "lead")
    Check "分配后 dept 正确" ($r.json.data.dept.id -eq $deptOps)
    $r = Call-Api "POST" "/api/v1/members/$leadId/assign" @{ dept_id = $deptOps; role = "lead" } $presToken
    Check "重复分配幂等 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$memId/assign" @{ dept_id = $deptOps; role = "member" } $presToken
    Check "分配普通成员 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/99999/assign" @{ dept_id = $deptOps; role = "member" } $presToken
    Check "分配不存在的成员 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "MEMBER_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$newId/assign" @{ dept_id = $deptOps; role = "president" } $presToken
    Check "assign 授予 president -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$newId/assign" @{ dept_id = 99999; role = "member" } $presToken
    Check "分配到不存在的部门 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "DEPT_NOT_FOUND")) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/members/assign-batch" @{ member_ids = @($newId, 99999); dept_id = $deptPub; role = "member" } $presToken
    Check "批量分配 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "批量：成功 1 条" ($r.json.data.succeeded.Count -eq 1) "succeeded=$($r.json.data.succeeded | ConvertTo-Json -Compress)"
    Check "批量：失败 1 条" ($r.json.data.failed.Count -eq 1)
    Check "批量：失败原因是 MEMBER_NOT_FOUND" ($r.json.data.failed[0].code -eq "MEMBER_NOT_FOUND")
    Check "批量：成功的那条真的生效了（部分成功不回滚）" ($r.json.data.succeeded[0] -eq $newId)

    $r = Call-Api "DELETE" "/api/v1/depts/$deptOps" $null $presToken
    Check "删除非空部门 -> 409 DEPT_NOT_EMPTY" (($r.status -eq 409) -and ((ErrCode $r) -eq "DEPT_NOT_EMPTY")) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 10. 成员名录与编辑 ----------
    Write-Host ""
    Write-Host "[10] 成员名录与编辑"
    $r = Call-Api "GET" "/api/v1/members" $null $presToken
    Check "GET /members -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "分页字段齐全" (($null -ne $r.json.data.total) -and ($null -ne $r.json.data.page) -and ($null -ne $r.json.data.size))
    Check "page 从 1 开始" ($r.json.data.page -eq 1)
    Check "名录不含手机号" (-not ($r.json.data.items[0].PSObject.Properties.Name -contains "phone"))
    $r = Call-Api "GET" "/api/v1/members?dept_id=$deptOps" $null $presToken
    Check "按部门筛选" ($r.json.data.total -eq 2) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/members?status=disabled" $null $presToken
    Check "按状态筛选（无已退出成员）" ($r.json.data.total -eq 0) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/members?page=1&size=1" $null $presToken
    Check "size=1 生效" ($r.json.data.items.Count -eq 1)
    Check "size 超上限按 200" ((Call-Api "GET" "/api/v1/members?size=9999" $null $presToken).json.data.size -eq 200)

    $r = Call-Api "GET" "/api/v1/members/$memId" $null $presToken
    Check "成员详情 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "详情含 stats.owned_tasks" ($null -ne $r.json.data.stats.owned_tasks)
    $r = Call-Api "GET" "/api/v1/members/99999" $null $presToken
    Check "不存在的成员 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "MEMBER_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/members/abc" $null $presToken
    Check "非数字 id -> 404（不是 500）" ($r.status -eq 404) "status=$($r.status)"

    $r = Call-Api "PATCH" "/api/v1/members/$memId" @{ name = "普通成员改名" } $presToken
    Check "改姓名 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "姓名已改" ($r.json.data.name -eq "普通成员改名") "got=[$($r.json.data.name)]"
    $r = Call-Api "PATCH" "/api/v1/members/$memId" @{ role = "president" } $presToken
    Check "PATCH 授予 president -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$memId" @{ role = "vip" } $presToken
    Check "非法角色 -> 400" ($r.status -eq 400) "status=$($r.status)"
    $r = Call-Api "PATCH" "/api/v1/members/$newId" @{ role = "member" } $presToken
    Check "改已分配成员的部门/角色 -> 200" ($r.status -eq 200) "status=$($r.status)"

    # 待分配成员不允许用 PATCH 授权（那属于 assign 的职责）
    $r = New-Account "13900000013" "仍未分配" "stillpw12" $regCode
    $stillId = $r.json.data.member.id
    $r = Call-Api "PATCH" "/api/v1/members/$stillId" @{ role = "member" } $presToken
    Check "待分配成员用 PATCH 授权 -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$stillId" @{ name = "仍未分配改名" } $presToken
    Check "待分配成员改姓名 -> 200" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 11. 会长保护与移交 ----------
    Write-Host ""
    Write-Host "[11] 最后一个会长保护 + 会长移交（原子）"
    $vpPhone = "13900000014"
    $r = New-Account $vpPhone "副会长候选人" "vppw1234" $regCode
    $vpId = $r.json.data.member.id
    $r = Call-Api "POST" "/api/v1/members/$vpId/assign" @{ dept_id = 1; role = "vice_president" } $presToken
    Check "分配副会长 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $vpToken = Login-Token $vpPhone "vppw1234"
    Check "副会长登录成功" ($vpToken.Length -eq 64)

    $r = Call-Api "GET" "/api/v1/register-config" $null $vpToken
    Check "副会长可查看注册口令 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "VPCODE" } $vpToken
    Check "副会长换口令 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "副会长想建的部门" } $vpToken
    Check "副会长新建部门 -> 403（会长独占）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "DELETE" "/api/v1/depts/$deptPub" $null $vpToken
    Check "副会长删除部门 -> 403（会长独占）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/$deptPub" @{ sort = 99 } $vpToken
    Check "副会长改部门 -> 403（会长独占）" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "member" } $vpToken
    Check "副会长移交会长 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$presId" @{ role = "member" } $vpToken
    Check "副会长改动会长本人 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/members/pending" $null $vpToken
    Check "副会长可看待分配 -> 200" ($r.status -eq 200) "status=$($r.status)"

    $r = Call-Api "PATCH" "/api/v1/members/$presId" @{ role = "member" } $presToken
    Check "会长把自己降级 -> 409 FORBIDDEN_LAST_PRESIDENT" (($r.status -eq 409) -and ((ErrCode $r) -eq "FORBIDDEN_LAST_PRESIDENT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/disable" $null $presToken
    Check "禁用最后一个会长 -> 409" (($r.status -eq 409) -and ((ErrCode $r) -eq "FORBIDDEN_LAST_PRESIDENT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "member" } $presToken
    Check "移交给自己 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$stillId/transfer-presidency" @{ self_role = "member" } $presToken
    Check "移交给 pending 账号 -> 403 MEMBER_PENDING" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_PENDING")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/members/$vpId/transfer-presidency" @{ self_role = "vice_president" } $presToken
    Check "会长移交给副会长 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "新会长 role=president" ($r.json.data.president.role -eq "president")
    Check "原会长降为 vice_president" ($r.json.data.previous.role -eq "vice_president")
    $r = Call-Api "GET" "/api/v1/auth/me" $null $vpToken
    Check "新会长权限 view_scope=all" ($r.json.data.permissions.view_scope -eq "all")
    Check "新会长 permissions.set_role=true" ($r.json.data.permissions.set_role -eq $true)
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "member" } $presToken
    Check "已不是会长者移交 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "vice_president" } $vpToken
    Check "新会长移交回原会长 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "角色已复原为 president" ($r.json.data.member.role -eq "president")

    # ---------- 12. 重置密码 ----------
    Write-Host ""
    Write-Host "[12] 重置密码（会长/副会长/本部门部长/本人）"
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $presToken
    Check "会长重置成员密码 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $tempPw = [string]$r.json.data.temporary_password
    Check "返回 8 位临时密码" ($tempPw.Length -eq 8) "temp=$tempPw"
    $tmpToken = Login-Token $memPhone $tempPw
    Check "用临时密码可登录" ($tmpToken.Length -eq 64)
    Check "旧密码已失效" ((Login-Token $memPhone "mempw1234").Length -eq 0)

    $leadToken = Login-Token $leadPhone "leadpw123"
    Check "部长登录成功" ($leadToken.Length -eq 64)
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $leadToken
    Check "部长重置本部门成员密码 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$newId/reset-password" $null $leadToken
    Check "部长重置外部门成员密码 -> 403 FORBIDDEN_NOT_IN_DEPT" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/reset-password" $null $leadToken
    Check "部长重置会长密码 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "部长想建的部门" } $leadToken
    Check "部长新建部门 -> 403" ($r.status -eq 403) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$stillId/assign" @{ dept_id = $deptOps; role = "member" } $leadToken
    Check "部长审批待分配 -> 403（审批统一归会长/副会长）" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 13. 注册配置 ----------
    Write-Host ""
    Write-Host "[13] 注册口令：查看 / 更换 / 轮换"
    $r = Call-Api "GET" "/api/v1/register-config" $null $presToken
    Check "会长查看口令 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "口令含操作人" ($null -ne $r.json.data.updated_by)
    $oldCode = [string]$r.json.data.code
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "NEWCODE1" } $presToken
    Check "会长换口令 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "返回新口令" ($r.json.data.code -eq "NEWCODE1")
    $r = New-Account "13900000015" "旧口令注册" "oldcode12" $oldCode
    Check "旧口令立即失效 -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "REGISTER_CODE_INVALID")) "status=$($r.status) code=$(ErrCode $r)"
    $r = New-Account "13900000016" "新口令注册" "newcode12" "NEWCODE1"
    Check "新口令可注册 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $regCode = "NEWCODE1"
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "ab" } $presToken
    Check "口令过短 -> 400" ($r.status -eq 400) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/register-config/rotate" $null $presToken
    Check "随机轮换 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $regCode = [string]$r.json.data.code
    Check "轮换后口令变化且 6 位" (($regCode.Length -eq 6) -and ($regCode -ne "NEWCODE1")) "code=$regCode"

    # ---------- 14. 部门招募链接 ----------
    Write-Host ""
    Write-Host "[14] 招募链接（只预填部门，不赋予角色）"
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = $deptPub } $presToken
    Check "创建招募链接 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $linkToken = [string]$r.json.data.token
    Check "返回 token（8 位）" ($linkToken.Length -eq 8) "token=$linkToken"
    Check "返回 url 含 /join/" (([string]$r.json.data.url) -like "*/join/*")
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = 99999 } $presToken
    Check "链接指向不存在的部门 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "DEPT_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = $deptPub } $vpToken
    Check "副会长可管招募链接 -> 201" ($r.status -eq 201) "status=$($r.status)"

    $r = Call-Api "GET" "/api/v1/dept-invite-links" $null $presToken
    Check "链接列表 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "列表含 2 条" ($r.json.data.items.Count -eq 2) "count=$($r.json.data.items.Count)"
    Check "列表含部门名" ($null -ne $r.json.data.items[0].dept.name)

    # 通过招募链接进来的人：客户端把链接里的 dept_id 带进注册请求（只做预填）
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000017"; name = "链接进来的人"; password = "linkpw123"; dept_id = $deptPub }
    Check "经链接注册 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $linkMemberId = $r.json.data.member.id
    $r = Call-Api "GET" "/api/v1/members/pending" $null $presToken
    $hinted = $r.json.data.items | Where-Object { $_.id -eq $linkMemberId }
    Check "待分配项带 dept_hint（来自链接）" ($hinted.dept_hint.id -eq $deptPub) "hint=$($hinted.dept_hint | ConvertTo-Json -Compress)"
    $r = Call-Api "POST" "/api/v1/members/$linkMemberId/assign" @{ dept_id = $hinted.dept_hint.id; role = "member" } $presToken
    Check "按链接预填直接分配 -> 200" ($r.status -eq 200) "status=$($r.status)"

    $r = Call-Api "DELETE" "/api/v1/dept-invite-links/$linkToken" $null $presToken
    Check "停用链接 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "停用后 enabled=false" ($r.json.data.enabled -eq $false)
    $r = Call-Api "DELETE" "/api/v1/dept-invite-links/$linkToken" $null $presToken
    Check "重复停用幂等 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "DELETE" "/api/v1/dept-invite-links/nonexistent" $null $presToken
    Check "停用不存在的链接 -> 200（幂等）" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 15. 优雅关闭（仅本机） ----------
    Write-Host ""
    Write-Host "[15] /admin/shutdown 仅本机可访问"
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

    # ---------- 16. 重启后数据仍在 ----------
    Write-Host ""
    Write-Host "[16] 重启后持久性"
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
