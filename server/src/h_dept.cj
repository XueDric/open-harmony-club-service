package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.1 · 部门（组织）—— 4 个接口
 *
 * 权限（2026-09-13 决策，api-design §3.1 / §3.8 / §6.1 已统一）：
 *   GET             全体 active 成员（只有 4 个组织，是所有人画界面要用的事实）
 *   POST/PATCH/DELETE   **仅会长**。组织架构是社团层面的事，增删改都会影响所有人的归属；
 *                       副会长可以管人（调部门、改角色），但不直接改动组织本身。
 *
 * ⚠ 锁规则：requireActive 内部会加锁，所以必须先认证、**再**加锁做修改。
 */

import std.collection.*
import stdx.encoding.json.*

/* GET /api/v1/depts */
public func handleDeptList(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.ViewMembers, Target())
    s.lock.lock()
    try {
        sendOk(ctx, deptListView(s))
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/depts */
public func handleDeptCreate(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.ManageDept, Target())
    let body = reqObj(ctx)
    let v = V()
    let name = v.need("name", reqStrOr(body, "name", ""), "请输入部门名称")
    v.done()

    s.lock.lock()
    try {
        if (deptNameTaken(s, name, 0)) {
            throw apiErrFields("ALREADY_EXISTS", "部门名已存在", oneField("name", "部门名已存在"))
        }
        /* sort 缺省 = 当前部门数（追加到末尾） */
        let sort = reqIntOr(body, "sort", s.departments.size)
        let d = Department()
        d.id = s.next_dept
        s.next_dept += 1
        d.name = name
        d.sort = sort
        s.departments[d.id] = d
        storeSave(s)
        let data = JsonObject()
        jPutObj(data, "dept", deptView(s, d))
        sendCreated(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* PATCH /api/v1/depts/{id} —— 字段全部可选：name / sort */
public func handleDeptUpdate(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.ManageDept, Target())
    let id = pathIdOr(ctx, "DEPT_NOT_FOUND")
    let body = reqObj(ctx)

    /* Department 没有、也不该有 lead_id：部长身份只由 Member.role = lead 表达。
     * 客户端若传了，明确报错而不是静默忽略——静默忽略会让调用方以为改成功了。 */
    if (body.get("lead_id").isSome()) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("lead_id", "不接受 lead_id：部长身份由成员的 role 表达，请改用 PATCH /members/{id}"))
    }

    s.lock.lock()
    try {
        let d = match (s.departments.get(id)) {
            case Some(x) => x
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        var touched = false
        match (jsonGetStr(body, "name")) {
            case Some(nm) =>
                if (isBlank(nm)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("name", "部门名称不能为空"))
                }
                if (deptNameTaken(s, nm, d.id)) {
                    throw apiErrFields("ALREADY_EXISTS", "部门名已存在", oneField("name", "部门名已存在"))
                }
                d.name = nm
                touched = true
            case None => ()
        }
        match (jsonGetInt64(body, "sort")) {
            case Some(sv) =>
                d.sort = sv
                touched = true
            case None => ()
        }
        if (touched) {
            storeSave(s)
        }
        let data = JsonObject()
        jPutObj(data, "dept", deptView(s, d))
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * DELETE /api/v1/depts/{id}
 *
 * 不允许删除非空部门——社团的组织架构变更应该是有意识的，
 * 不能一键把 8 个人变成无部门状态。
 *
 * 前置检查比文档多两条（文档只写了成员），否则会留下悬空引用：
 *   · 顶层课题还挂在这个部门 → 同样拒绝（Plan.dept_id 只存在顶层）
 *   · 已退出成员 / 历史任务的部门标签 → 不阻塞，但**置 0**，不留悬空 id
 */
public func handleDeptDelete(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.DeleteDept, Target())
    let id = pathIdOr(ctx, "DEPT_NOT_FOUND")

    s.lock.lock()
    try {
        match (s.departments.get(id)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        let n = activeMemberCountOfDept(s, id)
        if (n > 0) {
            throw apiErrMsg("DEPT_NOT_EMPTY", "该部门下还有 ${n} 名成员，必须先全部调离")
        }
        let pn = topPlanCountOfDept(s, id)
        if (pn > 0) {
            throw apiErrMsg("DEPT_NOT_EMPTY", "该部门下还有 ${pn} 个顶层课题，必须先移走或删除")
        }
        /* 已退出成员与历史任务的部门标签置 0，避免留下指向已删部门的 id */
        for ((_k, mm) in s.members) {
            if (mm.dept_id == id) {
                mm.dept_id = 0
            }
        }
        for ((_k, t) in s.tasks) {
            if (t.dept_id == id) {
                t.dept_id = 0
            }
        }
        s.departments.remove(id)
        storeSave(s)
        audit(s, m.id, "delete-dept", id, "部门已删除，遗留引用已清空")
        sendOk(ctx, JsonObject())
    } finally {
        s.lock.unlock()
    }
}
