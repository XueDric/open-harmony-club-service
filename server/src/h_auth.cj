package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 2 · 认证与注册（api-design.md Part 2，5 个接口中的 4 个 + 改密码）
 *
 * ⚠ 锁规则（重要）：
 *   requireMember / requireActive **内部会加 s.lock**，因此调用它们时
 *   绝不能已经持有 s.lock —— Mutex 不可重入，会死锁。
 *   handler 的统一形状是：**先认证（拿 Member），再单独加锁做修改**。
 */

import std.collection.*
import stdx.encoding.json.*

/* 登录限流参数（api-design §2.4）：15 分钟窗口，失败 5 次锁 15 分钟。 */
public let LOGIN_FAIL_WINDOW: Int64 = 900
public let LOGIN_FAIL_LIMIT: Int64 = 5
public let LOGIN_FAIL_LOCK: Int64 = 900

/*
 * 注册口令限流参数（N-6，2026-09-14 改）。
 * 窗口 15 分钟内错 10 次即锁该 IP；锁定时长**递增退避**：首次 5 分钟，
 * 同一 IP 每再触发一次翻倍，上限 1 小时。
 * 为什么不再固定 15 分钟：固定值让封锁成本恒定（每 15 分钟丢 10 个错口令就能一直锁着），
 * 递增退避让重复违规越来越贵。
 */
public let REG_FAIL_WINDOW: Int64 = 900
public let REG_FAIL_LIMIT: Int64 = 10
public let REG_FAIL_LOCK_BASE: Int64 = 300
public let REG_FAIL_LOCK_MAX: Int64 = 3600

/*
 * 登录失败表清理（P1 M-3）。
 * 原先只增不减：每个被试过的手机号都留一条记录，锁定过期也不回收。
 * 这里把"窗口已过且锁定已解除"的记录删掉；平时（表很小）直接返回，不做无谓遍历。
 */
func pruneLoginFail(s: Store, now: Int64): Unit {
    if (s.login_fail.size <= 500) {
        return
    }
    let doomed = ArrayList<String>()
    for ((k, r) in s.login_fail) {
        if (r.locked_until <= now && now - r.first_at > LOGIN_FAIL_WINDOW) {
            doomed.add(k)
        }
    }
    for (k in doomed) {
        s.login_fail.remove(k)
    }
}

/* 递增退避：level = 该 IP 已被锁过的次数。300 → 600 → 1200 → 2400 → 上限 3600。 */
func regLockSeconds(level: Int64): Int64 {
    var v = REG_FAIL_LOCK_BASE
    var i: Int64 = 0
    while (i < level && v < REG_FAIL_LOCK_MAX) {
        v = v * 2
        i += 1
    }
    if (v > REG_FAIL_LOCK_MAX) {
        v = REG_FAIL_LOCK_MAX
    }
    return v
}

/* 该 IP 此刻是否处于锁定期。 */
func regLocked(s: Store, ip: String, now: Int64): Bool {
    match (s.reg_fail.get(ip)) {
        case Some(st) => return st.locked_until > now
        case None => return false
    }
}

/* 节流表清理（与 pruneLoginFail 同构）：超过 500 条时回收"窗口已过且已解锁"的 IP。 */
func pruneRegFail(s: Store, now: Int64): Unit {
    if (s.reg_fail.size <= 500) {
        return
    }
    let doomed = ArrayList<String>()
    for ((k, st) in s.reg_fail) {
        if (st.locked_until <= now && now - st.first_at > REG_FAIL_WINDOW) {
            doomed.add(k)
        }
    }
    for (k in doomed) {
        s.reg_fail.remove(k)
    }
}

/*
 * 注册口令失败计数（P1 M-2；N-6 从全局计数改为**按 IP**）。
 * 窗口内累计到上限就锁定**该 IP**，锁定期间该 IP 的注册一律 429——
 * 其它 IP 完全不受影响，这是与旧全局锁最关键的区别。
 * 与 login_fail 同理不落盘：失败路径上写整库等于给攻击者一个放大杠杆。
 */
func regFailBump(s: Store, ip: String): Unit {
    let now = nowEpoch()
    let st = s.reg_fail.get(ip) ?? RegFail()
    if (st.first_at == 0 || now - st.first_at > REG_FAIL_WINDOW) {
        st.first_at = now
        st.count = 0
    }
    st.count += 1
    if (st.count >= REG_FAIL_LIMIT) {
        st.locked_until = now + regLockSeconds(st.lock_level)
        st.lock_level += 1
        st.count = 0
        st.first_at = now
    }
    s.reg_fail[ip] = st
    pruneRegFail(s, now)
}

/* 登录/注册成功的统一响应体。 */
func respondLogin(ctx: Context, s: Store, m: Member, token: String, expiresAt: Int64, created: Bool): Unit {
    let data = JsonObject()
    jPutStr(data, "token", token)
    jPutStr(data, "expires_at", isoLocal(expiresAt))
    jPutObj(data, "member", memberBrief(s, m))
    jPutObj(data, "permissions", permissionsOf(m))
    if (created) {
        sendCreated(ctx, data)
    } else {
        sendOk(ctx, data)
    }
}

/*
 * POST /api/v1/auth/register
 * 注册即登录，但账号是 pending、权限全 false，客户端应跳「等待管理员分配」页。
 * 请求体**不接受 role**——任何角色都必须由会长授予（api-design §2.3 注 4）。
 */
public func handleRegister(ctx: Context, s: Store): Unit {
    let body = reqObj(ctx)
    let v = V()
    let rc = v.need("register_code", reqStrOr(body, "register_code", ""), "请输入社团注册口令")
    let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
    let name = v.need("name", reqStrOr(body, "name", ""), "请输入姓名")
    let pw = v.need("password", reqStrOr(body, "password", ""), "请输入密码")
    if (phone.size > 0) {
        v.check("phone", isPhone(phone), "手机号格式不正确")
    }
    if (pw.size > 0) {
        v.check("password", pw.size >= 8, "密码至少 8 位")
    }
    v.done()

    let deptHint = reqIntOr(body, "dept_id", 0)

    /* ---------- ① 锁内（极短）：口令存在性 + 按 IP 限流；只把口令拷出来 ---------- */
    var expectedCode = ""
    s.lock.lock()
    try {
        if (s.register_code.size == 0) {
            throw apiErrMsg("REGISTER_CODE_INVALID", "社团尚未设置注册口令，请联系会长")
        }
        /* 限流（P1 M-2 / N-6）：注册口令是**全社团共用的一个短串**，必须限制尝试次数。
         *
         * 2026-09-14 从"全局计数"改成**按客户端 IP**：
         *   · 旧口径说"轻舟没有暴露可信客户端 IP"——这句是错的。轻舟通过
         *     ctx.http.request.remoteAddr 给出 **TCP 对端地址**，那是传输层事实，
         *     客户端伪造不了（可伪造的是 X-Forwarded-For 头，而本项目直连、不读它）；
         *     h_ops.cj 的 peerOf / clientIpOf 就是取它。
         *   · 旧全局锁的真实代价：攻击者每 15 分钟丢 10 个错口令就能把**所有人**
         *     挡在注册门外。改成按 IP 后，被锁的只有攻击者自己那个地址。
         *   · 锁定改为**递增退避**（见 regLockSeconds），重复违规成本上升。
         *
         * 已知局限（写清楚，别高估）：NAT / 校园网出口下整个社团可能共用一个公网 IP，
         * 那时按 IP 会近似退化成全局锁；拿不到对端地址时 key 为空串，同样退化为全局。
         * 两种情况都比"无条件全局锁"更窄，且锁只影响注册、不影响登录与其它接口。 */
        let ip = clientIpOf(ctx)
        if (regLocked(s, ip, nowEpoch())) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        expectedCode = s.register_code
    } finally {
        s.lock.unlock()
    }

    /* ---------- ② 锁外：口令比对 + PBKDF2（动作 2：这段 CPU 不占锁） ---------- */
    if (!constantTimeEq(rc, expectedCode)) {
        /* 失败记账要单独加一次锁（表在内存，不落盘） */
        s.lock.lock()
        try {
            regFailBump(s, clientIpOf(ctx))
        } finally {
            s.lock.unlock()
        }
        throw apiErr("REGISTER_CODE_INVALID")
    }
    let rec = newPasswordRecord(pw)

    /* ---------- ③ 锁内：清限流 + 复核手机号未被抢注 + 建账号 + 发令牌 ---------- */
    s.lock.lock()
    try {
        s.reg_fail.remove(clientIpOf(ctx))
        /* 锁外那段时间里，同一手机号可能已被别人注册成功 —— 复核一次 */
        if (memberByPhone(s, phone).isSome()) {
            throw apiErrFields("ALREADY_EXISTS", "该手机号已注册", oneField("phone", "该手机号已注册"))
        }
        let m = Member()
        m.id = s.next_member
        s.next_member += 1
        m.name = name
        m.phone = phone
        m.pw_salt = rec[0]
        m.pw_hash = rec[1]
        m.pw_iter = rec[2]
        m.status = "pending"
        m.role = ""
        m.dept_id = 0
        if (deptHint > 0 && s.departments.contains(deptHint)) {
            m.dept_hint = deptHint
        }
        m.joined_at = nowEpoch()
        s.members[m.id] = m

        let issued = issueToken(s, m.id)
        storeSave(s)
        respondLogin(ctx, s, m, issued[0], issued[1], true)
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/auth/login
 * 手机号不存在与密码错误返回同一个错误码，不泄露某号码是否注册过。
 * 限流：同一手机号 15 分钟内失败 5 次 → 锁定 15 分钟（api-design §2.4）。
 *
 * P1 M-3 的两处修正：
 *   1. 形态不对的手机号直接 400，**不写进 login_fail**。否则攻击者用随机串刷接口，
 *      就能让这张表无限膨胀（磁盘与内存一起涨）。
 *   2. 失败不再调用 storeSave。原先每失败一次就整库落盘一次 —— 一个 401 打出来
 *      18 MB 写盘，本身就是会被利用的放大杠杆。login_fail 是**短时效限流状态**，
 *      只留在内存：重启后清零可以接受（攻击者无法让服务重启），
 *      但绝不能每次都拿它去写整库。
 */
/*
 * 三阶段加锁（2026-09-15，容量基准的动作 2）。
 *
 * 为什么改：PBKDF2 一次 10 万轮，实测 **~400 ms**，而它原先是在**全局锁里**跑的
 * （`s.lock.lock()` → `verifyPw` → `storeSave` → 响应）。后果是一次登录把整个服务
 * 卡住 0.4 s，登录只能串行 ≈ 2 次/秒 —— 千人社团招新期会明显排队。
 * 这不是存储的锅，是"锁里做 CPU 密集活"。
 *
 * 现在拆成三段：
 *   ① 锁内（极短）：限流判定 + 把该手机号的口令材料**拷成标量**带出锁
 *   ② 锁外：`verifyPw`（最贵的 CPU，不再占锁）
 *   ③ 锁内（短）：记失败账 / 复核 `pw_hash` 未被并发改过 / 签令牌 / 落盘
 *
 * ⚠ 纪律：**不能把 `Member` 引用带出锁外使用**（会被并发修改）。这里只拷
 * `pw_salt / pw_hash / pw_iter` 与 `id` 四个标量；第 ③ 段重新按 id 取成员并复核。
 */
public func handleLogin(ctx: Context, s: Store): Unit {
    let body = reqObj(ctx)
    let v = V()
    let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
    let pw = v.need("password", reqStrOr(body, "password", ""), "请输入密码")
    if (phone.size > 0) {
        v.check("phone", isPhone(phone), "手机号格式不正确")
    }
    v.done()

    /* ---------- ① 锁内：限流判定 + 取口令材料 ---------- */
    var credSalt = ""
    var credHash = ""
    var credIter: Int64 = 0
    var memberId: Int64 = 0
    var found = false
    s.lock.lock()
    try {
        let now = nowEpoch()
        let lf = s.login_fail.get(phone) ?? LoginFail()
        if (lf.locked_until > now) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        match (memberByPhone(s, phone)) {
            case Some(m) =>
                credSalt = m.pw_salt
                credHash = m.pw_hash
                credIter = m.pw_iter
                memberId = m.id
                found = true
            case None => ()
        }
    } finally {
        s.lock.unlock()
    }

    /* ---------- ② 锁外：口令校验（~400 ms CPU，不占锁） ---------- */
    /*
     * N-16：号码不存在也照样跑一次**等价成本**的 PBKDF2（假材料，结果丢弃）。
     * 否则"号码不存在"比"口令错误"快一个量级，登录接口就能被用来枚举手机号。
     * 材料由纯函数 loginCreds 给出（见 auth.cj），它同时是这条修复的回归闸门。
     */
    let creds = loginCreds(found, credSalt, credHash, credIter)
    let ok = verifyPw(pw, creds[0], creds[1], creds[2]) && found

    /* ---------- ③ 锁内：记账 / 复核 / 签发 ---------- */
    s.lock.lock()
    try {
        if (!ok) {
            /* 手机号不存在与口令错误走同一条路：不泄露某个号码是否注册过 */
            let now = nowEpoch()
            var lf = s.login_fail.get(phone) ?? LoginFail()
            if (now - lf.first_at > LOGIN_FAIL_WINDOW) {
                lf.count = 0
                lf.first_at = now
            }
            lf.count += 1
            if (lf.count >= LOGIN_FAIL_LIMIT) {
                lf.locked_until = now + LOGIN_FAIL_LOCK
                lf.count = 0
                lf.first_at = now
            }
            s.login_fail[phone] = lf
            pruneLoginFail(s, now)
            /* 故意不落盘：见上方注释第 2 条 */
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }

        /* 锁外那段时间里账号可能被改密 / 移出 / 删除 —— 复核后才签发 */
        let m = match (s.members.get(memberId)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        if (m.pw_hash != credHash) {
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        if (m.status == "disabled") {
            throw apiErr("MEMBER_DISABLED")
        }
        s.login_fail.remove(phone)
        let issued = issueToken(s, m.id)
        storeSave(s)
        respondLogin(ctx, s, m, issued[0], issued[1], false)
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/auth/logout —— 服务端删映射，旧令牌立即失效。 */
public func handleLogout(ctx: Context, s: Store): Unit {
    let tok = match (bearerToken(ctx)) {
        case Some(t) => t
        case None => throw apiErr("AUTH_REQUIRED")
    }
    s.lock.lock()
    try {
        s.tokens.remove(tok)
        storeSave(s)
    } finally {
        s.lock.unlock()
    }
    sendOk(ctx, JsonObject())
}

/*
 * GET /api/v1/auth/me
 * 客户端启动时第一个调用的接口：既校验令牌，又拿权限摘要。
 * pending 账号也能正常调用（返回 view_scope = none），不能当成错误。
 */
public func handleMe(ctx: Context, s: Store): Unit {
    let m = requireMember(ctx, s)
    let data = JsonObject()
    jPutObj(data, "member", memberSelf(s, m))
    jPutObj(data, "permissions", permissionsOf(m))
    sendOk(ctx, data)
}

/* PUT /api/v1/auth/password —— 本人改密，改完其他令牌全部失效。 */
public func handleChangePassword(ctx: Context, s: Store): Unit {
    let m = requireMember(ctx, s)
    let tok = bearerToken(ctx) ?? ""
    let body = reqObj(ctx)
    let v = V()
    let oldPw = v.need("old_password", reqStrOr(body, "old_password", ""), "请输入原密码")
    let newPw = v.need("new_password", reqStrOr(body, "new_password", ""), "请输入新密码")
    if (newPw.size > 0) {
        v.check("new_password", newPw.size >= 8, "密码至少 8 位")
    }
    v.done()

    /*
     * 三段式（动作 2）：验旧口令与算新口令**都是** PBKDF2（两次约 800 ms），
     * 原先全在锁里 → 一次改密把全服卡 0.8 s。现在只把标量拷出锁。
     */
    var curSalt = ""
    var curHash = ""
    var curIter: Int64 = 0
    s.lock.lock()
    try {
        let cur = match (s.members.get(m.id)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_REQUIRED")
        }
        curSalt = cur.pw_salt
        curHash = cur.pw_hash
        curIter = cur.pw_iter
    } finally {
        s.lock.unlock()
    }

    /* 锁外：**先验旧口令**，验过了才算新口令 —— 失败时只花一次 PBKDF2，不给放大杠杆 */
    if (!verifyPw(oldPw, curSalt, curHash, curIter)) {
        throw apiErr("AUTH_BAD_CREDENTIALS")
    }
    let rec = newPasswordRecord(newPw)

    s.lock.lock()
    try {
        let cur = match (s.members.get(m.id)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_REQUIRED")
        }
        /* 锁外那段时间里口令可能已被改过（例如管理员重置）—— 复核，别用旧凭据覆盖新口令 */
        if (cur.pw_hash != curHash) {
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        cur.pw_salt = rec[0]
        cur.pw_hash = rec[1]
        cur.pw_iter = rec[2]
        revokeOtherTokens(s, m.id, tok)
        storeSave(s)
    } finally {
        s.lock.unlock()
    }
    sendOk(ctx, JsonObject())
}
