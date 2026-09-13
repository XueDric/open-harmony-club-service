package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 对外 JSON 视图（模型的投影）。
 *
 * 一条硬规则：**MemberBrief 不含手机号**（api-design §2.7）。
 * 名录只需要姓名、部门、角色。手机号只在 /auth/me、本人资料，
 * 以及会长/副会长可见的管理视图里出现——成本为零的隐私最小化。
 */

import std.collection.*
import stdx.encoding.json.*

/* 人：名录、任务负责人、课题负责人等所有出现"人"的地方统一用它。 */
public func memberBrief(s: Store, m: Member): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", m.id)
    jPutStr(o, "name", m.name)
    if (m.status == "active" && m.role.size > 0) {
        jPutStr(o, "role", m.role)
    } else {
        jPutNull(o, "role")
    }
    if (m.dept_id > 0) {
        jPutObj(o, "dept", deptBriefObj(s, m.dept_id))
    } else {
        jPutNull(o, "dept")
    }
    jPutStr(o, "status", m.status)
    jPutTime(o, "joined_at", m.joined_at)
    return o
}

/* 本人视图：比 MemberBrief 多手机号（仅本人可见）。 */
public func memberSelf(s: Store, m: Member): JsonObject {
    let o = memberBrief(s, m)
    jPutStr(o, "phone", m.phone)
    return o
}

public func deptBriefObj(s: Store, deptId: Int64): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", deptId)
    match (s.departments.get(deptId)) {
        case Some(d) => jPutStr(o, "name", d.name)
        case None => jPutStr(o, "name", "")
    }
    return o
}

/*
 * 权限摘要。客户端读它**只为画界面**，绝不能用它替代服务端校验
 * （真正的拦截在 perms.cj 的 checkAccess / requireAccess）。
 */
public func permissionsOf(m: Member): JsonObject {
    let p = JsonObject()
    let active = m.status == "active"
    let global = active && (m.role == "president" || m.role == "vice_president")
    let deptAdmin = active && (m.role == "lead" || m.role == "vice_lead")
    var scope = "none"
    if (global) {
        scope = "all"
    } else if (deptAdmin || (active && m.role == "member")) {
        scope = "dept"
    }
    jPutStr(p, "view_scope", scope)
    jPutBool(p, "manage_members", global)
    jPutBool(p, "set_role", active && m.role == "president")
    jPutBool(p, "create_plan", global || deptAdmin)
    jPutBool(p, "create_task", global || deptAdmin)
    jPutBool(p, "update_any_task", global || deptAdmin)
    return p
}

/* 角色中文名，用于日志与导出。 */
public func roleLabel(role: String): String {
    if (role == "president") {
        return "会长"
    }
    if (role == "vice_president") {
        return "副会长"
    }
    if (role == "lead") {
        return "部长"
    }
    if (role == "vice_lead") {
        return "副部长"
    }
    if (role == "member") {
        return "成员"
    }
    return "待分配"
}

/* 角色必须是固定 5 档之一（v1-scope 规则 5：只能分配，不能自定义）。 */
public func isKnownRole(role: String): Bool {
    if (role == "president") {
        return true
    }
    if (role == "vice_president") {
        return true
    }
    if (role == "lead") {
        return true
    }
    if (role == "vice_lead") {
        return true
    }
    if (role == "member") {
        return true
    }
    return false
}

/* ===================== Part 3 的视图 ===================== */

/*
 * 部门（含部长与人数）。
 * `lead` 现查现算：v0.6 起**部长身份只由 `Member.role = lead` 表达**，
 * Department 表里没有、也不该有 lead_id（同一事实存两份必然不一致）。
 */
public func deptView(s: Store, d: Department): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", d.id)
    jPutStr(o, "name", d.name)
    jPutInt(o, "sort", d.sort)
    var lead: ?Member = None
    var count: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.dept_id != d.id || m.status != "active") {
            continue
        }
        count += 1
        if (m.role == "lead") {
            lead = Some(m)
        }
    }
    match (lead) {
        case Some(lm) => jPutObj(o, "lead", memberBrief(s, lm))
        case None => jPutNull(o, "lead")
    }
    jPutInt(o, "member_count", count)
    return o
}

/* 部门列表响应体（不分页：只有 4 个组织为一个量级）。 */
public func deptListView(s: Store): JsonObject {
    let list = sortedDepartments(s)
    let arr = JsonArray()
    for (d in list) {
        arr.add(deptView(s, d))
    }
    let data = JsonObject()
    data.put("items", arr)
    return data
}

/* 成员详情：MemberBrief + 计数摘要（只给计数，明细属于 Part 4 的列表接口）。 */
public func memberDetailView(s: Store, m: Member): JsonObject {
    let o = JsonObject()
    jPutObj(o, "member", memberBrief(s, m))
    var owned: Int64 = 0
    var open: Int64 = 0
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.owner_id != m.id) {
            continue
        }
        owned += 1
        if (t.status != "done") {
            open += 1
        }
    }
    var plans: Int64 = 0
    for ((_k, p) in s.plans) {
        if (p.owner_id == m.id) {
            plans += 1
        }
    }
    let st = JsonObject()
    jPutInt(st, "owned_tasks", owned)
    jPutInt(st, "open_tasks", open)
    jPutInt(st, "owned_plans", plans)
    jPutObj(o, "stats", st)
    return o
}

/* 待分配成员：MemberBrief + 来源部门提示 + 注册时间。 */
public func pendingView(s: Store, m: Member): JsonObject {
    let o = memberBrief(s, m)
    if (m.dept_hint > 0) {
        jPutObj(o, "dept_hint", deptBriefObj(s, m.dept_hint))
    } else {
        jPutNull(o, "dept_hint")
    }
    jPutTime(o, "registered_at", m.joined_at)
    return o
}

/* 招募链接。url 由请求的 Host 头拼出来，避免把域名写死在配置里。 */
public func inviteLinkView(s: Store, l: DeptInviteLink, url: String): JsonObject {
    let o = JsonObject()
    jPutStr(o, "token", l.token)
    if (url.size > 0) {
        jPutStr(o, "url", url)
    }
    jPutObj(o, "dept", deptBriefObj(s, l.dept_id))
    jPutBool(o, "enabled", l.enabled)
    jPutTime(o, "created_at", l.created_at)
    return o
}

/* 注册配置（仅会长 / 副会长可读）。 */
public func registerConfigView(s: Store): JsonObject {
    let o = JsonObject()
    jPutStr(o, "code", s.register_code)
    jPutTime(o, "updated_at", s.register_code_at)
    match (s.members.get(s.register_code_by)) {
        case Some(m) => jPutObj(o, "updated_by", memberBrief(s, m))
        case None => jPutNull(o, "updated_by")
    }
    return o
}

/* ===================== Part 4 的视图 ===================== */

/* 课题目录里引用一个课题时的最小形态。 */
public func planRefObj(p: Plan): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", p.id)
    jPutStr(o, "title", p.title)
    return o
}

/*
 * 任务所属课题的面包屑：从顶层到本级。
 * 带 guard，避免数据异常（环形）时死循环——环形校验在 M4 的移动接口上，
 * 但**读取路径不能假设数据一定干净**。
 */
public func planPath(s: Store, planId: Int64): JsonArray {
    let chain = ArrayList<Plan>()
    var cur = planId
    var guard: Int64 = 0
    while (cur > 0 && guard < 32) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                chain.add(p)
                cur = p.parent_id
            case None => cur = 0
        }
        guard += 1
    }
    let arr = JsonArray()
    var i = chain.size - 1
    while (i >= 0) {
        arr.add(planRefObj(chain[i]))
        i -= 1
    }
    return arr
}

/* TaskBrief（api-design §4.9）。`is_overdue` 与 `blocked` 都是服务端算好的派生量。 */
public func taskBrief(s: Store, t: Task, now: Int64): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", t.id)
    jPutStr(o, "title", t.title)
    jPutStr(o, "status", t.status)
    match (s.members.get(t.owner_id)) {
        case Some(m) => jPutObj(o, "owner", memberBrief(s, m))
        case None => jPutNull(o, "owner")
    }
    if (t.dept_id > 0) {
        jPutObj(o, "dept", deptBriefObj(s, t.dept_id))
    } else {
        jPutNull(o, "dept")
    }
    if (t.plan_id > 0) {
        match (s.plans.get(t.plan_id)) {
            case Some(p) => jPutObj(o, "plan", planRefObj(p))
            case None => jPutNull(o, "plan")
        }
    } else {
        jPutNull(o, "plan")
    }
    jPutTime(o, "due_at", t.due_at)
    jPutBool(o, "is_overdue", isTaskOverdue(t, now))
    jPutBool(o, "blocked", t.status == "blocked")
    jPutTime(o, "updated_at", t.updated_at)
    return o
}

/* TaskDetail = TaskBrief + desc / blocker / plan_path / created_by / created_at / completed_at */
public func taskDetail(s: Store, t: Task, now: Int64): JsonObject {
    let o = taskBrief(s, t, now)
    jPutStr(o, "desc", t.desc)
    if (t.blocker.size > 0) {
        jPutStr(o, "blocker", t.blocker)
    } else {
        jPutNull(o, "blocker")
    }
    o.put("plan_path", planPath(s, t.plan_id))
    match (s.members.get(t.created_by)) {
        case Some(m) => jPutObj(o, "created_by", memberBrief(s, m))
        case None => jPutNull(o, "created_by")
    }
    jPutTime(o, "created_at", t.created_at)
    jPutTime(o, "completed_at", t.completed_at)
    return o
}

public func taskArr(s: Store, list: Array<Task>, now: Int64): JsonArray {
    let arr = JsonArray()
    for (t in list) {
        arr.add(taskBrief(s, t, now))
    }
    return arr
}

