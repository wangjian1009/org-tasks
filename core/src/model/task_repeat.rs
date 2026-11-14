//! 规划时间戳重复规则的结构化投影与局部编辑。
use super::{CoreError, OrgFile};
use orgize::{SyntaxKind, ast::Headline};
use serde::{Deserialize, Serialize};
use std::ops::Range;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskRepeatMode {
    Cumulative,
    CatchUp,
    AfterCompletion,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskRepeatUnit {
    Hour,
    Day,
    Week,
    Month,
    Year,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskRepeatRule {
    pub mode: TaskRepeatMode,
    pub interval: u32,
    pub unit: TaskRepeatUnit,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRepeatInfo {
    pub date: String,
    pub has_time: bool,
    pub rule: Option<TaskRepeatRule>,
}

fn parse(part: &str) -> Option<TaskRepeatRule> {
    let (mode, rest) = if let Some(rest) = part.strip_prefix("++") {
        (TaskRepeatMode::CatchUp, rest)
    } else if let Some(rest) = part.strip_prefix(".+") {
        (TaskRepeatMode::AfterCompletion, rest)
    } else {
        (TaskRepeatMode::Cumulative, part.strip_prefix('+')?)
    };
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    let interval = rest.get(..digits)?.parse::<u32>().ok().filter(|n| *n > 0)?;
    let unit = match rest.as_bytes().get(digits)? {
        b'h' => TaskRepeatUnit::Hour,
        b'd' => TaskRepeatUnit::Day,
        b'w' => TaskRepeatUnit::Week,
        b'm' => TaskRepeatUnit::Month,
        b'y' => TaskRepeatUnit::Year,
        _ => return None,
    };
    let suffix = &rest[digits + 1..];
    if !suffix.is_empty() {
        let window = suffix.strip_prefix('/')?;
        let digits = window.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 || !matches!(&window[digits..], "" | "h" | "d" | "w" | "m" | "y") {
            return None;
        }
    }
    Some(TaskRepeatRule {
        mode,
        interval,
        unit,
    })
}

fn timestamp_range(file: &OrgFile, headline: &Headline, kind: SyntaxKind) -> Option<Range<usize>> {
    for (_, _, fields) in super::task_operation_executor::planning_lines(file, headline) {
        for (field, a, b) in fields {
            if field != kind {
                continue;
            }
            let source = &file.source_bytes()[a..b];
            let start = source.iter().position(|c| matches!(c, b'<' | b'['))?;
            let close = if source[start] == b'<' { b'>' } else { b']' };
            let end = source[start..].iter().position(|c| *c == close)? + start + 1;
            return Some(a + start..a + end);
        }
    }
    None
}

fn parts(raw: &str) -> impl Iterator<Item = (Range<usize>, &str)> {
    let mut at = 0;
    raw.split_inclusive(char::is_whitespace)
        .filter_map(move |part| {
            let start = at;
            at += part.len();
            let text = part.trim_end();
            (!text.is_empty()).then_some((start..start + text.len(), text))
        })
}

pub(super) fn repeat_info(
    file: &OrgFile,
    headline: &Headline,
    kind: SyntaxKind,
) -> Option<TaskRepeatInfo> {
    let range = timestamp_range(file, headline, kind)?;
    let raw = std::str::from_utf8(&file.source_bytes()[range]).ok()?;
    let inner = &raw[1..raw.len() - 1];
    Some(TaskRepeatInfo {
        date: inner.get(..10)?.into(),
        has_time: inner
            .split_whitespace()
            .any(|part| part.as_bytes().get(2) == Some(&b':')),
        rule: parts(inner).find_map(|(_, part)| parse(part)),
    })
}

pub(super) fn planning_info(file: &OrgFile, headline: &Headline, kind: SyntaxKind) -> Option<super::TaskPlanningInfo> {
    let range = timestamp_range(file, headline, kind)?;
    let raw = std::str::from_utf8(&file.source_bytes()[range]).ok()?;
    let time = raw[1..raw.len() - 1].split_whitespace()
        .find(|part| part.as_bytes().get(2) == Some(&b':'))
        .map(|part| {
            let (start, end) = part.split_once('-').map_or((part, None), |(a, b)| (a, Some(b.to_owned())));
            super::TaskPlanningTime { start: start.into(), end }
        });
    Some(super::TaskPlanningInfo { date: raw.get(1..11)?.into(), time })
}

pub(super) fn has_hourly_repeater(raw: &str) -> bool {
    raw.split(['<', '>', '[', ']']).flat_map(str::split_whitespace)
        .filter_map(parse).any(|rule| rule.unit == TaskRepeatUnit::Hour)
}

pub(super) fn planning_timestamp(
    file: &OrgFile,
    headline: &Headline,
    kind: SyntaxKind,
) -> Option<String> {
    for (_, _, fields) in super::task_operation_executor::planning_lines(file, headline) {
        for (field, a, b) in fields {
            if field != kind {
                continue;
            }
            let source = std::str::from_utf8(&file.source_bytes()[a..b]).ok()?;
            let start = source.find(['<', '['])?;
            return Some(source[start..].trim_end().into());
        }
    }
    None
}

pub(super) fn modify_repeat(
    file: &mut OrgFile,
    headline: &Headline,
    kind: SyntaxKind,
    rule: &Option<TaskRepeatRule>,
) -> Result<(), CoreError> {
    let Some(range) = timestamp_range(file, headline, kind) else {
        return if rule.is_none() {
            Ok(())
        } else {
            Err(CoreError::InvalidInput("请先设置重复任务的日期"))
        };
    };
    let info = repeat_info(file, headline, kind).expect("已有规划时间戳");
    if let Some(rule) = rule {
        if rule.interval == 0 {
            return Err(CoreError::InvalidInput("重复间隔必须大于零"));
        }
        if rule.unit == TaskRepeatUnit::Hour && !info.has_time {
            return Err(CoreError::InvalidInput("按小时重复必须先指定时刻"));
        }
    }
    let raw = std::str::from_utf8(&file.source_bytes()[range.clone()]).expect("UTF-8");
    let inner = &raw[1..raw.len() - 1];
    let existing = parts(inner).find(|(_, part)| parse(part).is_some());
    let value = rule.as_ref().map(|rule| {
        let prefix = match rule.mode {
            TaskRepeatMode::Cumulative => "+",
            TaskRepeatMode::CatchUp => "++",
            TaskRepeatMode::AfterCompletion => ".+",
        };
        let unit = match rule.unit {
            TaskRepeatUnit::Hour => 'h',
            TaskRepeatUnit::Day => 'd',
            TaskRepeatUnit::Week => 'w',
            TaskRepeatUnit::Month => 'm',
            TaskRepeatUnit::Year => 'y',
        };
        let window = existing
            .as_ref()
            .and_then(|(_, part)| part.find('/').map(|at| &part[at..]))
            .unwrap_or("");
        format!("{prefix}{}{unit}{window}", rule.interval)
    });
    let (edit, value) = match (existing, value) {
        (Some((part, _)), Some(value)) => (
            range.start + 1 + part.start..range.start + 1 + part.end,
            value,
        ),
        (Some((part, _)), None) => {
            let mut start = part.start;
            while start > 0 && inner.as_bytes()[start - 1].is_ascii_whitespace() {
                start -= 1;
            }
            (
                range.start + 1 + start..range.start + 1 + part.end,
                String::new(),
            )
        }
        (None, Some(value)) => (range.end - 1..range.end - 1, format!(" {value}")),
        (None, None) => return Ok(()),
    };
    super::task_operation_executor::replace(file, edit, value.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TaskModification;
    fn file(source: &str) -> OrgFile {
        OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap()
    }
    fn apply(file: &mut OrgFile, change: TaskModification) -> Result<(), CoreError> {
        let headline = file.path_headlines()[0].1.clone();
        super::super::task_operation_executor::modify(file, &headline, &change)
    }
    fn rule(mode: TaskRepeatMode) -> TaskRepeatRule {
        TaskRepeatRule {
            mode,
            interval: 2,
            unit: TaskRepeatUnit::Week,
        }
    }
    #[test]
    fn projects_both_rules_without_reading_body_or_children() {
        let f = file(
            "* TODO Task\nSCHEDULED: <2026-11-11 Wed 09:30 .+4w/5w -2d> DEADLINE: <2026-11-20 Fri ++1m>\n<2026-11-11 Wed +1d>\n** Child\n",
        );
        let content = f.task_edit_content(&f.path_headlines()[0].0).unwrap();
        let info = content.scheduled_repeat.unwrap();
        assert_eq!(info.date, "2026-11-11");
        assert!(info.has_time);
        assert_eq!(
            info.rule.unwrap(),
            TaskRepeatRule {
                mode: TaskRepeatMode::AfterCompletion,
                interval: 4,
                unit: TaskRepeatUnit::Week
            }
        );
        assert_eq!(
            content.deadline_repeat.unwrap().rule.unwrap().mode,
            TaskRepeatMode::CatchUp
        );
        let f = file("* Parent\n<2026-11-11 Wed +1d>\n** Child\nSCHEDULED: <2026-11-11 Wed +1w>\n");
        assert!(
            f.task_edit_content(&f.path_headlines()[0].0)
                .unwrap()
                .scheduled_repeat
                .is_none()
        );
    }
    #[test]
    fn edits_only_repeater_and_preserves_window_time_warning_and_crlf() {
        let source = "* TODO Task :work:\r\n  SCHEDULED: <2026-11-11 Wed 09:30-10:00 .+4w/5w -2d>  DEADLINE: <2026-12-01 Tue +1m>\r\nNotes  \r\n** Child\r\n";
        let mut f = file(source);
        apply(
            &mut f,
            TaskModification::ScheduleRepeat(Some(rule(TaskRepeatMode::CatchUp))),
        )
        .unwrap();
        assert_eq!(
            f.source_bytes(),
            source.replace(".+4w/5w", "++2w/5w").as_bytes()
        );
        apply(
            &mut f,
            TaskModification::Schedule(Some(crate::TaskPlanningValue::Edit(crate::TaskPlanningEdit::date("2026-11-12".into())))),
        )
        .unwrap();
        assert_eq!(
            f.source_bytes(),
            source
                .replace(".+4w/5w", "++2w/5w")
                .replace("2026-11-11 Wed", "2026-11-12 Thu")
                .as_bytes()
        );
        apply(
            &mut f,
            TaskModification::Schedule(Some(crate::TaskPlanningValue::Edit(crate::TaskPlanningEdit::date("2026-11-11".into())))),
        )
        .unwrap();
        apply(&mut f, TaskModification::ScheduleRepeat(None)).unwrap();
        assert_eq!(f.source_bytes(), source.replace(" .+4w/5w", "").as_bytes());
        apply(
            &mut f,
            TaskModification::ScheduleRepeat(Some(rule(TaskRepeatMode::Cumulative))),
        )
        .unwrap();
        assert!(String::from_utf8_lossy(f.source_bytes()).contains("09:30-10:00 -2d +2w>"));
    }
    #[test]
    fn validates_intervals_dates_and_hourly_rules_before_writing() {
        let source = "* Task\nSCHEDULED: <2026-11-11 Wed>\n";
        let mut f = file(source);
        let mut invalid = rule(TaskRepeatMode::Cumulative);
        invalid.interval = 0;
        assert!(apply(&mut f, TaskModification::ScheduleRepeat(Some(invalid))).is_err());
        let mut hourly = rule(TaskRepeatMode::Cumulative);
        hourly.unit = TaskRepeatUnit::Hour;
        assert!(apply(&mut f, TaskModification::ScheduleRepeat(Some(hourly))).is_err());
        assert!(
            apply(
                &mut f,
                TaskModification::DeadlineRepeat(Some(rule(TaskRepeatMode::CatchUp)))
            )
            .is_err()
        );
        assert_eq!(f.source_bytes(), source.as_bytes());
        apply(&mut f, TaskModification::DeadlineRepeat(None)).unwrap();
        apply(
            &mut f,
            TaskModification::Deadline(Some(crate::TaskPlanningValue::Edit(crate::TaskPlanningEdit::date("2026-12-01".into())))),
        )
        .unwrap();
        apply(
            &mut f,
            TaskModification::DeadlineRepeat(Some(rule(TaskRepeatMode::AfterCompletion))),
        )
        .unwrap();
        let edit = f.task_edit_content(&f.path_headlines()[0].0).unwrap();
        assert_eq!(
            edit.deadline_repeat.unwrap().rule,
            Some(rule(TaskRepeatMode::AfterCompletion))
        );
    }

    #[test]
    fn changing_a_repeat_date_preserves_the_end_of_a_date_range() {
        let source = "* Task\nSCHEDULED: <2026-11-11 Wed +1w>--<2026-11-13 Fri>\n";
        let mut f = file(source);
        apply(
            &mut f,
            TaskModification::Schedule(Some(crate::TaskPlanningValue::Edit(crate::TaskPlanningEdit::date("2026-11-12".into())))),
        )
        .unwrap();
        assert_eq!(
            f.source_bytes(),
            source
                .replace("2026-11-11 Wed", "2026-11-12 Thu")
                .as_bytes()
        );
        apply(&mut f, TaskModification::ScheduleRepeat(None)).unwrap();
        assert!(
            String::from_utf8_lossy(f.source_bytes())
                .contains("<2026-11-12 Thu>--<2026-11-13 Fri>")
        );
    }
}
