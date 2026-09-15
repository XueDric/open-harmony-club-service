package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 【本地适配 · 暂时性】轻舟 RbacStore 的数据层替换 —— 2026-09-14
 *
 * 背景
 *   轻舟升级到 3ea387e 后，框架的 src/store.cj 用 CangDB 存 RBAC 数据
 *   （users / roles / permissions / role_permissions），而 CangDB 的上游仓库
 *   （gitcode.com/BIT-FSSLab/CangDB）**只有 README、没有任何代码**，
 *   于是 `import cangdb.*` 编译不过，整个构建被卡住。
 *
 * 本文件的定位
 *   把那个数据层**对齐到我们项目自己的接口与原则**：
 *     · 持久化用**文件存储**（内存 + 原子落盘 JSON，先写 .tmp 再 rename），
 *       与 server/src/store.cj 完全同一套做法；项目原则是「不用数据库」（README 设计原则）
 *     · 公开 API 与轻舟原版**逐一对齐**（同名同签名），所以 rbac.cj 与 examples/admin.cj
 *       不需要任何改动就能编、能用
 *   即：只换数据层，不动调用方。
 *
 * 怎么撤销（拿到可用的 CangDB 之后）
 *   1. 删掉本文件
 *   2. server/build.ps1 的框架文件排除表去掉 'store.cj'
 *   3. 把轻舟的 src/store.cj 放回默认构建
 *
 * ⚠ 与 DEF-1 补丁同一个教训：这是**跟着上游文件走的适配**，上游再改 store.cj 时
 *    本文件会静默过期。升级轻舟后请重跑 server 的三套测试。
 *
 * 与轻舟原版的差异（只有一处语义变化，必须知道）
 *   · 原版 role_permissions 是一张 JOIN 表；本实现内部用 HashMap<roleId, Array<permId>>
 *     表达同一事实（对外 API 不暴露该表，行为一致）
 *   · close() 在原版是关库；本实现是"落盘 + 无操作"（文件存储没有连接可关）
 */

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/* 与轻舟 src/store.cj 完全一致的三个行类型。 */
public class UserRow {
    public let id: Int64
    public let username: String
    public let passwordHash: String
    public let roleId: Int64
    public init(id: Int64, username: String, passwordHash: String, roleId: Int64) {
        this.id = id
        this.username = username
        this.passwordHash = passwordHash
        this.roleId = roleId
    }
}

public class RoleRow {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

public class PermRow {
    public let id: Int64
    public let code: String
    public let name: String
    public init(id: Int64, code: String, name: String) {
        this.id = id
        this.code = code
        this.name = name
    }
}

/*
 * RBAC 数据访问层。公开 API 与轻舟 src/store.cj 的 RbacStore 逐一对齐。
 * path：JSON 文件路径（相对 cwd），与我们的数据目录约定一致。
 */
public class RbacStore {
    private let path: String
    private var users: HashMap<Int64, UserRow> = HashMap<Int64, UserRow>()
    private var roles: HashMap<Int64, RoleRow> = HashMap<Int64, RoleRow>()
    private var perms: HashMap<Int64, PermRow> = HashMap<Int64, PermRow>()
    /* roleId -> 该角色拥有的 permission id 列表（替代原版的 role_permissions JOIN 表） */
    private var rolePerms: HashMap<Int64, ArrayList<Int64>> = HashMap<Int64, ArrayList<Int64>>()

    public init(path: String) {
        this.path = path
        if (exists(path)) {
            load()
        }
        /* 首次打开才灌种子数据（与原版一致：admin/admin123、user/user123） */
        if (roles.size == 0) {
            seed()
            save()
        }
    }

    /* ===================== 与上游一致的公开 API ===================== */

    public func findUserByUsername(username: String): ?UserRow {
        for ((_k, u) in users) {
            if (u.username == username) {
                return Some(u)
            }
        }
        return None
    }

    public func findUserById(id: Int64): ?UserRow {
        return users.get(id)
    }

    public func listUsers(): ArrayList<UserRow> {
        let out = ArrayList<UserRow>()
        for ((_k, u) in users) {
            out.add(u)
        }
        return sortedUsers(out)
    }

    public func createUser(username: String, passwordHash: String, roleId: Int64): Int64 {
        let id = nextUserId()
        users[id] = UserRow(id, username, passwordHash, roleId)
        save()
        return id
    }

    public func deleteUser(id: Int64): Bool {
        if (!users.contains(id)) {
            return false
        }
        users.remove(id)
        save()
        return true
    }

    public func listRoles(): ArrayList<RoleRow> {
        let out = ArrayList<RoleRow>()
        for ((_k, r) in roles) {
            out.add(r)
        }
        return sortedRoles(out)
    }

    public func listPermissions(): ArrayList<PermRow> {
        let out = ArrayList<PermRow>()
        for ((_k, p) in perms) {
            out.add(p)
        }
        return sortedPerms(out)
    }

    public func roleNameOf(roleId: Int64): String {
        match (roles.get(roleId)) {
            case Some(r) => return r.name
            case None => return ""
        }
    }

    /* 用户 -> 角色 -> 权限，与原版一样是分步查询 + 应用层组合。 */
    public func permissionCodesOf(userId: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        let u = match (users.get(userId)) {
            case Some(x) => x
            case None => return out
        }
        match (rolePerms.get(u.roleId)) {
            case Some(pids) =>
                for (pid in pids) {
                    match (perms.get(pid)) {
                        case Some(p) => out.add(p.code)
                        case None => ()
                    }
                }
            case None => ()
        }
        return out
    }

    public func hasPermission(userId: Int64, code: String): Bool {
        for (c in permissionCodesOf(userId)) {
            if (c == code) {
                return true
            }
        }
        return false
    }

    /* 原版关库；文件存储没有连接可关，这里落盘即可。 */
    public func close(): Unit {
        save()
    }

    /* ===================== 种子数据（与上游同一份） ===================== */

    private func seed(): Unit {
        roles[1] = RoleRow(1, "admin")
        roles[2] = RoleRow(2, "user")
        perms[1] = PermRow(1, "user:list", "查看用户")
        perms[2] = PermRow(2, "user:create", "创建用户")
        perms[3] = PermRow(3, "user:delete", "删除用户")
        perms[4] = PermRow(4, "role:list", "查看角色")
        perms[5] = PermRow(5, "perm:list", "查看权限")
        perms[6] = PermRow(6, "dashboard:view", "查看仪表盘")
        /* admin 角色拥有全部 6 个权限 */
        let adminPerms = ArrayList<Int64>()
        var i: Int64 = 1
        while (i <= 6) {
            adminPerms.add(i)
            i += 1
        }
        rolePerms[1] = adminPerms
        /* user 角色仅有 dashboard:view */
        let userPerms = ArrayList<Int64>()
        userPerms.add(6)
        rolePerms[2] = userPerms
        /* 两个内置账号，口令哈希与原版同盐同轮数 */
        users[1] = UserRow(1, "admin", hashPassword("admin123", "qz2026", 1000), 1)
        users[2] = UserRow(2, "user", hashPassword("user123", "qz2026", 1000), 2)
    }

    private func nextUserId(): Int64 {
        var mx: Int64 = 0
        for ((k, _u) in users) {
            if (k > mx) {
                mx = k
            }
        }
        return mx + 1
    }

    /* 原版是 `ORDER BY id`：这里按 id 升序。规模很小，插入排序足够。 */
    private func sortedUsers(a: ArrayList<UserRow>): ArrayList<UserRow> {
        let arr = a.toArray()
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].id > cur.id) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
            i += 1
        }
        let out = ArrayList<UserRow>()
        for (x in arr) {
            out.add(x)
        }
        return out
    }

    private func sortedRoles(a: ArrayList<RoleRow>): ArrayList<RoleRow> {
        let arr = a.toArray()
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].id > cur.id) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
            i += 1
        }
        let out = ArrayList<RoleRow>()
        for (x in arr) {
            out.add(x)
        }
        return out
    }

    private func sortedPerms(a: ArrayList<PermRow>): ArrayList<PermRow> {
        let arr = a.toArray()
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].id > cur.id) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
            i += 1
        }
        let out = ArrayList<PermRow>()
        for (x in arr) {
            out.add(x)
        }
        return out
    }

    /* ===================== 文件存储（与 server/src/store.cj 同一套做法） ===================== */

    private func load(): Unit {
        let text = String.fromUtf8(File.readFrom(path))
        var root: ?JsonObject = None
        try {
            root = Some(JsonValue.fromStr(text).asObject())
        } catch (e: Exception) {
            root = None
        }
        var r: JsonObject
        match (root) {
            case Some(x) => r = x
            /* 与 store.cj 同一口径：解析失败绝不当成空库，否则下次保存会覆盖真实数据 */
            case None => throw Exception("RBAC 数据文件无法解析：${path}")
        }
        users = HashMap<Int64, UserRow>()
        roles = HashMap<Int64, RoleRow>()
        perms = HashMap<Int64, PermRow>()
        rolePerms = HashMap<Int64, ArrayList<Int64>>()

        for (o in objArr(r, "users")) {
            let id = reqIntOr(o, "id", 0)
            users[id] = UserRow(id, reqStrOr(o, "username", ""), reqStrOr(o, "password_hash", ""),
                reqIntOr(o, "role_id", 0))
        }
        for (o in objArr(r, "roles")) {
            let id = reqIntOr(o, "id", 0)
            roles[id] = RoleRow(id, reqStrOr(o, "name", ""))
        }
        for (o in objArr(r, "permissions")) {
            let id = reqIntOr(o, "id", 0)
            perms[id] = PermRow(id, reqStrOr(o, "code", ""), reqStrOr(o, "name", ""))
        }
        for (o in objArr(r, "role_permissions")) {
            let rid = reqIntOr(o, "role_id", 0)
            let pid = reqIntOr(o, "permission_id", 0)
            var list: ArrayList<Int64>
            match (rolePerms.get(rid)) {
                case Some(x) => list = x
                case None =>
                    list = ArrayList<Int64>()
                    rolePerms[rid] = list
            }
            list.add(pid)
        }
    }

    public func save(): Unit {
        let root = JsonObject()
        let ua = JsonArray()
        for ((_k, u) in users) {
            let o = JsonObject()
            jPutInt(o, "id", u.id)
            jPutStr(o, "username", u.username)
            jPutStr(o, "password_hash", u.passwordHash)
            jPutInt(o, "role_id", u.roleId)
            ua.add(o)
        }
        root.put("users", ua)
        let ra = JsonArray()
        for ((_k, r) in roles) {
            let o = JsonObject()
            jPutInt(o, "id", r.id)
            jPutStr(o, "name", r.name)
            ra.add(o)
        }
        root.put("roles", ra)
        let pa = JsonArray()
        for ((_k, p) in perms) {
            let o = JsonObject()
            jPutInt(o, "id", p.id)
            jPutStr(o, "code", p.code)
            jPutStr(o, "name", p.name)
            pa.add(o)
        }
        root.put("permissions", pa)
        let rpa = JsonArray()
        for ((rid, pids) in rolePerms) {
            for (pid in pids) {
                let o = JsonObject()
                jPutInt(o, "role_id", rid)
                jPutInt(o, "permission_id", pid)
                rpa.add(o)
            }
        }
        root.put("role_permissions", rpa)

        /* 原子落盘：先写 .tmp 再 rename，与 server/src/store.cj 同一口径 */
        let dir = parentDir(path)
        if (dir.size > 0 && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let tmp = path + ".tmp"
        File.writeTo(tmp, root.toString().toArray())
        rename(tmp, to: path, overwrite: true)
    }

    /* JSON 对象数组；缺失或类型不对时返回空（与 store.cj 的 arrOf 同义）。 */
    private func objArr(o: JsonObject, key: String): ArrayList<JsonObject> {
        let out = ArrayList<JsonObject>()
        match (jsonGetArray(o, key)) {
            case Some(a) =>
                var i: Int64 = 0
                let n = a.size()
                while (i < n) {
                    match (a.get(i)) {
                        case Some(v) =>
                            try {
                                out.add(v.asObject())
                            } catch (e: Exception) {
                                /* 逐条坏数据在这里跳过；load() 已在文件级做了"不静默降级" */
                                ()
                            }
                        case None => ()
                    }
                    i += 1
                }
            case None => ()
        }
        return out
    }

    private func parentDir(p: String): String {
        let b = p.toArray()
        var i = b.size - 1
        while (i >= 0) {
            if (b[i] == 47 || b[i] == 92) {
                return String.fromUtf8(b[0..i])
            }
            i -= 1
        }
        return ""
    }
}
