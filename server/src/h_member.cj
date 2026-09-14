package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.2–3.4 · 成员名录、待分配与授权、会长移交 —— 8 个接口
 *
 * 两处设计要点：
 *   1. **注册与授权分离**：assign 只做"授予部门+角色"这一件事，
 *      注册接口不产生任何权限（v1-scope 规则 12）。
 *   2. **权限与字段一一对应**：改姓名走 EditMemberName，改部门/角色走 SetRole，
 *      两者权限不同，不能因为它们在同一个请求体里就合并判定。
 *
 * ⚠ 锁规则：requireActive 内部加锁；handler 先认证、再单独加锁。
 */

import std.collection.*
import stdx.encoding.json.*

/* 组装一条批量失败记录。 */
func addFail(arr: JsonArray, id: Int64, code: String): Unit {
    let o = JsonObject()
    jPutInt(o, "id", id)
    jPutStr(o, "code", code)
    arr.add(o)
}

/* 名下有未完成任务：把任务清单放进 error.fields.tasks（见 api-design §3.2 注）。 */
func openTasksError(s: Store, m: Member, open: Array<Task>): ApiError {
    let arr = JsonArray()
    for (t in open) {
        let o = JsonObject()
        jPutInt(o, "id", t.id)
        jPutStr(o, "title", t.title)
        jPutStr(o, "status", t.status)
        arr.add(o)
    }
    let fields = JsonObject()
    fields.put("tasks", arr)
    return apiErrFields("MEMBER_HAS_OPEN_TASKS", "${m.name} 名下还有 ${open.size} 个未完成任务，需先转交", fields)
}

/* 为某个成员构造权限判定目标。 */
func targetOf(actor: Member, tgt: Member): Target {
    let t = Target()
    t.member_id = tgt.id
    t.dept_id = tgt.dept_id
    t.target_role = tgt.role
    t.owner_id = tgt.id
    t.is_self = (tgt.id == actor.id)
    return t
}

/*
 * GET /api/v1/members —— 成员名录
 * 全社团可见（api-design §3.2）：这是第 1 节第一个问题「社团里有哪些人」的答案。
 * 默认只返回 active；用 ?status= 查其它状态。
 */
public func handleMemberList(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ViewMembers, Target())
    let fDept = queryIntOr(ctx, "dept_id", 0)
    let fRole = ctx.queryParamOr("role", "")
    let fStatus = ctx.queryParamOr("status", "active")

    s.lock.lock()
    try {
        let picked = ArrayList<Member>()
        for ((_k, x) in s.members) {
            if (fStatus.size > 0 && x.status != fStatus) {
                continue
            }
            if (fDept > 0 && x.dept_id != fDept) {
                continue
            }
            if (fRole.size > 0 && x.role != fRole) {
                continue
            }
            picked.add(x)
        }
        let sorted = sortedMembers(s, picked)
        let arr = ArrayList<JsonObject>()
        for (x in sorted) {
            arr.add(memberBrief(s, x))
        }
        sendOk(ctx, pagedJson(ctx, arr))
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/members/{id} —— 详情（MemberBrief + 计数摘要） */
public func handleMemberDetail(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ViewMembers, Target())
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        sendOk(ctx, memberDetailView(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/members/pending —— 待分配列表（先来先处理） */
public func handleMemberPending(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.AssignPending, Target())
    s.lock.lock()
    try {
        let arr = JsonArray()
        for (x in pendingMembers(s)) {
            arr.add(pendingView(s, x))
        }
        let data = JsonObject()
        data.put("items", arr)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * PATCH /api/v1/members/{id} —— 编辑成员（name / dept_id / role 全部可选）
 *
 * 字段级权限：name → EditMemberName；dept_id / role → SetRole。
 * 待分配成员不接受 dept_id / role——那属于 assign 的职责，避免两条路径各写一半。
 */
public func handleMemberUpdate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    let body = reqObj(ctx)

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        let t = targetOf(actor, tgt)
        var touched = false

        match (jsonGetStr(body, "name")) {
            case Some(nm) =>
                requireAccess(actor, Action.EditMemberName, t)
                if (isBlank(nm)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("name", "姓名不能为空"))
                }
                tgt.name = nm
                touched = true
            case None => ()
        }

        var newDept: ?Int64 = None
        match (jsonGetInt64(body, "dept_id")) {
            case Some(x) => newDept = Some(x)
            case None => ()
        }
        var newRole: ?String = None
        match (jsonGetStr(body, "role")) {
            case Some(x) => newRole = Some(x)
            case None => ()
        }

        if (newDept.isSome() || newRole.isSome()) {
            requireAccess(actor, Action.SetRole, t)
            if (tgt.status == "pending") {
                throw apiErrMsg("VALIDATION_FAILED", "待分配成员请用 POST /members/{id}/assign 授予部门与角色")
            }
            match (newRole) {
                case Some(r) =>
                    if (!isKnownRole(r)) {
                        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                            oneField("role", "角色必须是 5 档预设之一"))
                    }
                    if (r == "president") {
                        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                            oneField("role", "会长只能通过「移交会长」产生"))
                    }
                    /* 规则 10：系统必须始终至少有一个 president */
                    if (tgt.role == "president" && presidentCount(s) <= 1) {
                        throw apiErr("FORBIDDEN_LAST_PRESIDENT")
                    }
                    tgt.role = r
                    touched = true
                case None => ()
            }
            match (newDept) {
                case Some(did) =>
                    if (did > 0) {
                        match (s.departments.get(did)) {
                            case Some(_) => ()
                            case None => throw apiErr("DEPT_NOT_FOUND")
                        }
                    }
                    tgt.dept_id = did
                    touched = true
                case None => ()
            }
        }

        if (touched) {
            storeSave(s)
        }
        sendOk(ctx, memberBrief(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/{id}/disable —— 移出社团
 *
 * 账号与历史记录全部保留（不删除），日后可恢复。
 * 名下有未完成任务会被拒绝：不允许"人走了任务跟着烂尾"（api-design §3.2）。
 */
public func handleMemberDisable(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.DisableMember, targetOf(actor, tgt))
        if (tgt.status == "disabled") {
            /* 幂等：已经是退出状态 */
            sendOk(ctx, memberBrief(s, tgt))
            return
        }
        if (tgt.role == "president" && presidentCount(s) <= 1) {
            throw apiErr("FORBIDDEN_LAST_PRESIDENT")
        }
        let open = openTasksOf(s, tgt.id)
        if (open.size > 0) {
            throw openTasksError(s, tgt, open)
        }
        tgt.status = "disabled"
        storeSave(s)
        audit(s, actor.id, "disable-member", tgt.id, "移出社团（账号保留）")
        sendOk(ctx, memberBrief(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/{id}/assign —— 单个分配（部门 + 角色）
 * **幂等**：对已是 active 的成员重复调用同样的分配，返回 200 而不报错。
 */
public func handleMemberAssign(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    let body = reqObj(ctx)
    let v = V()
    let role = v.need("role", reqStrOr(body, "role", ""), "请选择角色")
    let deptId = reqIntOr(body, "dept_id", 0)
    v.check("dept_id", deptId > 0, "请选择部门")
    v.check("role", isKnownRole(role), "角色必须是 5 档预设之一")
    if (role == "president") {
        v.check("role", false, "会长只能通过「移交会长」产生")
    }
    v.done()

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.AssignPending, targetOf(actor, tgt))
        match (s.departments.get(deptId)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        if (tgt.role == "president" && presidentCount(s) <= 1) {
            throw apiErr("FORBIDDEN_LAST_PRESIDENT")
        }
        /* M-4：assign 同时承担"审批待分配"和"恢复已退出成员"两件事。
         * 文档（api-design §3.2）写明移出社团是**保留数据、日后可恢复**，
         * 所以这里不拒绝 disabled 目标；但绝不能让它**静默**发生——
         * 审计里必须能一眼看出这次是"复活"而不是普通分配，
         * 否则事后追查"这个人是怎么回来的"会查不出来。 */
        let wasDisabled = (tgt.status == "disabled")
        tgt.dept_id = deptId
        tgt.role = role
        tgt.status = "active"
        tgt.dept_hint = 0
        storeSave(s)
        if (wasDisabled) {
            audit(s, actor.id, "restore-member", tgt.id,
                "恢复已退出成员：部门=${deptId} 角色=${role}（恢复与分配同用 assign，此处按恢复记账）")
        } else {
            audit(s, actor.id, "assign-member", tgt.id, "部门=${deptId} 角色=${role}")
        }
        sendOk(ctx, memberBrief(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/assign-batch —— 批量分配
 *
 * ⚠ **绝不能"一条失败就整体回滚"**。招新期一次处理 20 个人，
 * 因为其中 1 个数据有问题就全部不生效，会长会疯掉。
 * 逐条报告、让成功的生效，才是可用的批量语义。
 */
public func handleMemberAssignBatch(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let v = V()
    let role = v.need("role", reqStrOr(body, "role", ""), "请选择角色")
    let deptId = reqIntOr(body, "dept_id", 0)
    v.check("dept_id", deptId > 0, "请选择部门")
    v.check("role", isKnownRole(role) && role != "president", "角色不合法（会长只能通过「移交」产生）")
    v.done()

    let ids = match (jsonGetArray(body, "member_ids")) {
        case Some(a) => a
        case None => throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("member_ids", "请提供成员列表"))
    }
    if (ids.size() == 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("member_ids", "成员列表不能为空"))
    }
    if (ids.size() > 200) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("member_ids", "一次最多处理 200 人"))
    }

    s.lock.lock()
    try {
        requireAccess(actor, Action.AssignPending, Target())
        match (s.departments.get(deptId)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        let ok = JsonArray()
        let bad = JsonArray()
        var restored: Int64 = 0
        var i: Int64 = 0
        while (i < ids.size()) {
            let cell = ids.get(i)
            i += 1
            match (cell) {
                case Some(jv) =>
                    var id: Int64 = -1
                    try {
                        id = jv.asInt().getValue()
                    } catch (e: Exception) {
                        id = -1
                    }
                    if (id < 0) {
                        addFail(bad, id, "VALIDATION_FAILED")
                        continue
                    }
                    match (s.members.get(id)) {
                        case Some(tgt) =>
                            /* N-10：外层那次 requireAccess 传的是**裸 Target()**，只能挡角色维度
                             * （部长 / 成员），挡不住同权。所以这里逐条按成员建 Target 再判一次；
                             * 失败写进 bad 数组，保持"绝不整体回滚、逐条报告"的批量语义。 */
                            let deny = checkAccess(actor, Action.AssignPending, targetOf(actor, tgt)) ?? ""
                            if (deny.size > 0) {
                                addFail(bad, id, deny)
                            } else if (tgt.role == "president" && presidentCount(s) <= 1) {
                                addFail(bad, id, "FORBIDDEN_LAST_PRESIDENT")
                            } else {
                                /* M-4：批量路径同样可能复活已退出成员，单独计数并单独记账 */
                                if (tgt.status == "disabled") {
                                    restored += 1
                                }
                                tgt.dept_id = deptId
                                tgt.role = role
                                tgt.status = "active"
                                tgt.dept_hint = 0
                                ok.add(JsonInt(id))
                            }
                        case None => addFail(bad, id, "MEMBER_NOT_FOUND")
                    }
                case None => ()
            }
        }
        storeSave(s)
        audit(s, actor.id, "assign-batch", deptId,
            "成功=${ok.size()} 失败=${bad.size()} 角色=${role} 其中恢复已退出成员=${restored}")
        let data = JsonObject()
        data.put("succeeded", ok)
        data.put("failed", bad)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/{id}/transfer-presidency —— 会长移交（**仅现任会长**）
 *
 * 这是**一个原子操作**，内部同时完成：目标 → president，自己 → self_role。
 * 为什么不能"改两次角色"：分两步做中间会出现零会长状态，
 * 一旦第二步失败（网络、进程重启），社团就永久失去管理能力（规则 10/11）。
 *
 * 本接口是**产生会长的唯一入口**：assign 与 PATCH /members 一律拒绝 role=president。
 */
public func handleTransferPresidency(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    let body = reqObj(ctx)
    let selfRole = reqStrOr(body, "self_role", "vice_president")

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.TransferPresidency, targetOf(actor, tgt))
        if (tgt.id == actor.id) {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("id", "不能把会长移交给自己"))
        }
        if (tgt.status == "pending") {
            throw apiErr("MEMBER_PENDING")
        }
        if (tgt.status == "disabled") {
            throw apiErr("MEMBER_DISABLED")
        }
        if (!isKnownRole(selfRole) || selfRole == "president") {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                oneField("self_role", "self_role 必须是会长以外的合法角色"))
        }
        /* 两步同时生效，只落盘一次——不会出现零会长的中间态 */
        tgt.role = "president"
        actor.role = selfRole
        storeSave(s)
        audit(s, actor.id, "transfer-presidency", tgt.id, "原会长降为 ${selfRole}")
        let data = JsonObject()
        jPutObj(data, "president", memberBrief(s, tgt))
        jPutObj(data, "previous", memberBrief(s, actor))
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}
