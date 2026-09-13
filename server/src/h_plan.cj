package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 5 · 课题 —— 6 个接口
 *
 * 课题是**可层层往下分割的容器**，任务是叶子。v1-scope 3.5.2 列了四个"必须做对"的点：
 *   1. 环形引用校验        -> handlePlanMove 里的 planWouldCycle（向上遍历）
 *   2. 递归进度聚合        -> planStatsAll（自底向上一次算完，O(n)）
 *   3. 删除上提，不级联    -> handlePlanDelete
 *   4. 任意层级都要有负责人 -> 创建与编辑时 owner_id 必填
 *
 * 两条贯穿全篇的数据规则：
 *   · dept_id 只存在**顶层课题**上，子课题的部门由所属根决定（规则 19）
 *     —— 于是「子课题不允许跨部门」自动成立，移动时也不需要级联更新部门
 *   · 课题**不设 status**，进度完全由整棵子树的任务聚合而来（规则 7）
 *     —— 从结构上杜绝「任务全完成了、课题还写着进行中」
 *
 * ⚠ 锁规则：requireActive 内部加锁；handler 先认证、再单独加锁。
 */

import std.collection.*
import stdx.encoding.json.*

/* 课题的权限判定目标：部门取"有效部门"（根的部门），负责人用于负责人条款。 */
func targetOfPlan(s: Store, p: Plan): Target {
    let tgt = Target()
    tgt.dept_id = planDeptOf(s, p.id)
    tgt.owner_id = p.owner_id
    tgt.creator_id = p.created_by
    return tgt
}

/* 课题目录（GET /plans）：返回森林，不分页。 */
public func handlePlanTree(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let fDept = queryIntOr(ctx, "dept_id", 0)
    var depthLimit = queryIntOr(ctx, "depth", PLAN_MAX_DEPTH)
    if (depthLimit < 1) {
        depthLimit = 1
    }
    if (depthLimit > PLAN_MAX_DEPTH) {
        depthLimit = PLAN_MAX_DEPTH
    }
    let includeProgress = ctx.queryParamOr("include_progress", "true") != "false"

    s.lock.lock()
    try {
        /* 可见范围按**根课题的部门**判定：子课题跟着根走 */
        let visible = HashSet<Int64>()
        let roots = ArrayList<Plan>()
        for ((_k, p) in s.plans) {
            if (p.parent_id > 0) {
                continue
            }
            if (fDept > 0 && p.dept_id != fDept) {
                continue
            }
            let tgt = Target()
            tgt.dept_id = p.dept_id
            if (!can(actor, Action.ViewTasks, tgt)) {
                continue
            }
            planSubtreeInto(s, p.id, visible)
            roots.add(p)
        }
        let stats = planStatsAll(s, visible)
        let arr0 = roots.toArray()
        sortByKey<Plan>(arr0, { p: Plan => p.id })
        let items = JsonArray()
        for (p in arr0) {
            items.add(planNodeJson(s, p, stats, includeProgress, depthLimit, 1))
        }
        let data = JsonObject()
        data.put("items", items)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* GET /plans/{id} —— 详情：PlanBrief + 面包屑 + 子课题（平铺）+ **本级**任务 */
public func handlePlanDetail(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "PLAN_NOT_FOUND")
    s.lock.lock()
    try {
        let p = match (s.plans.get(id)) {
            case Some(x) => x
            case None => throw apiErr("PLAN_NOT_FOUND")
        }
        requireAccess(actor, Action.ViewTasks, targetOfPlan(s, p))

        let sub = HashSet<Int64>()
        planSubtreeInto(s, id, sub)
        let stats = planStatsAll(s, sub)

        let data = JsonObject()
        jPutObj(data, "plan", planDetailView(s, p, stats.get(id)))
        /* 面包屑：从顶层到本级，含自身 */
        data.put("path", planPath(s, id))
        let kids = JsonArray()
        for (c in planChildrenOf(s, id)) {
            kids.add(planBrief(s, c, stats.get(c.id), true))
        }
        data.put("children", kids)

        /* tasks 只返回本级任务，不含子课题的——子课题的任务在各自详情页里 */
        let list = ArrayList<Task>()
        for ((_k, t) in s.tasks) {
            if (t.deleted_at > 0 || t.plan_id != id) {
                continue
            }
            list.add(t)
        }
        let sortedT = sortedTasksByDue(list)
        let now = nowEpoch()
        let items = ArrayList<JsonObject>()
        for (t in sortedT) {
            items.add(taskBrief(s, t, now))
        }
        jPutObj(data, "tasks", pagedJson(ctx, items))
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /plans —— 创建课题或子课题
 *
 * dept_id 的规则（api-design §5.4）：
 *   顶层课题：**必须**提供 dept_id
 *   子课题  ：**不接受** dept_id，部门继承自根课题（规则 19）
 * 两者都错时返回 VALIDATION_FAILED，而不是静默忽略——静默忽略会让调用方以为生效了。
 */
public func handlePlanCreate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let v = V()
    let title = v.need("title", reqStrOr(body, "title", ""), "请输入课题名称")
    v.done()
    let ownerId = reqIntOr(body, "owner_id", 0)
    if (ownerId <= 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("owner_id", "任意层级的课题都必须有负责人"))
    }
    let parentId = reqIntOr(body, "parent_id", 0)
    let bodyDept = reqIntOr(body, "dept_id", 0)
    let desc = reqStrOr(body, "desc", "")
    let dueAt = reqTime(body, "due_at")
    let clientToken = reqStrOr(body, "client_token", "")

    s.lock.lock()
    try {
        let now = nowEpoch()
        if (clientToken.size > 0) {
            match (idemHit(s, "plan", clientToken, now)) {
                case Some(rid) =>
                    match (s.plans.get(rid)) {
                        case Some(existing) =>
                            let data = JsonObject()
                            jPutObj(data, "plan", planDetailView(s, existing, None))
                            jPutBool(data, "duplicated", true)
                            sendOk(ctx, data)
                            return
                        case None => ()
                    }
                case None => ()
            }
        }

        let owner = match (s.members.get(ownerId)) {
            case Some(m) => m
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        if (owner.status == "pending") {
            throw apiErr("MEMBER_PENDING")
        }
        if (owner.status == "disabled") {
            throw apiErr("MEMBER_DISABLED")
        }

        var deptId: Int64 = 0
        if (parentId > 0) {
            if (bodyDept > 0) {
                throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                    oneField("dept_id", "子课题不接受 dept_id，部门继承自所属根课题"))
            }
            match (s.plans.get(parentId)) {
                case Some(_) => ()
                case None => throw apiErr("PLAN_NOT_FOUND")
            }
            if (planDepthOf(s, parentId) + 1 > PLAN_MAX_DEPTH) {
                throw apiErr("PLAN_DEPTH_EXCEEDED")
            }
            deptId = planDeptOf(s, parentId)
        } else {
            if (bodyDept <= 0) {
                throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                    oneField("dept_id", "顶层课题必须指定所属部门"))
            }
            match (s.departments.get(bodyDept)) {
                case Some(_) => ()
                case None => throw apiErr("DEPT_NOT_FOUND")
            }
            deptId = bodyDept
        }

        /* 权限：部长/副部长只能在本部门建课题 */
        let tgt = Target()
        tgt.dept_id = deptId
        tgt.owner_id = owner.id
        requireAccess(actor, Action.CreatePlan, tgt)

        let p = Plan()
        p.id = s.next_plan
        s.next_plan += 1
        p.title = title
        p.desc = desc
        p.parent_id = parentId
        p.owner_id = ownerId
        p.dept_id = if (parentId > 0) { 0 } else { deptId }
        p.due_at = dueAt
        p.created_by = actor.id
        p.created_at = now
        p.updated_at = now
        s.plans[p.id] = p
        if (clientToken.size > 0) {
            idemPut(s, "plan", clientToken, p.id, now)
        }
        storeSave(s)

        let data = JsonObject()
        jPutObj(data, "plan", planDetailView(s, p, None))
        sendCreated(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * PATCH /plans/{id} —— 编辑课题内容
 * 字段全部可选：title / desc / owner_id / due_at
 * dept_id 不可通过本接口修改（子课题根本不存该字段；顶层换部门 v1 不做）。
 */
public func handlePlanUpdate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "PLAN_NOT_FOUND")
    let body = reqObj(ctx)

    s.lock.lock()
    try {
        let p = match (s.plans.get(id)) {
            case Some(x) => x
            case None => throw apiErr("PLAN_NOT_FOUND")
        }
        requireAccess(actor, Action.EditPlan, targetOfPlan(s, p))
        if (body.containsKey("dept_id")) {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                oneField("dept_id", "部门由所属根课题决定，不能通过本接口修改"))
        }
        var touched = false
        match (jsonGetStr(body, "title")) {
            case Some(x) =>
                if (isBlank(x)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("title", "课题名称不能为空"))
                }
                p.title = x
                touched = true
            case None => ()
        }
        match (jsonGetStr(body, "desc")) {
            case Some(x) =>
                p.desc = x
                touched = true
            case None => ()
        }
        match (jsonGetInt64(body, "owner_id")) {
            case Some(oid) =>
                if (oid <= 0) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField("owner_id", "负责人不能置空，课题必须始终有人负责"))
                }
                match (s.members.get(oid)) {
                    case Some(m) =>
                        if (m.status != "active") {
                            throw apiErr("MEMBER_PENDING")
                        }
                    case None => throw apiErr("MEMBER_NOT_FOUND")
                }
                p.owner_id = oid
                touched = true
            case None => ()
        }
        if (body.containsKey("due_at")) {
            p.due_at = reqTime(body, "due_at")
            touched = true
        }
        if (touched) {
            p.updated_at = nowEpoch()
            storeSave(s)
        }
        /* 与 POST /plans、GET /plans/{id} 保持一致：对象包在 data.plan 下 */
        let data = JsonObject()
        jPutObj(data, "plan", planDetailView(s, p, None))
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /plans/{id}/move —— 移动课题（换父节点）
 *
 * 校验顺序按 api-design §5.6：
 *   1. 不能挂到自己下面           -> PLAN_CYCLE_DETECTED (409)
 *   2. 目标不能是自身的后代       -> PLAN_CYCLE_DETECTED (409)
 *   3. 目标必须存在               -> PLAN_NOT_FOUND (404)
 *   4. 提升为顶层时需要确定部门   -> VALIDATION_FAILED (400)
 * 另外两条 v1 决策：禁止跨部门移动（§5.10 决策 3）；移动后总深度不得超过 6 层。
 *
 * new_parent_id 为 null 表示**提升为顶层课题**；此时可用 dept_id 指定部门，
 * 不传则沿用原来的有效部门。
 */
public func handlePlanMove(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "PLAN_NOT_FOUND")
    let body = reqObj(ctx)
    var newParent: Int64 = 0
    if (body.containsKey("new_parent_id")) {
        newParent = reqIntOr(body, "new_parent_id", 0)
    }
    let bodyDept = reqIntOr(body, "dept_id", 0)

    s.lock.lock()
    try {
        let p = match (s.plans.get(id)) {
            case Some(x) => x
            case None => throw apiErr("PLAN_NOT_FOUND")
        }
        let curDept = planDeptOf(s, id)
        let tgt = Target()
        tgt.dept_id = curDept
        tgt.owner_id = p.owner_id
        requireAccess(actor, Action.MovePlan, tgt)

        if (newParent == id) {
            throw apiErr("PLAN_CYCLE_DETECTED")
        }
        if (newParent > 0) {
            match (s.plans.get(newParent)) {
                case Some(_) => ()
                case None => throw apiErr("PLAN_NOT_FOUND")
            }
            /* 向上遍历校验：目标父节点不能是本课题自身或它的任何后代 */
            if (planWouldCycle(s, id, newParent)) {
                throw apiErr("PLAN_CYCLE_DETECTED")
            }
            let newDept = planDeptOf(s, newParent)
            /* 部门范围：部长只能操作本部门的课题 */
            let tgt2 = Target()
            tgt2.dept_id = newDept
            tgt2.owner_id = p.owner_id
            requireAccess(actor, Action.MovePlan, tgt2)
            /* 即便会长也不允许跨部门移动：换根即换部门，v1 保持部门边界清晰 */
            if (newDept != curDept) {
                throw apiErrMsg("VALIDATION_FAILED", "v1 不允许跨部门移动课题（部门由根课题决定）")
            }
            /* 深度：新父节点的深度 + 被移动子树的高度，不得超过 6 层 */
            if (planDepthOf(s, newParent) + planHeightOf(s, id) > PLAN_MAX_DEPTH) {
                throw apiErr("PLAN_DEPTH_EXCEEDED")
            }
            p.parent_id = newParent
        } else {
            /* 提升为顶层课题：必须有部门 */
            var d = curDept
            if (bodyDept > 0) {
                d = bodyDept
            }
            if (d <= 0) {
                throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                    oneField("dept_id", "提升为顶层课题时需要确定所属部门"))
            }
            match (s.departments.get(d)) {
                case Some(_) => ()
                case None => throw apiErr("DEPT_NOT_FOUND")
            }
            p.parent_id = 0
            p.dept_id = d
        }
        p.updated_at = nowEpoch()
        storeSave(s)
        audit(s, actor.id, "move-plan", id, "new_parent=${newParent}")

        let sub = HashSet<Int64>()
        planSubtreeInto(s, id, sub)
        let stats = planStatsAll(s, sub)
        let data = JsonObject()
        jPutObj(data, "plan", planDetailView(s, p, stats.get(id)))
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * DELETE /plans/{id} —— 删除课题，**子节点上提一级，绝不级联删除**
 *
 *   子课题      -> parent_id = P.parent_id
 *   本级任务    -> plan_id   = P.parent_id
 *   P 是顶层时  -> 子课题变为顶层并**继承 P 的 dept_id**（dept_id 只存顶层，这一步不能漏）
 *                  本级任务变为独立任务
 *
 * 为什么不做级联删除：任务承载着人的工作量记录，一次误删丢掉整棵子树
 * 是这个设计里最不可接受的失败模式（规则 9）。
 * 整个上提必须**原子完成**，不能出现"子课题提上去了、任务还挂在已删课题下"的中间态
 * —— 这里先改完所有引用、最后一次落盘，因此不会出现中间态。
 */
public func handlePlanDelete(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "PLAN_NOT_FOUND")

    s.lock.lock()
    try {
        let p = match (s.plans.get(id)) {
            case Some(x) => x
            case None => throw apiErr("PLAN_NOT_FOUND")
        }
        requireAccess(actor, Action.DeletePlan, targetOfPlan(s, p))

        /* 上提逻辑抽在 store.cj 的 planDeletePromote（纯函数，可单测） */
        let moved = planDeletePromote(s, id)
        storeSave(s)
        audit(s, actor.id, "delete-plan", id, "上提课题=${moved[0]} 上提任务=${moved[1]}")

        let data = JsonObject()
        jPutInt(data, "moved_plans", moved[0])
        jPutInt(data, "moved_tasks", moved[1])
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}
