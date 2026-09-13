package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 入口：serve / init-admin / test
 *
 * 构建：server/build.ps1（cjc 1.1.3 + stdx 1.1.3.1 + 轻舟源码同包编译）
 *
 * 部署约束（..\docs\deploy-windows-verify.md §3）：
 *   · **cwd 必须是 exe 所在目录**——数据目录与证书都按相对路径读
 *   · 4 个 DLL 必须与 exe 同目录（含两个 OpenSSL 3 DLL，缺失时 crypto 运行时才报错）
 */

import std.collection.*
import std.convert.*
import std.fs.*
import stdx.encoding.json.*


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
    println("  club-server serve-tls [端口] [数据目录] [证书] [私钥]  启动 HTTPS（默认 8443 / data / certs/cert.pem / certs/key.pem）")
    println("  club-server test                                       运行单测")
    println("")
    println("数据目录默认 data/（相对当前工作目录）。冒烟测试用独立目录，避免碰正式数据。")
    println("证书必须是**带 SAN** 的自签证书（现代客户端只看 subjectAltName，完全忽略 CN）。")
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
        /* 招募链接落地页（无需登录，L-2）。链接是发到群里的，点开必须有内容。 */
        .get("/join/:token", { ctx: Context, _: () -> Unit =>
            handleJoinLanding(ctx, s)
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
        /* Part 5 · 课题（6） */
        .get("/api/v1/plans", { ctx: Context, _: () -> Unit =>
            handlePlanTree(ctx, s)
        })
        .post("/api/v1/plans", { ctx: Context, _: () -> Unit =>
            handlePlanCreate(ctx, s)
        })
        .get("/api/v1/plans/:id", { ctx: Context, _: () -> Unit =>
            handlePlanDetail(ctx, s)
        })
        .patch("/api/v1/plans/:id", { ctx: Context, _: () -> Unit =>
            handlePlanUpdate(ctx, s)
        })
        .post("/api/v1/plans/:id/move", { ctx: Context, _: () -> Unit =>
            handlePlanMove(ctx, s)
        })
        .delete("/api/v1/plans/:id", { ctx: Context, _: () -> Unit =>
            handlePlanDelete(ctx, s)
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

    /*
     * 中间件顺序说明（P1 M-5）：timeout 原先写在 router.middleware() **之后**，
     * 那是错的位置。轻舟的 use() 按注册顺序串成洋葱，先注册的在**外层**；
     * 而 router 命中路由后是直接 `h(ctx, next)` 调用 handler，我们的 handler 从不调 next()，
     * 因此排在 router 后面的 timeout 中间件**一次都没有被执行过**——
     * 它既没计时，也没机会发 408。
     * 移到 router 之前（外层）才会真正参与：dispatch 前后各计一次时。
     *
     * 即便如此也要说清楚它的能力边界（读 timeout.cj 的实现）：它是"事后软超时"，
     * 只能在 handler 返回后判断是否超时，**无法中断**已经跑起来的同步 handler。
     * 真正的防线是 handler 里不做慢操作；这一层是给将来不留神写出的慢路径兜底。
     */
    return QingZhouApp()
        .use(requestId())
        .use(logger())
        .use(bodyParser())
        .use(cors())
        .use(timeout(15000))
        .use(router.middleware())
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

/*
 * HTTPS 启动。
 *
 * 轻舟的 serveTls(port, certPem, keyPem) 收的是 **PEM 字符串**而不是文件路径，
 * 因此读文件、异常处理都在调用方（见 ..\docs\qingzhou-tls-verification.md 第 3 节的责任转移）。
 *
 * ⚠ 绝不静默降级：证书或私钥读不到、解析失败时**直接退出**，
 * 不允许 catch 之后回退到明文 serve()——那会让"HTTPS 没起来"变成静默的明文服务。
 */
func cmdServeTls(port: UInt16, dir: String, certPath: String, keyPath: String): Int64 {
    let loaded = loadOrExit(dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    if (presidentCount(s) == 0) {
        println("[WARN] 当前没有任何会长账号，请先执行：club-server init-admin <手机号> <初始密码>")
    }
    if (!exists(certPath)) {
        println("[FATAL] 找不到证书：${certPath}")
        return 1
    }
    if (!exists(keyPath)) {
        println("[FATAL] 找不到私钥：${keyPath}")
        return 1
    }
    var certPem = ""
    var keyPem = ""
    try {
        certPem = String.fromUtf8(File.readFrom(certPath))
        keyPem = String.fromUtf8(File.readFrom(keyPath))
    } catch (e: Exception) {
        println("[FATAL] 证书或私钥读取失败：${e.message}")
        return 1
    }

    let box = HandleBox()
    let app = buildApp(s, box)
    println("社团管理工具 · 服务端 v${APP_VERSION}  (HTTPS)")
    println("监听 :${port}  数据目录 ${s.dir}  成员 ${s.members.size} 人")
    println("证书 ${certPath}")
    println("私钥 ${keyPath}（内容不会写入日志）")

    var handle: ?ServerHandle = None
    try {
        handle = Some(app.serveTls(port, certPem, keyPem))
    } catch (e: Exception) {
        println("[FATAL] TLS 启动失败：${e.message}")
        println("        （PEM 无法解析时框架会抛异常；这里不做任何明文回退）")
        return 1
    }
    match (handle) {
        case Some(h) =>
            box.handle = Some(h)
            h.wait()
        case None => return 1
    }
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
    if (args[0] == "serve-tls") {
        var port: UInt16 = 8443
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
        let certPath = if (args.size > 3) {
            args[3]
        } else {
            "certs/cert.pem"
        }
        let keyPath = if (args.size > 4) {
            args[4]
        } else {
            "certs/key.pem"
        }
        return cmdServeTls(port, dir, certPath, keyPath)
    }
    usage()
    return 1
}
