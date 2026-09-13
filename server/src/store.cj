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

/* ===================== Store ===================== */

public class Store {
    public let dir: String
    public let lock: Mutex = Mutex()

    public var departments: HashMap<Int64, Department> = HashMap<Int64, Department>()
    public var members: HashMap<Int64, Member> = HashMap<Int64, Member>()
    public var plans: HashMap<Int64, Plan> = HashMap<Int64, Plan>()
    public var tasks: HashMap<Int64, Task> = HashMap<Int64, Task>()
    public var invite_links: HashMap<String, DeptInviteLink> = HashMap<String, DeptInviteLink>()
    public var tokens: HashMap<String, TokenRecord> = HashMap<String, TokenRecord>()
    public var idem: HashMap<String, IdemRecord> = HashMap<String, IdemRecord>()
    public var login_fail: HashMap<String, LoginFail> = HashMap<String, LoginFail>()

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
            s.departments = deptArrFromJson(r, "departments")
            s.members = memberArrFromJson(r, "members")
            s.plans = planArrFromJson(r, "plans")
            s.tasks = taskArrFromJson(r, "tasks")
            s.invite_links = linkArrFromJson(r, "invite_links")
            s.tokens = tokenArrFromJson(r, "tokens")
            s.login_fail = loginFailArrFromJson(r, "login_fail")
            s.idem = idemArrFromJson(r, "idem")
            return s
        case None =>
            /* 绝不静默降级为空库：下一次保存会把真实数据覆盖掉。 */
            throw Exception("数据文件无法解析，已停止启动以免覆盖数据：${file}")
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

func loginFailArrFromJson(o: JsonObject, key: String): HashMap<String, LoginFail> {
    let m = HashMap<String, LoginFail>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let obj = v.asObject()
                    let phone = reqStrOr(obj, "phone", "")
                    let lf = LoginFail()
                    lf.count = reqIntOr(obj, "count", 0)
                    lf.first_at = reqIntOr(obj, "first_at", 0)
                    lf.locked_until = reqIntOr(obj, "locked_until", 0)
                    if (phone.size > 0) {
                        m[phone] = lf
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

/*
 * 原子落盘：写 tmp → 备份旧文件 → rename 覆盖。
 * 任何一步失败都抛异常（宁可让调用方看到错误，也不要"看起来保存成功了"）。
 */
public func storeSave(s: Store): Unit {
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

    let fails = JsonArray()
    for ((k, f) in s.login_fail) {
        let o = JsonObject()
        jPutStr(o, "phone", k)
        jPutInt(o, "count", f.count)
        jPutInt(o, "first_at", f.first_at)
        jPutInt(o, "locked_until", f.locked_until)
        fails.add(o)
    }
    root.put("login_fail", fails)

    let idems = JsonArray()
    for ((k, r) in s.idem) {
        idems.add(idemToJson(k, r))
    }
    root.put("idem", idems)

    let text = root.toString()
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

/* ===================== 查询辅助 ===================== */

public func memberById(s: Store, id: Int64): ?Member {
    return s.members.get(id)
}

public func memberByPhone(s: Store, phone: String): ?Member {
    for ((_k, m) in s.members) {
        if (m.phone == phone) {
            return Some(m)
        }
    }
    return None
}

public func deptById(s: Store, id: Int64): ?Department {
    return s.departments.get(id)
}

public func planById(s: Store, id: Int64): ?Plan {
    return s.plans.get(id)
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

/* 按 Int64 键做插入排序。社团规模（几十~几百条），够用且无额外依赖。 */
func sortByKey<T>(arr: Array<T>, key: (T) -> Int64): Unit {
    var i: Int64 = 1
    while (i < arr.size) {
        let cur = arr[i]
        let ck = key(cur)
        var j: Int64 = i - 1
        while (j >= 0 && key(arr[j]) > ck) {
            arr[j + 1] = arr[j]
            j -= 1
        }
        arr[j + 1] = cur
        i += 1
    }
}

/* 部门展示顺序：sort → id。 */
public func sortedDepartments(s: Store): Array<Department> {
    let out = ArrayList<Department>()
    for ((_k, d) in s.departments) {
        out.add(d)
    }
    let arr = out.toArray()
    sortByKey<Department>(arr, { d: Department => d.sort * 1000000 + d.id })
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
        ds * 1000000 + m.id
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

func idemKey(kind: String, token: String): String {
    return "${kind}:${token}"
}

/* 24 小时内命中则返回首次创建的资源 id。 */
public func idemHit(s: Store, kind: String, token: String, now: Int64): ?Int64 {
    let k = idemKey(kind, token)
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

public func idemPut(s: Store, kind: String, token: String, resourceId: Int64, now: Int64): Unit {
    let rec = IdemRecord()
    rec.resource_id = resourceId
    rec.created_at = now
    s.idem[idemKey(kind, token)] = rec
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
