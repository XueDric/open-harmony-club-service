package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 敏感操作审计日志。
 *
 * api-design §3.5 明确要求：重置密码"该操作记入日志（谁在什么时候重置了谁）——
 * 这是敏感操作，需要可追溯"。
 *
 * 落点：<数据目录>/audit.log，一行一条、制表符分隔，**追加写**。
 * 为什么不用 stdout：进程重启后控制台输出就没了，而这类记录的意义正在于事后追查。
 */

import std.collection.*
import std.fs.*

/*
 * 审计字段的清洗（L-9）。
 *
 * 格式是一行一条、制表符分隔，但 note 里会拼进调用方给的字符串（例如链接 token
 * 直接取自 URL 路径）。未清洗时，一个含换行的 token 就能在日志里**伪造出一整条记录**，
 * 含制表符则能挪动字段边界——事后追查时看到的是攻击者写的内容。
 * 这里在唯一的写入口做替换：CR/LF/TAB 换成空格，同时把控制字符一并挡掉。
 */
func auditSafe(v: String): String {
    let out = ArrayList<UInt8>()
    for (b in v.toArray()) {
        if (b == 13 || b == 10 || b == 9) {
            out.add(UInt8(32))
        } else if (b < 32) {
            out.add(UInt8(63))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/* 追加一行审计记录。失败不抛错——审计日志写不进去，不该让业务操作失败。 */
public func audit(s: Store, actorId: Int64, action: String, targetId: Int64, note: String): Unit {
    try {
        if (!exists(s.dir)) {
            Directory.create(s.dir, recursive: true)
        }
        let line = "${isoLocal(nowEpoch())}\tactor=${actorId}\t${auditSafe(action)}\ttarget=${targetId}\t${auditSafe(note)}\n"
        File.appendTo("${s.dir}/audit.log", line.toArray())
    } catch (e: Exception) {
        println("[WARN] 审计日志写入失败: ${e.message}")
    }
}
