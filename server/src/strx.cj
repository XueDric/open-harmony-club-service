package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 字节级字符串工具。
 *
 * 为什么这些都自己写：探针实测（见 server/.probe）在 cjc 1.1.3 + stdx 1.1.3.1 上
 * 只确认了 String 的 toArray() / fromUtf8() / trimAscii() / toAsciiLower() / size
 * 等少量入口。前缀、包含、纯数字这类判断全部落在自己手上，
 * 避免再撞上 stdx 里"声明了但没实现"的 API（轻舟 DEF-1 就是这类问题）。
 *
 * ⚠ Cangjie 的 String.size 是 **字节数**，不是字符数。中文一个字 3 字节。
 */

/* s 是否以 prefix 开头（逐字节，大小写敏感）。 */
public func startsWithAscii(s: String, prefix: String): Bool {
    let a = s.toArray()
    let p = prefix.toArray()
    if (a.size < p.size) {
        return false
    }
    var i: Int64 = 0
    while (i < p.size) {
        if (a[i] != p[i]) {
            return false
        }
        i += 1
    }
    return true
}

/* s 是否包含 needle（逐字节，大小写敏感）。 */
public func containsAscii(s: String, needle: String): Bool {
    let a = s.toArray()
    let n = needle.toArray()
    if (n.size == 0) {
        return true
    }
    if (a.size < n.size) {
        return false
    }
    var i: Int64 = 0
    while (i + n.size <= a.size) {
        var j: Int64 = 0
        var hit = true
        while (j < n.size) {
            if (a[i + j] != n[j]) {
                hit = false
                break
            }
            j += 1
        }
        if (hit) {
            return true
        }
        i += 1
    }
    return false
}

/* 是否全为 ASCII 数字，且非空。 */
public func isDigits(s: String): Bool {
    let a = s.toArray()
    if (a.size == 0) {
        return false
    }
    var i: Int64 = 0
    while (i < a.size) {
        let c = a[i]
        if (c < 48 || c > 57) {
            return false
        }
        i += 1
    }
    return true
}

/* 手机号：11 位、以 1 开头、全数字。v1 只做形态校验，不做短信验证（见 api-design §2.1）。 */
public func isPhone(s: String): Bool {
    if (s.size != 11) {
        return false
    }
    if (!startsWithAscii(s, "1")) {
        return false
    }
    return isDigits(s)
}

/* 从 start 字节处截到末尾。 */
public func subFrom(s: String, start: Int64): String {
    let a = s.toArray()
    if (start >= a.size) {
        return ""
    }
    if (start < 0) {
        return s
    }
    return String.fromUtf8(a[start..a.size])
}

/* 去除首尾 ASCII 空白后是否为空。 */
public func isBlank(s: String): Bool {
    return s.trimAscii().size == 0
}

/*
 * 定时安全的字节比较（L-6）。
 *
 * 用途：注册口令、密码摘要这类"猜中了就通过"的比对。`==` 在第一个不同的字节就返回，
 * 逐字节试探理论上能把搜索空间从"猜整个值"压到"逐个字节猜"。本机测量这种差异
 * 淹没在 HTTP 抖动里，但修复成本几乎为零，所以比。
 *
 * 长度不同也要走完整圈：先记长度不等，再统一把较短串补 0 比完，最后合并结果。
 */
public func constantTimeEq(a: String, b: String): Bool {
    let x = a.toArray()
    let y = b.toArray()
    var diff: Int64 = if (x.size == y.size) { 0 } else { 1 }
    let n = if (x.size < y.size) { x.size } else { y.size }
    var i: Int64 = 0
    while (i < n) {
        diff = diff | Int64(x[i] ^ y[i])
        i += 1
    }
    return diff == 0
}
