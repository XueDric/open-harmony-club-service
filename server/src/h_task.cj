package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 4 · 任务 —— 8 个接口
 *
 * 本部分是工具的核心：第 1 节的第二个问题「每件事由谁负责、做到什么程度」全落在这里。
 *
 * 三条不能打折的规则：
 *   · **一个任务只能有一个负责人**（必填且不可置空）——多个负责人等于没人负责
 *   · **状态只有 4 档**，不做进度百分比；「逾期」是派生量，永不落盘（规则 2/15）
 *   · **进入 blocked 必须填 blocker**，离开时自动清空——这是信息量最大的字段
 *
 * ⚠ 锁规则：requireActive 内部加锁；handler 先认证、再单独加锁。
 */

import std.collection.*
import stdx.encoding.json.*

/* 权限判定目标：把任务的三个关键事实交给 can()。 */
func targetOfTask(actor: Member, t: Task): Target {
    let tgt = Target()
    tgt.dept_id = t.dept_id
    tgt.owner_id = t.owner_id
    tgt.creator_id = t.created_by
    tgt.is_self = (t.owner_id == actor.id)
    return tgt
}

/* ===================== 「我的任务」首页的分组（纯函数，便于单测） ===================== */

public class MineGroups {
    public var overdue: Array<Task> = Array<Task>()
    public var blocked: Array<Task> = Array<Task>()
    public var due_today: Array<Task> = Array<Task>()
    public var due_week: Array<Task> = Array<Task>()
    public var later: Array<Task> = Array<Task>()
    public var no_due: Array<Task> = Array<Task>()
    public var open_total: Int64 = 0

    public init() {}
}

/*
 * 分组口径（服务端算，客户端不重复实现——否则跨设备口径会不一致）：
 *   overdue    due_at < 现在
 *   due_today  今天之内到期
 *   due_week   未来 7 天内（滚动窗口，不按自然周；否则周日会让该组变空）
 *   later      再往后
 *   no_due     没有截止时间
 *   blocked    **额外**一组：阻塞是状态，逾期是时间事实，两者不互斥（api-design §4.1）
 *
 * 只列**未完成**任务：首页是"我负责什么"，已完成的不该再出现在逾期里。
 */
public func groupMine(s: Store, ownerId: Int64, now: Int64): MineGroups {
    let g = MineGroups()
    let todayStart = startOfLocalDay(now)
    let tomorrow = todayStart + DAY_SECONDS
    let weekEnd = todayStart + 7 * DAY_SECONDS

    let overdue = ArrayList<Task>()
    let blocked = ArrayList<Task>()
    let today = ArrayList<Task>()
    let week = ArrayList<Task>()
    let later = ArrayList<Task>()
    let none = ArrayList<Task>()

    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.owner_id != ownerId) {
            continue
        }
        if (t.status == "done") {
            continue
        }
        g.open_total += 1
        if (t.status == "blocked") {
            blocked.add(t)
        }
        if (t.due_at <= 0) {
            none.add(t)
            continue
        }
        if (t.due_at < now) {
            overdue.add(t)
            continue
        }
        if (t.due_at < tomorrow) {
            today.add(t)
            continue
        }
        if (t.due_at < weekEnd) {
            week.add(t)
            continue
        }
        later.add(t)
    }

    g.overdue = sortedTasksByDue(overdue)
    g.blocked = sortedTasksByDue(blocked)
    g.due_today = sortedTasksByDue(today)
    g.due_week = sortedTasksByDue(week)
    g.later = sortedTasksByDue(later)
    g.no_due = sortedTasksByDue(none)
    return g
}

/*
 * GET /api/v1/tasks/mine —— **v1 最重要的接口**
 *
 * 真正让人每天打开 App 的是「我负责什么」，不是组织架构图。
 * 永远只返回自己的任务，因此不需要 can() 判定。
 */
public func handleTasksMine(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    s.lock.lock()
    try {
        let now = nowEpoch()
        let g = groupMine(s, actor.id, now)
        let data = JsonObject()
        data.put("overdue", taskArr(s, g.overdue, now))
        data.put("blocked", taskArr(s, g.blocked, now))
        data.put("due_today", taskArr(s, g.due_today, now))
        data.put("due_week", taskArr(s, g.due_week, now))
        data.put("later", taskArr(s, g.later, now))
        data.put("no_due", taskArr(s, g.no_due, now))
        let counts = JsonObject()
        jPutInt(counts, "overdue", g.overdue.size)
        jPutInt(counts, "blocked", g.blocked.size)
        jPutInt(counts, "open_total", g.open_total)
        jPutObj(data, "counts", counts)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/tasks —— 列表（按 view_scope 过滤 + 筛选 + 分页） */
public func handleTaskList(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let fDept = queryIntOr(ctx, "dept_id", 0)
    let fOwner = queryIntOr(ctx, "owner_id", 0)
    let fStatus = ctx.queryParamOr("status", "")
    let fPlan = queryIntOr(ctx, "plan_id", 0)
    let fOverdue = ctx.queryParamOr("overdue", "") == "true"
    let includeSub = ctx.queryParamOr("include_subplans", "true") != "false"

    s.lock.lock()
    try {
        let now = nowEpoch()
        var planScope: ?HashSet<Int64> = None
        if (fPlan > 0) {
            match (s.plans.get(fPlan)) {
                case Some(_) => ()
                case None => throw apiErr("PLAN_NOT_FOUND")
            }
            if (includeSub) {
                planScope = Some(planSubtreeIds(s, fPlan))
            } else {
                let only = HashSet<Int64>()
                only.add(fPlan)
                planScope = Some(only)
            }
        }

        let picked = ArrayList<Task>()
        for ((_k, t) in s.tasks) {
            if (t.deleted_at > 0) {
                continue
            }
            if (fDept > 0 && t.dept_id != fDept) {
                continue
            }
            if (fOwner > 0 && t.owner_id != fOwner) {
                continue
            }
            if (fStatus.size > 0 && t.status != fStatus) {
                continue
            }
            match (planScope) {
                case Some(ids) =>
                    if (!ids.contains(t.plan_id)) {
                        continue
                    }
                case None => ()
            }
            if (fOverdue && !isTaskOverdue(t, now)) {
                continue
            }
            if (!can(actor, Action.ViewTasks, targetOfTask(actor, t))) {
                continue
            }
            picked.add(t)
        }
        let sorted = sortedTasksByDue(picked)
        let out = ArrayList<JsonObject>()
        for (t in sorted) {
            out.add(taskBrief(s, t, now))
        }
        sendOk(ctx, pagedJson(ctx, out))
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/tasks/{id} */
public func handleTaskDetail(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    s.lock.lock()
    try {
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.ViewTasks, targetOfTask(actor, t))
        sendOk(ctx, taskDetail(s, t, nowEpoch()))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/tasks
 *
 * 幂等：带 `client_token` 时 24 小时内重复提交返回首次结果（HTTP 200 + duplicated: true）。
 * 移动网络不稳定，用户点一下没反应就会再点一次——这个成本很低，能挡掉
 * "一个任务被创建三遍"这类最常见的脏数据。
 */
public func handleTaskCreate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let v = V()
    let title = v.need("title", reqStrOr(body, "title", ""), "请输入任务标题")
    v.done()
    let ownerId = reqIntOr(body, "owner_id", 0)
    if (ownerId <= 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("owner_id", "必须指定唯一的负责人"))
    }
    let desc = reqStrOr(body, "desc", "")
    let planId = reqIntOr(body, "plan_id", 0)
    let dueAt = reqTime(body, "due_at")
    let clientToken = reqStrOr(body, "client_token", "")

    s.lock.lock()
    try {
        let now = nowEpoch()
        if (clientToken.size > 0) {
            match (idemHit(s, "task", actor.id, clientToken, now)) {
                case Some(rid) =>
                    match (activeTaskById(s, rid)) {
                        case Some(existing) =>
                            /* 命中也不能免检：拿首次结果回放之前，按本次操作者重新判一次
                             * 查看权限（P0 H-2）。键里已经带了 actorId，这一层是防御纵深——
                             * 万一将来有人改动键的构成，越权读也不会被顺手放回来。 */
                            requireAccess(actor, Action.ViewTasks, targetOfTask(actor, existing))
                            let data = JsonObject()
                            jPutObj(data, "task", taskDetail(s, existing, now))
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
        /* 分配范围：部长/副部长只能分给本部门成员；会长/副会长可跨部门。
         * 用 owner 的部门构造目标，can() 里就是这一条。 */
        let tgt = Target()
        tgt.dept_id = owner.dept_id
        tgt.owner_id = owner.id
        requireAccess(actor, Action.CreateTask, tgt)

        if (planId > 0) {
            match (s.plans.get(planId)) {
                case Some(_) => ()
                case None => throw apiErr("PLAN_NOT_FOUND")
            }
            /*
             * N-18（部门边界）：任务的**负责人**必须与课题同部门。
             * 原实现只校验"课题存在"，于是 A 部门的部长能把自己部门的任务挂进 B 部门的课题，
             * 而 handlePlanDetail 列本级任务时不再逐条 can()（前提是"能看课题就能看它的任务"），
             * B 部门的人因此在课题详情里读到了这个任务 —— 跨部门的信息可见性。
             * 口径已先落回 api-design.md §4.1（「任务创建」的 plan_id 字段说明）。
             */
            let planDept = planDeptOf(s, planId)
            if (planDept > 0 && planDept != owner.dept_id) {
                throw apiErrMsg("FORBIDDEN_NOT_IN_DEPT", "课题属于其它部门，不能把任务挂到跨部门的课题下")
            }
        }

        let t = Task()
        t.id = s.next_task
        s.next_task += 1
        t.title = title
        t.desc = desc
        t.owner_id = ownerId
        t.plan_id = planId
        t.dept_id = owner.dept_id
        t.status = "todo"
        t.due_at = dueAt
        t.created_by = actor.id
        t.created_at = now
        t.updated_at = now
        s.tasks[t.id] = t
        if (clientToken.size > 0) {
            idemPut(s, "task", actor.id, clientToken, t.id, now)
        }
        storeSave(s)

        let data = JsonObject()
        jPutObj(data, "task", taskDetail(s, t, now))
        sendCreated(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * PATCH /api/v1/tasks/{id}
 * 字段全部可选：title / desc / owner_id / due_at / plan_id
 * 改 owner_id 就是**转交**，会更新 updated_at，并且**部门标签跟随新负责人**。
 */
public func handleTaskUpdate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    let body = reqObj(ctx)

    s.lock.lock()
    try {
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.EditTask, targetOfTask(actor, t))
        var touched = false

        /* ---------- 阶段一：只收集 + 校验，**绝不碰 t**（N-15） ----------
         * t 是 s.tasks 里的活引用，"边校验边赋值"会让被 4xx 拒绝的请求留下半改状态。 */
        var nextTitle: ?String = None
        match (jsonGetStr(body, "title")) {
            case Some(x) =>
                if (isBlank(x)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("title", "标题不能为空"))
                }
                nextTitle = Some(x)
            case None => ()
        }
        var nextDesc: ?String = None
        match (jsonGetStr(body, "desc")) {
            case Some(x) => nextDesc = Some(x)
            case None => ()
        }
        var nextOwner: ?Int64 = None
        var nextOwnerDept: Int64 = 0
        match (jsonGetInt64(body, "owner_id")) {
            case Some(oid) =>
                if (oid <= 0) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField("owner_id", "负责人不能置空——任务必须始终有人负责"))
                }
                let owner = match (s.members.get(oid)) {
                    case Some(m) => m
                    case None => throw apiErr("MEMBER_NOT_FOUND")
                }
                /* L-8：原先无论 pending 还是 disabled 都报 MEMBER_PENDING，
                 * 客户端会提示「尚未被分配」，而真实原因是「已被移出社团」。
                 * 两种状态给两个码，与创建路径（本文件 handleTaskCreate）保持一致。 */
                if (owner.status == "pending") {
                    throw apiErrMsg("MEMBER_PENDING", "目标成员尚未被分配，不能接任务")
                }
                if (owner.status == "disabled") {
                    throw apiErrMsg("MEMBER_DISABLED", "目标成员已被移出社团，不能接任务")
                }
                /* 转交同样受分配范围约束 */
                let tgt2 = Target()
                tgt2.dept_id = owner.dept_id
                tgt2.owner_id = owner.id
                requireAccess(actor, Action.CreateTask, tgt2)
                nextOwner = Some(oid)
                nextOwnerDept = owner.dept_id
            case None => ()
        }
        var nextPlan: ?Int64 = None
        match (jsonGetInt64(body, "plan_id")) {
            case Some(pid) =>
                if (pid > 0) {
                    match (s.plans.get(pid)) {
                        case Some(_) => ()
                        case None => throw apiErr("PLAN_NOT_FOUND")
                    }
                }
                nextPlan = Some(pid)
            case None => ()
        }
        /* due_at 要区分"没传"和"传了 null"：显式传 null 表示清空截止时间 */
        var dueGiven = false
        var dueVal: Int64 = 0
        if (body.containsKey("due_at")) {
            dueVal = reqTime(body, "due_at")
            dueGiven = true
        }

        /*
         * N-18（部门边界）：只要本次动到了 owner 或 plan，就要求**结果状态**里
         * "任务的负责人与课题同部门"。只在动到这两个字段时检查，
         * 这样历史数据本来就不一致时也不会连改名都被挡住。
         */
        if (nextOwner.isSome() || nextPlan.isSome()) {
            var effOwner: Int64 = t.owner_id
            match (nextOwner) {
                case Some(x) => effOwner = x
                case None => ()
            }
            var effPlan: Int64 = t.plan_id
            match (nextPlan) {
                case Some(x) => effPlan = x
                case None => ()
            }
            if (effPlan > 0 && effOwner > 0) {
                var ownerDept: Int64 = 0
                match (s.members.get(effOwner)) {
                    case Some(m) => ownerDept = m.dept_id
                    case None => ()
                }
                let planDept = planDeptOf(s, effPlan)
                if (planDept > 0 && ownerDept > 0 && planDept != ownerDept) {
                    throw apiErrMsg("FORBIDDEN_NOT_IN_DEPT", "任务的负责人与课题不在同一部门")
                }
            }
        }

        /* ---------- 阶段二：全部通过之后才落值（N-15） ---------- */
        match (nextTitle) {
            case Some(x) =>
                t.title = x
                touched = true
            case None => ()
        }
        match (nextDesc) {
            case Some(x) =>
                t.desc = x
                touched = true
            case None => ()
        }
        match (nextOwner) {
            case Some(oid) =>
                t.owner_id = oid
                t.dept_id = nextOwnerDept
                touched = true
            case None => ()
        }
        match (nextPlan) {
            case Some(pid) =>
                t.plan_id = pid
                touched = true
            case None => ()
        }
        if (dueGiven) {
            t.due_at = dueVal
            touched = true
        }
        if (touched) {
            t.updated_at = nowEpoch()
            storeSave(s)
        }
        sendOk(ctx, taskDetail(s, t, nowEpoch()))
    } finally {
        s.lock.unlock()
    }
}

/*
 * PUT /api/v1/tasks/{id}/status —— 状态流转与阻塞原因
 *
 * 1. 进入 blocked 必须带 blocker，否则 BLOCKER_REQUIRED
 * 2. 离开 blocked 自动清空 blocker（历史由 updated_at 体现，v1 不做完整变更历史）
 * 3. 进入 done 记 completed_at；退回其他状态时清空
 * 4. **允许任意状态互跳，不设状态机**——真实情况是"这事其实早做完了，我忘了标"
 */
public func handleTaskStatus(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    let body = reqObj(ctx)
    let v = V()
    let status = v.need("status", reqStrOr(body, "status", ""), "请选择任务状态")
    v.check("status", isTaskStatus(status), "状态只能是 todo / doing / blocked / done")
    v.done()
    let blocker = reqStrOr(body, "blocker", "")

    s.lock.lock()
    try {
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.UpdateTaskStatus, targetOfTask(actor, t))

        if (status == "blocked" && isBlank(blocker)) {
            throw apiErrFields("BLOCKER_REQUIRED", "进入阻塞状态必须填写阻塞原因",
                oneField("blocker", "请说明卡在哪里，这比任何进度百分比都有用"))
        }
        let now = nowEpoch()
        t.status = status
        if (status == "blocked") {
            t.blocker = blocker
        } else {
            t.blocker = ""
        }
        if (status == "done") {
            if (t.completed_at <= 0) {
                t.completed_at = now
            }
        } else {
            t.completed_at = 0
        }
        t.updated_at = now
        storeSave(s)
        sendOk(ctx, taskDetail(s, t, now))
    } finally {
        s.lock.unlock()
    }
}

/*
 * DELETE /api/v1/tasks/{id} —— **软删除**
 * 任务承载着人的工作量记录，硬删除会让"这学期我做了多少事"永远无法回答，
 * 而误删在移动端非常容易发生（v1-scope 规则 17）。
 */
public func handleTaskDelete(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    s.lock.lock()
    try {
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.DeleteTask, targetOfTask(actor, t))
        t.deleted_at = nowEpoch()
        t.updated_at = t.deleted_at
        storeSave(s)
        sendOk(ctx, JsonObject())
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/tasks/lookup —— 日历同步用（api-design §4.8）
 *
 * 服务端**不存任何日历字段**：日历事件在成员自己的手机上，且同一任务可能被多人加入。
 * 客户端本地维护 task_id → {event_id, cached_*}，用这个接口批量确认
 * "我加过日历的任务现在还在不在"。返回 missing 里的 id 即需清理的本地事件。
 *
 * 没有它，客户端就无法可靠回收日历事件，日历里会堆错误提醒——两周后成员就不再相信它。
 */
public func handleTaskLookup(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let ids = match (jsonGetArray(body, "task_ids")) {
        case Some(a) => a
        case None => throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("task_ids", "请提供任务 id 列表"))
    }
    if (ids.size() > 500) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("task_ids", "一次最多查询 500 个"))
    }
    s.lock.lock()
    try {
        let items = JsonArray()
        let missing = JsonArray()
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
                    var found = false
                    if (id > 0) {
                        match (activeTaskById(s, id)) {
                            case Some(t) =>
                                if (can(actor, Action.ViewTasks, targetOfTask(actor, t))) {
                                    let o = JsonObject()
                                    jPutInt(o, "id", t.id)
                                    jPutTime(o, "due_at", t.due_at)
                                    jPutStr(o, "status", t.status)
                                    jPutTime(o, "updated_at", t.updated_at)
                                    items.add(o)
                                    found = true
                                }
                            case None => ()
                        }
                    }
                    if (!found) {
                        missing.add(JsonInt(id))
                    }
                case None => ()
            }
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("missing", missing)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}
