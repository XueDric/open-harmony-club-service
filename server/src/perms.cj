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
 * 判定四层（依次）：
 *   1. 账号状态      pending → MEMBER_PENDING；disabled → MEMBER_DISABLED
 *   2. 动作语义      这个动作对目标有没有额外约束（如"不能重置同权/更高权的人"）→ FORBIDDEN_ROLE
 *   3. 角色维度      这个角色能不能做这个动作 → FORBIDDEN_ROLE
 *   4. 部门范围      目标资源在不在自己的范围内 → FORBIDDEN_NOT_IN_DEPT
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
    /* 2. 动作语义层（不看部门范围，但要读角色档位）
     *
     * 「不可作用于与自己**同权或更高权**的人」（2026-09-14 定，当天从"仅重置密码"
     * **推广到改名 / 改角色 / 禁用 / 审批分配 `assign`**）。
     *
     * 只保护"重置密码"是不够的：副会长档在 roleAllows 里对
     * EditMemberName / SetRole / DisableMember 只排除了 president，
     * 于是**副会长可以把另一位副会长降级为 member，或直接禁用**——
     * 同权之间本就不该能互相处置。现在这几类动作一起受这条约束。
     *
     * N-10 的教训：第一次推广时漏了 `assign` / `assign-batch`（它们同样写 role 与 status），
     * 结果副会长仍能降级同权者，甚至把会长刚移出的同权副会长"复活"（推翻会长的决定）。
     * 所以这里把**所有能写 role / status 的路径**列出来对账，新增接口时回到这张表：
     *   PATCH /members/{id}                     → SetRole / EditMemberName  ✅
     *   POST  /members/{id}/disable             → DisableMember            ✅
     *   POST  /members/{id}/assign              → AssignPending            ✅
     *   POST  /members/assign-batch             → AssignPending（逐条判）   ✅
     *   POST  /members/{id}/transfer-presidency → 会长独占                 —
     *   DELETE /depts/{id}（清 dept_id）        → 会长独占                 —
     *   POST  /auth/register（建 pending 账号） → 不属"处置既有成员"        —
     *
     * 规则本身一次覆盖三种情况：
     *   · 自己与自己同权 → "重置密码"连自己也禁（见下）；其余动作对自己网开一面；
     *   · 副会长与副会长同权 → 不能互相重置 / 降级 / 禁用 / 改名；
     *   · 会长档位最高，除自己外无人与之同权 → 会长仍能作用于任何更低档的人。
     *
     * 为什么不用 outranks()：它对 president 直接短路返回 true，
     * 于是"会长作用于会长自己"会被放行 —— 那正是 N-7 要拦的那一条。
     *
     * 为什么放在这里而不是 handler 里：会长与副会长的角色分支都是"直接放行"
     * （roleAllows 里 president 一档 `return true`、副会长档只排除 president），
     * 只有这一层拦得住他们；而"权限判定只有一处"是本项目的铁律。
     *
     * 判定用「目标 id 就是操作者 id」而不是只看 t.is_self：is_self 是派生的便利
     * 标志，新调用点忘填就静默失效；member_id 是必填事实。 */
    let peerForbidden = match (a) {
        case ResetPassword => true
        case SetRole => true
        case DisableMember => true
        case EditMemberName => true
        /* N-10：assign / assign-batch 也是成员处置类动作（能改 role 与 status）。
         * 漏掉它的后果有两个面：① 副会长可降级同权副会长；
         * ② 副会长能用 assign 把会长刚移出的同权副会长"复活"，推翻会长的决定。
         * 注意 pending 目标（role=""，档位 0）不会被误拦 —— 审批待分配照常可用。 */
        case AssignPending => true
        case _ => false
    }
    let isSelf = t.is_self || (t.member_id > 0 && t.member_id == m.id)
    if (peerForbidden && !isSelf) {
        if (roleRank(t.target_role) >= roleRank(m.role)) {
            return Some("FORBIDDEN_ROLE")
        }
    }
    /* 「重置密码」额外连**自己**也不许（N-7）：它是管理员救济动作，
     * 而这条路径收尾会 revokeOtherTokens(s, tgt.id, "") 把目标的**全部**令牌作废，
     * 对本人执行就是"响应 200、自己当场掉线"（客户端拿到成功却立刻 401）。
     * 改自己的姓名 / 角色 / 启停则是既有口径（且属自伤，没有提权收益），不受这条影响。 */
    match (a) {
        case ResetPassword =>
            if (isSelf) {
                return Some("FORBIDDEN_ROLE")
            }
        case _ => ()
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
