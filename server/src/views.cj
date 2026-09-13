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
