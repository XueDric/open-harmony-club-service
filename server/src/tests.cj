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

    storeSave(s)

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
    storeSave(s)
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

    if (exists(dir)) {
        remove(dir, recursive: true)
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
    let other = Target()
    other.dept_id = 3
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

/* ===================== 入口 ===================== */

public func runTests(): Int64 {
    println("=== 社团管理工具 · 服务端单测 ===")
    let t = TR()
    testTime(t)
    testStr(t)
    testIds(t)
    testPassword(t)
    testStore(t)
    testPerms(t)
    testViews(t)
    println("")
    println("PASS ${t.pass} / FAIL ${t.fail}")
    if (t.fail == 0) {
        return 0
    }
    return 1
}
