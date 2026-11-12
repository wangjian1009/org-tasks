//! Edna 日期操作，包括相对日期、落点和 float；不依赖宿主时区解析器。
use super::{Result, error};
use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime, NaiveTime};

pub(super) fn read(raw: &str) -> Result<(NaiveDateTime, bool)> {
    let raw = raw.trim_start_matches(['<', '[']);
    let date = NaiveDate::parse_from_str(raw.get(..10).ok_or(error("日期无效"))?, "%Y-%m-%d")
        .map_err(|_| error("日期无效"))?;
    let clock = raw.split_whitespace().find_map(|part| {
        part.get(..5)
            .and_then(|s| NaiveTime::parse_from_str(s, "%H:%M").ok())
    });
    Ok((
        date.and_time(clock.unwrap_or(NaiveTime::MIN)),
        clock.is_some(),
    ))
}
fn weekday(s: &str) -> Option<u32> {
    match s.to_ascii_lowercase().as_str() {
        "sun" | "sunday" => Some(0),
        "mon" | "monday" => Some(1),
        "tue" | "tues" | "tuesday" => Some(2),
        "wed" | "wednesday" => Some(3),
        "thu" | "thur" | "thurs" | "thursday" => Some(4),
        "fri" | "friday" => Some(5),
        "sat" | "saturday" => Some(6),
        _ => None,
    }
}
fn month(s: &str) -> Option<u32> {
    s.parse().ok().or_else(|| {
        [
            "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
        ]
        .iter()
        .position(|m| s.to_ascii_lowercase().starts_with(m))
        .map(|n| n as u32 + 1)
    })
}
fn normalized(year: i32, month: i64, day: i64, time: NaiveTime) -> Result<NaiveDateTime> {
    let year = i64::from(year) + (month - 1).div_euclid(12);
    let month = (month - 1).rem_euclid(12) as u32 + 1;
    let value = i32::try_from(year)
        .ok()
        .and_then(|year| NaiveDate::from_ymd_opt(year, month, 1))
        .and_then(|date| {
            date.and_time(time)
                .checked_add_signed(Duration::try_days(day.checked_sub(1)?)?)
        })
        .ok_or(error("日期超出有效范围"))?;
    if !(1..=9999).contains(&value.year()) {
        return Err(error("日期超出有效范围"));
    }
    Ok(value)
}
pub(super) fn add(base: NaiveDateTime, n: i64, unit: &str) -> Result<NaiveDateTime> {
    let delta = match unit {
        "M" => Duration::try_minutes(n),
        "h" => Duration::try_hours(n),
        "d" => Duration::try_days(n),
        "w" => n.checked_mul(7).and_then(Duration::try_days),
        "m" | "y" => {
            let months = if unit == "y" {
                n.checked_mul(12)
            } else {
                Some(n)
            }
            .ok_or(error("日期超出有效范围"))?;
            return normalized(
                base.year(),
                i64::from(base.month())
                    .checked_add(months)
                    .ok_or(error("日期超出有效范围"))?,
                i64::from(base.day()),
                base.time(),
            );
        }
        _ => return Err(error("日期单位无效")),
    }
    .ok_or(error("日期超出有效范围"))?;
    let value = base
        .checked_add_signed(delta)
        .ok_or(error("日期超出有效范围"))?;
    if !(1..=9999).contains(&value.year()) {
        return Err(error("日期超出有效范围"));
    }
    Ok(value)
}
fn direction(s: &str) -> Result<(i64, bool, &str)> {
    let count = s.bytes().take_while(|c| matches!(c, b'+' | b'-')).count();
    if count > 2 {
        return Err(error("日期方向无效"));
    }
    Ok((
        if count > 0 && s.as_bytes()[count - 1] == b'-' {
            -1
        } else {
            1
        },
        count == 2,
        &s[count..],
    ))
}
fn lands(day: u32, s: &str) -> Result<bool> {
    Ok(match s.to_ascii_lowercase().as_str() {
        "weekday" | "wkdy" => (1..=5).contains(&day),
        "weekend" | "wknd" => day == 0 || day == 6,
        _ => day == weekday(s).ok_or(error("落点星期无效"))?,
    })
}
fn relative(
    arg: &str,
    old: Option<NaiveDateTime>,
    now: NaiveDateTime,
) -> Result<(NaiveDateTime, bool, bool)> {
    let mut words = arg.split_whitespace();
    let first = words.next().ok_or(error("缺少相对日期"))?;
    let (sign, current, rest) = direction(first)?;
    let base = if current {
        now
    } else {
        old.ok_or(error("不能递增不存在的时间戳"))?
    };
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    // Edna 对省略数字的相对表达式按 string-to-number 取 0。
    let n = if digits == 0 {
        0
    } else {
        rest[..digits]
            .parse::<i64>()
            .map_err(|_| error("日期间隔无效"))?
    };
    let unit = &rest[digits..];
    let mut value = if ["M", "h", "d", "w", "m", "y"].contains(&unit) {
        add(base, n * sign, unit)?
    } else if ["weekday", "wkdy"].contains(&unit) {
        let mut value = add(base, n * sign, "d")?;
        while !lands(value.weekday().num_days_from_sunday(), "wkdy")? {
            value = add(value, sign, "d")?;
        }
        value
    } else {
        let target = weekday(unit).ok_or(error("相对日期单位无效"))?;
        let mut delta =
            (i64::from(target) - i64::from(base.weekday().num_days_from_sunday())).rem_euclid(7);
        if delta == 0 {
            delta = 7;
        }
        if sign < 0 {
            delta -= 7;
            if delta == 0 {
                delta = -7;
            }
        }
        if n > 1 {
            delta += (n - 1) * 7 * sign;
        }
        add(base, delta, "d")?
    };
    if let Some(landing) = words.next() {
        if !["M", "h"].contains(&unit) {
            let (sign, _, landing) = direction(landing)?;
            while !lands(value.weekday().num_days_from_sunday(), landing)? {
                value = add(value, sign, "d")?;
            }
        }
    }
    if words.next().is_some() {
        return Err(error("相对日期参数过多"));
    }
    Ok((value, current, ["M", "h"].contains(&unit)))
}
fn floating(
    arg: &str,
    old: Option<NaiveDateTime>,
    now: NaiveDateTime,
) -> Result<(NaiveDateTime, bool, bool)> {
    let words = arg.split_whitespace().collect::<Vec<_>>();
    if !(3..=5).contains(&words.len()) {
        return Err(error("float 日期参数无效"));
    }
    let (sign, current, n) = direction(words[1])?;
    let n: i64 = n.parse().map_err(|_| error("float 次数无效"))?;
    if n == 0 || n > 10000 {
        return Err(error("float 次数超出有效范围"));
    }
    let base = if current {
        now
    } else {
        old.ok_or(error("不能递增不存在的时间戳"))?
    };
    let target = weekday(words[2])
        .or_else(|| words[2].parse::<u32>().ok().filter(|n| *n < 7))
        .ok_or(error("float 星期无效"))?;
    let m = words
        .get(3)
        .map(|s| month(s).ok_or(error("float 月份无效")))
        .transpose()?
        .unwrap_or(0);
    if m > 12 {
        return Err(error("float 月份无效"));
    }
    let (year, m) = if m == 0 {
        (base.year(), i64::from(base.month()) + sign)
    } else {
        (
            base.year()
                + if sign > 0 && m <= base.month() {
                    1
                } else if sign < 0 && m >= base.month() {
                    -1
                } else {
                    0
                },
            i64::from(m),
        )
    };
    let day = words
        .get(4)
        .map(|s| s.parse::<i64>().map_err(|_| error("float 日期无效")))
        .transpose()?
        .unwrap_or(0);
    let mut value = if day != 0 {
        normalized(year, m, day, base.time())?
    } else if sign > 0 {
        normalized(year, m, 1, base.time())?
    } else {
        add(normalized(year, m + 1, 1, base.time())?, -1, "d")?
    };
    let delta = if sign > 0 {
        (i64::from(target) - i64::from(value.weekday().num_days_from_sunday())).rem_euclid(7)
    } else {
        -(i64::from(value.weekday().num_days_from_sunday()) - i64::from(target)).rem_euclid(7)
    };
    value = add(value, delta + (n - 1) * 7 * sign, "d")?;
    Ok((value, current, false))
}
fn replace_date(raw: &str, value: NaiveDateTime, include_time: bool) -> String {
    let mut result = raw.to_owned();
    let start = usize::from(result.starts_with(['<', '[']));
    result.replace_range(start..start + 10, &value.format("%Y-%m-%d").to_string());
    let close = result.find(['>', ']']).unwrap_or(result.len());
    let mut tail = result[start + 10..close]
        .split_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if tail
        .first()
        .is_some_and(|s| s.chars().all(char::is_alphabetic))
    {
        tail.remove(0);
    }
    if include_time {
        if let Some(index) = tail.iter().position(|s| s.as_bytes().get(2) == Some(&b':')) {
            let old = tail[index].clone();
            let suffix = old.get(5..).unwrap_or("");
            // org-timestamp-change 的时刻范围保持持续时长。
            tail[index] = if let Some(end) = suffix
                .strip_prefix('-')
                .and_then(|s| s.get(..5))
                .and_then(|s| NaiveTime::parse_from_str(s, "%H:%M").ok())
            {
                let begin = NaiveTime::parse_from_str(&old[..5], "%H:%M").unwrap();
                format!(
                    "{}-{}",
                    value.format("%H:%M"),
                    (value + (end - begin)).format("%H:%M")
                )
            } else {
                format!("{}{suffix}", value.format("%H:%M"))
            };
        } else {
            tail.insert(0, value.format("%H:%M").to_string());
        }
    }
    let tail = if tail.is_empty() {
        String::new()
    } else {
        format!(" {}", tail.join(" "))
    };
    result.replace_range(start + 10..close, &format!(" {}{tail}", value.format("%a")));
    result
}
pub(super) fn plan(
    arg: &str,
    old: Option<&str>,
    source: Option<&str>,
    format: Option<&str>,
    now: NaiveDateTime,
    utc_offset: i32,
) -> Result<Option<String>> {
    if ["rm", "remove"].contains(&arg) {
        return Ok(None);
    }
    if ["cp", "copy"].contains(&arg) {
        let (value, clock) = read(source.ok_or(error("来源没有可复制的时间戳"))?)?;
        return Ok(Some(format!(
            "<{}>",
            value.format(if clock {
                "%Y-%m-%d %a %H:%M"
            } else {
                "%Y-%m-%d %a"
            })
        )));
    }
    let old_time = old.map(read).transpose()?;
    if arg.starts_with(['+', '-']) || arg.starts_with("float ") {
        let (value, current, force_time) = if arg.starts_with("float ") {
            floating(arg, old_time.map(|v| v.0), now)?
        } else {
            relative(arg, old_time.map(|v| v.0), now)?
        };
        let include_time = if let Some((_, time)) = old_time {
            time
        } else if force_time {
            true
        } else {
            match format {
                None | Some("short") => false,
                Some("long") => true,
                _ => return Err(error("EDNA_TS_FORMAT 必须为 short 或 long")),
            }
        };
        let template = if current {
            format!(
                "<{}>",
                now.format(if include_time {
                    "%Y-%m-%d %a %H:%M"
                } else {
                    "%Y-%m-%d %a"
                })
            )
        } else {
            old.unwrap().into()
        };
        return Ok(Some(replace_date(&template, value, include_time)));
    }
    // Org 的绝对日期与星期快捷形式；不接受无法确定含义的自然语言。
    let arg = arg.trim_matches(['<', '>']);
    let mut words = arg.split_whitespace();
    let first = words.next().ok_or(error("缺少日期"))?;
    let date = if let Ok(date) = NaiveDate::parse_from_str(first, "%Y-%m-%d") {
        date
    } else if let Some(target) = weekday(first) {
        let base = old_time.map_or(now, |v| v.0);
        let delta =
            (i64::from(target) - i64::from(base.weekday().num_days_from_sunday())).rem_euclid(7);
        add(base, if delta == 0 { 7 } else { delta }, "d")?.date()
    } else if first == "." || first == "today" {
        now.date()
    } else if first == "tomorrow" {
        add(now, 1, "d")?.date()
    } else if first == "yesterday" {
        add(now, -1, "d")?.date()
    } else {
        return Err(error("日期表达式无法解析"));
    };
    let mut clock = None;
    for word in words {
        if weekday(word).is_some() {
            continue;
        }
        if clock.is_some() {
            return Err(error("日期参数过多"));
        }
        clock = Some(NaiveTime::parse_from_str(word, "%H:%M").map_err(|_| error("日期时刻无效"))?);
    }
    // Edna 将 org-read-date-analyze 的空时区替换为 0，再以本地时间输出。
    let value = add(
        date.and_time(clock.unwrap_or(NaiveTime::MIN)),
        i64::from(utc_offset) / 60,
        "M",
    )?;
    Ok(Some(format!(
        "<{}>",
        value.format(if clock.is_some() {
            "%Y-%m-%d %a %H:%M"
        } else {
            "%Y-%m-%d %a"
        })
    )))
}

pub(super) fn supports(arg: &str) -> bool {
    if arg.starts_with(['+', '-'])
        || arg.starts_with("float ")
        || ["rm", "remove", "cp", "copy"].contains(&arg)
    {
        return true;
    }
    let first = arg
        .trim_matches(['<', '>'])
        .split_whitespace()
        .next()
        .unwrap_or("");
    NaiveDate::parse_from_str(first, "%Y-%m-%d").is_ok()
        || weekday(first).is_some()
        || [".", "today", "tomorrow", "yesterday"].contains(&first)
}
