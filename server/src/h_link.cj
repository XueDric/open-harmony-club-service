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

/*
 * 链接落地页地址。用请求的 Host 头拼，避免把域名写死进配置。
 *
 * L-2 已知取舍：接口文档里这个 URL 是要发到群里的"落地页"，但原先**没有 /join/{token}
 * 这个路由**，点开就是 404；而且 Host 头是调用方可控的，响应里的 url 会被污染
 * （只在调用方自己的响应里，不落盘、不影响他人，所以定为低危）。
 * 现在补上了落地页（handleJoinLanding），Host 头的问题保留并记录：
 * 真正上线时应改为配置项（服务端已知自己的公网地址）。
 */
func linkUrl(ctx: Context, token: String): String {
    let host = ctx.requestHeader("host") ?? "localhost"
    return "https://${host}/join/${token}"
}

/*
 * GET /join/{token} —— 招募链接的落地页（无需登录，L-2）。
 *
 * 客户端是 HarmonyOS 应用，浏览器打开链接无法直接唤起 App（v1 不做 deep link 配置），
 * 因此这里给一个**最小可用**的说明页：告诉用户链接属于哪个部门、下一步该做什么。
 * 只暴露部门名——那本来就是链接持有者能看到的信息，不含任何口令、成员或任务数据。
 */
public func handleJoinLanding(ctx: Context, s: Store): Unit {
    let token = ctx.paramOr("token", "")
    var deptName = ""
    s.lock.lock()
    try {
        match (s.invite_links.get(token)) {
            case Some(l) =>
                if (l.enabled) {
                    match (s.departments.get(l.dept_id)) {
                        case Some(d) => deptName = d.name
                        case None => deptName = ""
                    }
                }
            case None => ()
        }
    } finally {
        s.lock.unlock()
    }
    let html = if (deptName.size > 0) {
        joinPageHtml("加入「${deptName}」", "请在社团管理 App 内注册，并向管理员索取注册口令。")
    } else {
        joinPageHtml("链接已失效", "这个招募链接已被停用或不存在，请向管理员索取新的链接。")
    }
    /* N-9：落地页是本项目唯一一处 HTML 输出，加一行 CSP。
     * 该页只有内联 style 属性、没有脚本也没有外部资源，所以 default-src 'none'
     * 不会破坏显示；即使将来哪一处漏了转义（N-1），注入的脚本也执行不了。 */
    ctx.header("content-type", "text/html; charset=utf-8")
        .header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'")
        .status(200)
        .body(html)
}

/* 落地页 HTML：不用模板引擎，也不引入任何外部资源（离线可看）。
 *
 * N-1：title / tip 一律先过 htmlEscape —— 页面上要显示部门名，而部门名只校验过
 * "非空"，直接拼接就是一个 HTML 注入点。转义在这里做（而不是调用处），
 * 将来谁再往这两个参数里塞用户数据也自动是安全的。 */
func joinPageHtml(title: String, tip: String): String {
    let t = htmlEscape(title)
    let p = htmlEscape(tip)
    return "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
        "<title>${t}</title></head>" +
        "<body style=\"font-family:sans-serif;padding:2rem;line-height:1.8;color:#222\">" +
        "<h2>${t}</h2><p>${p}</p>" +
        "<p style=\"color:#888;font-size:.9rem\">社团管理工具</p>" +
        "</body></html>"
}

/*
 * 生成不与现有链接冲突的 token（**16 字节 = 32 个十六进制字符**）。
 *
 * N-19：原先是 `randHex(4)`（4 字节 = 32 bit），而 `GET /join/{token}` 免认证、
 * 命中就返回部门名 —— 32 位空间可以枚举（配合并发是小时级）。
 * 链接本身不免除注册口令（"链接是便利，口令才是准入"），所以危害有限；
 * 但没必要留这个缺口：与会话令牌（32 字节）同口径更省心。
 * 重试循环保留（现在第一次必然成功），上限不动。
 */
func freshLinkToken(s: Store): String {
    var i: Int64 = 0
    while (i < 64) {
        let t = randHex(16)
        if (!s.invite_links.contains(t)) {
            return t
        }
        i += 1
    }
    /* 极端情况退化为更长 token，绝不返回重复值 */
    return randHex(32)
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
                /* 幂等：不存在也返回成功。
                 * L-3：响应形状必须与存在时一致——原先返回空对象 {}，
                 * 客户端读 data.link.enabled 会拿到 null，得写一个"有没有 data.link"的特例。
                 * 这里给同一个视图，字段齐全、enabled 恒为 false。 */
                sendOk(ctx, inviteLinkView(s, goneLink(token), linkUrl(ctx, token)))
        }
    } finally {
        s.lock.unlock()
    }
}

/* 为"已不存在"的链接造一个同形状的替身：token 原样回显、enabled=false、其余为空。 */
func goneLink(token: String): DeptInviteLink {
    let l = DeptInviteLink()
    l.token = token
    l.dept_id = 0
    l.enabled = false
    l.created_by = 0
    l.created_at = 0
    return l
}
