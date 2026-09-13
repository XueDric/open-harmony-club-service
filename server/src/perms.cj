package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 权限判定 —— **全项目唯一一处**（api-design §1.6）。
 *
 * 铁律（..\docs\..\docs\HANDOFF.md §5）：权限判定收敛到一个函数，**禁止在每个 handler 里手写 if**。
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


/*
 * 角色档位：数字越大权限越高。
 * 部长与副部长同档（v1-scope §3.4.3：两者同权，仅名称不同）。
 * 待分配/未知角色为 0，低于任何在册角色。
 */
func roleRank(role: String): Int64 {
    if (role == "president") { return 5 }
    if (role == "vice_president") { return 4 }
    if (role == "lead") { return 3 }
    if (role == "vice_lead") { return 3 }
    if (role == "member") { return 1 }
    return 0
}

/*
 * 「不能改动同档或更高档的人」——2026-09-14 修复权限漏洞。
 *
 * 原先这条约束只写在副会长分支里，部长/副部长分支对 EditMemberName / ResetPassword
 * 直接放行，而部门范围判定只要求「同一部门」。于是只要把部长分到会长所在的部门，
 * 部长就能改会长的姓名、重置会长的密码，进而接管会长账号——报告里的 P0 H-1。
 *
 * 修法是把约束从「一个分支的特例」改成「部长档的档位规则」：
 * 目标档位必须**严格低于**操作者本人。这样部长动不了副部长/部长/副会长/会长。
 * （副会长是否改得动同僚副会长，文档口径是「与会长同权」，因此那一档仍只排除会长本人，
 *  不在这个函数里收紧。）
 */
func outranks(actor_role: String, target_role: String): Bool {
    if (actor_role == "president") {
        return true
    }
    /* 目标档位未知（空串）：宁拒不放过，避免将来某个新 handler 忘填 target_role
     * 就把这条规则悄悄绕过。 */
    if (target_role == "") {
        return false
    }
    return roleRank(target_role) < roleRank(actor_role)
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
            /* 只能作用于档位比自己低的成员（P0 H-1）：部长改不了同僚部长，
             * 更改不了副会长与会长，即使目标恰好和自己同部门。
             * 例外是**改自己的姓名**：那不是提权（改名不改变角色），
             * 而 api-design §3.8 的矩阵里「编辑成员姓名」对部长/副部长是「本部门」，
             * 本部门当然包含自己。scopeAllows 里原本就为此留了一条 is_self 分支。 */
            case EditMemberName => return t.is_self || outranks(role, t.target_role)
            /* 重置密码没有 is_self 例外：本接口签发一次性临时密码，是管理员救济动作，
             * 本人改密走 PUT /auth/password（P2 L-4，口径已统一）。 */
            case ResetPassword => return outranks(role, t.target_role)
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
