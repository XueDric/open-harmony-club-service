package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.5–3.6 · 重置密码与注册配置 —— 4 个接口
 *
 * 重置密码是 v1 里「忘记密码」的**唯一出路**（不做短信/邮箱自助找回），
 * 所以它必须是可追溯的敏感操作：每次重置都写入 <数据目录>/audit.log。
 */

import stdx.encoding.json.*

/*
 * POST /api/v1/members/{id}/reset-password
 *
 * 权限：会长 / 副会长（任意成员）、部长 / 副部长（本部门内档位低于自己的成员），
 * 以及**不能**对自己用——本人改密走 PUT /auth/password（需原密码）。
 *
 * L-4 口径澄清：api-design §3.8 汇总表与 v1-scope §3.4.3 曾把本接口写成"仅本人可用"，
 * 与 §3.5 / §6.1 的"会长重置成员密码"自相矛盾。已统一为**管理员操作**：
 *   · 本接口是"忘记密码"的唯一出路，它签发一次性临时密码，属于管理员救济动作；
 *   · 「本人可用」的语义由 PUT /auth/password 承担（要验原密码，更安全）；
 *   · 因此 scopeAllows 里那条 `case ResetPassword => return true` 的死代码已删除
 *     （角色维度从不给 member 放行 ResetPassword，那条分支永远到不了）。
 * 两处文档已同步，tests 里也钉了一条"成员对自己重置 -> 403"。
 */
public func handleResetPassword(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.ResetPassword, targetOf(actor, tgt))
        let temp = newTempPassword()
        let rec = newPasswordRecord(temp)
        tgt.pw_salt = rec[0]
        tgt.pw_hash = rec[1]
        tgt.pw_iter = rec[2]
        /* 改密后该成员的所有令牌失效——这是账号被盗时的自救手段 */
        revokeOtherTokens(s, tgt.id, "")
        storeSave(s)
        audit(s, actor.id, "reset-password", tgt.id, "临时密码已签发（其余令牌已失效）")
        let data = JsonObject()
        jPutStr(data, "temporary_password", temp)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/register-config —— 口令存明文，仅会长/副会长可读（v1-scope §5） */
public func handleRegisterConfigGet(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ViewRegisterCode, Target())
    s.lock.lock()
    try {
        sendOk(ctx, registerConfigView(s))
    } finally {
        s.lock.unlock()
    }
}

/*
 * PUT /api/v1/register-config/code —— 更换口令（**仅会长**）
 * 更换后旧口令立即失效；正在注册的人会失败，需在群里同步公告。
 */
public func handleRegisterConfigPut(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ChangeRegisterCode, Target())
    let body = reqObj(ctx)
    let v = V()
    let code = v.need("code", reqStrOr(body, "code", ""), "请输入新的注册口令")
    if (code.size > 0) {
        /* M-2：下限从 4 提到 6。注册口令是**全社团共用**、只需猜中一次就拿到账号的
         * 单一秘密，4 位字符（尤其纯数字）在线爆破是分钟级的事。6 位是成本与
         * 可传播性（要在群里发）之间的折中，同时配合 handleRegister 的失败限流。 */
        v.check("code", code.size >= 6, "注册口令至少 6 位")
        v.check("code", code.size <= 32, "注册口令最多 32 位")
    }
    v.done()

    s.lock.lock()
    try {
        s.register_code = code
        s.register_code_by = actor.id
        s.register_code_at = nowEpoch()
        storeSave(s)
        audit(s, actor.id, "change-register-code", 0, "注册口令已更换")
        sendOk(ctx, registerConfigView(s))
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/register-config/rotate —— 随机轮换（仅会长），用于"口令可能外泄" */
public func handleRegisterConfigRotate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ChangeRegisterCode, Target())
    s.lock.lock()
    try {
        s.register_code = newRegisterCode()
        s.register_code_by = actor.id
        s.register_code_at = nowEpoch()
        storeSave(s)
        audit(s, actor.id, "rotate-register-code", 0, "注册口令已随机轮换")
        sendOk(ctx, registerConfigView(s))
    } finally {
        s.lock.unlock()
    }
}
