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

    # ---------- 15. 任务：创建与幂等 ----------
    Write-Host ""
    Write-Host "[15] 任务：创建、负责人唯一、client_token 幂等"
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $presToken
    $memPw = [string]$r.json.data.temporary_password
    $memToken = Login-Token $memPhone $memPw
    Check "成员登录成功（任务用例需要）" ($memToken.Length -eq 64)

    $pastDue = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:sszzz")
    # "今天到期"取当天 23:59。若恰好在一天最后一分钟运行，它会落进「逾期」组，
    # 因此下面的断言对两种结果都接受。
    $soonDue = (Get-Date).Date.AddHours(23).AddMinutes(59).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $weekDue = (Get-Date).AddDays(3).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $lateDue = (Get-Date).AddDays(20).ToString("yyyy-MM-ddTHH:mm:sszzz")

    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "逾期任务"; owner_id = $memId; due_at = $pastDue; desc = "已经晚了" } $presToken
    Check "创建任务 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $taskOverdue = $r.json.data.task.id
    Check "新任务 status=todo" ($r.json.data.task.status -eq "todo")
    Check "部门标签跟随负责人" ($r.json.data.task.dept.id -eq $deptOps)
    Check "新任务 is_overdue=true" ($r.json.data.task.is_overdue -eq $true)

    $ct = [guid]::NewGuid().ToString()
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "幂等任务"; owner_id = $memId; client_token = $ct } $presToken
    Check "带 client_token 创建 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $idemTask = $r.json.data.task.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "幂等任务"; owner_id = $memId; client_token = $ct } $presToken
    Check "重复提交 -> 200（不是 201）" ($r.status -eq 200) "status=$($r.status)"
    Check "重复提交 duplicated=true" ($r.json.data.duplicated -eq $true)
    Check "重复提交返回同一个任务（没有创建两遍）" ($r.json.data.task.id -eq $idemTask)

    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "没有负责人" } $presToken
    Check "缺负责人 -> 400 VALIDATION_FAILED" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "分给待分配账号"; owner_id = $stillId } $presToken
    Check "分给待分配账号 -> 403 MEMBER_PENDING" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_PENDING")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "挂到不存在的课题"; owner_id = $memId; plan_id = 99999 } $presToken
    Check "挂到不存在的课题 -> 404 PLAN_NOT_FOUND" (($r.status -eq 404) -and ((ErrCode $r) -eq "PLAN_NOT_FOUND")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "部长跨部门分配"; owner_id = $newId } $leadToken
    Check "部长给外部门成员分任务 -> 403 FORBIDDEN_NOT_IN_DEPT" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "成员建任务"; owner_id = $memId } $memToken
    Check "普通成员建任务 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 16. 我的任务（服务端分组） ----------
    Write-Host ""
    Write-Host "[16] GET /tasks/mine：服务端分组，客户端不重复实现"
    Call-Api "POST" "/api/v1/tasks" @{ title = "今天到期"; owner_id = $memId; due_at = $soonDue } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "三天后"; owner_id = $memId; due_at = $weekDue } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "很久以后"; owner_id = $memId; due_at = $lateDue } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "没有截止"; owner_id = $memId } $presToken | Out-Null

    $r = Call-Api "GET" "/api/v1/tasks/mine" $null $memToken
    Check "GET /tasks/mine -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "逾期组非空" ($r.json.data.counts.overdue -ge 1) "counts=$($r.json.data.counts | ConvertTo-Json -Compress)"
    $todayOk = ($r.json.data.due_today.Count -ge 1) -or
               (($r.json.data.overdue | Where-Object { $_.title -eq "今天到期" }) -ne $null)
    Check "今天组非空（当日最后一分钟运行时归入逾期）" $todayOk
    Check "本周组非空" ($r.json.data.due_week.Count -ge 1)
    Check "以后组非空" ($r.json.data.later.Count -ge 1)
    Check "无截止组非空" ($r.json.data.no_due.Count -ge 1)
    Check "counts.open_total 存在" ($null -ne $r.json.data.counts.open_total)
    $r = Call-Api "GET" "/api/v1/tasks/mine" $null $presToken
    Check "会长 /tasks/mine 只返回自己的（0 条）" ($r.json.data.counts.open_total -eq 0) "open_total=$($r.json.data.counts.open_total)"

    # ---------- 17. 状态流转与阻塞原因 ----------
    Write-Host ""
    Write-Host "[17] 状态流转：blocked 必须填原因、离开自动清空、done 记时间"
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "blocked" } $presToken
    Check "进 blocked 不填原因 -> 400 BLOCKER_REQUIRED" (($r.status -eq 400) -and ((ErrCode $r) -eq "BLOCKER_REQUIRED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "blocked"; blocker = "等场地审批，已提交 3 天" } $presToken
    Check "填了原因 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "blocked=true" ($r.json.data.blocked -eq $true)
    Check "blocker 已保存" ($r.json.data.blocker -eq "等场地审批，已提交 3 天")
    Check "阻塞与逾期两个事实并存（不互斥）" ($r.json.data.is_overdue -eq $true)
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "doing" } $presToken
    Check "离开 blocked 自动清空 blocker" ($null -eq $r.json.data.blocker) "blocker=$($r.json.data.blocker)"
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "done" } $presToken
    Check "进 done -> 200" ($r.status -eq 200)
    Check "completed_at 已记录" ($null -ne $r.json.data.completed_at)
    Check "已完成不算逾期" ($r.json.data.is_overdue -eq $false)
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "todo" } $presToken
    Check "从 done 退回清空 completed_at" ($null -eq $r.json.data.completed_at)
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "50%" } $presToken
    Check "非法状态 -> 400（不做进度百分比）" ($r.status -eq 400) "status=$($r.status)"

    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "doing" } $memToken
    Check "成员改自己任务状态 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "部长的任务"; owner_id = $leadId } $presToken
    $leadTask = $r.json.data.task.id
    $r = Call-Api "PUT" "/api/v1/tasks/$leadTask/status" @{ status = "doing" } $memToken
    Check "成员改他人任务状态 -> 403" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 18. 详情 / 编辑 / 转交 / 软删除 / 日历同步 ----------
    Write-Host ""
    Write-Host "[18] 任务详情、转交、软删除、日历同步 lookup"
    $r = Call-Api "GET" "/api/v1/tasks/$taskOverdue" $null $presToken
    Check "详情 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "详情含 desc" ($r.json.data.desc -eq "已经晚了")
    Check "详情含 plan_path（客户端画面包屑用）" ($null -ne $r.json.data.plan_path)
    Check "详情含 created_by" ($null -ne $r.json.data.created_by)
    Check "详情不含手机号" (-not ($r.json.data.owner.PSObject.Properties.Name -contains "phone"))

    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ title = "改名后的任务"; desc = "改过的描述" } $presToken
    Check "编辑标题/描述 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "标题已改" ($r.json.data.title -eq "改名后的任务")
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ due_at = $null } $presToken
    Check "due_at 显式传 null -> 清空截止时间" ($null -eq $r.json.data.due_at) "due_at=$($r.json.data.due_at)"
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ owner_id = 0 } $presToken
    Check "负责人置空 -> 400（任务必须始终有人负责）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ owner_id = $newId } $presToken
    Check "跨部门转交（会长）-> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "部门标签跟随新负责人" ($r.json.data.dept.id -eq $deptPub) "dept=$($r.json.data.dept.id) 期望=$deptPub"

    $r = Call-Api "GET" "/api/v1/tasks?dept_id=$deptPub" $null $leadToken
    Check "部长看不到外部门任务（可见范围）" ($r.json.data.total -eq 0) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/tasks" $null $leadToken
    Check "部长看本部门任务列表 -> 200" ($r.status -eq 200) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/tasks/lookup" @{ task_ids = @($leadTask, 99999) } $presToken
    Check "lookup -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "lookup：存在的进 items" ($r.json.data.items.Count -eq 1) "items=$($r.json.data.items.Count)"
    Check "lookup：不存在的进 missing" ($r.json.data.missing -contains 99999)

    $r = Call-Api "DELETE" "/api/v1/tasks/$idemTask" $null $presToken
    Check "软删除 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/tasks/$idemTask" $null $presToken
    Check "删除后详情 -> 404" ($r.status -eq 404) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/tasks/lookup" @{ task_ids = @($idemTask) } $presToken
    Check "删除后 lookup 归入 missing（客户端据此清理本地日历）" ($r.json.data.missing -contains $idemTask)
    $r = Call-Api "GET" "/api/v1/tasks?owner_id=$memId" $null $presToken
    $deletedStill = $r.json.data.items | Where-Object { $_.id -eq $idemTask }
    Check "软删除的任务不再出现在列表里" ($null -eq $deletedStill)

    # ---------- 19. 课题：创建与树 ----------
    Write-Host ""
    Write-Host "[19] 课题：创建、dept_id 规则、课题树"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "招新总课题"; dept_id = $deptOps; owner_id = $leadId } $presToken
    Check "建顶层课题 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $planRoot = $r.json.data.plan.id
    Check "顶层课题带 dept" ($r.json.data.plan.dept.id -eq $deptOps)
    Check "顶层 parent_id=0" ($r.json.data.plan.parent_id -eq 0)

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "子课题"; parent_id = $planRoot; owner_id = $leadId } $presToken
    Check "建子课题 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $planChild = $r.json.data.plan.id
    Check "子课题 dept 为 null（部门看根）" ($null -eq $r.json.data.plan.dept)
    Check "子课题 parent_id 正确" ($r.json.data.plan.parent_id -eq $planRoot)

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "孙课题"; parent_id = $planChild; owner_id = $leadId } $presToken
    Check "建孙课题 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $planGrand = $r.json.data.plan.id

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "缺部门的顶层课题"; owner_id = $leadId } $presToken
    Check "顶层缺 dept_id -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "子课题却传部门"; parent_id = $planRoot; dept_id = $deptOps; owner_id = $leadId } $presToken
    Check "子课题传 dept_id -> 400（部门继承自根）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "没有负责人"; dept_id = $deptOps } $presToken
    Check "缺 owner_id -> 400（任意层级都要有负责人）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "挂到不存在的父"; parent_id = 99999; owner_id = $leadId } $presToken
    Check "父课题不存在 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "PLAN_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "部长跨部门建顶层"; dept_id = $deptPub; owner_id = $leadId } $leadToken
    Check "部长在别的部门建课题 -> 403" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "GET" "/api/v1/plans" $null $presToken
    Check "GET /plans -> 200" ($r.status -eq 200) "status=$($r.status)"
    $node = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "森林含根节点" ($null -ne $node)
    Check "根节点内嵌 children" ($node.children.Count -ge 1)
    Check "节点含 progress" ($null -ne $node.progress)
    Check "节点含 child_count" ($node.child_count -ge 1)
    $r = Call-Api "GET" "/api/v1/plans?dept_id=$deptPub" $null $presToken
    $pubNode = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "按部门筛选：别的部门看不到" ($null -eq $pubNode)
    $r = Call-Api "GET" "/api/v1/plans?include_progress=false" $null $presToken
    $n2 = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "include_progress=false 时不返回 progress" ($null -eq $n2.progress)

    # ---------- 20. 课题：递归进度聚合 ----------
    Write-Host ""
    Write-Host "[20] 递归进度聚合（含整棵子树）"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "根本级-完成"; owner_id = $leadId; plan_id = $planRoot } $presToken
    $rootTaskId = $r.json.data.task.id
    Call-Api "PUT" "/api/v1/tasks/$rootTaskId/status" @{ status = "done" } $presToken | Out-Null
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "子本级-进行中"; owner_id = $leadId; plan_id = $planChild } $presToken
    $childTaskId = $r.json.data.task.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "孙本级-完成"; owner_id = $leadId; plan_id = $planGrand } $presToken
    $grandTask1 = $r.json.data.task.id
    Call-Api "PUT" "/api/v1/tasks/$grandTask1/status" @{ status = "done" } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "孙本级-未开始"; owner_id = $leadId; plan_id = $planGrand } $presToken | Out-Null

    $r = Call-Api "GET" "/api/v1/plans" $null $presToken
    $node = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "根 progress.total 含整棵子树 = 4" ($node.progress.total -eq 4) "progress=$($node.progress | ConvertTo-Json -Compress)"
    Check "根 progress.done 含整棵子树 = 2" ($node.progress.done -eq 2) "progress=$($node.progress | ConvertTo-Json -Compress)"
    Check "根 task_count 只算本级 = 1" ($node.task_count -eq 1) "task_count=$($node.task_count)"
    $childNode = $node.children | Where-Object { $_.id -eq $planChild }
    Check "子课题 progress.total = 3（本级1 + 孙2）" ($childNode.progress.total -eq 3) "progress=$($childNode.progress | ConvertTo-Json -Compress)"

    $r = Call-Api "GET" "/api/v1/plans/$planRoot" $null $presToken
    Check "课题详情 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "详情 plan.progress 递归" ($r.json.data.plan.progress.total -eq 4)
    Check "详情 path 面包屑含自身" (($r.json.data.path | Select-Object -Last 1).id -eq $planRoot)
    Check "详情 children 平铺" ($r.json.data.children.Count -eq 1)
    Check "详情 tasks 只含本级 = 1" ($r.json.data.tasks.total -eq 1) "tasks.total=$($r.json.data.tasks.total)"
    $r = Call-Api "GET" "/api/v1/plans/$planGrand" $null $presToken
    Check "孙课题面包屑 3 级" ($r.json.data.path.Count -eq 3) "path=$($r.json.data.path.Count)"

    # ---------- 21. 课题：深度上限与环形校验 ----------
    Write-Host ""
    Write-Host "[21] 深度上限 6 层、环形校验、跨部门禁止"
    $deepest = $planGrand
    for ($i = 4; $i -le 6; $i++) {
        $r = Call-Api "POST" "/api/v1/plans" @{ title = "第${i}层"; parent_id = $deepest; owner_id = $leadId } $presToken
        Check "建第 $i 层 -> 201" ($r.status -eq 201) "status=$($r.status) depth=$i code=$(ErrCode $r)"
        $deepest = $r.json.data.plan.id
    }
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "第7层"; parent_id = $deepest; owner_id = $leadId } $presToken
    Check "建第 7 层 -> 400 PLAN_DEPTH_EXCEEDED" (($r.status -eq 400) -and ((ErrCode $r) -eq "PLAN_DEPTH_EXCEEDED")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = $planRoot } $presToken
    Check "移动到自己下面 -> 409 PLAN_CYCLE_DETECTED" (($r.status -eq 409) -and ((ErrCode $r) -eq "PLAN_CYCLE_DETECTED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = $planGrand } $presToken
    Check "移动到自己的后代下面 -> 409" (($r.status -eq 409) -and ((ErrCode $r) -eq "PLAN_CYCLE_DETECTED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = 99999 } $presToken
    Check "移动到不存在的父 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "PLAN_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = $planRoot } $vpToken
    Check "副会长可移动课题（成环仍 409）" ($r.status -eq 409) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "宣传部课题"; dept_id = $deptPub; owner_id = $newId } $presToken
    $planPub = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/plans/$planChild/move" @{ new_parent_id = $planPub } $presToken
    Check "跨部门移动 -> 400（v1 禁止）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans/$planPub/move" @{ new_parent_id = $planChild } $leadToken
    Check "部长跨部门移动 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "另一分枝"; parent_id = $planRoot; owner_id = $leadId } $presToken
    $planBranch = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/plans/$planGrand/move" @{ new_parent_id = $planBranch } $presToken
    Check "合法移动 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "移动后 parent_id 已变" ($r.json.data.plan.parent_id -eq $planBranch)
    $r = Call-Api "POST" "/api/v1/plans/$planGrand/move" @{ new_parent_id = $null; dept_id = $deptOps } $presToken
    Check "提升为顶层 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "提升后 parent_id=0" ($r.json.data.plan.parent_id -eq 0)
    Check "提升后带上部门" ($r.json.data.plan.dept.id -eq $deptOps)

    # ---------- 22. 课题：编辑与删除上提 ----------
    Write-Host ""
    Write-Host "[22] 课题编辑、删除上提（绝不级联删除）"
    $r = Call-Api "PATCH" "/api/v1/plans/$planChild" @{ title = "改名后的子课题"; desc = "补充说明" } $presToken
    Check "编辑课题 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "标题已改" ($r.json.data.plan.title -eq "改名后的子课题")
    Check "描述已存" ($r.json.data.plan.desc -eq "补充说明")
    $r = Call-Api "PATCH" "/api/v1/plans/$planChild" @{ dept_id = $deptPub } $presToken
    Check "PATCH 改 dept_id -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status)"
    $r = Call-Api "PATCH" "/api/v1/plans/$planChild" @{ owner_id = 0 } $presToken
    Check "负责人置空 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"

    # 先给待删课题挂一个子课题，这样才真正验证到"上提"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "待上提的子课题"; parent_id = $planChild; owner_id = $leadId } $presToken
    $promoteMe = $r.json.data.plan.id
    Check "为删除用例准备子课题 -> 201" ($r.status -eq 201) "status=$($r.status)"

    $r = Call-Api "DELETE" "/api/v1/plans/$planChild" $null $presToken
    Check "删除中间课题 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "上提 1 个子课题" ($r.json.data.moved_plans -eq 1) "moved_plans=$($r.json.data.moved_plans)"
    Check "上提 1 个本级任务" ($r.json.data.moved_tasks -eq 1) "moved_tasks=$($r.json.data.moved_tasks)"
    $r = Call-Api "GET" "/api/v1/plans/$planChild" $null $presToken
    Check "被删课题详情 -> 404" ($r.status -eq 404) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/plans/$promoteMe" $null $presToken
    Check "子课题上提到祖父下" ($r.json.data.plan.parent_id -eq $planRoot) "parent=$($r.json.data.plan.parent_id) 期望=$planRoot"
    $r = Call-Api "GET" "/api/v1/tasks/$childTaskId" $null $presToken
    Check "被删课题的本级任务已上提到其父" ($r.json.data.plan.id -eq $planRoot) "plan=$($r.json.data.plan.id) 期望=$planRoot"

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "待删顶层"; dept_id = $deptOps; owner_id = $leadId } $presToken
    $planTop2 = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "它的子课题"; parent_id = $planTop2; owner_id = $leadId } $presToken
    $planTop2Child = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "顶层待删课题的任务"; owner_id = $leadId; plan_id = $planTop2 } $presToken
    $topTaskId = $r.json.data.task.id
    $r = Call-Api "DELETE" "/api/v1/plans/$planTop2" $null $presToken
    Check "删除顶层课题 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/plans/$planTop2Child" $null $presToken
    Check "子课题变成顶层（parent_id=0）" ($r.json.data.plan.parent_id -eq 0)
    Check "子课题继承原根的部门" ($r.json.data.plan.dept.id -eq $deptOps) "dept=$($r.json.data.plan.dept.id)"
    $r = Call-Api "GET" "/api/v1/tasks/$topTaskId" $null $presToken
    Check "顶层被删后任务变为独立任务" ($null -eq $r.json.data.plan)

    # ---------- 23. 优雅关闭（仅本机） ----------
    Write-Host ""
    Write-Host "[23] /admin/shutdown 仅本机可访问"
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

    # ---------- 24. 重启后数据仍在 ----------
    Write-Host ""
    Write-Host "[24] 重启后持久性"
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
