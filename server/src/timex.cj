package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 时间与时区 —— 全项目唯一口径（api-design §1.8）。
 *
 * 事实：
 *   · 服务端**统一存 UTC epoch 秒**（Int64），展示时转本地
 *   · 本项目固定 +08:00（中国大陆），偏移量只在这里定义一次
 *   · 「逾期」是派生量（v1-scope 规则 15），由 due_at 与当前时间算出，绝不落盘
 *
 * 为什么自己算历法：轻舟 docs/API.md 第 428 行明确写了 std.time 没有 UTC 工厂方法，
 * 且 DateTime 的本地字段依赖机器时区。自己按 epoch 做纯函数换算，
 * 结果与机器时区无关、可单测、可对拍——这正是"服务端权威"要的性质。
 *
 * 算法：Howard Hinnant 的 civil_from_days / days_from_civil（公有领域，广泛验证）。
 * 只处理 epoch >= 0（1970 之后），负 epoch 不在本工具的时间范围内。
 */

import std.time.*

/* 时区偏移（秒）。改这里就是改全项目口径。 */
public let TZ_OFFSET: Int64 = 8 * 3600
public let DAY_SECONDS: Int64 = 86400

public func nowEpoch(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

/* epoch 天 → (年, 月, 日)。仅 z0 >= 0。 */
func civilFromDays(z0: Int64): (Int64, Int64, Int64) {
    let z = z0 + 719468
    let era = z / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y0 = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = if (mp < 10) {
        mp + 3
    } else {
        mp - 9
    }
    let y = if (m <= 2) {
        y0 + 1
    } else {
        y0
    }
    return (y, m, d)
}

/* (年, 月, 日) → epoch 天。 */
func daysFromCivil(y0: Int64, m: Int64, d: Int64): Int64 {
    let y = if (m <= 2) {
        y0 - 1
    } else {
        y0
    }
    let era = y / 400
    let yoe = y - era * 400
    let mp = if (m > 2) {
        m - 3
    } else {
        m + 9
    }
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

/* epoch → 本地 (+08:00) 的 (年,月,日,时,分,秒)。 */
public func partsLocal(epoch: Int64): (Int64, Int64, Int64, Int64, Int64, Int64) {
    let t = epoch + TZ_OFFSET
    let days = t / DAY_SECONDS
    let rem = t - days * DAY_SECONDS
    let civil = civilFromDays(days)
    let hh = rem / 3600
    let mm = (rem - hh * 3600) / 60
    let ss = rem - hh * 3600 - mm * 60
    return (civil[0], civil[1], civil[2], hh, mm, ss)
}

func padN2(n: Int64): String {
    if (n < 10) {
        return "0${n}"
    }
    return "${n}"
}

func padN4(n: Int64): String {
    if (n < 10) {
        return "000${n}"
    }
    if (n < 100) {
        return "00${n}"
    }
    if (n < 1000) {
        return "0${n}"
    }
    return "${n}"
}

/* 时区偏移的 ISO 形式，如 "+08:00"。 */
func tzSuffix(): String {
    let off = TZ_OFFSET
    let sign = if (off < 0) { "-" } else { "+" }
    let a = if (off < 0) { 0 - off } else { off }
    let hh = a / 3600
    let mm = (a - hh * 3600) / 60
    return "${sign}${padN2(hh)}:${padN2(mm)}"
}

/* API 对外的时间格式：2026-09-20T18:00:00+08:00 */
public func isoLocal(epoch: Int64): String {
    let p = partsLocal(epoch)
    return "${padN4(p[0])}-${padN2(p[1])}-${padN2(p[2])}T${padN2(p[3])}:${padN2(p[4])}:${padN2(p[5])}${tzSuffix()}"
}

/* 日志用的 UTC 形式。 */
public func isoUtc(epoch: Int64): String {
    let days = epoch / DAY_SECONDS
    let rem = epoch - days * DAY_SECONDS
    let civil = civilFromDays(days)
    let hh = rem / 3600
    let mm = (rem - hh * 3600) / 60
    let ss = rem - hh * 3600 - mm * 60
    return "${padN4(civil[0])}-${padN2(civil[1])}-${padN2(civil[2])}T${padN2(hh)}:${padN2(mm)}:${padN2(ss)}Z"
}

/* 从 b 的 pos 处取 len 位数字；非法返回 -1。 */
func numAt(b: Array<UInt8>, pos: Int64, len: Int64): Int64 {
    if (pos < 0 || pos + len > b.size) {
        return -1
    }
    var v: Int64 = 0
    var i: Int64 = 0
    while (i < len) {
        let c = b[pos + i]
        if (c < 48 || c > 57) {
            return -1
        }
        v = v * 10 + Int64(c - 48)
        i += 1
    }
    return v
}

/*
 * 解析 ISO 8601。接受：
 *   2026-09-20T18:00:00+08:00   （标准形态，客户端发这个）
 *   2026-09-20T18:00:00Z
 *   2026-09-20T18:00:00        （无偏移，按 +08:00 解释）
 *   2026-09-20 18:00:00        （空格分隔）
 *   2026-09-20                 （当日 00:00:00 本地）
 * 其余一律 None（调用方转 VALIDATION_FAILED）。
 */
public func parseIso(s: String): ?Int64 {
    let b = s.toArray()
    if (b.size < 10) {
        return None
    }
    let y = numAt(b, 0, 4)
    let mo = numAt(b, 5, 2)
    let d = numAt(b, 8, 2)
    if (y < 0 || mo < 0 || d < 0) {
        return None
    }
    if (b[4] != 45 || b[7] != 45) {
        return None
    }

    var hh: Int64 = 0
    var mi: Int64 = 0
    var ss: Int64 = 0
    var pos: Int64 = 10
    if (b.size > 10) {
        let sep = b[10]
        if (sep != 84 && sep != 32) {
            return None
        }
        if (b.size < 19) {
            return None
        }
        hh = numAt(b, 11, 2)
        mi = numAt(b, 14, 2)
        ss = numAt(b, 17, 2)
        if (hh < 0 || mi < 0 || ss < 0) {
            return None
        }
        if (b[13] != 58 || b[16] != 58) {
            return None
        }
        pos = 19
    }

    var off: Int64 = TZ_OFFSET
    if (pos < b.size) {
        let c = b[pos]
        if (c == 90) {
            off = 0
            pos += 1
        } else if (c == 43 || c == 45) {
            if (b.size < pos + 6) {
                return None
            }
            let oh = numAt(b, pos + 1, 2)
            let om = numAt(b, pos + 4, 2)
            if (oh < 0 || om < 0 || b[pos + 3] != 58) {
                return None
            }
            off = oh * 3600 + om * 60
            if (c == 45) {
                off = 0 - off
            }
            pos += 6
        } else {
            return None
        }
    }
    if (pos != b.size) {
        return None
    }
    if (mo < 1 || mo > 12 || d < 1 || d > 31) {
        return None
    }
    if (hh > 23 || mi > 59 || ss > 60) {
        return None
    }

    let days = daysFromCivil(y, mo, d)
    return Some(days * DAY_SECONDS + hh * 3600 + mi * 60 + ss - off)
}

/* 本地 (+08:00) 当天的 00:00:00 对应 epoch。 */
public func startOfLocalDay(epoch: Int64): Int64 {
    let t = epoch + TZ_OFFSET
    let days = t / DAY_SECONDS
    return days * DAY_SECONDS - TZ_OFFSET
}


/* 逾期是派生量，永不落盘。 */
public func isOverdue(dueAt: Int64, now: Int64): Bool {
    if (dueAt <= 0) {
        return false
    }
    return dueAt < now
}
