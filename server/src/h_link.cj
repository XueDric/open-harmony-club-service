package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.7 · 部门招募链接 —— 3 个接口
 *
 * 设计要点（api-design §3.7）：
 *   · 招募链接**只做部门预填**，不赋予任何角色；通过它注册的人仍是 pending
 *   · **链接不免除注册口令**：单一门槛。链接是便利，口令才是准入
 *   · 每个部门可以有多个链接（"2026 秋招" / "补录"），便于分别停用
 */

import std.collection.*
import stdx.encoding.json.*

/* 链接落地页地址。用请求的 Host 头拼，避免把域名写死进配置。 */
func linkUrl(ctx: Context, token: String): String {
    let host = ctx.requestHeader("host") ?? "localhost"
    return "https://${host}/join/${token}"
}

/* 生成不与现有链接冲突的 token（8 个十六进制字符，够短好念）。 */
func freshLinkToken(s: Store): String {
    var i: Int64 = 0
    while (i < 64) {
        let t = randHex(4)
        if (!s.invite_links.contains(t)) {
            return t
        }
        i += 1
    }
    /* 极端情况退化为更长 token，绝不返回重复值 */
    return randHex(16)
}

/* GET /api/v1/dept-invite-links */
public func handleInviteLinkList(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ManageInviteLink, Target())
    s.lock.lock()
    try {
        let list = ArrayList<DeptInviteLink>()
        for ((_k, l) in s.invite_links) {
            list.add(l)
        }
        let arr0 = list.toArray()
        sortByKey<DeptInviteLink>(arr0, { l: DeptInviteLink => l.created_at * 1000 + l.dept_id })
        let arr = JsonArray()
        for (l in arr0) {
            arr.add(inviteLinkView(s, l, linkUrl(ctx, l.token)))
        }
        let data = JsonObject()
        data.put("items", arr)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/dept-invite-links */
public func handleInviteLinkCreate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ManageInviteLink, Target())
    let body = reqObj(ctx)
    let v = V()
    let deptId = reqIntOr(body, "dept_id", 0)
    v.check("dept_id", deptId > 0, "请选择部门")
    v.done()

    s.lock.lock()
    try {
        match (s.departments.get(deptId)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        let l = DeptInviteLink()
        l.token = freshLinkToken(s)
        l.dept_id = deptId
        l.enabled = true
        l.created_by = actor.id
        l.created_at = nowEpoch()
        s.invite_links[l.token] = l
        storeSave(s)
        let data = JsonObject()
        jPutObj(data, "link", inviteLinkView(s, l, linkUrl(ctx, l.token)))
        /* 也把 token/url 提到顶层，方便客户端直接用（api-design §3.7 的响应示例） */
        jPutStr(data, "token", l.token)
        jPutStr(data, "url", linkUrl(ctx, l.token))
        sendCreated(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * DELETE /api/v1/dept-invite-links/{token} —— 停用链接（**不是删除记录**）
 *
 * 语义是"停用"：记录保留、enabled 置 false，便于在列表里看到"已停用的秋招链接"。
 * **幂等**：对不存在或已停用的 token 重复调用一律返回 200——
 * 与 assign 同理，客户端重试不该产生错误。
 */
public func handleInviteLinkDisable(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ManageInviteLink, Target())
    let token = ctx.paramOr("token", "")
    if (token.size == 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("token", "缺少链接标识"))
    }
    s.lock.lock()
    try {
        match (s.invite_links.get(token)) {
            case Some(l) =>
                l.enabled = false
                storeSave(s)
                audit(s, actor.id, "disable-invite-link", l.dept_id, "token=${token}")
                sendOk(ctx, inviteLinkView(s, l, linkUrl(ctx, token)))
            case None =>
                /* 幂等：不存在也返回成功 */
                sendOk(ctx, JsonObject())
        }
    } finally {
        s.lock.unlock()
    }
}
