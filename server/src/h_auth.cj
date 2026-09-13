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

/* 注册口令限流参数：窗口 15 分钟，错 10 次锁 15 分钟（见 handleRegister）。 */
public let REG_FAIL_WINDOW: Int64 = 900
public let REG_FAIL_LIMIT: Int64 = 10
public let REG_FAIL_LOCK: Int64 = 900

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

/*
 * 注册口令失败计数（P1 M-2）。窗口内累计到上限就锁定，锁定期间注册一律 429。
 * 与 login_fail 同理不落盘：失败路径上写整库等于给攻击者一个放大杠杆。
 */
func regFailBump(s: Store): Unit {
    let now = nowEpoch()
    if (s.reg_fail_first_at == 0 || now - s.reg_fail_first_at > REG_FAIL_WINDOW) {
        s.reg_fail_first_at = now
        s.reg_fail_count = 0
    }
    s.reg_fail_count += 1
    if (s.reg_fail_count >= REG_FAIL_LIMIT) {
        s.reg_fail_until = now + REG_FAIL_LOCK
        s.reg_fail_count = 0
        s.reg_fail_first_at = now
    }
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

    s.lock.lock()
    try {
        if (s.register_code.size == 0) {
            throw apiErrMsg("REGISTER_CODE_INVALID", "社团尚未设置注册口令，请联系会长")
        }
        /* 限流（P1 M-2）：注册口令是**全社团共用的一个短串**，原先可以无限次试。
         * 这里做全局计数：15 分钟内错 10 次就锁 15 分钟。
         * 为什么是全局而不是按 IP：轻舟没有暴露可信客户端 IP，伪造 X-Forwarded-For
         * 就能绕过；而注册是低频动作，全局锁的误伤可接受。
         * 代价要写清楚：攻击者可以用它把正常注册挡在门外（DoS），
         * 所以阈值放宽到 10 次，且锁只影响注册、不影响登录与其它接口。 */
        if (s.reg_fail_until > nowEpoch()) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        if (!constantTimeEq(rc, s.register_code)) {
            regFailBump(s)
            throw apiErr("REGISTER_CODE_INVALID")
        }
        s.reg_fail_count = 0
        s.reg_fail_first_at = 0
        s.reg_fail_until = 0
        if (memberByPhone(s, phone).isSome()) {
            throw apiErrFields("ALREADY_EXISTS", "该手机号已注册", oneField("phone", "该手机号已注册"))
        }
        let m = Member()
        m.id = s.next_member
        s.next_member += 1
        m.name = name
        m.phone = phone
        let rec = newPasswordRecord(pw)
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
public func handleLogin(ctx: Context, s: Store): Unit {
    let body = reqObj(ctx)
    let v = V()
    let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
    let pw = v.need("password", reqStrOr(body, "password", ""), "请输入密码")
    if (phone.size > 0) {
        v.check("phone", isPhone(phone), "手机号格式不正确")
    }
    v.done()

    s.lock.lock()
    try {
        let now = nowEpoch()
        var lf = s.login_fail.get(phone) ?? LoginFail()
        if (lf.locked_until > now) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        if (now - lf.first_at > LOGIN_FAIL_WINDOW) {
            lf.count = 0
            lf.first_at = now
        }

        let found = memberByPhone(s, phone)
        var bad = false
        var target: ?Member = None
        match (found) {
            case Some(m) =>
                if (verifyPw(pw, m.pw_salt, m.pw_hash, m.pw_iter)) {
                    target = Some(m)
                } else {
                    bad = true
                }
            case None => bad = true
        }

        if (bad) {
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

        match (target) {
            case Some(m) =>
                if (m.status == "disabled") {
                    throw apiErr("MEMBER_DISABLED")
                }
                s.login_fail.remove(phone)
                let issued = issueToken(s, m.id)
                storeSave(s)
                respondLogin(ctx, s, m, issued[0], issued[1], false)
            case None => throw apiErr("AUTH_BAD_CREDENTIALS")
        }
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

    s.lock.lock()
    try {
        if (!verifyPw(oldPw, m.pw_salt, m.pw_hash, m.pw_iter)) {
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        let rec = newPasswordRecord(newPw)
        m.pw_salt = rec[0]
        m.pw_hash = rec[1]
        m.pw_iter = rec[2]
        revokeOtherTokens(s, m.id, tok)
        storeSave(s)
    } finally {
        s.lock.unlock()
    }
    sendOk(ctx, JsonObject())
}
