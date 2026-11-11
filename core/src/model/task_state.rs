//! 任务状态、重复调度和配置驱动日志；语义依据 Org Info 的 Progress Logging 与 Repeated tasks。
use super::task_operation_executor::{
    end, newline, planning, planning_lines, replace, start, validate_state,
};
use super::{CoreError, OrgFile, TodoLogAction, TodoWorkflowKind};
use chrono::{Datelike, Duration, Months, NaiveDate, NaiveDateTime, NaiveTime, Timelike};
use orgize::{
    SyntaxKind,
    ast::{Drawer, Headline, Timestamp},
    rowan::ast::AstNode,
};
use std::{collections::BTreeMap, ops::Range};

struct Logging {
    done: Option<TodoLogAction>,
    repeat: Option<TodoLogAction>,
    states: BTreeMap<String, (Option<TodoLogAction>, Option<TodoLogAction>)>,
    drawer: Option<String>,
    reversed: bool,
}

fn keywords(file: &OrgFile) -> Result<Vec<(String, String)>, CoreError> {
    let mut settings = super::service::file_keywords(file.todo_setup.as_bytes())?;
    settings.extend(super::service::file_keywords(file.source_bytes())?);
    Ok(settings)
}

fn property(
    file: &OrgFile,
    headline: &Headline,
    name: &str,
    inherit: bool,
) -> Result<Option<String>, CoreError> {
    let headline = metadata_node(file, headline);
    Ok(super::properties::resolve(
        &headline, name,
        file.file_keywords.properties.get(&name.to_ascii_uppercase()).map(String::as_str),
        inherit,
    ))
}

impl Logging {
    fn option(&mut self, option: &str) {
        use TodoLogAction::{Note, Time};
        match option.to_ascii_lowercase().as_str() {
            "logdone" => self.done = Some(Time),
            "lognotedone" => self.done = Some(Note),
            "nologdone" => self.done = None,
            "logrepeat" => self.repeat = Some(Time),
            "lognoterepeat" => self.repeat = Some(Note),
            "nologrepeat" => self.repeat = None,
            "logdrawer" => self.drawer = Some("LOGBOOK".into()),
            "nologdrawer" => self.drawer = None,
            "logstatesreversed" => self.reversed = true,
            "nologstatesreversed" => self.reversed = false,
            _ => (),
        }
    }

    fn load(file: &OrgFile, headline: &Headline) -> Result<Self, CoreError> {
        let mut result = Self {
            done: None,
            repeat: None,
            states: BTreeMap::new(),
            drawer: None,
            reversed: true,
        };
        for flow in &file.todo.workflows {
            for state in &flow.states {
                result
                    .states
                    .insert(state.name.clone(), (state.enter_log, state.leave_log));
            }
        }
        for (key, value) in keywords(file)? {
            if key == "STARTUP" {
                for option in value.split_whitespace() {
                    result.option(option);
                }
            }
        }
        if let Some(value) =
            property(file, headline, "LOGGING", true)?.filter(|value| !value.is_empty())
        {
            result.done = None;
            result.repeat = None;
            result.states.clear();
            for option in value.split_whitespace() {
                if matches!(
                    option.to_ascii_lowercase().as_str(),
                    "logdone"
                        | "lognotedone"
                        | "nologdone"
                        | "logrepeat"
                        | "lognoterepeat"
                        | "nologrepeat"
                ) {
                    result.option(option);
                }
                if option.contains('(') {
                    let state = super::todo::parse_state(option)?;
                    result
                        .states
                        .insert(state.name, (state.enter_log, state.leave_log));
                }
            }
        }
        if let Some(value) = property(file, headline, "LOG_INTO_DRAWER", true)? {
            result.drawer = match value.as_str() {
                "nil" => None,
                "t" => Some("LOGBOOK".into()),
                _ => Some(value),
            };
        }
        if result.drawer.as_ref().is_some_and(|name| {
            name.is_empty() || !name.chars().all(|c| c.is_alphanumeric() || c == '_')
        }) {
            return Err(CoreError::InvalidInput("日志 drawer 名称无效"));
        }
        Ok(result)
    }
}

fn node_at(file: &OrgFile, offset: usize) -> Result<Headline, CoreError> {
    file.path_headlines()
        .into_iter()
        .map(|(_, node)| node)
        .find(|node| start(node) == offset)
        .ok_or(CoreError::InvalidInput("状态修改破坏了标题结构"))
}

fn set_keyword(
    file: &mut OrgFile,
    headline: &Headline,
    value: Option<&str>,
) -> Result<(), CoreError> {
    validate_state(file, value)?;
    if let Some(token) = headline.todo_keyword() {
        let a = u32::from(token.text_range().start()) as usize;
        let mut b = a + token.len();
        if value.is_none() && file.source_bytes().get(b) == Some(&b' ') {
            b += 1;
        }
        replace(file, a..b, value.unwrap_or("").as_bytes())?;
    } else if let Some(value) = value {
        let a = start(headline) + headline.level() + 1;
        replace(file, a..a, format!("{value} ").as_bytes())?;
    }
    let updated = node_at(file, start(headline))?;
    if updated
        .todo_keyword()
        .map(|token| token.to_string())
        .as_deref()
        != value
        || updated.title_raw() != headline.title_raw()
    {
        return Err(CoreError::InvalidInput(
            "标题或状态不能被 Org 重新解释为其他字段",
        ));
    }
    Ok(())
}

pub(super) fn modify(
    file: &mut OrgFile,
    headline: &Headline,
    value: Option<&str>,
) -> Result<(), CoreError> {
    modify_at(file, headline, value, chrono::Local::now().naive_local())
}

/// 新建时不模拟状态切换；完成时间与关闭说明同样只由显式配置触发。
pub(super) fn log_created_completion(
    file: &mut OrgFile,
    headline: &Headline,
    now: NaiveDateTime,
) -> Result<(), CoreError> {
    if !headline.todo_keyword().is_some_and(|state| {
        file.todo.done_keywords.iter().any(|done| done == state.as_ref())
    }) {
        return Ok(());
    }
    let settings = Logging::load(file, headline)?;
    if settings.done.is_none() {
        return Ok(());
    }
    let timestamp = now.format("[%Y-%m-%d %a %H:%M]").to_string();
    let offset = start(headline);
    planning(
        file, headline, "CLOSED", SyntaxKind::PLANNING_CLOSED,
        &Some(timestamp.clone()),
    )?;
    if settings.done == Some(TodoLogAction::Note) {
        add_log(
            file, &node_at(file, offset)?, &settings,
            &format!("- CLOSING NOTE {timestamp}"),
        )?;
    }
    Ok(())
}

fn modify_at(
    file: &mut OrgFile,
    headline: &Headline,
    value: Option<&str>,
    now: NaiveDateTime,
) -> Result<(), CoreError> {
    validate_state(file, value)?;
    let previous = headline.todo_keyword().map(|token| token.to_string());
    if previous.as_deref() != value
        && headline
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
            .any(|child| start(&child) != start(headline) && child.todo_keyword().is_some())
    {
        return Err(CoreError::InvalidInput("存在子任务时不能修改父任务状态"));
    }
    let settings = Logging::load(file, headline)?;
    let was_done = previous
        .as_ref()
        .is_some_and(|state| file.todo.done_keywords.contains(state));
    let is_done = value.is_some_and(|state| {
        file.todo
            .done_keywords
            .iter()
            .any(|keyword| keyword == state)
    });
    let entered_done = is_done && !was_done;
    let timestamp = now.format("[%Y-%m-%d %a %H:%M]").to_string();
    let offset = start(headline);
    // 在改动前计算全部时间戳，非法重复规则会使整个操作组失败。
    let repeated = if entered_done {
        repeat_edits(headline, now)?
    } else {
        Vec::new()
    };
    let repeating = !repeated.is_empty();
    let repeat_state = if repeating {
        repeat_state(file, headline, previous.as_deref())?
    } else {
        value.map(str::to_owned)
    };
    let log_action = value
        .and_then(|state| settings.states.get(state))
        .and_then(|pair| pair.0)
        .or_else(|| {
            previous
                .as_ref()
                .and_then(|state| settings.states.get(state))
                .and_then(|pair| pair.1)
        });
    for (range, value) in repeated.into_iter().rev() {
        replace(file, range, value.as_bytes())?;
    }
    set_keyword(file, &node_at(file, offset)?, repeat_state.as_deref())?;
    let updated = node_at(file, offset)?;
    if !is_done || repeating {
        planning(file, &updated, "CLOSED", SyntaxKind::PLANNING_CLOSED, &None)?;
    } else if settings.done.is_some() && (entered_done || updated.closed().is_none()) {
        planning(
            file,
            &updated,
            "CLOSED",
            SyntaxKind::PLANNING_CLOSED,
            &Some(timestamp.clone()),
        )?;
    }
    if repeating {
        let updated = node_at(file, offset)?;
        if updated
            .scheduled()
            .is_some_and(|ts| repeater(&ts.raw()).is_none())
        {
            planning(
                file,
                &updated,
                "SCHEDULED",
                SyntaxKind::PLANNING_SCHEDULED,
                &None,
            )?;
        }
        let updated = node_at(file, offset)?;
        let has_clock = updated.section().is_some_and(|section| {
            section
                .syntax()
                .descendants()
                .any(|node| node.kind() == SyntaxKind::CLOCK)
        });
        if settings.repeat.is_some() || has_clock {
            set_property(file, &updated, "LAST_REPEAT", &timestamp)?;
        }
    }
    // 与 Org 一致，目标状态的进入日志优先于来源状态的离开日志；无状态目标不记状态日志。
    if let Some(state) =
        value.filter(|_| log_action.is_some() || (repeating && settings.repeat.is_some()))
    {
        let log = format!(
            "- State {:<12} from {:<12} {timestamp}",
            format!("\"{state}\""),
            format!("\"{}\"", previous.as_deref().unwrap_or(""))
        );
        add_log(file, &node_at(file, offset)?, &settings, &log)?;
    } else if entered_done && settings.done == Some(TodoLogAction::Note) {
        add_log(
            file,
            &node_at(file, offset)?,
            &settings,
            &format!("- CLOSING NOTE {timestamp}"),
        )?;
    }
    Ok(())
}

fn repeat_state(
    file: &OrgFile,
    headline: &Headline,
    previous: Option<&str>,
) -> Result<Option<String>, CoreError> {
    if let Some(state) = property(file, headline, "REPEAT_TO_STATE", false)?
        && validate_state(file, Some(&state)).is_ok()
    {
        return Ok(Some(state));
    }
    let flow = file.todo.workflows.iter().find(|flow| {
        flow.states
            .iter()
            .any(|state| Some(state.name.as_str()) == previous)
    });
    if flow.is_some_and(|flow| flow.kind == TodoWorkflowKind::Type) {
        return Ok(previous.map(str::to_owned));
    }
    Ok(flow
        .and_then(|flow| flow.states.first())
        .map(|state| state.name.clone())
        .or_else(|| file.todo.initial_state.clone()))
}

fn metadata_node(file: &OrgFile, headline: &Headline) -> Headline {
    let source = std::str::from_utf8(file.source_bytes()).expect("UTF-8");
    let masked = mask_repeater_windows(source);
    if masked == source {
        return headline.clone();
    }
    orgize::Org::parse(&masked)
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
        .find(|node| start(node) == start(headline))
        .unwrap_or_else(|| headline.clone())
}

fn body_start(file: &OrgFile, headline: &Headline) -> usize {
    let mut at = file.source_bytes()[start(headline)..]
        .iter()
        .position(|byte| *byte == b'\n')
        .map(|n| start(headline) + n + 1)
        .unwrap_or(end(headline));
    if let Some((_, last, _)) = planning_lines(file, headline).last() {
        at = at.max(*last);
    }
    if let Some(drawer) = metadata_node(file, headline).properties() {
        at = at.max(u32::from(drawer.end()) as usize);
    }
    at
}

fn insert_line(file: &mut OrgFile, at: usize, content: &str) -> Result<(), CoreError> {
    let prefix = if at > 0 && file.source_bytes()[at - 1] != b'\n' {
        newline(file)
    } else {
        ""
    };
    replace(
        file,
        at..at,
        format!("{prefix}{content}{}", newline(file)).as_bytes(),
    )
}

fn set_property(
    file: &mut OrgFile,
    headline: &Headline,
    name: &str,
    value: &str,
) -> Result<(), CoreError> {
    if let Some(drawer) = metadata_node(file, headline).properties() {
        if let Some(entry) = super::properties::entries(&drawer)
            .find(|entry| !entry.append && entry.name.eq_ignore_ascii_case(name))
        {
            let range = entry.value_range;
            return replace(
                file,
                u32::from(range.start()) as usize..u32::from(range.end()) as usize,
                value.as_bytes(),
            );
        }
        return insert_line(
            file,
            u32::from(drawer.content_start()) as usize,
            &format!(":{name}: {value}"),
        );
    }
    let nl = newline(file);
    insert_line(
        file,
        body_start(file, headline),
        &format!(":PROPERTIES:{nl}:{name}: {value}{nl}:END:"),
    )
}

fn add_log(
    file: &mut OrgFile,
    headline: &Headline,
    settings: &Logging,
    log: &str,
) -> Result<(), CoreError> {
    if let Some(name) = &settings.drawer {
        if let Some(drawer) = headline
            .section()
            .into_iter()
            .flat_map(|section| {
                section
                    .syntax()
                    .children()
                    .filter_map(Drawer::cast)
                    .collect::<Vec<_>>()
            })
            .find(|drawer| drawer.name().eq_ignore_ascii_case(name))
        {
            let at = if settings.reversed {
                drawer.content_start()
            } else {
                drawer.content_end()
            };
            return insert_line(file, u32::from(at) as usize, log);
        }
        let nl = newline(file);
        return insert_line(
            file,
            body_start(file, headline),
            &format!(":{name}:{nl}{log}{nl}:END:"),
        );
    }
    let mut at = body_start(file, headline);
    if !settings.reversed {
        let source = std::str::from_utf8(&file.source_bytes()[at..end(headline)]).expect("UTF-8");
        for line in source.split_inclusive('\n') {
            if !line.trim_start().starts_with("- State ") && !line.trim().is_empty() {
                break;
            }
            at += line.len();
        }
    }
    insert_line(file, at, log)
}

#[derive(Clone, Copy)]
struct Repeater {
    kind: u8,
    count: u32,
    unit: u8,
}

fn repeater(raw: &str) -> Option<Repeater> {
    for part in raw
        .split('>')
        .next()
        .unwrap_or(raw)
        .trim_start_matches('<')
        .split_whitespace()
    {
        let (kind, rest) = if let Some(rest) = part.strip_prefix("++") {
            (b'+', rest)
        } else if let Some(rest) = part.strip_prefix(".+") {
            (b'.', rest)
        } else if let Some(rest) = part.strip_prefix('+') {
            (b' ', rest)
        } else {
            continue;
        };
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        let count = rest.get(..digits)?.parse().ok()?;
        let unit = *rest.as_bytes().get(digits)?;
        if !b"hdwmy".contains(&unit) || count == 0 {
            continue;
        }
        let suffix = &rest[digits + 1..];
        if !suffix.is_empty() && !suffix.starts_with('/') {
            continue;
        }
        return Some(Repeater { kind, count, unit });
    }
    None
}

fn add_months(time: NaiveDateTime, months: u32) -> Option<NaiveDateTime> {
    // Org 使用 encode-time 的溢出归一化：一月三十一日加一月会进入三月。
    time.with_day(1)?
        .checked_add_months(Months::new(months))?
        .checked_add_signed(Duration::days(i64::from(time.day() - 1)))
}

fn advance(time: NaiveDateTime, rule: Repeater) -> Result<NaiveDateTime, CoreError> {
    let result = match rule.unit {
        b'h' => time.checked_add_signed(Duration::hours(i64::from(rule.count))),
        b'd' => time.checked_add_signed(Duration::days(i64::from(rule.count))),
        b'w' => time.checked_add_signed(Duration::days(i64::from(rule.count) * 7)),
        b'm' => add_months(time, rule.count),
        b'y' => rule.count.checked_mul(12).and_then(|n| add_months(time, n)),
        _ => None,
    };
    result.ok_or(CoreError::InvalidInput("重复时间超出有效日期范围"))
}

fn shift(raw: &str, now: NaiveDateTime) -> Result<String, CoreError> {
    let mut parts = raw
        .char_indices()
        .filter_map(|(i, c)| (c == '<').then_some(i))
        .collect::<Vec<_>>();
    parts.push(raw.len());
    let mut result = raw.to_owned();
    let mut all_edits = Vec::new();
    for pair in parts.windows(2) {
        let a = pair[0];
        let Some(close) = raw[a..pair[1]].find('>').map(|i| a + i) else {
            continue;
        };
        let Some(rule) = repeater(&raw[a..=close]) else {
            continue;
        };
        let date = NaiveDate::parse_from_str(
            raw.get(a + 1..a + 11)
                .ok_or(CoreError::InvalidInput("重复日期无效"))?,
            "%Y-%m-%d",
        )
        .map_err(|_| CoreError::InvalidInput("重复日期无效"))?;
        let mut weekday = None;
        let mut clock = None;
        let mut cursor = a + 11;
        for word in raw[a + 11..close].split_whitespace() {
            let position = raw[cursor..close].find(word).map(|n| cursor + n).unwrap();
            cursor = position + word.len();
            if weekday.is_none() && word.chars().all(char::is_alphabetic) {
                weekday = Some(position..cursor);
            }
            if clock.is_none()
                && word.len() >= 5
                && word.as_bytes().get(2) == Some(&b':')
                && let Ok(value) = NaiveTime::parse_from_str(&word[..5], "%H:%M")
            {
                clock = Some((position..position + 5, value));
            }
        }
        if rule.unit == b'h' && clock.is_none() {
            return Err(CoreError::InvalidInput("按小时重复必须指定时刻"));
        }
        let original = date.and_time(
            clock
                .as_ref()
                .map(|(_, value)| *value)
                .unwrap_or(NaiveTime::MIN),
        );
        let shifted = {
            let base = if rule.kind == b'.' {
                if rule.unit == b'h' {
                    now.with_second(0).unwrap().with_nanosecond(0).unwrap()
                } else {
                    now.date().and_time(original.time())
                }
            } else {
                original
            };
            let mut next = advance(base, rule)?;
            if rule.kind == b'+' {
                while if rule.unit == b'h' {
                    next <= now
                } else {
                    next.date() <= now.date()
                } {
                    next = advance(next, rule)?;
                }
            }
            next
        };
        if !(1..=9999).contains(&shifted.year()) {
            return Err(CoreError::InvalidInput("重复时间超出有效日期范围"));
        }
        let mut edits = vec![(a + 1..a + 11, shifted.format("%Y-%m-%d").to_string())];
        if let Some(range) = weekday {
            edits.push((range, shifted.format("%a").to_string()));
        } else {
            edits.push((a + 11..a + 11, format!(" {}", shifted.format("%a"))));
        }
        if rule.unit == b'h' {
            if let Some((range, _)) = &clock {
                edits.push((range.clone(), shifted.format("%H:%M").to_string()));
            }
            // 同日时刻范围保持原持续时间。
            if let Some((range, original_time)) = clock
                && raw.as_bytes().get(range.end) == Some(&b'-')
            {
                let target = range.end + 1..range.end + 6;
                let old_end = NaiveTime::parse_from_str(
                    raw.get(target.clone())
                        .ok_or(CoreError::InvalidInput("重复时刻范围无效"))?,
                    "%H:%M",
                )
                .map_err(|_| CoreError::InvalidInput("重复时刻范围无效"))?;
                let duration = old_end - original_time;
                edits.push((target, (shifted + duration).format("%H:%M").to_string()));
            }
        }
        // 先收集全部字节区间，统一倒序替换，原重复器、预警及其他修饰保持原样。
        for (relative, _) in raw[a..close].match_indices(" --") {
            let begin = a + relative;
            let token = raw[begin + 3..close]
                .split_whitespace()
                .next()
                .unwrap_or("");
            let digits = token.bytes().take_while(u8::is_ascii_digit).count();
            if digits > 0
                && token.len() == digits + 1
                && b"hdwmy".contains(&token.as_bytes()[digits])
            {
                edits.push((begin..begin + 3 + token.len(), String::new()));
            }
        }
        all_edits.extend(edits);
    }
    all_edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    for (range, value) in all_edits {
        result.replace_range(range, &value);
    }
    Ok(result)
}

/// 为 orgize 尚未识别的 /Nunit 窗口提供等长解析投影，源文件字节不变。
pub(super) fn mask_repeater_windows(source: &str) -> String {
    let mut bytes = source.as_bytes().to_vec();
    let mut cursor = 0;
    while let Some(relative) = source[cursor..].find('<') {
        let begin = cursor + relative;
        let Some(end) = source[begin..].find('>').map(|n| begin + n) else {
            break;
        };
        cursor = end + 1;
        if source
            .get(begin + 1..begin + 11)
            .is_none_or(|date| NaiveDate::parse_from_str(date, "%Y-%m-%d").is_err())
        {
            continue;
        }
        for (relative, _) in source[begin..end].match_indices('/') {
            let slash = begin + relative;
            let before = source[begin..slash].split_whitespace().last().unwrap_or("");
            let tail = &source[slash + 1..end];
            let digits = tail.bytes().take_while(u8::is_ascii_digit).count();
            if digits == 0 || repeater(before).is_none() {
                continue;
            }
            let finish = slash
                + 1
                + digits
                + usize::from(
                    tail.as_bytes()
                        .get(digits)
                        .is_some_and(|unit| b"hdwmy".contains(unit)),
                );
            if finish < end && !source.as_bytes()[finish].is_ascii_whitespace() {
                continue;
            }
            bytes[slash..finish].fill(b' ');
        }
    }
    String::from_utf8(bytes).expect("只替换 ASCII 重复窗口")
}

fn repeat_edits(
    headline: &Headline,
    now: NaiveDateTime,
) -> Result<Vec<(Range<usize>, String)>, CoreError> {
    let mut timestamps = BTreeMap::new();
    for node in headline.syntax().descendants() {
        if node
            .ancestors()
            .filter_map(Headline::cast)
            .next()
            .is_none_or(|parent| start(&parent) != start(headline))
        {
            continue;
        }
        if let Some(timestamp) = Timestamp::cast(node.clone()).filter(Timestamp::is_active) {
            timestamps.insert(
                u32::from(timestamp.start()) as usize,
                (u32::from(timestamp.end()) as usize, timestamp.raw()),
            );
        } else if matches!(
            node.kind(),
            SyntaxKind::PARAGRAPH | SyntaxKind::HEADLINE_TITLE
        ) {
            let raw = node.to_string();
            let masked = mask_repeater_windows(&raw);
            if raw == masked {
                continue;
            }
            // 仍由 orgize 识别真实时间戳，代码、逐字内容与链接中的伪时间戳不参与。
            let parsed = orgize::Org::parse(&masked);
            let base = u32::from(node.text_range().start()) as usize;
            for timestamp in parsed
                .document()
                .syntax()
                .descendants()
                .filter_map(Timestamp::cast)
                .filter(Timestamp::is_active)
            {
                let a = u32::from(timestamp.start()) as usize;
                let b = u32::from(timestamp.end()) as usize;
                timestamps.insert(base + a, (base + b, raw[a..b].to_owned()));
            }
        }
    }
    let mut edits = Vec::new();
    for (begin, (end, raw)) in timestamps {
        if repeater(&raw).is_some() {
            edits.push((begin..end, shift(&raw, now)?));
        }
    }
    Ok(edits)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn normalize(source: &str) -> (Vec<String>, Vec<String>) {
        let mut ordinary = Vec::new();
        let mut planning = Vec::new();
        for line in source.lines() {
            let line = line.trim_end();
            if ["CLOSED:", "SCHEDULED:", "DEADLINE:"]
                .iter()
                .any(|name| line.trim_start().starts_with(name))
            {
                let mut positions = ["CLOSED:", "SCHEDULED:", "DEADLINE:"]
                    .into_iter()
                    .filter_map(|name| line.find(name))
                    .collect::<Vec<_>>();
                positions.sort_unstable();
                positions.push(line.len());
                for pair in positions.windows(2) {
                    planning.push(line[pair[0]..pair[1]].trim().to_owned());
                }
            } else {
                ordinary.push(line.to_owned());
            }
        }
        planning.sort();
        (ordinary, planning)
    }

    #[test]
    fn state_logs_and_repeaters_match_emacs_info_reference() {
        let data: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/data/task_state_emacs.json")).unwrap();
        let now =
            NaiveDateTime::parse_from_str(data["now"].as_str().unwrap(), "%Y-%m-%d %H:%M").unwrap();
        let mut errors = Vec::new();
        for case in data["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let mut file = OrgFile::new(
                "repo".into(),
                "tasks.org".into(),
                case["source"].as_str().unwrap().as_bytes().to_vec(),
            )
            .unwrap();
            for action in case["actions"].as_array().unwrap() {
                let headline = file
                    .path_headlines()
                    .into_iter()
                    .map(|(_, node)| node)
                    .find(|node| node.title_raw().trim() == "Task")
                    .unwrap();
                if let Err(error) = modify_at(&mut file, &headline, action["state"].as_str(), now) {
                    errors.push(format!("{name}: {error}"));
                    break;
                }
                let actual = std::str::from_utf8(file.source_bytes()).unwrap();
                if normalize(actual) != normalize(action["expected"].as_str().unwrap()) {
                    errors.push(format!(
                        "{name}: {:?}\n实际:\n{actual}\n预期:\n{}",
                        action["state"],
                        action["expected"].as_str().unwrap()
                    ));
                    break;
                }
            }
        }
        assert!(errors.is_empty(), "{}", errors.join("\n\n"));
    }
}

#[cfg(test)]
mod property_tests {
    use super::*;

    #[test]
    fn logging_properties_combine_file_defaults_ancestors_and_local_additions() {
        let source = ":PROPERTIES:\n:LOGGING+: logrepeat\n:END:\n#+PROPERTY: LOGGING logdone\n* Parent\n:PROPERTIES:\n:LOGGING+: TODO(!)\n:END:\n** Child\n:PROPERTIES:\n:LOGGING+: DONE(!)\n:END:\n";
        let file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
        let child = file.syntax().document().syntax().descendants().filter_map(Headline::cast)
            .find(|node| node.title_raw().trim() == "Child").unwrap();
        assert_eq!(property(&file, &child, "logging", true).unwrap().as_deref(), Some("logdone logrepeat TODO(!) DONE(!)"));
        assert_eq!(property(&file, &child, "LOGGING", false).unwrap().as_deref(), Some("logdone logrepeat DONE(!)"));
        let logging = Logging::load(&file, &child).unwrap();
        assert_eq!(logging.done, Some(TodoLogAction::Time));
        assert_eq!(logging.repeat, Some(TodoLogAction::Time));
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn updating_an_empty_property_preserves_its_drawer_and_unrelated_bytes() {
        let source = "* TODO Task\r\n:PROPERTIES:\r\n:LAST_REPEAT:   \r\n:Genres: Classic\r\n:Genres+: Baroque\r\n:END:\r\n正文  \r\n";
        let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
        let headline = file.syntax().first_node::<Headline>().unwrap();
        set_property(&mut file, &headline, "LAST_REPEAT", "[2026-11-11 Wed 10:00]").unwrap();
        assert_eq!(file.source_bytes(), source.replace(":LAST_REPEAT:   ", ":LAST_REPEAT:   [2026-11-11 Wed 10:00]").as_bytes());
        let headline = file.syntax().first_node::<Headline>().unwrap();
        assert_eq!(super::super::properties::own(&headline, "Genres").as_deref(), Some("Classic Baroque"));
    }
}
