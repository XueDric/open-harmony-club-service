package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 运维接口：健康检查 + 优雅关闭。
 *
 * Windows 没有 std.runtime.Signal（HANDOFF §6），优雅关闭只能靠端点触发。
 * 因此 /admin/shutdown **必须限制为本机可访问**，否则任何人都能远程关停服务。
 */

import stdx.encoding.json.*

public let APP_VERSION: String = "0.1.0"

/* GET /health —— 不带 /api 前缀、不需要认证（api-design §1.1）。 */
public func handleHealth(ctx: Context): Unit {
    let data = JsonObject()
    jPutStr(data, "status", "ok")
    jPutStr(data, "version", APP_VERSION)
    jPutStr(data, "time", isoLocal(nowEpoch()))
    sendOk(ctx, data)
}

/*
 * 取客户端地址的文本形式。
 * stdx 的 remoteAddr 具体类型未固定，这里统一用字符串插值取它的文本表示，
 * 避免把类型写死（探针实测该属性存在，但打印格式需运行时确认）。
 */
public func peerOf(ctx: Context): String {
    match (ctx.http) {
        case Some(h) => return "${h.request.remoteAddr}"
        case None => return ""
    }
}

public func isLocalPeer(ctx: Context): Bool {
    let p = peerOf(ctx)
    if (p.size == 0) {
        return false
    }
    if (containsAscii(p, "127.0.0.1")) {
        return true
    }
    if (containsAscii(p, "::1")) {
        return true
    }
    if (containsAscii(p, "localhost")) {
        return true
    }
    return false
}
