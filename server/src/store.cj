package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 数据模型与持久化。
 *
 * 持久化策略（v1-scope §8）：**内存 Store + 写时原子落盘 JSON**，不用数据库。
 *   · 单一快照文件 data/db.json，保证跨表一致（不会出现"任务存了、索引没存"）
 *   · 原子写：先写 db.json.tmp，再把旧文件备份成 db.json.bak，最后 rename 覆盖
 *   · 解析失败**绝不静默降级为空库**——那会在下一次保存时把真实数据覆盖掉。
 *     启动时宁可报错退出，让人去修文件。
 *
 * 并发：stdx 服务器可能并发处理请求，所有对 Store 的读写都在 store.lock 下进行。
 * Mutex 不可重入，因此 handler 只在最外层加一次锁。
 *
 * 空值约定：Int64 用 0 表示"无"。parent_id=0 顶层课题、plan_id=0 独立任务、
 * dept_id=0 未分配、时间字段 0 表示 null。1970 年不会成为真实业务值。
 */

import std.collection.*
import std.fs.*
import std.sync.*
import stdx.encoding.json.*

/* ===================== 数据模型（v1-scope §5） ===================== */

public class Department {
    public var id: Int64 = 0
    public var name: String = ""
    public var sort: Int64 = 0
}

public class Member {
    public var id: Int64 = 0
    public var name: String = ""
    public var phone: String = ""
    /* 口令：算法/迭代次数/盐/摘要分开存，避免解析复合字符串 */
    public var pw_algo: String = "pbkdf2-sha256"
    public var pw_iter: Int64 = 0
    public var pw_salt: String = ""
    public var pw_hash: String = ""
    public var role: String = ""          /* pending 时为空 */
    public var dept_id: Int64 = 0         /* pending 时为 0 */
    public var dept_hint: Int64 = 0       /* 招募链接带来的部门预填，仅提示用 */
    public var status: String = "pending" /* pending / active / disabled */
    public var joined_at: Int64 = 0
}

public class Plan {
    public var id: Int64 = 0
    public var title: String = ""
    public var desc: String = ""
    public var parent_id: Int64 = 0       /* 0 = 顶层课题 */
    public var owner_id: Int64 = 0        /* 必填，任意层级都要有 */
    public var dept_id: Int64 = 0         /* 仅顶层有值（v1-scope 规则 19） */
    public var due_at: Int64 = 0
    public var created_by: Int64 = 0
    public var created_at: Int64 = 0
    public var updated_at: Int64 = 0
}

public class Task {
    public var id: Int64 = 0
    public var title: String = ""
    public var desc: String = ""
    public var owner_id: Int64 = 0        /* 必填且唯一（规则 1） */
    public var plan_id: Int64 = 0
    public var dept_id: Int64 = 0
    public var status: String = "todo"    /* todo / doing / blocked / done */
    public var blocker: String = ""
    public var due_at: Int64 = 0
    public var updated_at: Int64 = 0
    public var completed_at: Int64 = 0
    public var deleted_at: Int64 = 0      /* 软删除（规则 17） */
    public var source: String = ""
    public var created_by: Int64 = 0
    public var created_at: Int64 = 0
}

public class DeptInviteLink {
    public var token: String = ""
    public var dept_id: Int64 = 0
    public var enabled: Bool = true
    public var created_by: Int64 = 0
    public var created_at: Int64 = 0
}

public class TokenRecord {
    public var member_id: Int64 = 0
    public var created_at: Int64 = 0
    public var expires_at: Int64 = 0
}

public class IdemRecord {
    public var resource_id: Int64 = 0
    public var created_at: Int64 = 0
}

public class LoginFail {
    public var count: Int64 = 0
    public var first_at: Int64 = 0
    public var locked_until: Int64 = 0
}

/*
 * 注册口令的失败状态（N-6）。**按客户端 IP 各存一份**，不再是一个全局计数。
 * lock_level 记录"这个 IP 已经被锁过几次"，锁定时长按它翻倍（递增退避）。
 */
public class RegFail {
    public var count: Int64 = 0
    public var first_at: Int64 = 0
    public var locked_until: Int64 = 0
    public var lock_level: Int64 = 0
}

/* ===================== Store ===================== */

public class Store {
    public let dir: String
    public let lock: Mutex = Mutex()

    /*
     * 动作 4（2026-09-15）：写盘专用锁。与 lock 分开，否则**整库磁盘 IO** 会占住全局锁。
     * 加锁顺序恒为 `lock → save_lock`（先取全局锁改内存/取快照，解锁后再取 save_lock 写盘），
     * 不存在反向获取，因此不会死锁。
     */
    public let save_lock: Mutex = Mutex()
    /* 提交序号（在 lock 内自增）与已落盘序号（在 save_lock 内更新）：并发写盘收敛到最新快照 */
    public var seq: Int64 = 0
    public var saved_seq: Int64 = 0
    /* 待落盘快照：storeSave 在锁内挂上，snapshotFlush 中间件在解锁后写出去（见 flushPending） */
    public var pending: ?Snapshot = None

    public var departments: HashMap<Int64, Department> = HashMap<Int64, Department>()
    public var members: HashMap<Int64, Member> = HashMap<Int64, Member>()
    public var plans: HashMap<Int64, Plan> = HashMap<Int64, Plan>()
    public var tasks: HashMap<Int64, Task> = HashMap<Int64, Task>()
    public var invite_links: HashMap<String, DeptInviteLink> = HashMap<String, DeptInviteLink>()
    public var tokens: HashMap<String, TokenRecord> = HashMap<String, TokenRecord>()
    public var idem: HashMap<String, IdemRecord> = HashMap<String, IdemRecord>()

    /*
     * login_fail / reg_fail_* 是**短时效限流状态，只存在内存里，不落盘**
     * （P1 M-3）。理由：失败是高频路径，每失败一次就整库原子写一次，
     * 等于给攻击者一个"发一个 401 换 18 MB 磁盘写"的放大杠杆。
     * 重启后计数清零可以接受 —— 攻击者没有让服务重启的手段。
     */
    public var login_fail: HashMap<String, LoginFail> = HashMap<String, LoginFail>()
    /* N-6：注册口令节流从"一个全局计数"改成**按客户端 IP**（key = IP，不含端口）。
     * 拿不到对端地址时 key 为空串，退化为全局锁——总比完全不锁好。 */
    public var reg_fail: HashMap<String, RegFail> = HashMap<String, RegFail>()

    /*
     * N-17：待写审计行（**只存在内存里，不落盘**）。
     * audit() 是在锁内被调用的，那时不能做文件 IO —— 与动作 4 确立的
     * "锁内只准备数据、IO 放锁外"同一口径。真正的 append 由请求链末端的
     * snapshotFlush 中间件（解锁后）调用 auditWrite 完成。
     */
    public var audit_pending: ArrayList<String> = ArrayList<String>()

    public var next_dept: Int64 = 1
    public var next_member: Int64 = 1
    public var next_plan: Int64 = 1
    public var next_task: Int64 = 1

    /* 注册配置（全局单例）：口令存明文，仅会长/副会长可读（v1-scope §5） */
    public var register_code: String = ""
    public var register_code_by: Int64 = 0
    public var register_code_at: Int64 = 0

    public init(dir: String) {
        this.dir = dir
    }

    public func dbFile(): String {
        return "${dir}/db.json"
    }
}

/* ===================== 序列化 ===================== */

func deptToJson(d: Department): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", d.id)
    jPutStr(o, "name", d.name)
    jPutInt(o, "sort", d.sort)
    return o
}

func deptFromJson(o: JsonObject): Department {
    let d = Department()
    d.id = reqIntOr(o, "id", 0)
    d.name = reqStrOr(o, "name", "")
    d.sort = reqIntOr(o, "sort", 0)
    return d
}

func memberToJson(m: Member): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", m.id)
    jPutStr(o, "name", m.name)
    jPutStr(o, "phone", m.phone)
    jPutStr(o, "pw_algo", m.pw_algo)
    jPutInt(o, "pw_iter", m.pw_iter)
    jPutStr(o, "pw_salt", m.pw_salt)
    jPutStr(o, "pw_hash", m.pw_hash)
    jPutStr(o, "role", m.role)
    jPutInt(o, "dept_id", m.dept_id)
    jPutInt(o, "dept_hint", m.dept_hint)
    jPutStr(o, "status", m.status)
    jPutInt(o, "joined_at", m.joined_at)
    return o
}

func memberFromJson(o: JsonObject): Member {
    let m = Member()
    m.id = reqIntOr(o, "id", 0)
    m.name = reqStrOr(o, "name", "")
    m.phone = reqStrOr(o, "phone", "")
    m.pw_algo = reqStrOr(o, "pw_algo", "pbkdf2-sha256")
    m.pw_iter = reqIntOr(o, "pw_iter", 0)
    m.pw_salt = reqStrOr(o, "pw_salt", "")
    m.pw_hash = reqStrOr(o, "pw_hash", "")
    m.role = reqStrOr(o, "role", "")
    m.dept_id = reqIntOr(o, "dept_id", 0)
    m.dept_hint = reqIntOr(o, "dept_hint", 0)
    m.status = reqStrOr(o, "status", "pending")
    m.joined_at = reqIntOr(o, "joined_at", 0)
    return m
}

func planToJson(p: Plan): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", p.id)
    jPutStr(o, "title", p.title)
    jPutStr(o, "desc", p.desc)
    jPutInt(o, "parent_id", p.parent_id)
    jPutInt(o, "owner_id", p.owner_id)
    jPutInt(o, "dept_id", p.dept_id)
    jPutInt(o, "due_at", p.due_at)
    jPutInt(o, "created_by", p.created_by)
    jPutInt(o, "created_at", p.created_at)
    jPutInt(o, "updated_at", p.updated_at)
    return o
}

func planFromJson(o: JsonObject): Plan {
    let p = Plan()
    p.id = reqIntOr(o, "id", 0)
    p.title = reqStrOr(o, "title", "")
    p.desc = reqStrOr(o, "desc", "")
    p.parent_id = reqIntOr(o, "parent_id", 0)
    p.owner_id = reqIntOr(o, "owner_id", 0)
    p.dept_id = reqIntOr(o, "dept_id", 0)
    p.due_at = reqIntOr(o, "due_at", 0)
    p.created_by = reqIntOr(o, "created_by", 0)
    p.created_at = reqIntOr(o, "created_at", 0)
    p.updated_at = reqIntOr(o, "updated_at", 0)
    return p
}

func taskToJson(t: Task): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", t.id)
    jPutStr(o, "title", t.title)
    jPutStr(o, "desc", t.desc)
    jPutInt(o, "owner_id", t.owner_id)
    jPutInt(o, "plan_id", t.plan_id)
    jPutInt(o, "dept_id", t.dept_id)
    jPutStr(o, "status", t.status)
    jPutStr(o, "blocker", t.blocker)
    jPutInt(o, "due_at", t.due_at)
    jPutInt(o, "updated_at", t.updated_at)
    jPutInt(o, "completed_at", t.completed_at)
    jPutInt(o, "deleted_at", t.deleted_at)
    jPutStr(o, "source", t.source)
    jPutInt(o, "created_by", t.created_by)
    jPutInt(o, "created_at", t.created_at)
    return o
}

func taskFromJson(o: JsonObject): Task {
    let t = Task()
    t.id = reqIntOr(o, "id", 0)
    t.title = reqStrOr(o, "title", "")
    t.desc = reqStrOr(o, "desc", "")
    t.owner_id = reqIntOr(o, "owner_id", 0)
    t.plan_id = reqIntOr(o, "plan_id", 0)
    t.dept_id = reqIntOr(o, "dept_id", 0)
    t.status = reqStrOr(o, "status", "todo")
    t.blocker = reqStrOr(o, "blocker", "")
    t.due_at = reqIntOr(o, "due_at", 0)
    t.updated_at = reqIntOr(o, "updated_at", 0)
    t.completed_at = reqIntOr(o, "completed_at", 0)
    t.deleted_at = reqIntOr(o, "deleted_at", 0)
    t.source = reqStrOr(o, "source", "")
    t.created_by = reqIntOr(o, "created_by", 0)
    t.created_at = reqIntOr(o, "created_at", 0)
    return t
}

func linkToJson(l: DeptInviteLink): JsonObject {
    let o = JsonObject()
    jPutStr(o, "token", l.token)
    jPutInt(o, "dept_id", l.dept_id)
    jPutBool(o, "enabled", l.enabled)
    jPutInt(o, "created_by", l.created_by)
    jPutInt(o, "created_at", l.created_at)
    return o
}

func linkFromJson(o: JsonObject): DeptInviteLink {
    let l = DeptInviteLink()
    l.token = reqStrOr(o, "token", "")
    l.dept_id = reqIntOr(o, "dept_id", 0)
    l.enabled = reqBoolOr(o, "enabled", true)
    l.created_by = reqIntOr(o, "created_by", 0)
    l.created_at = reqIntOr(o, "created_at", 0)
    return l
}

func tokenToJson(t: TokenRecord): JsonObject {
    let o = JsonObject()
    jPutInt(o, "member_id", t.member_id)
    jPutInt(o, "created_at", t.created_at)
    jPutInt(o, "expires_at", t.expires_at)
    return o
}

func tokenFromJson(o: JsonObject): TokenRecord {
    let t = TokenRecord()
    t.member_id = reqIntOr(o, "member_id", 0)
    t.created_at = reqIntOr(o, "created_at", 0)
    t.expires_at = reqIntOr(o, "expires_at", 0)
    return t
}

func idemToJson(k: String, r: IdemRecord): JsonObject {
    let o = JsonObject()
    jPutStr(o, "key", k)
    jPutInt(o, "resource_id", r.resource_id)
    jPutInt(o, "created_at", r.created_at)
    return o
}

/* ===================== 加载 / 保存 ===================== */

public func storeLoad(dir: String): Store {
    let s = Store(dir)
    let file = s.dbFile()
    if (!exists(file)) {
        return s
    }
    let text = String.fromUtf8(File.readFrom(file))
    var root: ?JsonObject = None
    try {
        root = Some(JsonValue.fromStr(text).asObject())
    } catch (e: Exception) {
        root = None
    }
    match (root) {
        case Some(r) =>
            s.next_dept = reqIntOr(r, "next_dept", 1)
            s.next_member = reqIntOr(r, "next_member", 1)
            s.next_plan = reqIntOr(r, "next_plan", 1)
            s.next_task = reqIntOr(r, "next_task", 1)
            s.register_code = reqStrOr(r, "register_code", "")
            s.register_code_by = reqIntOr(r, "register_code_by", 0)
            s.register_code_at = reqIntOr(r, "register_code_at", 0)
            /* 每条记录解析完都对一次总数（P1 M-7），见 checkLoaded */
            let deptArr = arrOf(r, "departments")
            s.departments = deptArrFromJson(r, "departments")
            checkLoaded("departments", deptArr, s.departments.size, file)
            let memberArr = arrOf(r, "members")
            s.members = memberArrFromJson(r, "members")
            checkLoaded("members", memberArr, s.members.size, file)
            let planArr = arrOf(r, "plans")
            s.plans = planArrFromJson(r, "plans")
            checkLoaded("plans", planArr, s.plans.size, file)
            let taskArr = arrOf(r, "tasks")
            s.tasks = taskArrFromJson(r, "tasks")
            checkLoaded("tasks", taskArr, s.tasks.size, file)
            let linkArr = arrOf(r, "invite_links")
            s.invite_links = linkArrFromJson(r, "invite_links")
            checkLoaded("invite_links", linkArr, s.invite_links.size, file)
            let tokenArr = arrOf(r, "tokens")
            s.tokens = tokenArrFromJson(r, "tokens")
            checkLoaded("tokens", tokenArr, s.tokens.size, file)
            /* N-5：idem 原先漏了 checkLoaded，是 8 张表里唯一的例外。
             * 它的影响确实最小（24 小时 TTL 的幂等映射，丢一条最坏是客户端重试时
             * 多建一个资源），但"例外只存在于代码里"正是后人最容易踩的坑——
             * 口径统一成一种，读代码的人就不必再猜哪张表特殊。 */
            let idemArr = arrOf(r, "idem")
            s.idem = idemArrFromJson(r, "idem")
            checkLoaded("idem", idemArr, s.idem.size, file)
            /* login_fail 不再从文件读（P1 M-3：短时效限流状态只留内存）。
             * 旧文件里的 login_fail 字段被忽略，不影响启动。 */
            return s
        case None =>
            /* 绝不静默降级为空库：下一次保存会把真实数据覆盖掉。 */
            throw Exception("数据文件无法解析，已停止启动以免覆盖数据：${file}")
    }
}

/*
 * 逐条校验：JSON 数组里有几条，就必须解析出几条（P1 M-7）。
 *
 * 原先每个元素的解析失败都被 `catch { () }` 静默吞掉：文件里 100 个任务，
 * 坏了 3 个，服务照常启动，用户看到 97 个任务——接着下一次保存就把那 3 条永久覆盖。
 * 静默丢数据比直接起不来严重得多，所以这里与"文件级解析失败"同一口径：
 * 宁可起不来，也不要带着残缺数据继续写。
 *
 * 条数不等也可能是两条记录主键相同（后者覆盖前者），这同样是文件不一致，
 * 拒绝启动也是正确的处理。
 */
func checkLoaded(label: String, arr: JsonArray, loaded: Int64, file: String): Unit {
    if (arr.size() != loaded) {
        throw Exception("数据文件 ${label} 有 ${arr.size()} 条，只解析出 ${loaded} 条（记录损坏或主键重复），已停止启动以免覆盖数据：${file}")
    }
}

/* 逐个把数组元素解析成模型；key 在 JSON 里存成数组，读时按下标遍历（JsonArray 不支持 for-in）。 */
func arrOf(o: JsonObject, key: String): JsonArray {
    match (jsonGetArray(o, key)) {
        case Some(a) => return a
        case None => return JsonArray()
    }
}

func deptArrFromJson(o: JsonObject, key: String): HashMap<Int64, Department> {
    let m = HashMap<Int64, Department>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let d = deptFromJson(v.asObject())
                    m[d.id] = d
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func memberArrFromJson(o: JsonObject, key: String): HashMap<Int64, Member> {
    let m = HashMap<Int64, Member>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = memberFromJson(v.asObject())
                    m[x.id] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func planArrFromJson(o: JsonObject, key: String): HashMap<Int64, Plan> {
    let m = HashMap<Int64, Plan>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = planFromJson(v.asObject())
                    m[x.id] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func taskArrFromJson(o: JsonObject, key: String): HashMap<Int64, Task> {
    let m = HashMap<Int64, Task>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = taskFromJson(v.asObject())
                    m[x.id] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func linkArrFromJson(o: JsonObject, key: String): HashMap<String, DeptInviteLink> {
    let m = HashMap<String, DeptInviteLink>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = linkFromJson(v.asObject())
                    m[x.token] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func tokenArrFromJson(o: JsonObject, key: String): HashMap<String, TokenRecord> {
    let m = HashMap<String, TokenRecord>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let obj = v.asObject()
                    let tok = reqStrOr(obj, "token", "")
                    if (tok.size > 0) {
                        m[tok] = tokenFromJson(obj)
                    }
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func idemArrFromJson(o: JsonObject, key: String): HashMap<String, IdemRecord> {
    let m = HashMap<String, IdemRecord>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let obj = v.asObject()
                    let k = reqStrOr(obj, "key", "")
                    let r = IdemRecord()
                    r.resource_id = reqIntOr(obj, "resource_id", 0)
                    r.created_at = reqIntOr(obj, "created_at", 0)
                    if (k.size > 0) {
                        m[k] = r
                    }
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

/* ===================== 落盘：序列化在锁内、写盘在锁外（动作 4） ===================== */

/* 一次变更的快照：text = 完整 db.json 内容，seq = 提交序号。 */
public class Snapshot {
    public var text: String = ""
    public var seq: Int64 = 0

    public init() {}
}

/*
 * 在**锁内**取一致快照：把当前 Store 渲染成 db.json 内容，并自增提交序号。
 * ⚠ 调用方必须已持 `s.lock`，否则快照可能跨表不一致（"任务存了、别的没存"）。
 *
 * 为什么把 storeSave 拆成两步（2026-09-15，容量基准的动作 4）：
 *   原先 storeSave 在全局锁里做**整库磁盘 IO** —— 写 .tmp、把旧文件复制成 .bak、
 *   rename，合计约 **3 倍文件大小**的 IO。实测：1000 人 2.51 MB → 单次写占锁 56 ms；
 *   3000 人 7.55 MB → 124 ms，而这段时间**所有请求都在排队**。
 *   现在只有"序列化"留在锁内（几毫秒到十几毫秒），IO 挪到锁外由 save_lock 串行。
 *
 * 语义没有变：调用方仍然是"先 writeSnapshot、再响应"，所以
 * **响应 200 依旧代表已落盘** —— 这条强语义正是 L-7 当初把 IO 放进锁里的理由，
 * 本次只是把 IO 挪出锁，而不是放弃它。
 */
public func storeSnapshot(s: Store): Snapshot {
    let snap = Snapshot()
    snap.text = renderDb(s)
    s.seq += 1
    snap.seq = s.seq
    return snap
}

/*
 * 在**锁外**写盘。并发写盘由 s.save_lock 串行，序号守卫保证"新快照不会被旧快照覆盖"：
 *   A(seq5) 与 B(seq6) 并发，无论谁先拿到 save_lock 都收敛到 seq6 ——
 *   A 先写(5)、B 后写(6) ✓；B 先写(6)、A 发现 5 <= saved_seq 直接跳过 ✓
 *   （seq6 的快照是在 s.lock 内取的，必然已包含 A 的变更，跳过不会丢数据）
 *   → 而且两者都会在返回前看到"磁盘上已有不低于自己的版本"，与 storeSave 的旧语义等价。
 */
public func writeSnapshot(s: Store, snap: Snapshot): Unit {
    if (snap.text.size == 0) {
        return
    }
    s.save_lock.lock()
    try {
        if (snap.seq <= s.saved_seq) {
            return
        }
        writeDbFile(s, snap.text)
        s.saved_seq = snap.seq
    } finally {
        s.save_lock.unlock()
    }
}

/*
 * 提交一次变更（**在锁内调用**）：把当前状态序列化成快照挂到 `s.pending`，**不碰磁盘**。
 * 真正的写盘由请求链末端的 `snapshotFlush` 中间件在**解锁之后**完成（见 flushPending）。
 *
 * 于是全局锁只承担"序列化"（几毫秒到十几毫秒），不再承担整库 IO
 * （实测 1000 人 2.51 MB 时单次写占锁 56 ms、3000 人 7.55 MB 时 124 ms）。
 *
 * ⚠ 语义没有降低：`snapshotFlush` 跑在 `ctx.commit()` **之前**，所以
 *   **响应 200 依旧代表数据已经写在磁盘上** —— 这正是 L-7 当初把 IO 放进锁里的理由。
 * ⚠ 若 handler 抛异常，`next()` 不会返回、pending 不落盘 —— 与改造前一致
 *   （旧代码抛异常时也执行不到 storeSave 那一行）。
 */
public func storeSave(s: Store): Unit {
    let snap = storeSnapshot(s)
    s.save_lock.lock()
    try {
        s.pending = Some(snap)
    } finally {
        s.save_lock.unlock()
    }
}

/*
 * 同步落盘：给**不在 HTTP 请求里**的调用方用（`init-admin`、单测）。
 * 请求里的 handler 用 storeSave 即可，不要用这个（会重新把 IO 放回锁内）。
 */
public func storeSaveNow(s: Store): Unit {
    writeSnapshot(s, storeSnapshot(s))
}

/*
 * 把待落盘的东西写出去（幂等）：审计行 + 整库快照；没有待写内容时是空操作。
 *
 * 两件事都在**解锁之后**做（调用方是请求链末端的 snapshotFlush 中间件）：
 *   · 审计行（N-17）：原先在锁内 `File.appendTo`，与动作 4 的口径不一致；
 *   · 整库快照（动作 4）：见 storeSave 的注释。
 * 顺序是先审计、后快照：即便快照被序号守卫跳过，审计行也已经落地。
 */
public func flushPending(s: Store): Unit {
    /* 1) 取走待写审计行 —— 只为了搬动数组，短暂持全局锁（加锁顺序与别处一致） */
    var auditLines = ArrayList<String>()
    s.lock.lock()
    try {
        if (s.audit_pending.size > 0) {
            auditLines = s.audit_pending
            s.audit_pending = ArrayList<String>()
        }
    } finally {
        s.lock.unlock()
    }
    auditWrite(s, auditLines)

    /* 2) 取走待写快照（在 save_lock 内），再锁外写盘 */
    var take: ?Snapshot = None
    s.save_lock.lock()
    try {
        take = s.pending
        s.pending = None
    } finally {
        s.save_lock.unlock()
    }
    match (take) {
        case Some(x) => writeSnapshot(s, x)
        case None => ()
    }
}

/*
 * 请求链上的刷盘中间件。**必须挂在 router 之前**：
 * 这样 `next()` 返回时 handler 已经跑完并解锁（我们的 handler 不调用 next），
 * 而整条链仍在 `ctx.commit()` 之前 —— 顺序是「改内存 → 解锁 → 写盘 → 发响应」。
 */
public func snapshotFlush(s: Store): Middleware {
    return { ctx: Context, next: () -> Unit =>
        next()
        flushPending(s)
    }
}

/* 真正的文件写入：写 .tmp → 备份旧文件 → rename 覆盖。 */
func writeDbFile(s: Store, text: String): Unit {
    /* 注意：Cangjie 的 Directory.create 在目录已存在时**照样抛异常**
     * （即使 recursive: true），必须先判断存在性，否则第二次落盘就会崩。 */
    if (!exists(s.dir)) {
        Directory.create(s.dir, recursive: true)
    }
    let tmp = s.dbFile() + ".tmp"
    File.writeTo(tmp, text.toArray())
    if (exists(s.dbFile())) {
        File.writeTo(s.dbFile() + ".bak", File.readFrom(s.dbFile()))
    }
    rename(tmp, to: s.dbFile(), overwrite: true)
}

/* 把整个 Store 渲染成 db.json 的文本（不碰磁盘）。 */
func renderDb(s: Store): String {
    let root = JsonObject()
    root.put("version", JsonInt(1))
    jPutInt(root, "next_dept", s.next_dept)
    jPutInt(root, "next_member", s.next_member)
    jPutInt(root, "next_plan", s.next_plan)
    jPutInt(root, "next_task", s.next_task)
    jPutStr(root, "register_code", s.register_code)
    jPutInt(root, "register_code_by", s.register_code_by)
    jPutInt(root, "register_code_at", s.register_code_at)

    let depts = JsonArray()
    for ((_k, d) in s.departments) {
        depts.add(deptToJson(d))
    }
    root.put("departments", depts)

    let members = JsonArray()
    for ((_k, m) in s.members) {
        members.add(memberToJson(m))
    }
    root.put("members", members)

    let plans = JsonArray()
    for ((_k, p) in s.plans) {
        plans.add(planToJson(p))
    }
    root.put("plans", plans)

    let tasks = JsonArray()
    for ((_k, x) in s.tasks) {
        tasks.add(taskToJson(x))
    }
    root.put("tasks", tasks)

    let links = JsonArray()
    for ((_k, l) in s.invite_links) {
        links.add(linkToJson(l))
    }
    root.put("invite_links", links)

    let toks = JsonArray()
    for ((k, t) in s.tokens) {
        let o = tokenToJson(t)
        jPutStr(o, "token", k)
        toks.add(o)
    }
    root.put("tokens", toks)

    /* login_fail / reg_fail 不落盘（P1 M-3 / N-6），见 Store 字段上的注释。 */

    let idems = JsonArray()
    for ((k, r) in s.idem) {
        idems.add(idemToJson(k, r))
    }
    root.put("idem", idems)

    return root.toString()
}

/* ===================== 查询辅助 ===================== */


public func memberByPhone(s: Store, phone: String): ?Member {
    for ((_k, m) in s.members) {
        if (m.phone == phone) {
            return Some(m)
        }
    }
    return None
}



/* 未删除的任务。全项目一致地用它过滤【v1-scope 规则 17】。 */
public func activeTaskById(s: Store, id: Int64): ?Task {
    match (s.tasks.get(id)) {
        case Some(t) =>
            if (t.deleted_at > 0) {
                return None
            }
            return Some(t)
        case None => return None
    }
}

/* 会长人数：规则 10「系统必须始终至少有一个 president」。 */
public func presidentCount(s: Store): Int64 {
    var n: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.role == "president" && m.status != "disabled") {
            n += 1
        }
    }
    return n
}

/* 待分配列表（先来先处理，即按 id 升序 = 注册顺序）。 */
public func pendingMembers(s: Store): Array<Member> {
    let out = ArrayList<Member>()
    for ((_k, m) in s.members) {
        if (m.status == "pending") {
            out.add(m)
        }
    }
    let arr = out.toArray()
    sortByKey<Member>(arr, { m: Member => m.id })
    return arr
}

/*
 * 按 Int64 键排序：**原地堆排序 O(n log n)**。
 *
 * 2026-09-15 替换原先的插入排序。为什么必须换（见 docs/capacity-baseline.md 的实测）：
 * 这里排的不是"几十条"，而是**某个用户能看见的全部任务 / 成员**——会长看得见全社团。
 * 插入排序是 O(n²)，实测：
 *     可见任务  8000 个 → GET /tasks 168 ms
 *     可见任务 24000 个 → GET /tasks **1017 ms**（数据涨 3 倍，延迟涨 6 倍 = 平方项）
 * 换堆排序后回到同一量级下几十毫秒。
 *
 * 为什么自己写而不用 std.sort：本项目只用**已实测过**的标准库入口（docs/API-NOTES.md 开头的纪律）。
 * 堆排序原地、零额外分配、不引入新 API。
 *
 * 稳定性：堆排序不稳定。但所有调用点的键都含唯一 id（如 `due_at * 1000 + id`），
 * 键互不相同，稳定与否不影响结果。
 */
func sortByKey<T>(arr: Array<T>, key: (T) -> Int64): Unit {
    let n = arr.size
    if (n < 2) {
        return
    }
    /* 1) 建大顶堆：从最后一个非叶节点起逐个下沉 */
    var i = n / 2 - 1
    while (i >= 0) {
        siftDown<T>(arr, i, n, key)
        i -= 1
    }
    /* 2) 反复把堆顶（当前最大）换到末尾，再对缩小后的堆下沉 */
    var end = n - 1
    while (end > 0) {
        let tmp = arr[0]
        arr[0] = arr[end]
        arr[end] = tmp
        siftDown<T>(arr, 0, end, key)
        end -= 1
    }
}

/* 把 root0 处的元素在 [0, end) 范围内下沉到正确位置。 */
func siftDown<T>(arr: Array<T>, root0: Int64, end: Int64, key: (T) -> Int64): Unit {
    var root = root0
    var go = true
    while (go) {
        let left = root * 2 + 1
        if (left >= end) {
            go = false
        } else {
            var pick = left
            let right = left + 1
            if (right < end && key(arr[left]) < key(arr[right])) {
                pick = right
            }
            if (key(arr[root]) < key(arr[pick])) {
                let tmp = arr[root]
                arr[root] = arr[pick]
                arr[pick] = tmp
                root = pick
            } else {
                go = false
            }
        }
    }
}

/*
 * 复合排序键的安全折算（P1 M-8）。
 *
 * `sort * 1000000 + id` 这个写法隐含前提：sort 必须是有界的小整数。原先没有校验，
 * 一个 sort = 9223372036854775807 会让乘法溢出，排序键变成一个大负数，
 * 而且这个坏值会**落盘**——之后每一次 GET /depts 都在排序时溢出，
 * 接口从此永久 500，只能手工改文件才能恢复。
 *
 * 两道防线：handler 侧校验 sort 取值范围（h_dept.cj 的 SORT_MIN/SORT_MAX），
 * 这里再夹一次——因为磁盘上可能已经有旧版本写下的越界值。夹紧只影响排序先后，
 * 不会丢数据，也不会让接口起不来。
 */
public let SORT_MIN: Int64 = 0
public let SORT_MAX: Int64 = 10000

func sortKeyClamp(v: Int64): Int64 {
    if (v < SORT_MIN) {
        return SORT_MIN
    }
    if (v > SORT_MAX) {
        return SORT_MAX
    }
    return v
}

/* 部门展示顺序：sort → id。 */
public func sortedDepartments(s: Store): Array<Department> {
    let out = ArrayList<Department>()
    for ((_k, d) in s.departments) {
        out.add(d)
    }
    let arr = out.toArray()
    sortByKey<Department>(arr, { d: Department => sortKeyClamp(d.sort) * 1000000 + d.id })
    return arr
}

/* 成员展示顺序：部门 sort → id（未分配部门排最后）。 */
public func sortedMembers(s: Store, list: ArrayList<Member>): Array<Member> {
    let arr = list.toArray()
    sortByKey<Member>(arr, { m: Member =>
        var ds: Int64 = 999
        match (s.departments.get(m.dept_id)) {
            case Some(d) => ds = d.sort
            case None => ds = 999
        }
        sortKeyClamp(ds) * 1000000 + m.id
    })
    return arr
}

/* 某成员名下**未完成**的任务——移出社团前必须先转交（api-design §3.2）。 */
public func openTasksOf(s: Store, memberId: Int64): Array<Task> {
    let out = ArrayList<Task>()
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.owner_id != memberId || t.status == "done") {
            continue
        }
        out.add(t)
    }
    let arr = out.toArray()
    sortByKey<Task>(arr, { t: Task => t.id })
    return arr
}

/* 部门下还有多少"没退出"的成员（删除部门的前置检查）。 */
public func activeMemberCountOfDept(s: Store, deptId: Int64): Int64 {
    var n: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.dept_id == deptId && m.status != "disabled") {
            n += 1
        }
    }
    return n
}

/* 部门下还有多少顶层课题（Plan.dept_id 只存在顶层，见 v1-scope 规则 19）。 */
public func topPlanCountOfDept(s: Store, deptId: Int64): Int64 {
    var n: Int64 = 0
    for ((_k, p) in s.plans) {
        if (p.parent_id == 0 && p.dept_id == deptId) {
            n += 1
        }
    }
    return n
}

/* 部门重名检查（改名与新建共用）。 */
public func deptNameTaken(s: Store, name: String, exceptId: Int64): Bool {
    for ((_k, d) in s.departments) {
        if (d.id != exceptId && d.name == name) {
            return true
        }
    }
    return false
}

/* ===================== 任务辅助（Part 4） ===================== */

/* 状态只有 4 档（v1-scope 规则 2：不做进度百分比）。 */
public func isTaskStatus(st: String): Bool {
    if (st == "todo") {
        return true
    }
    if (st == "doing") {
        return true
    }
    if (st == "blocked") {
        return true
    }
    if (st == "done") {
        return true
    }
    return false
}

/*
 * 逾期是**派生量**（规则 15），由 due_at 与当前时间算出，永不落盘。
 * 已完成的任务不再标逾期——"做完了"这个事实优先于"当时晚了"。
 */
public func isTaskOverdue(t: Task, now: Int64): Bool {
    if (t.status == "done") {
        return false
    }
    return isOverdue(t.due_at, now)
}

/* 按截止时间升序；无截止的排最后（api-design §4.1）。 */
public func sortedTasksByDue(list: ArrayList<Task>): Array<Task> {
    let arr = list.toArray()
    sortByKey<Task>(arr, { t: Task =>
        if (t.due_at > 0) {
            t.due_at * 1000 + t.id
        } else {
            9000000000000 + t.id
        }
    })
    return arr
}

/*
 * 课题子树的所有 id（含自身）。
 * `GET /tasks?plan_id=` 默认包含整棵子树——多级课题下，
 * 按父课题筛选却只看到本级任务，是不符合直觉的。
 */
public func planSubtreeIds(s: Store, rootId: Int64): HashSet<Int64> {
    let out = HashSet<Int64>()
    let queue = ArrayList<Int64>()
    queue.add(rootId)
    out.add(rootId)
    var i: Int64 = 0
    while (i < queue.size) {
        let cur = queue[i]
        i += 1
        for ((_k, p) in s.plans) {
            if (p.parent_id == cur && !out.contains(p.id)) {
                out.add(p.id)
                queue.add(p.id)
            }
        }
    }
    return out
}

/* ===================== 幂等（api-design §1.9） ===================== */

public let IDEM_TTL: Int64 = 86400

/*
 * 幂等键必须带上提交者本人（P0 H-2）。
 * 原先只按 kind + token 索引：甲用 client_token 建了资源，乙拿同一个 token 重放，
 * 就会被当成「甲的重复提交」，直接把甲的资源读回去——一个绕过权限判定的越权读。
 * 带上 actorId 后，乙的 token 匹配不到任何记录，走正常创建流程，该 403 还是 403。
 */
func idemKey(kind: String, actorId: Int64, token: String): String {
    return "${kind}:${actorId}:${token}"
}

/* 24 小时内命中则返回首次创建的资源 id。 */
public func idemHit(s: Store, kind: String, actorId: Int64, token: String, now: Int64): ?Int64 {
    let k = idemKey(kind, actorId, token)
    match (s.idem.get(k)) {
        case Some(rec) =>
            if (now - rec.created_at <= IDEM_TTL) {
                return Some(rec.resource_id)
            }
            s.idem.remove(k)
            return None
        case None => return None
    }
}

public func idemPut(s: Store, kind: String, actorId: Int64, token: String, resourceId: Int64, now: Int64): Unit {
    let rec = IdemRecord()
    rec.resource_id = resourceId
    rec.created_at = now
    s.idem[idemKey(kind, actorId, token)] = rec
    /* 顺带清理过期项，避免这张表无限增长 */
    if (s.idem.size > 200) {
        let doomed = ArrayList<String>()
        for ((k, r) in s.idem) {
            if (now - r.created_at > IDEM_TTL) {
                doomed.add(k)
            }
        }
        for (k in doomed) {
            s.idem.remove(k)
        }
    }
}

/* ===================== 课题辅助（Part 5） ===================== */

/* 深度硬上限 6 层（v1-scope 规则 18）。上限的意义是防呆，不是限制表达。 */
public let PLAN_MAX_DEPTH: Int64 = 6

/* 脏数据保护用的遍历上限，远大于任何合法深度。 */
let PLAN_WALK_GUARD: Int64 = 64

/*
 * 从 planId 向上走到根课题（顶层 parent_id == 0）。
 * 带 guard：万一数据里有环，读取路径也不能死循环。
 */
public func planRootOf(s: Store, planId: Int64): Int64 {
    var cur = planId
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                if (p.parent_id <= 0) {
                    return cur
                }
                cur = p.parent_id
            case None => return cur
        }
        guard += 1
    }
    return cur
}

/*
 * 课题的**有效部门**：顶层课题存 dept_id，子课题的部门由所属根决定。
 * 这正是「子课题不允许跨部门」自动成立、移动时也不需要级联更新部门的原因（规则 19）。
 */
public func planDeptOf(s: Store, planId: Int64): Int64 {
    let root = planRootOf(s, planId)
    match (s.plans.get(root)) {
        case Some(p) => return p.dept_id
        case None => return 0
    }
}

/* 层级：顶层为 1。 */
public func planDepthOf(s: Store, planId: Int64): Int64 {
    var cur = planId
    var d: Int64 = 1
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                if (p.parent_id <= 0) {
                    return d
                }
                cur = p.parent_id
                d += 1
            case None => return d
        }
        guard += 1
    }
    return d
}

/* 以 planId 为根的子树高度（含自身）。带层级 guard，防脏数据成环。 */
public func planHeightOf(s: Store, planId: Int64): Int64 {
    return planHeightFrom(s, planId, 0)
}

func planHeightFrom(s: Store, planId: Int64, level: Int64): Int64 {
    if (level > PLAN_WALK_GUARD) {
        return 1
    }
    let kids = planChildrenOf(s, planId)
    if (kids.size == 0) {
        return 1
    }
    var best: Int64 = 0
    for (k in kids) {
        let h = planHeightFrom(s, k.id, level + 1)
        if (h > best) {
            best = h
        }
    }
    return best + 1
}

/* 直接子课题，按 id 升序。 */
public func planChildrenOf(s: Store, planId: Int64): Array<Plan> {
    let out = ArrayList<Plan>()
    for ((_k, p) in s.plans) {
        if (p.parent_id == planId) {
            out.add(p)
        }
    }
    let arr = out.toArray()
    sortByKey<Plan>(arr, { p: Plan => p.id })
    return arr
}

/*
 * 环形校验（api-design §5.6 的实现提示）：**从目标父节点向上遍历到根**，
 * 而不是向下扫子树——向上遍历的深度通常远小于子树规模。
 * 一旦成环，递归进度聚合会无限循环并拖垮服务，这是多级结构下最容易出的事故。
 */
public func planWouldCycle(s: Store, planId: Int64, newParentId: Int64): Bool {
    if (newParentId <= 0) {
        return false
    }
    var cur = newParentId
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        if (cur == planId) {
            return true
        }
        match (s.plans.get(cur)) {
            case Some(p) => cur = p.parent_id
            case None => return false
        }
        guard += 1
    }
    return false
}

/* 把 rootId 及其全部后代加入 out（供可见性集合与统计用）。 */
public func planSubtreeInto(s: Store, rootId: Int64, out: HashSet<Int64>): Unit {
    let queue = ArrayList<Int64>()
    queue.add(rootId)
    out.add(rootId)
    var i: Int64 = 0
    while (i < queue.size) {
        let cur = queue[i]
        i += 1
        for ((_k, p) in s.plans) {
            if (p.parent_id == cur && !out.contains(p.id)) {
                out.add(p.id)
                queue.add(p.id)
            }
        }
    }
}

/* 一个课题的聚合统计。 */
public class PlanStats {
    public var own_total: Int64 = 0    /* 本级任务总数 */
    public var own_done: Int64 = 0     /* 本级已完成 */
    public var task_count: Int64 = 0   /* 本级任务数（对外字段） */
    public var total: Int64 = 0        /* 递归聚合：含整棵子树 */
    public var done: Int64 = 0         /* 递归聚合：含整棵子树 */
    public var child_count: Int64 = 0  /* 直接子课题数 */

    public init() {}
}

/*
 * 递归进度聚合，**自底向上一次算完，O(n)**。
 *
 * api-design §5.8 明确警告：不要对每个节点各自递归（那是 O(n^2)，课题一多就明显变慢）。
 * 做法：先按"深度从深到浅"排序，再依次把子节点的聚合值累加到父节点——
 * 处理到某个节点时，它的所有子节点必然已经算完。
 *
 * 只统计**未删除**的任务；已完成按 status == done 判定。
 */
public func planStatsAll(s: Store, ids: HashSet<Int64>): HashMap<Int64, PlanStats> {
    let stats = HashMap<Int64, PlanStats>()

    /* 1) 建表 + 直接子课题数 */
    for ((_k, p) in s.plans) {
        if (!ids.contains(p.id)) {
            continue
        }
        stats[p.id] = PlanStats()
    }
    for ((_k, p) in s.plans) {
        if (!ids.contains(p.id) || p.parent_id <= 0 || !ids.contains(p.parent_id)) {
            continue
        }
        match (stats.get(p.parent_id)) {
            case Some(parent) => parent.child_count += 1
            case None => ()
        }
    }

    /* 2) 本级任务数 */
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.plan_id <= 0 || !ids.contains(t.plan_id)) {
            continue
        }
        match (stats.get(t.plan_id)) {
            case Some(st) =>
                st.task_count += 1
                st.own_total += 1
                if (t.status == "done") {
                    st.own_done += 1
                }
            case None => ()
        }
    }

    /* 3) 先把 total/done 初始化成**本级值** */
    for ((_k, p) in s.plans) {
        if (!ids.contains(p.id)) {
            continue
        }
        match (stats.get(p.id)) {
            case Some(st) =>
                st.total = st.own_total
                st.done = st.own_done
            case None => ()
        }
    }

    /* 4) 深度从深到浅累加到父节点。注意这里**不能**再重置 total/done，
     *    否则会把子节点刚累加进来的值覆盖回本级值（父课题进度会永远偏小）。 */
    let list = ArrayList<Plan>()
    for ((_k, p) in s.plans) {
        if (ids.contains(p.id)) {
            list.add(p)
        }
    }
    let arr = list.toArray()
    sortByKey<Plan>(arr, { p: Plan => 0 - planDepthOf(s, p.id) * 1000000 + p.id })
    for (p in arr) {
        match (stats.get(p.id)) {
            case Some(st) =>
                if (p.parent_id > 0) {
                    match (stats.get(p.parent_id)) {
                        case Some(parent) =>
                            parent.total += st.total
                            parent.done += st.done
                        case None => ()
                    }
                }
            case None => ()
        }
    }
    return stats
}

/*
 * 单个课题的聚合统计（含整棵子树）。
 *
 * 存在的理由（P1 M-1）：POST /plans 与 PATCH /plans/{id} 的响应里也带 progress，
 * 起初那里传的是 None，序列化出来就是 total=0 / done=0——一个假进度。客户端改完
 * 标题，进度条会突然归零。凡是返回 plan 对象的地方都必须用这个函数取真值。
 * 命中幂等回放时同理。
 */
public func planStatsOf(s: Store, id: Int64): ?PlanStats {
    let sub = HashSet<Int64>()
    planSubtreeInto(s, id, sub)
    return planStatsAll(s, sub).get(id)
}

/*
 * 删除课题：**直接子节点上提一级，绝不级联删除**（v1-scope 规则 9）。
 *
 *   子课题   -> parent_id = P.parent_id
 *   任务     -> plan_id   = P.parent_id
 *   P 是顶层 -> 子课题变为顶层并**继承 P 的 dept_id**（dept_id 只存顶层，这一步不能漏）
 *               任务变为独立任务（plan_id = 0）
 *
 * 为什么不做级联删除：任务承载着人的工作量记录，一次误删丢掉整棵子树
 * 是这个设计里最不可接受的失败模式。
 *
 * 返回（上提的课题数，上提的任务数）；任务数只算未删除的。
 * 抽成纯函数是为了可单测；handler 负责权限、审计与落盘。
 */
public func planDeletePromote(s: Store, id: Int64): (Int64, Int64) {
    let target = match (s.plans.get(id)) {
        case Some(x) => x
        case None => return (0, 0)
    }
    let newParent = target.parent_id
    let wasTop = (newParent <= 0)
    let inheritDept = target.dept_id
    let now = nowEpoch()
    var movedPlans: Int64 = 0
    var movedTasks: Int64 = 0

    for ((_k, c) in s.plans) {
        if (c.parent_id == id && c.id != id) {
            c.parent_id = newParent
            if (wasTop) {
                c.dept_id = inheritDept
            }
            c.updated_at = now
            movedPlans += 1
        }
    }
    for ((_k, t) in s.tasks) {
        if (t.plan_id == id) {
            t.plan_id = newParent
            t.updated_at = now
            if (t.deleted_at <= 0) {
                movedTasks += 1
            }
        }
    }
    s.plans.remove(id)
    return (movedPlans, movedTasks)
}
