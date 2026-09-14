package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 运维接口：健康检查 + 优雅关闭。
 *
 * Windows 没有 std.runtime.Signal（..\docs\..\docs\HANDOFF.md §6），优雅关闭只能靠端点触发。
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

/*
 * 取客户端 IP（**不含端口**）—— N-6 的注册节流按它分桶。
 *
 * 实测 remoteAddr 的文本是 "IP:端口"（例：127.0.0.1:14764），所以必须剥端口；
 * 否则同一台机器每个连接都是新 key，限流形同虚设。
 * IPv6 常见形态是 "[::1]:14764"（取方括号内），无方括号时按最后一个冒号切。
 * 拿不到地址时返回空串，调用方自行兜底（当前会退化为全局锁）。
 *
 * N-12 已知退化：若对端地址是**既无方括号也无端口的裸 IPv6**（如 `::1`），
 * "最后一个冒号"这条规则会切出 `":"` 这种垃圾 key。实测 remoteAddr 总是
 * `[::1]:14764` 形态，所以只在异常形态下出现；后果是这些请求共用一个桶
 * （退化为全局），**不是漏洞**。真要严谨，应先判断"有无方括号"再决定切法。
 */
public func clientIpOf(ctx: Context): String {
    let p = peerOf(ctx)
    let n = p.size
    if (n == 0) {
        return ""
    }
    let a = p.toArray()
    /* 先找最后一个 ']'：IPv6 的 [::1]:port 形式 */
    var rb: Int64 = -1
    var i: Int64 = 0
    while (i < n) {
        if (a[i] == 93) {
            rb = i
        }
        i += 1
    }
    if (rb > 0) {
        return String.fromUtf8(a[1..rb])
    }
    /* 再找最后一个 ':'，切掉端口 */
    var cb: Int64 = -1
    i = 0
    while (i < n) {
        if (a[i] == 58) {
            cb = i
        }
        i += 1
    }
    if (cb > 0) {
        return String.fromUtf8(a[0..cb])
    }
    return p
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
