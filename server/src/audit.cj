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

import std.fs.*

/* 追加一行审计记录。失败不抛错——审计日志写不进去，不该让业务操作失败。 */
public func audit(s: Store, actorId: Int64, action: String, targetId: Int64, note: String): Unit {
    try {
        if (!exists(s.dir)) {
            Directory.create(s.dir, recursive: true)
        }
        let line = "${isoLocal(nowEpoch())}\tactor=${actorId}\t${action}\ttarget=${targetId}\t${note}\n"
        File.appendTo("${s.dir}/audit.log", line.toArray())
    } catch (e: Exception) {
        println("[WARN] 审计日志写入失败: ${e.message}")
    }
}
