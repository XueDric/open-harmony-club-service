package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 权限判定 —— **全项目唯一一处**（api-design §1.6）。
 *
 * 铁律（HANDOFF §5）：权限判定收敛到一个函数，**禁止在每个 handler 里手写 if**。
 * 十几个接口各写一遍权限，一定会漏掉某个组合，而权限漏洞是社团工具里
 * 最难发现、后果最难受的一类缺陷。
 *
 * 判定三层（依次）：
 *   1. 账号状态      pending → MEMBER_PENDING；disabled → MEMBER_DISABLED
 *   2. 角色维度      这个角色能不能做这个动作 → FORBIDDEN_ROLE
 *   3. 部门范围      目标资源在不在自己的范围内 → FORBIDDEN_NOT_IN_DEPT
 *
 * 角色口径（v1-scope §3.4.3，v0.6 起）：
 *   会长        全部
 *   副会长      除「移交会长」与「改动会长本人」外，与会长同权
 *   部长/副部长  本部门成员、任务、课题（两者同权，仅名称不同）
 *   成员        只读本部门 + 只能改自己的任务状态
 *
 * 注意：Cangjie 枚举不支持 ==，这里一律用 match（探针已实测）。
 */

/* 受权限保护的动作。新增能力时先在这里加一项，再改 can()，最后才写 handler。 */
public enum Action {
    | ViewMembers
    | ViewTasks
    | EditMemberName
    | SetRole
    | DisableMember
    | AssignPending
    | ResetPassword
    | ManageDept
    | DeleteDept
    | ViewRegisterCode
    | ChangeRegisterCode
    | ManageInviteLink
    | TransferPresidency
    | CreatePlan
    | EditPlan
    | MovePlan
    | DeletePlan
    | CreateTask
    | EditTask
    | DeleteTask
    | UpdateTaskStatus
}

/*
 * 判定所需的"目标事实"。handler 负责把目标资源的部门/负责人/创建人填进来。
 * 缺省 0 表示"不适用"。
 */
public class Target {
    public var dept_id: Int64 = 0      /* 目标资源的部门 */
    public var owner_id: Int64 = 0     /* 任务/课题负责人 */
    public var creator_id: Int64 = 0   /* 任务创建人 */
    public var member_id: Int64 = 0    /* 目标成员 */
    public var target_role: String = "" /* 目标成员角色（用于"不能改动会长本人"） */
    public var is_self: Bool = false   /* 目标是否就是操作者本人 */

    public init() {}
}

public func targetSelf(m: Member): Target {
    let t = Target()
    t.member_id = m.id
    t.is_self = true
    t.dept_id = m.dept_id
    t.target_role = m.role
    return t
}

/* 角色维度：这个角色能不能做这个动作（不看范围）。 */
func roleAllows(role: String, a: Action, t: Target): Bool {
    if (role == "president") {
        return true
    }
    if (role == "vice_president") {
        /* 与会长同权，只有这几处例外 */
        match (a) {
            case TransferPresidency => return false
            /* 注册口令：副会长**仅可查看**（api-design §3.6） */
            case ChangeRegisterCode => return false
            /* 部门增删改：**仅会长**。
             * 2026-09-13 决策（原先 §3.1/§6.1 与 §3.8 汇总表冲突，已统一为会长独占，
             * 文档三处已同步）。 */
            case ManageDept => return false
            case DeleteDept => return false
            case EditMemberName => return t.target_role != "president"
            case SetRole => return t.target_role != "president"
            case DisableMember => return t.target_role != "president"
            case ResetPassword => return t.target_role != "president"
            case _ => return true
        }
    }
    if (role == "lead" || role == "vice_lead") {
        match (a) {
            case ViewMembers => return true
            case ViewTasks => return true
            case EditMemberName => return true
            case ResetPassword => return true
            case CreatePlan => return true
            case EditPlan => return true
            case MovePlan => return true
            case DeletePlan => return true
            case CreateTask => return true
            case EditTask => return true
            case DeleteTask => return true
            case UpdateTaskStatus => return true
            case _ => return false
        }
    }
    if (role == "member") {
        match (a) {
            case ViewMembers => return true
            case ViewTasks => return true
            case UpdateTaskStatus => return t.is_self
            case _ => return false
        }
    }
    /* pending（无角色）或未知角色：一律拒绝 */
    return false
}

/* 部门范围维度。 */
func scopeAllows(m: Member, a: Action, t: Target): Bool {
    /* 名录全社团可见——这是"社团里有哪些人"这个问题的答案（api-design §3.2） */
    match (a) {
        case ViewMembers => return true
        case _ => ()
    }
    if (m.role == "president" || m.role == "vice_president") {
        return true
    }
    /* 自己的任务状态：与部门无关（跨部门被指派时也要能更新） */
    if (t.is_self) {
        match (a) {
            case UpdateTaskStatus => return true
            case ResetPassword => return true
            case _ => ()
        }
    }
    if (t.member_id > 0 && t.member_id == m.id) {
        match (a) {
            case EditMemberName => return true
            case _ => ()
        }
    }
    match (a) {
        case EditTask =>
            if (t.creator_id == m.id) {
                return true
            }
        case DeleteTask =>
            if (t.creator_id == m.id) {
                return true
            }
        case EditPlan =>
            if (t.owner_id == m.id) {
                return true
            }
        case _ => ()
    }
    return t.dept_id == m.dept_id
}

/* 返回拒绝原因的错误码；允许则返回 None。 */
public func checkAccess(m: Member, a: Action, t: Target): ?String {
    if (m.status == "pending") {
        return Some("MEMBER_PENDING")
    }
    if (m.status == "disabled") {
        return Some("MEMBER_DISABLED")
    }
    if (!roleAllows(m.role, a, t)) {
        return Some("FORBIDDEN_ROLE")
    }
    if (!scopeAllows(m, a, t)) {
        return Some("FORBIDDEN_NOT_IN_DEPT")
    }
    return None
}

/* 对外只需要这一个问题：能不能。 */
public func can(m: Member, a: Action, t: Target): Bool {
    return checkAccess(m, a, t).isNone()
}

/* handler 用法：requireAccess(m, Action.CreateTask, tgt)。不通过直接抛 403。 */
public func requireAccess(m: Member, a: Action, t: Target): Unit {
    match (checkAccess(m, a, t)) {
        case Some(code) => throw apiErr(code)
        case None => ()
    }
}
