package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 认证：口令哈希、令牌、认证辅助。
 *
 * 口令：PBKDF2-HMAC-SHA256，100000 次迭代，16 字节随机盐。
 *   为什么不直接用现成的：stdx.crypto.digest 只确认了 SHA256 与 HMAC，
 *   没有确认 PBKDF2 入口。本实现按 RFC 2898 写，并已用
 *   RFC 7914 §11 的公开测试向量 + .NET Rfc2898DeriveBytes 双向对拍（见 tests.cj）。
 *
 * 令牌：32 字节随机 → 64 位十六进制，服务端存 token → member 映射。
 *   **不是无状态 JWT**：这样"移出社团"能立即踢下线（api-design §1.4）。
 */

import std.collection.*
import std.random.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*

public let PBKDF2_ITER: Int64 = 100000
public let TOKEN_TTL: Int64 = 30 * 86400        /* 30 天 */
public let RENEW_AFTER: Int64 = 86400           /* 每天最多续期落盘一次 */

/* ===================== 口令 ===================== */

func hmacSha256(key: Array<UInt8>, msg: Array<UInt8>): Array<UInt8> {
    let mac = HMAC(key, { => SHA256() })
    mac.write(msg)
    return mac.finish()
}

/* RFC 2898 PBKDF2，PRF = HMAC-SHA256。 */
public func pbkdf2Sha256(pwd: Array<UInt8>, salt: Array<UInt8>, iters: Int64, dkLen: Int64): Array<UInt8> {
    let hLen: Int64 = 32
    let blocks: Int64 = (dkLen + hLen - 1) / hLen
    let out = ArrayList<UInt8>()
    var i: Int64 = 1
    while (i <= blocks) {
        let seed = ArrayList<UInt8>(salt)
        seed.add(UInt8((i >> 24) & 0xFF))
        seed.add(UInt8((i >> 16) & 0xFF))
        seed.add(UInt8((i >> 8) & 0xFF))
        seed.add(UInt8(i & 0xFF))
        var u = hmacSha256(pwd, seed.toArray())
        let t = u.clone()
        var c: Int64 = 1
        while (c < iters) {
            u = hmacSha256(pwd, u)
            var j: Int64 = 0
            while (j < hLen) {
                t[j] = t[j] ^ u[j]
                j += 1
            }
            c += 1
        }
        for (b in t) {
            out.add(b)
        }
        i += 1
    }
    return out.toArray()[0..dkLen]
}

/* 生成本项目的口令记录（盐 + 摘要）。 */
public func newPasswordRecord(pw: String): (String, String, Int64) {
    let salt = randBytes(16)
    let dk = pbkdf2Sha256(pw.toArray(), salt, PBKDF2_ITER, 32)
    return (toHexString(salt), toHexString(dk), PBKDF2_ITER)
}

/*
 * 校验口令。任何一步异常都当作"不匹配"，绝不向上抛。
 * 名字不叫 verifyPassword 是因为**轻舟自己已经有一个同名函数**（security.cj），
 * 同包编译会冲突。
 */
public func verifyPw(pw: String, saltHex: String, hashHex: String, iters: Int64): Bool {
    var salt: Array<UInt8> = Array<UInt8>()
    match (fromHexString(saltHex)) {
        case Some(x) => salt = x
        case None => return false
    }
    if (iters <= 0) {
        return false
    }
    let dk = pbkdf2Sha256(pw.toArray(), salt, iters, 32)
    /* 定时安全比较（L-6）：摘要比对也不该在第一个不同字节就返回 */
    return constantTimeEq(toHexString(dk), hashHex)
}

/* ===================== 令牌 ===================== */

/* 取出 Authorization: Bearer <token>。 */
public func bearerToken(ctx: Context): ?String {
    match (ctx.requestHeader("authorization")) {
        case Some(v) =>
            if (!startsWithAscii(v.toAsciiLower(), "bearer ")) {
                return None
            }
            let t = subFrom(v, 7).trimAscii()
            if (t.size == 0) {
                return None
            }
            return Some(t)
        case None => return None
    }
}

/*
 * 回收已过期令牌（2026-09-15，容量基准的动作 3）。
 *
 * 原先只有"某个**已过期**令牌被再次使用"时才会被删（requireMember 里那一处），
 * 用户不再登录就永远留着 —— 于是 tokens 表**只增不减**，
 * 而每次写都会把它整表序列化进 db.json。实测 1500 条 ≈ 165 KB，1200 人社团一学期
 * 累积上万条很现实，那会让**每一次写盘**都多背几百 KB。
 *
 * 这里在**签发令牌时顺手回收一次**（低频、O(n) 一趟），把表压回"活跃会话"量级。
 */
public func pruneTokens(s: Store, now: Int64): Int64 {
    let doomed = ArrayList<String>()
    for ((k, r) in s.tokens) {
        if (r.expires_at <= now) {
            doomed.add(k)
        }
    }
    for (k in doomed) {
        s.tokens.remove(k)
    }
    return doomed.size
}

public func issueToken(s: Store, memberId: Int64): (String, Int64) {
    let tok = newToken()
    let now = nowEpoch()
    /* 顺手回收过期令牌（动作 3）；调用方都持锁，见各 handler 的注释 */
    pruneTokens(s, now)
    let rec = TokenRecord()
    rec.member_id = memberId
    rec.created_at = now
    rec.expires_at = now + TOKEN_TTL
    s.tokens[tok] = rec
    return (tok, rec.expires_at)
}

/*
 * 认证：任何需要登录的接口都从这里拿当前成员。
 * 同时做令牌滑动续期——但最多每天落盘一次，否则每个请求都写整库。
 */
public func requireMember(ctx: Context, s: Store): Member {
    let tok = match (bearerToken(ctx)) {
        case Some(t) => t
        case None => throw apiErr("AUTH_REQUIRED")
    }
    s.lock.lock()
    try {
        match (s.tokens.get(tok)) {
            case Some(rec) =>
                let now = nowEpoch()
                if (rec.expires_at <= now) {
                    s.tokens.remove(tok)
                    storeSave(s)
                    throw apiErr("AUTH_TOKEN_EXPIRED")
                }
                if (rec.expires_at - now < TOKEN_TTL - RENEW_AFTER) {
                    rec.expires_at = now + TOKEN_TTL
                    storeSave(s)
                }
                match (s.members.get(rec.member_id)) {
                    case Some(m) => return m
                    case None => throw apiErr("AUTH_REQUIRED")
                }
            case None => throw apiErr("AUTH_REQUIRED")
        }
    } finally {
        s.lock.unlock()
    }
}

/* 需要"已被会长分配"的正式成员（pending/disabled 会被拒）。 */
public func requireActive(ctx: Context, s: Store): Member {
    let m = requireMember(ctx, s)
    if (m.status == "pending") {
        throw apiErr("MEMBER_PENDING")
    }
    if (m.status == "disabled") {
        throw apiErr("MEMBER_DISABLED")
    }
    return m
}

/* 使某个成员除 keepToken 以外的全部令牌失效（改密码时用）。 */
public func revokeOtherTokens(s: Store, memberId: Int64, keepToken: String): Unit {
    let doomed = ArrayList<String>()
    for ((k, r) in s.tokens) {
        if (r.member_id == memberId && k != keepToken) {
            doomed.add(k)
        }
    }
    for (k in doomed) {
        s.tokens.remove(k)
    }
}
