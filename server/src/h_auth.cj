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
        if (rc != s.register_code) {
            throw apiErr("REGISTER_CODE_INVALID")
        }
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
 */
public func handleLogin(ctx: Context, s: Store): Unit {
    let body = reqObj(ctx)
    let v = V()
    let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
    let pw = v.need("password", reqStrOr(body, "password", ""), "请输入密码")
    v.done()

    s.lock.lock()
    try {
        let now = nowEpoch()
        var lf = s.login_fail.get(phone) ?? LoginFail()
        if (lf.locked_until > now) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        if (now - lf.first_at > 900) {
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
            if (lf.count >= 5) {
                lf.locked_until = now + 900
                lf.count = 0
                lf.first_at = now
            }
            s.login_fail[phone] = lf
            storeSave(s)
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
