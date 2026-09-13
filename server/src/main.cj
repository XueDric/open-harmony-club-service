package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 入口：serve / init-admin / test
 *
 * 构建：server/build.ps1（cjc 1.1.3 + stdx 1.1.3.1 + 轻舟源码同包编译）
 *
 * 部署约束（deploy-windows-verify.md §3）：
 *   · **cwd 必须是 exe 所在目录**——数据目录与证书都按相对路径读
 *   · 4 个 DLL 必须与 exe 同目录（含两个 OpenSSL 3 DLL，缺失时 crypto 运行时才报错）
 */

import std.collection.*
import std.convert.*
import std.fs.*
import stdx.encoding.json.*

/* 运行期参数（当前用默认值；服务器信息到位后再接配置文件） */
public class Options {
    public var data_dir: String = "data"
    public var port: UInt16 = 8080
    public var cert_pem: String = "certs/cert.pem"
    public var key_pem: String = "certs/key.pem"

    public init() {}
}

/* 用对象持有 ServerHandle：闭包捕获 var 的语义不可靠，这里显式放进盒子里。 */
class HandleBox {
    public var handle: ?ServerHandle = None

    init() {}
}

func usage(): Unit {
    println("社团管理工具 · 服务端 v${APP_VERSION}")
    println("")
    println("用法:")
    println("  club-server init-admin <手机号> <初始密码> [数据目录]   初始化首任会长与 4 个组织（仅空库可执行）")
    println("  club-server serve [端口] [数据目录]                    启动 HTTP 服务（默认 8080 / data）")
    println("  club-server test                                       运行单测")
    println("")
    println("数据目录默认 data/（相对当前工作目录）。冒烟测试用独立目录，避免碰正式数据。")
}

/* 加载数据；失败就退出——绝不带着空库继续跑。 */
func loadOrExit(dir: String): ?Store {
    try {
        return Some(storeLoad(dir))
    } catch (e: Exception) {
        println("[FATAL] ${e.message}")
        return None
    }
}

/* 预置 4 个组织（v1-scope §5，可改名） */
func seedDepartments(s: Store): Unit {
    let names = ["主席团", "课题部", "运营部", "宣传部"]
    var i: Int64 = 0
    while (i < names.size) {
        let d = Department()
        d.id = s.next_dept
        s.next_dept += 1
        d.name = names[i]
        d.sort = i
        s.departments[d.id] = d
        i += 1
    }
}

func deptIdByName(s: Store, name: String): Int64 {
    for ((_k, d) in s.departments) {
        if (d.name == name) {
            return d.id
        }
    }
    return 0
}

/*
 * 首任会长用**初始化命令**预置（api-design §2.8 决策 8），
 * 不采用"首个注册者自动成为会长"——那等于把社团管理权交给第一个扫码的人。
 */
func cmdInitAdmin(phone: String, pw: String, dir: String): Int64 {
    if (!isPhone(phone)) {
        println("手机号格式不正确（11 位，以 1 开头）")
        return 1
    }
    if (pw.size < 8) {
        println("初始密码至少 8 位")
        return 1
    }
    let loaded = loadOrExit(dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    s.lock.lock()
    try {
        if (presidentCount(s) > 0) {
            println("已存在会长账号：init-admin 只能对空库执行一次")
            return 1
        }
        if (memberByPhone(s, phone).isSome()) {
            println("该手机号已存在，不能重复初始化")
            return 1
        }
        if (s.departments.size == 0) {
            seedDepartments(s)
        }
        let now = nowEpoch()
        let m = Member()
        m.id = s.next_member
        s.next_member += 1
        m.name = "会长"
        m.phone = phone
        let rec = newPasswordRecord(pw)
        m.pw_salt = rec[0]
        m.pw_hash = rec[1]
        m.pw_iter = rec[2]
        m.role = "president"
        m.dept_id = deptIdByName(s, "主席团")
        m.status = "active"
        m.joined_at = now
        s.members[m.id] = m

        if (s.register_code.size == 0) {
            s.register_code = newRegisterCode()
            s.register_code_by = m.id
            s.register_code_at = now
        }
        storeSave(s)

        println("已创建首任会长：${phone}（成员 id=${m.id}，部门=${m.dept_id}）")
        println("当前注册口令：${s.register_code}")
        println("数据目录：${s.dir}（db.json）")
    } finally {
        s.lock.unlock()
    }
    return 0
}

/* 优雅关闭端点：仅本机可访问。 */
func handleShutdown(ctx: Context, box: HandleBox): Unit {
    if (!isLocalPeer(ctx)) {
        throw apiErrMsg("FORBIDDEN_ROLE", "该端点仅允许本机访问（来自 ${peerOf(ctx)}）")
    }
    let data = JsonObject()
    jPutStr(data, "status", "shutting-down")
    sendOk(ctx, data)
    /* 不能在请求线程里直接 shutdown()——那会等待本请求自己结束，形成死锁。
     * 交给后台线程，请求正常返回后再关。 */
    match (box.handle) {
        case Some(h) => spawn {
            h.shutdown()
        }
        case None => ()
    }
}

func buildApp(s: Store, box: HandleBox): QingZhouApp {
    let router = Router()
        /* 运维 */
        .get("/health", { ctx: Context, _: () -> Unit =>
            handleHealth(ctx)
        })
        .post("/admin/shutdown", { ctx: Context, _: () -> Unit =>
            handleShutdown(ctx, box)
        })
        /* Part 2 · 认证与注册 */
        .post("/api/v1/auth/register", { ctx: Context, _: () -> Unit =>
            handleRegister(ctx, s)
        })
        .post("/api/v1/auth/login", { ctx: Context, _: () -> Unit =>
            handleLogin(ctx, s)
        })
        .post("/api/v1/auth/logout", { ctx: Context, _: () -> Unit =>
            handleLogout(ctx, s)
        })
        .get("/api/v1/auth/me", { ctx: Context, _: () -> Unit =>
            handleMe(ctx, s)
        })
        .put("/api/v1/auth/password", { ctx: Context, _: () -> Unit =>
            handleChangePassword(ctx, s)
        })
        /* Part 3 · 组织与成员（19） */
        .get("/api/v1/depts", { ctx: Context, _: () -> Unit =>
            handleDeptList(ctx, s)
        })
        .post("/api/v1/depts", { ctx: Context, _: () -> Unit =>
            handleDeptCreate(ctx, s)
        })
        .patch("/api/v1/depts/:id", { ctx: Context, _: () -> Unit =>
            handleDeptUpdate(ctx, s)
        })
        .delete("/api/v1/depts/:id", { ctx: Context, _: () -> Unit =>
            handleDeptDelete(ctx, s)
        })
        .get("/api/v1/members", { ctx: Context, _: () -> Unit =>
            handleMemberList(ctx, s)
        })
        /* 静态段优先（router.cj 的 walk 先查 Static 再查 Param），
         * 但仍显式排在 :id 之前，避免将来换路由实现时踩坑。 */
        .get("/api/v1/members/pending", { ctx: Context, _: () -> Unit =>
            handleMemberPending(ctx, s)
        })
        .post("/api/v1/members/assign-batch", { ctx: Context, _: () -> Unit =>
            handleMemberAssignBatch(ctx, s)
        })
        .get("/api/v1/members/:id", { ctx: Context, _: () -> Unit =>
            handleMemberDetail(ctx, s)
        })
        .patch("/api/v1/members/:id", { ctx: Context, _: () -> Unit =>
            handleMemberUpdate(ctx, s)
        })
        .post("/api/v1/members/:id/disable", { ctx: Context, _: () -> Unit =>
            handleMemberDisable(ctx, s)
        })
        .post("/api/v1/members/:id/assign", { ctx: Context, _: () -> Unit =>
            handleMemberAssign(ctx, s)
        })
        .post("/api/v1/members/:id/transfer-presidency", { ctx: Context, _: () -> Unit =>
            handleTransferPresidency(ctx, s)
        })
        .post("/api/v1/members/:id/reset-password", { ctx: Context, _: () -> Unit =>
            handleResetPassword(ctx, s)
        })
        .get("/api/v1/register-config", { ctx: Context, _: () -> Unit =>
            handleRegisterConfigGet(ctx, s)
        })
        .put("/api/v1/register-config/code", { ctx: Context, _: () -> Unit =>
            handleRegisterConfigPut(ctx, s)
        })
        .post("/api/v1/register-config/rotate", { ctx: Context, _: () -> Unit =>
            handleRegisterConfigRotate(ctx, s)
        })
        .get("/api/v1/dept-invite-links", { ctx: Context, _: () -> Unit =>
            handleInviteLinkList(ctx, s)
        })
        .post("/api/v1/dept-invite-links", { ctx: Context, _: () -> Unit =>
            handleInviteLinkCreate(ctx, s)
        })
        .delete("/api/v1/dept-invite-links/:token", { ctx: Context, _: () -> Unit =>
            handleInviteLinkDisable(ctx, s)
        })
        /* Part 4 · 任务（8） */
        .get("/api/v1/tasks/mine", { ctx: Context, _: () -> Unit =>
            handleTasksMine(ctx, s)
        })
        .post("/api/v1/tasks/lookup", { ctx: Context, _: () -> Unit =>
            handleTaskLookup(ctx, s)
        })
        .get("/api/v1/tasks", { ctx: Context, _: () -> Unit =>
            handleTaskList(ctx, s)
        })
        .post("/api/v1/tasks", { ctx: Context, _: () -> Unit =>
            handleTaskCreate(ctx, s)
        })
        .get("/api/v1/tasks/:id", { ctx: Context, _: () -> Unit =>
            handleTaskDetail(ctx, s)
        })
        .patch("/api/v1/tasks/:id", { ctx: Context, _: () -> Unit =>
            handleTaskUpdate(ctx, s)
        })
        .put("/api/v1/tasks/:id/status", { ctx: Context, _: () -> Unit =>
            handleTaskStatus(ctx, s)
        })
        .delete("/api/v1/tasks/:id", { ctx: Context, _: () -> Unit =>
            handleTaskDelete(ctx, s)
        })

    /*
     * 统一错误出口：
     *   ApiError → 按错误码表落状态码与 {ok:false,error:{code,message,fields}}
     *   其它异常 → 记日志 + 500 INTERNAL，**不向客户端暴露堆栈**（api-design §1.3）
     */
    let errHandler: Middleware = { ctx: Context, _: () -> Unit =>
        match (ctx.err()) {
            case Some(e: ApiError) => sendError(ctx, e)
            case Some(e) =>
                println("[ERROR] ${ctx.method()} ${ctx.path()} -> ${e.message}")
                sendError(ctx, apiErr("INTERNAL"))
            case None => ()
        }
    }

    return QingZhouApp()
        .use(requestId())
        .use(logger())
        .use(bodyParser())
        .use(cors())
        .use(router.middleware())
        .use(timeout(15000))
        .onError(errHandler)
}

func cmdServe(port: UInt16, dir: String): Int64 {
    let loaded = loadOrExit(dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    if (presidentCount(s) == 0) {
        println("[WARN] 当前没有任何会长账号，请先执行：club-server init-admin <手机号> <初始密码>")
    }
    let box = HandleBox()
    let app = buildApp(s, box)
    println("社团管理工具 · 服务端 v${APP_VERSION}")
    println("监听 :${port}  数据目录 ${s.dir}  成员 ${s.members.size} 人  课题 ${s.plans.size} 个  任务 ${s.tasks.size} 个")
    let handle = app.serve(port)
    box.handle = Some(handle)
    handle.wait()
    println("服务已停止")
    return 0
}

main(args: Array<String>): Int64 {
    if (args.size == 0) {
        usage()
        return 1
    }
    if (args[0] == "test") {
        return runTests()
    }
    if (args[0] == "init-admin") {
        if (args.size < 3) {
            println("用法: club-server init-admin <手机号> <初始密码> [数据目录]")
            return 1
        }
        let dir = if (args.size > 3) {
            args[3]
        } else {
            "data"
        }
        return cmdInitAdmin(args[1], args[2], dir)
    }
    if (args[0] == "serve") {
        var port: UInt16 = 8080
        if (args.size > 1) {
            try {
                port = UInt16.parse(args[1])
            } catch (e: Exception) {
                println("端口不合法: ${args[1]}")
                return 1
            }
        }
        let dir = if (args.size > 2) {
            args[2]
        } else {
            "data"
        }
        return cmdServe(port, dir)
    }
    usage()
    return 1
}
