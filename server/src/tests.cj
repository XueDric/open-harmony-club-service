package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 单测：main.exe test
 *
 * 只测**纯逻辑**（时间、口令、权限、落盘）——它们能脱离 HTTP 运行，
 * 也正是最容易错、错了最难发现的部分。接口层的行为由
 * tests/smoke.ps1 打真实 HTTP 覆盖（集成证据）。
 *
 * 时间用**独立实现算出的锚点**对拍：锚点由 .NET DateTimeOffset 生成，
 * 与本项目代码无任何共享逻辑，因此能真正发现历法算错。
 */

import std.collection.*
import std.fs.*
import stdx.encoding.hex.*
import stdx.encoding.json.*

class TR {
    public var pass: Int64 = 0
    public var fail: Int64 = 0

    public init() {}

    public func ok(name: String, cond: Bool): Unit {
        if (cond) {
            pass += 1
        } else {
            fail += 1
            println("  FAIL ${name}")
        }
    }

    public func eqs(name: String, got: String, want: String): Unit {
        if (got == want) {
            pass += 1
        } else {
            fail += 1
            println("  FAIL ${name}\n       got  [${got}]\n       want [${want}]")
        }
    }

    public func eqi(name: String, got: Int64, want: Int64): Unit {
        if (got == want) {
            pass += 1
        } else {
            fail += 1
            println("  FAIL ${name}\n       got  ${got}\n       want ${want}")
        }
    }
}

/* ===================== 时间 ===================== */

func testTime(t: TR): Unit {
    println("- timex 时间与时区")
    /* 锚点：由 .NET DateTimeOffset 独立算出（+08:00 口径） */
    t.eqs("isoLocal(0)", isoLocal(0), "1970-01-01T08:00:00+08:00")
    t.eqs("isoLocal(1e9)", isoLocal(1000000000), "2001-09-09T09:46:40+08:00")
    t.eqs("isoLocal(闰日)", isoLocal(1709179200), "2024-02-29T12:00:00+08:00")
    t.eqs("isoLocal(2026元旦)", isoLocal(1767196800), "2026-01-01T00:00:00+08:00")
    t.eqs("isoUtc(2e9)", isoUtc(2000000000), "2033-05-18T03:33:20Z")

    t.eqi("parseIso(+08:00)", parseIso("2026-09-20T18:00:00+08:00") ?? -1, 1789898400)
    t.eqi("parseIso(Z)", parseIso("2001-09-09T01:46:40Z") ?? -1, 1000000000)
    t.eqi("parseIso(无偏移=+08)", parseIso("2026-09-20T18:00:00") ?? -1, 1789898400)
    t.eqi("parseIso(空格分隔)", parseIso("2026-09-20 18:00:00") ?? -1, 1789898400)
    t.eqi("parseIso(仅日期)", parseIso("2026-09-20") ?? -1, 1789833600)
    t.eqi("parseIso(+00:00 = 同一时刻)", parseIso("2026-09-20T10:00:00+00:00") ?? -1, 1789898400)
    t.eqi("parseIso(负偏移 -08:00)", parseIso("2026-09-20T00:00:00-08:00") ?? -1, 1789891200)
    t.eqi("parseIso(+08:00 同日更早)", parseIso("2026-09-20T02:00:00+08:00") ?? -1, 1789840800)
    t.ok("parseIso(斜杠)=None", parseIso("2026/09/20").isNone())
    t.ok("parseIso(空)=None", parseIso("").isNone())
    t.ok("parseIso(乱)=None", parseIso("不是时间").isNone())
    t.ok("parseIso(月越界)=None", parseIso("2026-13-01T00:00:00+08:00").isNone())

    /* P1 M-6：ArkTS/JS 的 toISOString() 带毫秒，必须收 */
    t.eqi("parseIso(小数秒 .307Z)", parseIso("2026-09-20T10:00:00.307Z") ?? -1, 1789898400)
    t.eqi("parseIso(小数秒 +08:00)", parseIso("2026-09-20T18:00:00.5+08:00") ?? -1, 1789898400)
    t.eqi("parseIso(小数秒 无偏移)", parseIso("2026-09-20T18:00:00.123456") ?? -1, 1789898400)
    t.ok("parseIso(只有点没数字)=None", parseIso("2026-09-20T18:00:00.Z").isNone())
    /* P2 L-5：历法上不存在的日期必须拒绝，不能静默顺延 */
    t.ok("parseIso(2月30日)=None", parseIso("2026-02-30T00:00:00+08:00").isNone())
    t.ok("parseIso(平年2月29日)=None", parseIso("2026-02-29T00:00:00+08:00").isNone())
    t.eqi("parseIso(闰年2月29日) 有效", parseIso("2024-02-29T12:00:00+08:00") ?? -1, 1709179200)
    t.ok("parseIso(4月31日)=None", parseIso("2026-04-31T00:00:00+08:00").isNone())
    t.ok("parseIso(0日)=None", parseIso("2026-04-00T00:00:00+08:00").isNone())

    t.eqi("startOfLocalDay", startOfLocalDay(1789898400), 1789833600)
    t.eqi("startOfLocalDay(0)", startOfLocalDay(0), -28800)

    t.ok("逾期", isOverdue(100, 200))
    t.ok("无截止不算逾期", !isOverdue(0, 200))
    t.ok("未到期不算逾期", !isOverdue(300, 200))

    /* 400 天连续往返：历法算错会在某一天暴露 */
    var i: Int64 = 1600000000
    var good = true
    while (i < 1600000000 + 400 * 86400) {
        match (parseIso(isoLocal(i))) {
            case Some(x) =>
                if (x != i) {
                    good = false
                }
            case None => good = false
        }
        i += 86400 + 137
    }
    t.ok("400 天 ISO 往返", good)
}

/* ===================== 字符串 ===================== */

func testStr(t: TR): Unit {
    println("- strx 字符串与手机号")
    t.ok("startsWith", startsWithAscii("Bearer abc", "Bearer "))
    t.ok("startsWith 否", !startsWithAscii("bearer", "Bearer "))
    t.ok("contains", containsAscii("addr=127.0.0.1:5000", "127.0.0.1"))
    t.ok("contains 否", !containsAscii("addr=10.0.0.1", "127.0.0.1"))
    t.eqs("subFrom", subFrom("Bearer abc", 7), "abc")
    t.ok("isBlank", isBlank("   "))
    t.ok("非 blank", !isBlank(" x "))
    t.ok("phone 合法", isPhone("13800000000"))
    t.ok("phone 位数", !isPhone("1380000000"))
    t.ok("phone 首位", !isPhone("23800000000"))
    t.ok("phone 非数字", !isPhone("1380000000a"))
    t.ok("phone 空", !isPhone(""))

    /* L-6：定时安全比较 —— 语义必须与 == 一致，且长度不同也不能误判为相等 */
    t.ok("constantTimeEq 相等", constantTimeEq("ABC123", "ABC123"))
    t.ok("constantTimeEq 末位不同", !constantTimeEq("ABC123", "ABC124"))
    t.ok("constantTimeEq 首位不同", !constantTimeEq("ABC123", "XBC123"))
    t.ok("constantTimeEq 长度不同", !constantTimeEq("ABC123", "ABC1234"))
    t.ok("constantTimeEq 空串相等", constantTimeEq("", ""))
    t.ok("constantTimeEq 空与非空", !constantTimeEq("", "a"))
    t.ok("constantTimeEq 中文", constantTimeEq("社团口令", "社团口令"))
    t.ok("constantTimeEq 中文不同", !constantTimeEq("社团口令", "社团口另"))
}

/* ===================== 随机 ===================== */

func testIds(t: TR): Unit {
    println("- ids 随机与口令")
    t.eqi("token 长度", newToken().size, 64)
    t.ok("token 唯一", newToken() != newToken())
    t.eqi("注册口令长度", newRegisterCode().size, 6)
    t.eqi("临时密码长度", newTempPassword().size, 8)
    let alpha = CODE_ALPHABET
    var i: Int64 = 0
    var allIn = true
    while (i < 50) {
        let c = randCode(8)
        var j: Int64 = 0
        let cb = c.toArray()
        while (j < cb.size) {
            if (!containsAscii(alpha, String.fromUtf8(Array<UInt8>(1, repeat: cb[j])))) {
                allIn = false
            }
            j += 1
        }
        i += 1
    }
    t.ok("口令字母表不越界", allIn)
    var k: Int64 = 0
    var inRange = true
    while (k < 200) {
        let r = randBelow(10)
        if (r < 0 || r >= 10) {
            inRange = false
        }
        k += 1
    }
    t.ok("randBelow 范围", inRange)
    t.eqi("randBelow(1)", randBelow(1), 0)
}

/* ===================== 口令 ===================== */

func testPassword(t: TR): Unit {
    println("- auth 口令哈希")
    /* RFC 7914 §11 的 PBKDF2-HMAC-SHA256 公开测试向量 */
    let v1 = toHexString(pbkdf2Sha256("passwd".toArray(), "salt".toArray(), 1, 64))
    t.eqs("RFC7914 向量1", v1, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    let v2 = toHexString(pbkdf2Sha256("Password".toArray(), "NaCl".toArray(), 80000, 64))
    t.eqs("RFC7914 向量2", v2, "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
    /* 正式参数（100k）与 .NET Rfc2898DeriveBytes 对拍 */
    let v3 = toHexString(pbkdf2Sha256("password".toArray(), "saltSALT".toArray(), 100000, 32))
    t.eqs("100k 对拍 .NET", v3, "5c809e359c03e25b885cf90db237fdea07be535f27a2d4064ae719b6f2996aaa")

    let rec = newPasswordRecord("abc12345")
    t.ok("正确口令通过", verifyPw("abc12345", rec[0], rec[1], rec[2]))
    t.ok("错误口令拒绝", !verifyPw("abc12346", rec[0], rec[1], rec[2]))
    t.ok("空盐拒绝", !verifyPw("abc12345", "", rec[1], rec[2]))
    t.ok("迭代为0拒绝", !verifyPw("abc12345", rec[0], rec[1], 0))
    t.eqi("迭代次数", rec[2], PBKDF2_ITER)
    /* 同一口令两次的盐必须不同 */
    let rec2 = newPasswordRecord("abc12345")
    t.ok("盐随机", rec[0] != rec2[0])
}

/* ===================== 落盘 ===================== */

func testStore(t: TR): Unit {
    println("- store 落盘与加载")
    let dir = "build/test-data"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = Store(dir)

    let d = Department()
    d.id = 1
    d.name = "课题部"
    d.sort = 1
    s.departments[1] = d

    let m = Member()
    m.id = 1
    m.name = "张三"
    m.phone = "13800000000"
    m.pw_salt = "aa"
    m.pw_hash = "bb"
    m.pw_iter = 100000
    m.role = "member"
    m.dept_id = 1
    m.status = "active"
    m.joined_at = 1789898400
    s.members[1] = m
    s.next_member = 2

    let p = Plan()
    p.id = 1
    p.title = "2026 招新"
    p.owner_id = 1
    p.dept_id = 1
    p.created_at = 1789898400
    s.plans[1] = p

    let x = Task()
    x.id = 1
    x.title = "联系场地"
    x.desc = "需确认容纳人数"
    x.owner_id = 1
    x.plan_id = 1
    x.dept_id = 1
    x.status = "doing"
    x.due_at = 1789898400
    x.created_by = 1
    x.created_at = 1789898400
    x.updated_at = 1789898400
    s.tasks[1] = x

    let tok = TokenRecord()
    tok.member_id = 1
    tok.created_at = 1789898400
    tok.expires_at = 1789898400 + 100
    s.tokens["abc"] = tok
    s.register_code = "K3M9P2"
    s.register_code_by = 1

    storeSaveNow(s)

    t.ok("db.json 已生成", exists(s.dbFile()))
    t.ok("tmp 已清理", !exists(s.dbFile() + ".tmp"))

    let l = storeLoad(dir)
    t.eqi("成员数", l.members.size, 1)
    t.eqi("部门数", l.departments.size, 1)
    match (l.members.get(1)) {
        case Some(mm) =>
            t.eqs("中文姓名往返", mm.name, "张三")
            t.eqs("手机号往返", mm.phone, "13800000000")
            t.eqi("口令迭代往返", mm.pw_iter, 100000)
            t.eqi("部门往返", mm.dept_id, 1)
        case None => t.ok("成员 1 存在", false)
    }
    match (l.plans.get(1)) {
        case Some(pp) => t.eqs("课题标题往返", pp.title, "2026 招新")
        case None => t.ok("课题 1 存在", false)
    }
    match (l.tasks.get(1)) {
        case Some(tt) =>
            t.eqs("任务状态往返", tt.status, "doing")
            t.eqs("任务描述中文往返", tt.desc, "需确认容纳人数")
        case None => t.ok("任务 1 存在", false)
    }
    match (l.departments.get(1)) {
        case Some(dd) => t.eqs("部门名往返", dd.name, "课题部")
        case None => t.ok("部门 1 存在", false)
    }
    match (l.tokens.get("abc")) {
        case Some(tr) => t.eqi("令牌成员往返", tr.member_id, 1)
        case None => t.ok("令牌存在", false)
    }
    t.eqs("注册口令往返", l.register_code, "K3M9P2")
    t.eqi("next_member 往返", l.next_member, 2)

    /* 备份文件：**第二次保存**时才会生成（第一次没有旧库可备份） */
    storeSaveNow(s)
    t.ok("bak 已生成（第二次保存）", exists(s.dbFile() + ".bak"))

    /* 坏库：必须报错，绝不静默降级为空库（否则下次保存会覆盖真实数据） */
    File.writeTo(s.dbFile(), "{ not json".toArray())
    var threw = false
    try {
        storeLoad(dir)
    } catch (e: Exception) {
        threw = true
    }
    t.ok("坏库必须报错", threw)

    /*
     * P1 M-7：**单条记录**坏掉也必须报错。
     * 原先每个元素的解析异常都被 catch 吞掉：文件里 2 个部门坏 1 个，
     * 服务照常启动，用户看到 1 个；下一次保存就把那 1 条永久覆盖。
     * 这里手写一个"数组里混了一个字符串"的库，要求 storeLoad 直接拒绝启动。
     */
    let good = storeLoad(dir + "-m7")
    storeSaveNow(good) /* 先建出目录，再用坏内容覆盖 db.json */
    let badJson = "{\"version\":1,\"departments\":[\"这不是一个部门对象\",{\"id\":1,\"name\":\"课题部\",\"sort\":0}],\"members\":[]}"
    File.writeTo(good.dbFile(), badJson.toArray())
    var threw2 = false
    try {
        storeLoad(dir + "-m7")
    } catch (e: Exception) {
        threw2 = true
    }
    t.ok("单条坏记录必须报错（M-7）", threw2)

    /*
     * N-5：idem 也要走 checkLoaded —— 它原先漏了，是 8 张表里唯一的例外。
     * 影响确实最小（24 小时 TTL 的幂等映射，丢一条最坏是客户端重试时多建一个资源），
     * 但"例外只存在于代码里"正是后人最容易踩的坑，所以把口径统一成一种。
     */
    let idemDir = dir + "-n5"
    let goodIdem = storeLoad(idemDir)
    storeSaveNow(goodIdem) /* 先建出目录，再用坏内容覆盖 db.json */
    let badIdem = "{\"version\":1,\"departments\":[],\"members\":[],\"idem\":[\"这不是一个幂等记录\"]}"
    File.writeTo(goodIdem.dbFile(), badIdem.toArray())
    var threw3 = false
    try {
        storeLoad(idemDir)
    } catch (e: Exception) {
        threw3 = true
    }
    t.ok("idem 坏记录也必须报错（N-5）", threw3)

    /* P1 M-3：限流状态不落盘 —— 保存后 db.json 里不应出现 login_fail */
    let lf = LoginFail()
    lf.count = 3
    lf.first_at = 1789898400
    s.login_fail["13800000000"] = lf
    storeSaveNow(s)
    let after = String.fromUtf8(File.readFrom(s.dbFile()))
    t.ok("login_fail 不落盘（M-3）", !containsAscii(after, "login_fail"))
    /* 但内存里仍然有效（限流照常工作） */
    t.ok("login_fail 仍在内存", s.login_fail.size == 1)

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    if (exists(dir + "-m7")) {
        remove(dir + "-m7", recursive: true)
    }
    if (exists(dir + "-n5")) {
        remove(dir + "-n5", recursive: true)
    }
}

/* ===================== 权限 ===================== */

func mkMember(id: Int64, role: String, dept: Int64): Member {
    let m = Member()
    m.id = id
    m.role = role
    m.dept_id = dept
    m.status = "active"
    return m
}

func testPerms(t: TR): Unit {
    println("- perms 权限判定")
    let pres = mkMember(1, "president", 1)
    let vp = mkMember(2, "vice_president", 1)
    let lead = mkMember(7, "lead", 2)
    let vice = mkMember(8, "vice_lead", 2)
    let mem = mkMember(9, "member", 2)
    let pending = mkMember(10, "", 0)
    pending.status = "pending"
    let disabled = mkMember(11, "member", 2)
    disabled.status = "disabled"

    let own = Target()
    own.dept_id = 2
    /* 目标档位：自己的部门里的一个普通成员。
     * 必须显式填 —— H-1 之后「档位」是权限判定的一部分，
     * target_role 留空会按"目标档位未知"一律拒绝。 */
    own.member_id = 9
    own.target_role = "member"
    let other = Target()
    other.dept_id = 3
    other.member_id = 90
    other.target_role = "member"
    let presTarget = Target()
    presTarget.member_id = 1
    presTarget.target_role = "president"
    presTarget.dept_id = 1
    let selfTask = Target()
    selfTask.is_self = true
    selfTask.owner_id = 9
    selfTask.dept_id = 3
    let creatorTask = Target()
    creatorTask.creator_id = 7
    creatorTask.dept_id = 3
    let ownedPlan = Target()
    ownedPlan.owner_id = 7
    ownedPlan.dept_id = 3

    /* 会长 */
    t.ok("会长移交", can(pres, Action.TransferPresidency, other))
    t.ok("会长建部门", can(pres, Action.ManageDept, other))
    t.ok("会长删部门", can(pres, Action.DeleteDept, other))
    t.ok("会长改会长本人", can(pres, Action.SetRole, presTarget))
    t.ok("会长跨部门建任务", can(pres, Action.CreateTask, other))

    /* 副会长：除移交与改动会长本人外同权 */
    t.ok("副会长不能移交", !can(vp, Action.TransferPresidency, other))
    t.ok("副会长不能改会长本人", !can(vp, Action.SetRole, presTarget))
    t.ok("副会长不能禁用会长", !can(vp, Action.DisableMember, presTarget))
    t.ok("副会长可改他人角色", can(vp, Action.SetRole, other))
    t.ok("副会长不能增改部门（会长独占）", !can(vp, Action.ManageDept, other))
    t.ok("副会长不能删部门（会长独占）", !can(vp, Action.DeleteDept, other))
    t.ok("副会长可看口令", can(vp, Action.ViewRegisterCode, other))
    t.ok("副会长不可换口令", !can(vp, Action.ChangeRegisterCode, other))
    t.ok("副会长可管招募链接", can(vp, Action.ManageInviteLink, other))
    t.ok("部长不能增改部门", !can(lead, Action.ManageDept, own))
    t.ok("部长不能删部门", !can(lead, Action.DeleteDept, own))

    /* 部长 / 副部长：同权，限本部门 */
    t.ok("部长本部门建任务", can(lead, Action.CreateTask, own))
    t.ok("部长跨部门建任务 拒", !can(lead, Action.CreateTask, other))
    t.ok("副部长与部长同权", can(vice, Action.CreateTask, own))
    t.ok("部长建部门 拒", !can(lead, Action.ManageDept, own))
    t.ok("部长调部门 拒", !can(lead, Action.SetRole, own))
    t.ok("部长审批 拒", !can(lead, Action.AssignPending, own))
    t.ok("部长改本部门成员姓名", can(lead, Action.EditMemberName, own))
    t.ok("部长改外部门成员姓名 拒", !can(lead, Action.EditMemberName, other))
    t.ok("部长建课题", can(lead, Action.CreatePlan, own))
    t.ok("部长移动课题", can(lead, Action.MovePlan, own))

    /*
     * P0 H-1：档位规则。上面第 372 行只测了「副会长不能改会长本人」，
     * 而漏洞出在**部长**分支——部长拿到同部门的会长目标时畅通无阻。
     * 注意这里的目标刻意取**同部门**（dept 2 = 部长自己那个部门），
     * 否则 403 会是 FORBIDDEN_NOT_IN_DEPT 挡下来的，测了个假绿灯。
     */
    let sameDeptPres = Target()
    sameDeptPres.member_id = 1
    sameDeptPres.target_role = "president"
    sameDeptPres.dept_id = 2
    let sameDeptVp = Target()
    sameDeptVp.member_id = 2
    sameDeptVp.target_role = "vice_president"
    sameDeptVp.dept_id = 2
    let sameDeptLead = Target()
    sameDeptLead.member_id = 5
    sameDeptLead.target_role = "lead"
    sameDeptLead.dept_id = 2
    let sameDeptMember = Target()
    sameDeptMember.member_id = 9
    sameDeptMember.target_role = "member"
    sameDeptMember.dept_id = 2
    /* 「另一位副会长」：member_id 刻意不等于任何操作者本人，用来测**同权之间**的约束。
     * （sameDeptVp 的 member_id=2 恰好就是 vp 自己，拿它测同权会测成"对自己"。） */
    let peerVp = Target()
    peerVp.member_id = 12
    peerVp.target_role = "vice_president"
    peerVp.dept_id = 1

    t.ok("部长改同部门会长姓名 拒（H-1）", !can(lead, Action.EditMemberName, sameDeptPres))
    t.ok("部长重置同部门会长密码 拒（H-1）", !can(lead, Action.ResetPassword, sameDeptPres))
    t.eqs("部长动会长的错误码是角色维度（H-1）",
        checkAccess(lead, Action.ResetPassword, sameDeptPres) ?? "", "FORBIDDEN_ROLE")
    t.ok("副部长同样改不了会长本人（H-1）", !can(vice, Action.EditMemberName, sameDeptPres))
    t.ok("部长改同部门副会长姓名 拒（H-1）", !can(lead, Action.EditMemberName, sameDeptVp))
    t.ok("部长重置同部门副会长密码 拒（H-1）", !can(lead, Action.ResetPassword, sameDeptVp))
    t.ok("部长改同部门另一位部长姓名 拒（同档）", !can(lead, Action.EditMemberName, sameDeptLead))
    t.ok("部长改同部门普通成员姓名 允许", can(lead, Action.EditMemberName, sameDeptMember))
    t.ok("部长重置同部门普通成员密码 允许", can(lead, Action.ResetPassword, sameDeptMember))
    t.ok("副会长改会长本人仍拒", !can(vp, Action.EditMemberName, sameDeptPres))
    /* 同权约束推广（2026-09-14）：改名 / 改角色 / 禁用也一律不可作用于同权或更高权的人。
     * 注意 sameDeptVp.member_id == vp.id == 2，对 vp 而言那是**自己**——原断言写作
     * "副会长可改另一位副会长"其实名不副实。现在拆成两条：改自己（自己例外，仍允许）
     * 与改另一位副会长（同权，拒）。 */
    t.ok("副会长改自己的角色（自己例外）", can(vp, Action.SetRole, sameDeptVp))
    t.ok("副会长改另一位副会长的角色 拒（同权）", !can(vp, Action.SetRole, peerVp))
    t.ok("副会长禁用另一位副会长 拒（同权）", !can(vp, Action.DisableMember, peerVp))
    t.ok("副会长改另一位副会长的姓名 拒（同权）", !can(vp, Action.EditMemberName, peerVp))
    t.ok("会长仍可改副会长的角色（未过度收紧）", can(pres, Action.SetRole, peerVp))
    t.ok("会长仍可禁用副会长（未过度收紧）", can(pres, Action.DisableMember, peerVp))
    /* N-7：「重置密码**不含本人**」这条约束只能由 checkAccess 的动作语义层拦住——
     * 会长与副会长的角色分支都是"直接放行"（roleAllows 里 president 一档 return true、
     * 副会长档只排除 president）。
     *
     * 注意 sameDeptPres.member_id == pres.id == 1，对 pres 而言它字面上就是"自己"：
     * 原先这里写的是 `can(pres, ResetPassword, sameDeptPres)` 且断言为 true，
     * 也就是"会长可以重置自己"——那正是 N-7 要修掉的行为（会把自己的令牌全部作废，
     * 表现为"响应 200、自己当场掉线"）。现在改用 sameDeptVp（member_id=2，是别人）
     * 来测"不受档位限制"。
     *
     * 同一对 Target 正好也覆盖副会长：sameDeptVp.member_id == vp.id == 2。 */
    t.ok("会长重置他人不受档位限制", can(pres, Action.ResetPassword, sameDeptVp))
    /* 通用规则：不可作用于与自己**同权或更高权**的人 —— N-7 只是它的特例
     * （对自己而言就是同权）。副会长之间互为同权，原先没有这条约束，
     * 副会长可以把另一位副会长重置下线 / 降级 / 禁用。 */
    t.ok("副会长重置另一位副会长（同权）拒", !can(vp, Action.ResetPassword, peerVp))
    t.eqs("同权被拒的错误码（动作语义层）",
        checkAccess(vp, Action.ResetPassword, peerVp) ?? "", "FORBIDDEN_ROLE")
    t.ok("会长重置副会长（更低档）允许", can(pres, Action.ResetPassword, peerVp))
    t.ok("副会长重置部长（更低档）允许", can(vp, Action.ResetPassword, sameDeptLead))
    t.ok("会长重置普通成员（更低档）允许", can(pres, Action.ResetPassword, sameDeptMember))
    /* N-10：assign / assign-batch 同样写 role 与 status，属成员处置类动作，
     * 必须受同一条同权约束（第一次推广时漏了它们，副会长据此仍可降级同权者，
     * 甚至把会长刚移出的同权副会长"复活"）。 */
    t.ok("副会长用 assign 降级另一位副会长 拒（N-10）", !can(vp, Action.AssignPending, peerVp))
    t.ok("会长用 assign 调整副会长 允许（未过度收紧）", can(pres, Action.AssignPending, peerVp))
    let pendingTgt = Target()
    pendingTgt.member_id = 20
    pendingTgt.target_role = ""        /* 待分配成员还没有角色（档位 0） */
    pendingTgt.dept_id = 0
    t.ok("副会长审批待分配成员 允许（N-10 未误拦 pending）", can(vp, Action.AssignPending, pendingTgt))
    t.ok("会长对自己重置 拒（N-7）", !can(pres, Action.ResetPassword, sameDeptPres))
    t.eqs("会长对自己重置的错误码（N-7）",
        checkAccess(pres, Action.ResetPassword, sameDeptPres) ?? "", "FORBIDDEN_ROLE")
    t.ok("副会长对自己重置 拒（N-7）", !can(vp, Action.ResetPassword, sameDeptVp))
    /* 目标档位未知时宁拒不放过 */
    let unknownRole = Target()
    unknownRole.dept_id = 2
    t.ok("目标档位未知 拒（防漏填 target_role）", !can(lead, Action.ResetPassword, unknownRole))

    /* 成员 */
    t.ok("成员看名录（全社团）", can(mem, Action.ViewMembers, other))
    t.ok("成员看本部门任务", can(mem, Action.ViewTasks, own))
    t.ok("成员看外部门任务 拒", !can(mem, Action.ViewTasks, other))
    t.ok("成员改自己任务状态（跨部门也行）", can(mem, Action.UpdateTaskStatus, selfTask))
    t.ok("成员改他人任务状态 拒", !can(mem, Action.UpdateTaskStatus, own))
    t.ok("成员建任务 拒", !can(mem, Action.CreateTask, own))
    t.ok("成员换口令 拒", !can(mem, Action.ChangeRegisterCode, own))
    t.ok("成员移交 拒", !can(mem, Action.TransferPresidency, other))

    /* 创建人 / 负责人条款：跨部门也成立 */
    t.ok("创建人可编辑任务（跨部门）", can(lead, Action.EditTask, creatorTask))
    t.ok("创建人可删除任务（跨部门）", can(lead, Action.DeleteTask, creatorTask))
    t.ok("负责人可编辑课题（跨部门）", can(lead, Action.EditPlan, ownedPlan))

    /* 状态维度 */
    t.ok("pending 一律拒绝", !can(pending, Action.ViewMembers, own))
    t.ok("disabled 一律拒绝", !can(disabled, Action.ViewMembers, own))
    t.eqs("pending 错误码", checkAccess(pending, Action.ViewMembers, own) ?? "", "MEMBER_PENDING")
    t.eqs("disabled 错误码", checkAccess(disabled, Action.ViewMembers, own) ?? "", "MEMBER_DISABLED")
    t.eqs("跨部门错误码", checkAccess(lead, Action.CreateTask, other) ?? "", "FORBIDDEN_NOT_IN_DEPT")
    t.eqs("角色错误码", checkAccess(mem, Action.CreateTask, own) ?? "", "FORBIDDEN_ROLE")

    /* 会长人数（规则 10） */
    let s = Store("build/test-data-perm")
    let m1 = mkMember(1, "president", 1)
    let m2 = mkMember(2, "lead", 2)
    s.members[1] = m1
    s.members[2] = m2
    t.eqi("会长人数=1", presidentCount(s), 1)
    let m3 = mkMember(3, "president", 1)
    s.members[3] = m3
    t.eqi("会长人数=2", presidentCount(s), 2)
    let m4 = mkMember(4, "president", 1)
    m4.status = "disabled"
    s.members[4] = m4
    t.eqi("禁用的会长不计入", presidentCount(s), 2)
}

/* ===================== 视图 ===================== */

func testViews(t: TR): Unit {
    println("- views 对外视图")
    let s = Store("build/test-data-views")
    let d = Department()
    d.id = 1
    d.name = "运营部"
    s.departments[1] = d

    let m = Member()
    m.id = 5
    m.name = "LiSi"
    m.phone = "13900000000"
    m.role = "lead"
    m.dept_id = 1
    m.status = "active"
    m.joined_at = 1767196800
    s.members[5] = m

    let brief = memberBrief(s, m).toString()
    t.ok("MemberBrief 不含手机号", !containsAscii(brief, "13900000000"))
    t.ok("MemberBrief 含姓名", containsAscii(brief, "LiSi"))
    t.ok("MemberBrief 含部门名", containsAscii(brief, "运营部"))

    let self = memberSelf(s, m).toString()
    t.ok("本人视图含手机号", containsAscii(self, "13900000000"))

    t.eqs("lead view_scope", jsonGetStr(permissionsOf(m), "view_scope") ?? "", "dept")
    t.ok("lead 不能设角色", (jsonGetBool(permissionsOf(m), "set_role") ?? true) == false)
    t.ok("lead 能建任务", (jsonGetBool(permissionsOf(m), "create_task") ?? false))

    let pres = mkMember(1, "president", 1)
    t.eqs("president view_scope", jsonGetStr(permissionsOf(pres), "view_scope") ?? "", "all")
    t.ok("president 能设角色", (jsonGetBool(permissionsOf(pres), "set_role") ?? false))

    /*
     * L-1：set_role 必须与真实权限一致。副会长**能**改他人角色（只有会长本人动不了），
     * 原先 permissionsOf 写死 role == "president"，客户端据此把副会长的角色入口藏了。
     */
    let vpView = mkMember(2, "vice_president", 1)
    t.ok("vice_president 能设角色（L-1）", (jsonGetBool(permissionsOf(vpView), "set_role") ?? false))
    t.ok("vice_president manage_members", (jsonGetBool(permissionsOf(vpView), "manage_members") ?? false))
    let viceView = mkMember(8, "vice_lead", 2)
    t.ok("vice_lead 不能设角色", (jsonGetBool(permissionsOf(viceView), "set_role") ?? true) == false)

    let mem = mkMember(9, "member", 2)
    t.eqs("member view_scope", jsonGetStr(permissionsOf(mem), "view_scope") ?? "", "dept")
    t.ok("member 不能改他人任务", (jsonGetBool(permissionsOf(mem), "update_any_task") ?? true) == false)

    let pend = mkMember(10, "", 0)
    pend.status = "pending"
    t.eqs("pending view_scope", jsonGetStr(permissionsOf(pend), "view_scope") ?? "", "none")
    t.ok("pending 无任何权限", (jsonGetBool(permissionsOf(pend), "create_task") ?? true) == false)

    t.ok("角色名合法", isKnownRole("vice_lead"))
    t.ok("角色名非法", !isKnownRole("admin"))
    t.eqs("角色中文名", roleLabel("vice_president"), "副会长")
}

/* ===================== Part 3 的视图与查询 ===================== */

func testPart3Views(t: TR): Unit {
    println("- views(Part3) 部门/成员/待分配/链接")
    let s = Store("build/test-data-p3")
    let d1 = Department()
    d1.id = 1
    d1.name = "主席团"
    d1.sort = 0
    let d2 = Department()
    d2.id = 2
    d2.name = "运营部"
    d2.sort = 2
    s.departments[1] = d1
    s.departments[2] = d2

    let pres = Member()
    pres.id = 1
    pres.name = "会长"
    pres.phone = "13800000000"
    pres.role = "president"
    pres.dept_id = 1
    pres.status = "active"
    pres.joined_at = 1767196800
    s.members[1] = pres

    let lead = Member()
    lead.id = 2
    lead.name = "部长"
    lead.phone = "13800000002"
    lead.role = "lead"
    lead.dept_id = 2
    lead.status = "active"
    lead.joined_at = 1767196800
    s.members[2] = lead

    let member = Member()
    member.id = 3
    member.name = "成员"
    member.phone = "13800000003"
    member.role = "member"
    member.dept_id = 2
    member.status = "active"
    member.joined_at = 1767196800
    s.members[3] = member

    let gone = Member()
    gone.id = 4
    gone.name = "已退出"
    gone.phone = "13800000004"
    gone.role = "member"
    gone.dept_id = 2
    gone.status = "disabled"
    gone.joined_at = 1767196800
    s.members[4] = gone

    let pend = Member()
    pend.id = 5
    pend.name = "新人"
    pend.phone = "13800000005"
    pend.status = "pending"
    pend.dept_hint = 2
    pend.joined_at = 1789898400
    s.members[5] = pend

    /* 部门视图：部长现查现算（没有 lead_id 字段） */
    let dv = deptView(s, d2).toString()
    t.ok("部门含部长姓名", containsAscii(dv, "部长"))
    t.ok("部门人数=2（active，不含已退出）", containsAscii(dv, "\"member_count\":2"))
    t.ok("部门不含手机号", !containsAscii(dv, "13800000002"))

    let dv1 = deptView(s, d1).toString()
    t.ok("主席团无部长时 lead 为 null", containsAscii(dv1, "\"lead\":null"))

    /* 部门顺序：sort 0 在 2 前面 */
    let ds = sortedDepartments(s)
    t.eqi("部门数", ds.size, 2)
    t.eqs("按 sort 排序", ds[0].name, "主席团")

    /*
     * P1 M-8：排序键必须对越界 sort 免疫。
     * 磁盘上可能已经有旧版本写下的超大 sort（那时接口不校验），
     * `sort * 1000000 + id` 会溢出成一个大负数，让排序结果颠倒甚至继续破坏后续逻辑。
     * 这里直接塞一个 Int64 最大值，要求函数不抛异常、结果仍确定。
     */
    let huge = Department()
    huge.id = 3
    huge.name = "越界部门"
    huge.sort = 9223372036854775807
    s.departments[3] = huge
    let ds2 = sortedDepartments(s)
    t.eqi("越界 sort 不丢部门", ds2.size, 3)
    t.ok("越界 sort 仍能排序（不抛异常）", ds2[0].name == "主席团")
    s.departments.remove(3)

    /* 成员排序：部门 sort → id（未分配部门排最后） */
    let picked = ArrayList<Member>()
    picked.add(s.members[3])
    picked.add(s.members[5])
    picked.add(s.members[1])
    let sorted = sortedMembers(s, picked)
    t.eqs("成员排序：主席团(sort0) 最前", sorted[0].name, "会长")
    t.eqs("成员排序：未分配部门最后", sorted[sorted.size - 1].name, "新人")

    /* 成员详情：计数摘要 */
    let task = Task()
    task.id = 1
    task.title = "T1"
    task.owner_id = 2
    task.status = "doing"
    task.dept_id = 2
    s.tasks[1] = task
    let task2 = Task()
    task2.id = 2
    task2.title = "T2"
    task2.owner_id = 2
    task2.status = "done"
    task2.dept_id = 2
    s.tasks[2] = task2
    let task3 = Task()
    task3.id = 3
    task3.title = "T3(已删)"
    task3.owner_id = 2
    task3.status = "doing"
    task3.deleted_at = 1789898400
    s.tasks[3] = task3
    let plan = Plan()
    plan.id = 1
    plan.title = "P1"
    plan.owner_id = 2
    plan.dept_id = 2
    s.plans[1] = plan

    let detail = memberDetailView(s, s.members[2]).toString()
    t.ok("owned_tasks=2（软删除不计）", containsAscii(detail, "\"owned_tasks\":2"))
    t.ok("open_tasks=1", containsAscii(detail, "\"open_tasks\":1"))
    t.ok("owned_plans=1", containsAscii(detail, "\"owned_plans\":1"))
    t.ok("详情不含手机号", !containsAscii(detail, "13800000002"))

    /* 未完成任务：只算 owner 匹配且未完成且未删除 */
    let open = openTasksOf(s, 2)
    t.eqi("未完成任务数", open.size, 1)
    t.eqs("未完成任务标题", open[0].title, "T1")

    /* 待分配视图 */
    let pv = pendingView(s, s.members[5]).toString()
    t.ok("待分配含 dept_hint 部门名", containsAscii(pv, "运营部"))
    t.ok("待分配含 registered_at", containsAscii(pv, "registered_at"))
    t.ok("待分配 role 为 null", containsAscii(pv, "\"role\":null"))

    /* 待分配列表顺序 = 注册顺序（id 升序） */
    let pending = pendingMembers(s)
    t.eqi("待分配人数", pending.size, 1)

    /* 部门前置检查 */
    t.eqi("运营部未退出成员数（部长+成员，不含已退出）", activeMemberCountOfDept(s, 2), 2)
    t.ok("部门重名检测", deptNameTaken(s, "运营部", 0))
    t.ok("改名时排除自身", !deptNameTaken(s, "运营部", 2))

    /* 招募链接视图 */
    let l = DeptInviteLink()
    l.token = "a1b2c3d4"
    l.dept_id = 2
    l.enabled = true
    l.created_by = 1
    l.created_at = 1789898400
    let lv = inviteLinkView(s, l, "https://example.com/join/a1b2c3d4").toString()
    t.ok("链接含 token", containsAscii(lv, "a1b2c3d4"))
    t.ok("链接含部门名", containsAscii(lv, "运营部"))
    t.ok("链接含 url", containsAscii(lv, "https://example.com/join/a1b2c3d4"))

    /* 注册配置视图 */
    s.register_code = "K3M9P2"
    s.register_code_by = 1
    s.register_code_at = 1789898400
    let rv = registerConfigView(s).toString()
    t.ok("注册配置含口令", containsAscii(rv, "K3M9P2"))
    t.ok("注册配置含操作人", containsAscii(rv, "会长"))
}

func testPaging(t: TR): Unit {
    println("- paging 分页")
    let all = ArrayList<JsonObject>()
    var i: Int64 = 1
    while (i <= 120) {
        let o = JsonObject()
        jPutInt(o, "id", i)
        all.add(o)
        i += 1
    }
    let p1 = pagedSlice(all, 1, 50).toString()
    t.ok("第 1 页 total=120", containsAscii(p1, "\"total\":120"))
    t.ok("第 1 页 page=1", containsAscii(p1, "\"page\":1"))
    t.ok("第 1 页 size=50", containsAscii(p1, "\"size\":50"))

    let p3 = pagedSlice(all, 3, 50)
    t.eqi("第 3 页条目数=20", (jsonGetArray(p3, "items") ?? JsonArray()).size(), 20)

    let pOver = pagedSlice(all, 99, 50)
    t.eqi("越界页返回空", (jsonGetArray(pOver, "items") ?? JsonArray()).size(), 0)

    let pMax = pagedSlice(all, 1, 5000)
    t.ok("size 上限 200", containsAscii(pMax.toString(), "\"size\":200"))

    let pZero = pagedSlice(all, 0, 0)
    t.ok("page<1 归 1", containsAscii(pZero.toString(), "\"page\":1"))
    t.ok("size<1 归 50", containsAscii(pZero.toString(), "\"size\":50"))
}

/* ===================== Part 4 的任务 ===================== */

func testTasks(t: TR): Unit {
    println("- tasks 分组/逾期/派生量")
    let s = Store("build/test-data-tasks")
    /* now = 2026-09-20T18:00:00+08:00；本地日界 todayStart = 1789833600 */
    let now: Int64 = 1789898400
    let todayStart = startOfLocalDay(now)
    let tomorrow = todayStart + 86400
    let weekEnd = todayStart + 7 * 86400

    let owner: Int64 = 7
    let other: Int64 = 8

    func mkTask(id: Int64, ownerId: Int64, due: Int64, status: String): Task {
        let x = Task()
        x.id = id
        x.title = "T${id}"
        x.owner_id = ownerId
        x.dept_id = 2
        x.status = status
        x.due_at = due
        x.created_by = 1
        x.created_at = now
        x.updated_at = now
        return x
    }

    let t1 = mkTask(1, owner, now - 3600, "doing")
    let t2 = mkTask(2, owner, now + 3600, "todo")
    let t3 = mkTask(3, owner, tomorrow + 3600, "todo")
    let t4 = mkTask(4, owner, weekEnd + 3600, "todo")
    let t5 = mkTask(5, owner, 0, "todo")
    let t6 = mkTask(6, owner, now + 7200, "blocked")
    let t7 = mkTask(7, owner, now - 7200, "done")
    let t8 = mkTask(8, other, now + 3600, "todo")
    let t9 = mkTask(9, owner, now + 3600, "todo")
    t9.deleted_at = now
    s.tasks[1] = t1
    s.tasks[2] = t2
    s.tasks[3] = t3
    s.tasks[4] = t4
    s.tasks[5] = t5
    s.tasks[6] = t6
    s.tasks[7] = t7
    s.tasks[8] = t8
    s.tasks[9] = t9

    let g = groupMine(s, owner, now)
    t.eqi("逾期组", g.overdue.size, 1)
    t.eqs("逾期组内容", g.overdue[0].title, "T1")
    t.eqi("今天组 = T2 + T6", g.due_today.size, 2)
    t.eqs("今天组按截止升序", g.due_today[0].title, "T2")
    t.eqi("本周组", g.due_week.size, 1)
    t.eqi("以后组", g.later.size, 1)
    t.eqi("无截止组", g.no_due.size, 1)
    t.eqi("阻塞组（与今天组并存，不互斥）", g.blocked.size, 1)
    t.eqs("阻塞组内容", g.blocked[0].title, "T6")
    t.eqi("未完成总数（不含 done/deleted/他人）", g.open_total, 6)

    /* 逾期是派生量 */
    t.ok("未完成且过期 = 逾期", isTaskOverdue(t1, now))
    t.ok("已完成不算逾期", !isTaskOverdue(t7, now))
    t.ok("无截止不算逾期", !isTaskOverdue(t5, now))

    t.ok("状态枚举合法", isTaskStatus("blocked"))
    t.ok("状态枚举非法", !isTaskStatus("doing50"))

    /* 排序：无截止排最后 */
    let mixed = ArrayList<Task>()
    mixed.add(t5)
    mixed.add(t1)
    mixed.add(t4)
    let sorted = sortedTasksByDue(mixed)
    t.eqs("有截止的在前", sorted[0].title, "T1")
    t.eqs("无截止排最后", sorted[2].title, "T5")

    /* 课题子树（M4 的多级课题要靠它） */
    let p1 = Plan()
    p1.id = 1
    p1.title = "根"
    p1.owner_id = 1
    p1.dept_id = 2
    let p2 = Plan()
    p2.id = 2
    p2.title = "子"
    p2.parent_id = 1
    p2.owner_id = 1
    let p3 = Plan()
    p3.id = 3
    p3.title = "孙"
    p3.parent_id = 2
    p3.owner_id = 1
    let p4 = Plan()
    p4.id = 4
    p4.title = "另一棵树"
    p4.owner_id = 1
    p4.dept_id = 2
    s.plans[1] = p1
    s.plans[2] = p2
    s.plans[3] = p3
    s.plans[4] = p4
    let sub = planSubtreeIds(s, 1)
    t.eqi("子树含自身 + 2 个后代", sub.size, 3)
    t.ok("子树含孙节点", sub.contains(3))
    t.ok("子树不含另一棵树", !sub.contains(4))

    let path = planPath(s, 3)
    t.eqi("面包屑 3 级", path.size(), 3)
    match (path.get(0)) {
        case Some(v) => t.ok("面包屑顶层在前", containsAscii(v.toString(), "根"))
        case None => t.ok("面包屑顶层在前", false)
    }

    /* TaskBrief / TaskDetail 的派生量与隐私 */
    t6.blocker = "等场地审批"
    let brief = taskBrief(s, t6, now).toString()
    t.ok("brief: blocked=true", containsAscii(brief, "\"blocked\":true"))
    t.ok("brief: is_overdue=false", containsAscii(brief, "\"is_overdue\":false"))
    t.ok("brief: 不含手机号", !containsAscii(brief, "\"phone\""))
    let detail = taskDetail(s, t6, now).toString()
    t.ok("detail 含 blocker", containsAscii(detail, "等场地审批"))
    t.ok("detail 含 plan_path", containsAscii(detail, "plan_path"))
    t.ok("detail 含 completed_at", containsAscii(detail, "completed_at"))

    /* 幂等表 */
    idemPut(s, "task", 7, "tok-1", 42, now)
    let hit1 = idemHit(s, "task", 7, "tok-1", now + 100)
    t.ok("24h 内命中", hit1.isSome())
    t.eqi("命中的是首次创建的资源", hit1 ?? -1, 42)
    t.ok("不同 kind 不串", idemHit(s, "plan", 7, "tok-1", now + 100).isNone())
    t.ok("超过 24h 失效", idemHit(s, "task", 7, "tok-1", now + 86401).isNone())
    t.ok("失效后被清理", !s.idem.contains("task:7:tok-1"))
    /* P0 H-2：幂等键必须按提交者隔离，否则乙拿甲的 client_token 重放就能读到甲的资源 */
    idemPut(s, "task", 7, "tok-shared", 42, now)
    t.ok("同一 token 换个人不命中（H-2）", idemHit(s, "task", 8, "tok-shared", now + 10).isNone())
    t.ok("本人重放仍然命中", idemHit(s, "task", 7, "tok-shared", now + 10).isSome())
}

/* ===================== Part 5 的课题 ===================== */

func planStatTotal(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.total
        case None => return -1
    }
}

func planStatDone(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.done
        case None => return -1
    }
}

func planStatOwn(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.task_count
        case None => return -1
    }
}

func planStatChild(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.child_count
        case None => return -1
    }
}

func testPlans(t: TR): Unit {
    println("- plans 课题树 递归聚合 环形校验 删除上提")
    let s = Store("build/test-data-plans")
    let p1 = Plan()
    p1.id = 1
    p1.title = "P1"
    p1.parent_id = 0
    p1.dept_id = 2
    p1.owner_id = 7
    let p2 = Plan()
    p2.id = 2
    p2.title = "P2"
    p2.parent_id = 1
    p2.owner_id = 7
    let p3 = Plan()
    p3.id = 3
    p3.title = "P3"
    p3.parent_id = 2
    p3.owner_id = 8
    let p4 = Plan()
    p4.id = 4
    p4.title = "P4"
    p4.parent_id = 0
    p4.dept_id = 3
    p4.owner_id = 9
    s.plans[1] = p1
    s.plans[2] = p2
    s.plans[3] = p3
    s.plans[4] = p4

    /* dept_id 只存顶层，子课题的部门由所属根决定（规则 19） */
    t.eqi("顶层部门", planDeptOf(s, 1), 2)
    t.eqi("子课题部门看根", planDeptOf(s, 2), 2)
    t.eqi("孙课题部门看根", planDeptOf(s, 3), 2)
    t.eqi("另一棵树部门", planDeptOf(s, 4), 3)
    t.eqi("向上找到的根", planRootOf(s, 3), 1)

    /* 层级与子树高度 */
    t.eqi("顶层深度", planDepthOf(s, 1), 1)
    t.eqi("孙深度", planDepthOf(s, 3), 3)
    t.eqi("顶层子树高度", planHeightOf(s, 1), 3)
    t.eqi("中间节点子树高度", planHeightOf(s, 2), 2)
    t.eqi("叶子高度", planHeightOf(s, 3), 1)
    t.eqi("顶层直接子节点数", planChildrenOf(s, 1).size, 1)

    /* 环形校验：从目标父节点向上遍历 */
    t.ok("不能挂到自己下面", planWouldCycle(s, 1, 1))
    t.ok("不能挂到自己的后代下面", planWouldCycle(s, 1, 3))
    t.ok("挂到无关节点可以", !planWouldCycle(s, 1, 4))
    t.ok("挂到自己的父节点可以", !planWouldCycle(s, 2, 1))
    t.ok("提升为顶层不算环", !planWouldCycle(s, 2, 0))

    /* 递归聚合：1 -> 2 -> 3，任务挂在不同层级 */
    let t1 = Task()
    t1.id = 1
    t1.title = "T1"
    t1.owner_id = 7
    t1.plan_id = 1
    t1.dept_id = 2
    t1.status = "done"
    let t2 = Task()
    t2.id = 2
    t2.title = "T2"
    t2.owner_id = 7
    t2.plan_id = 2
    t2.dept_id = 2
    t2.status = "doing"
    let t3 = Task()
    t3.id = 3
    t3.title = "T3"
    t3.owner_id = 7
    t3.plan_id = 3
    t3.dept_id = 2
    t3.status = "done"
    let t4 = Task()
    t4.id = 4
    t4.title = "T4"
    t4.owner_id = 7
    t4.plan_id = 3
    t4.dept_id = 2
    t4.status = "todo"
    let t5 = Task()
    t5.id = 5
    t5.title = "T5 已删除"
    t5.owner_id = 7
    t5.plan_id = 3
    t5.dept_id = 2
    t5.status = "done"
    t5.deleted_at = 1789898400
    s.tasks[1] = t1
    s.tasks[2] = t2
    s.tasks[3] = t3
    s.tasks[4] = t4
    s.tasks[5] = t5

    let ids = HashSet<Int64>()
    ids.add(1)
    ids.add(2)
    ids.add(3)
    let st = planStatsAll(s, ids)

    t.eqi("叶子 total 含自身", planStatTotal(st, 3), 2)
    t.eqi("叶子 done", planStatDone(st, 3), 1)
    t.eqi("叶子本级任务数 软删除不计", planStatOwn(st, 3), 2)
    t.eqi("中间节点 total 等于本级 1 加子树 2", planStatTotal(st, 2), 3)
    t.eqi("中间节点 done 等于 0 加 1", planStatDone(st, 2), 1)
    t.eqi("根 total 等于本级 1 加子树 3", planStatTotal(st, 1), 4)
    t.eqi("根 done 等于 1 加 1", planStatDone(st, 1), 2)
    t.eqi("本级任务数不含子课题", planStatOwn(st, 1), 1)
    t.eqi("根的直接子课题数", planStatChild(st, 1), 1)

    /* 删除中间节点：直接子节点上提一级 */
    let mv = planDeletePromote(s, 2)
    t.eqi("上提课题数", mv[0], 1)
    t.eqi("上提任务数", mv[1], 1)
    t.ok("被删课题已移除", !s.plans.contains(2))
    match (s.plans.get(3)) {
        case Some(x) => t.eqi("孙课题上提到根下", x.parent_id, 1)
        case None => t.ok("孙课题还在", false)
    }
    match (s.tasks.get(2)) {
        case Some(x) => t.eqi("本级任务上提到根下", x.plan_id, 1)
        case None => t.ok("任务还在", false)
    }

    /* 删除顶层：子课题变顶层并继承部门，孙节点不动 */
    let p5 = Plan()
    p5.id = 5
    p5.title = "P5"
    p5.parent_id = 0
    p5.dept_id = 3
    p5.owner_id = 9
    let p6 = Plan()
    p6.id = 6
    p6.title = "P6"
    p6.parent_id = 5
    p6.owner_id = 9
    let p7 = Plan()
    p7.id = 7
    p7.title = "P7"
    p7.parent_id = 6
    p7.owner_id = 9
    s.plans[5] = p5
    s.plans[6] = p6
    s.plans[7] = p7
    let t6 = Task()
    t6.id = 6
    t6.title = "T6"
    t6.owner_id = 9
    t6.plan_id = 5
    t6.dept_id = 3
    t6.status = "todo"
    s.tasks[6] = t6

    let mv2 = planDeletePromote(s, 5)
    t.eqi("删除顶层 上提 1 个子课题", mv2[0], 1)
    t.eqi("删除顶层 上提 1 个任务", mv2[1], 1)
    match (s.plans.get(6)) {
        case Some(x) =>
            t.eqi("子课题变为顶层", x.parent_id, 0)
            t.eqi("子课题继承原根的部门", x.dept_id, 3)
        case None => t.ok("子课题还在", false)
    }
    match (s.plans.get(7)) {
        case Some(x) => t.eqi("孙节点不被上提 父仍是 6", x.parent_id, 6)
        case None => t.ok("孙节点还在", false)
    }
    match (s.tasks.get(6)) {
        case Some(x) => t.eqi("顶层被删 本级任务变独立", x.plan_id, 0)
        case None => t.ok("任务还在", false)
    }
}

/* ===================== 注册口令节流（N-6） ===================== */

func testRegThrottle(t: TR): Unit {
    println("- auth 注册口令节流（按 IP + 递增退避）")
    let dir = "test-data-regthrottle"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = storeLoad(dir)
    let now = nowEpoch()

    /* 同一 IP 错 9 次还没锁，第 10 次触发锁定 */
    var i: Int64 = 0
    while (i < REG_FAIL_LIMIT - 1) {
        regFailBump(s, "10.0.0.1")
        i += 1
    }
    t.ok("错 9 次还没锁", !regLocked(s, "10.0.0.1", now))
    regFailBump(s, "10.0.0.1")
    t.ok("第 10 次触发锁定", regLocked(s, "10.0.0.1", now))

    /* 另一个 IP 完全不受影响 —— 这正是与旧全局锁最关键的区别（N-6 的核心收益） */
    t.ok("另一个 IP 不受影响", !regLocked(s, "10.0.0.2", now))
    i = 0
    while (i < REG_FAIL_LIMIT - 1) {
        regFailBump(s, "10.0.0.2")
        i += 1
    }
    t.ok("两个 IP 各数各的", !regLocked(s, "10.0.0.2", now))

    /* 递增退避：首次 5 分钟 */
    let st1 = s.reg_fail.get("10.0.0.1") ?? RegFail()
    let firstLock = st1.locked_until - now
    t.ok("首次锁 5 分钟", (firstLock >= REG_FAIL_LOCK_BASE - 2) && (firstLock <= REG_FAIL_LOCK_BASE + 2))
    t.ok("锁定期内判定为锁", regLocked(s, "10.0.0.1", now + 60))
    t.ok("锁到期自动解除", !regLocked(s, "10.0.0.1", now + REG_FAIL_LOCK_BASE + 2))

    /* 同一 IP 再触发一次 → 翻倍 */
    i = 0
    while (i < REG_FAIL_LIMIT) {
        regFailBump(s, "10.0.0.1")
        i += 1
    }
    let st2 = s.reg_fail.get("10.0.0.1") ?? RegFail()
    t.ok("第二次锁更久（翻倍）", st2.locked_until - nowEpoch() > firstLock)
    t.ok("退避有上限（1 小时）", regLockSeconds(99) == REG_FAIL_LOCK_MAX)

    /* 注册成功会清掉该 IP 的失败状态 */
    s.reg_fail.remove("10.0.0.1")
    t.ok("成功后该 IP 不再被锁", !regLocked(s, "10.0.0.1", nowEpoch()))

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/* ===================== 轻舟 RBAC 适配层（本地适配，非上游原版） ===================== */

/*
 * 覆盖 server/src/fw_rbac_store.cj + fw_rbac.cj：轻舟升级后新增的 RBAC 数据层与授权中间件，
 * 因 CangDB 上游无代码而由我们适配（数据层 = 文件存储、响应 = 我们的错误格式）。
 * 这里测的是"适配后的行为与上游语义一致"，重点是**落盘往返**（换成文件存储后的关键差异）。
 */
func testRbacAdaptation(t: TR): Unit {
    println("- 轻舟 RbacStore 适配版（文件存储，无 CangDB）")
    let dir = "test-data-rbac"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let path = "${dir}/rbac.json"
    let st = RbacStore(path)

    /* 种子数据与上游一致：2 个角色、6 个权限、2 个账号 */
    t.eqi("角色数=2", st.listRoles().size, 2)
    t.eqi("权限数=6", st.listPermissions().size, 6)
    t.eqi("用户数=2", st.listUsers().size, 2)
    t.eqs("角色名 admin", st.roleNameOf(1), "admin")
    t.eqs("不存在的角色名=空", st.roleNameOf(99), "")

    /* RBAC 链：用户 -> 角色 -> 权限（分步查询 + 应用层组合，与上游同口径） */
    t.ok("admin 有 user:list", st.hasPermission(1, "user:list"))
    t.ok("admin 有 dashboard:view", st.hasPermission(1, "dashboard:view"))
    t.ok("user 没有 user:list", !st.hasPermission(2, "user:list"))
    t.ok("user 有 dashboard:view", st.hasPermission(2, "dashboard:view"))
    t.eqi("admin 权限码 6 个", st.permissionCodesOf(1).size, 6)
    t.eqi("user 权限码 1 个", st.permissionCodesOf(2).size, 1)
    t.ok("不存在的用户无权限", !st.hasPermission(99, "user:list"))

    match (st.findUserByUsername("admin")) {
        case Some(u) => t.eqi("admin 的角色 id", u.roleId, 1)
        case None => t.ok("admin 存在", false)
    }
    t.ok("不存在的用户名 -> None", st.findUserByUsername("nobody").isNone())
    t.ok("按 id 查得到", st.findUserById(2).isSome())

    /* 落盘往返：换成文件存储后最关键的一条 —— 重开后数据必须还在 */
    let newId = st.createUser("tester", hashPassword("pw123456", "salt", 10), 2)
    t.ok("新用户 id 递增", newId > 2)
    st.close()

    let st2 = RbacStore(path)
    t.ok("重开后新用户还在", st2.findUserByUsername("tester").isSome())
    t.eqi("重开后用户数=3", st2.listUsers().size, 3)
    t.ok("重开后权限仍然正确", st2.hasPermission(1, "user:delete"))
    t.ok("删除用户返回 true", st2.deleteUser(newId))
    t.ok("重复删除返回 false", !st2.deleteUser(newId))
    st2.close()

    let st3 = RbacStore(path)
    t.eqi("删除后用户数=2", st3.listUsers().size, 2)
    st3.close()

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * 容量基准动作 4：storeSave 只在锁内取快照，写盘由 snapshotFlush 中间件在锁外完成。
 * 这里直接验证这条两段式契约本身（HTTP 层的端到端验证在冒烟测试 [24] 重启持久性里）：
 *   · storeSave 之后磁盘上**还没有**新数据 → 证明整库 IO 确实不在锁内那一段
 *   · pending 里已有完整快照，flushPending 之后磁盘上就有了
 *   · 没有待写快照时 flushPending 是空操作（幂等）
 *   · 序号守卫：并发写盘收敛到最新版本，旧快照不会覆盖新快照
 */
func testDeferredSave(t: TR): Unit {
    println("- store 动作4：快照在锁内、写盘在锁外")
    let dir = "build/test-data-deferred"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = Store(dir)

    let d = Department()
    d.id = 1
    d.name = "秘书处"
    s.departments[1] = d

    /* 第一段：锁内只取快照 —— 磁盘上不该有任何东西 */
    storeSave(s)
    t.ok("storeSave 后 pending 里有快照", s.pending.isSome())
    t.ok("storeSave 后**还没写盘**（IO 已移出锁内那一段）", !exists(s.dbFile()))

    /* 第二段：锁外写盘 */
    flushPending(s)
    t.ok("flushPending 后 db.json 已生成", exists(s.dbFile()))
    t.ok("flushPending 清空 pending", s.pending.isNone())
    let text = String.fromUtf8(File.readFrom(s.dbFile()))
    t.ok("落盘内容含本次变更", containsAscii(text, "秘书处"))

    /* 幂等：没有待写快照时是空操作，不碰文件 */
    flushPending(s)
    t.eqs("无待写快照时 flushPending 不改文件", String.fromUtf8(File.readFrom(s.dbFile())), text)
    t.ok("tmp 已清理", !exists(s.dbFile() + ".tmp"))

    /* 序号守卫：拿旧快照后写，不能把更新的版本覆盖回去 */
    let oldSnap = storeSnapshot(s)
    let newSnap = storeSnapshot(s)
    writeSnapshot(s, newSnap)
    writeSnapshot(s, oldSnap)
    t.eqi("旧快照被序号守卫拦住（saved_seq 不倒退）", s.saved_seq, newSnap.seq)
    t.ok("seq 单调递增", newSnap.seq > oldSnap.seq)

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * 容量基准动作 3：签发令牌时顺手回收过期令牌（auth.cj 的 pruneTokens）。
 * 回归点：原先 tokens 表**只增不减**（只有"某个已过期令牌被再次使用"才会删掉它），
 * 用户不再登录就永远留着，而每次写盘都要把整表序列化进 db.json。
 */
func testTokenPrune(t: TR): Unit {
    println("- auth 令牌回收（动作3）")
    let dir = "build/test-data-prune"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = Store(dir)
    let now: Int64 = 1789898400
    /* 用 2286 年当"永不过期"，避免测试依赖真实时钟（issueToken 内部会取 nowEpoch） */
    let far = 9999999999999

    for (i in 1..=3) {
        let r = TokenRecord()
        r.member_id = 1
        r.created_at = now - 100000
        r.expires_at = now - i
        s.tokens["expired-${i}"] = r
    }
    for (i in 1..=2) {
        let r = TokenRecord()
        r.member_id = 1
        r.created_at = now
        r.expires_at = far
        s.tokens["live-${i}"] = r
    }

    t.eqi("回收前 5 条", s.tokens.size, 5)
    t.eqi("回收了 3 条过期令牌", pruneTokens(s, now), 3)
    t.eqi("剩下 2 条活跃令牌", s.tokens.size, 2)
    t.ok("过期令牌已删除", !s.tokens.contains("expired-1"))
    t.ok("活跃令牌保留", s.tokens.contains("live-1"))

    /* 没有过期令牌时是空操作 */
    t.eqi("无过期令牌时返回 0", pruneTokens(s, now), 0)
    t.eqi("无过期令牌时表大小不变", s.tokens.size, 2)

    /* 真正的调用点：issueToken 会顺手回收（1970 年到期，任何真实时钟下都算过期） */
    let dead = TokenRecord()
    dead.member_id = 1
    dead.created_at = 1
    dead.expires_at = 1
    s.tokens["expired-later"] = dead
    let issued = issueToken(s, 7)
    t.ok("新令牌已签发", s.tokens.contains(issued[0]))
    t.ok("issueToken 顺手回收了过期令牌", !s.tokens.contains("expired-later"))
    t.eqi("表大小 = 2 活跃 + 1 新", s.tokens.size, 3)

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * 容量基准动作 1：sortByKey 由插入排序换成堆排序（store.cj）。
 * 复杂度是性能属性、不适合在单测里断言时间；这里守住的是**换实现不能换语义**：
 * 逆序输入、同键输入、单元素、空数组四个边界。
 */
func testSortEdge(t: TR): Unit {
    println("- sort 堆排序边界（动作1）")
    let n = 500
    let arr = ArrayList<Task>()
    var i = n
    while (i > 0) {
        let x = Task()
        x.id = i
        x.title = "T${i}"
        /* 确定性乱序：7919 与 100000 互质，键与 id 顺序完全错开 */
        x.due_at = (i * 7919) % 100000
        arr.add(x)
        i -= 1
    }
    let out = sortedTasksByDue(arr)
    t.eqi("元素一个不少", out.size, n)
    var ordered = true
    var j = 1
    while (j < out.size) {
        if (out[j - 1].due_at > out[j].due_at) {
            ordered = false
        }
        j += 1
    }
    t.ok("500 条乱序输入排成升序", ordered)
    /* 键含 id，同 due_at 也必须是全序（不会因不稳定而乱） */
    var strict = true
    j = 1
    while (j < out.size) {
        if (out[j - 1].due_at == out[j].due_at && out[j - 1].id >= out[j].id) {
            strict = false
        }
        j += 1
    }
    t.ok("同截止时间按 id 兜底", strict)

    /* 全部同键：仍然不丢元素、按 id 升序 */
    let same = ArrayList<Task>()
    var k: Int64 = 100
    while (k > 0) {
        let x = Task()
        x.id = k
        x.due_at = 5000
        same.add(x)
        k -= 1
    }
    let out2 = sortedTasksByDue(same)
    t.eqi("同键元素数不变", out2.size, 100)
    t.eqi("同键首元素是最小 id", out2[0].id, 1)
    t.eqi("同键末元素是最大 id", out2[99].id, 100)

    /* 边界：单元素 / 空数组 */
    let one = ArrayList<Task>()
    let only = Task()
    only.id = 9
    only.due_at = 1
    one.add(only)
    t.eqi("单元素原样返回", sortedTasksByDue(one).size, 1)
    t.eqi("空数组返回空", sortedTasksByDue(ArrayList<Task>()).size, 0)
}

/* ===================== 入口 ===================== */

public func runTests(): Int64 {
    println("=== 社团管理工具 · 服务端单测 ===")
    let t = TR()
    testTime(t)
    testStr(t)
    testIds(t)
    testPassword(t)
    testStore(t)
    testDeferredSave(t)
    testTokenPrune(t)
    testSortEdge(t)
    testPerms(t)
    testRegThrottle(t)
    testRbacAdaptation(t)
    testViews(t)
    testPart3Views(t)
    testPaging(t)
    testTasks(t)
    testPlans(t)
    println("")
    println("PASS ${t.pass} / FAIL ${t.fail}")
    if (t.fail == 0) {
        return 0
    }
    return 1
}
