//! Loki 星期排程、相对日期后继创建；与普通修改共用日期编辑和创建原语。
use super::{Call, Context, Result, Value, error, start, time};
use crate::model::{TaskCreation, TaskPlanningEdit, TaskPlanningTime, TaskPosition};
use chrono::{Datelike, Local, NaiveTime, TimeZone};
use orgize::SyntaxKind;

struct Rule<'a> {
    base: &'a str,
    weekdays: Vec<u32>,
    offset: Option<(i64, &'a str)>,
}

fn first_timestamp(raw: &str) -> (&str, &str) {
    raw.find(['>', ']'])
        .map_or((raw, ""), |close| raw.split_at(close + 1))
}

fn next_title(title: &str) -> String {
    let digits = title.bytes().rev().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return title.into();
    }
    let start = title.len() - digits;
    let mut bytes = title.as_bytes().to_vec();
    // 逐位进位，保留前导零且不受整数类型位数限制。
    for index in (start..bytes.len()).rev() {
        if bytes[index] != b'9' {
            bytes[index] += 1;
            return String::from_utf8(bytes).expect("仅修改 ASCII 数字");
        }
        bytes[index] = b'0';
    }
    bytes.insert(start, b'1');
    String::from_utf8(bytes).expect("仅修改 ASCII 数字")
}

fn stamp(date: TaskPlanningEdit) -> String {
    let day = chrono::NaiveDate::parse_from_str(&date.date, "%Y-%m-%d").expect("已计算的日期");
    let clock = date
        .time
        .flatten()
        .map(|time| {
            format!(
                " {}{}",
                time.start,
                time.end.map(|end| format!("-{end}")).unwrap_or_default()
            )
        })
        .unwrap_or_default();
    format!("<{}{}>", day.format("%Y-%m-%d %a"), clock)
}

impl<'a> Rule<'a> {
    fn parse(args: &'a [Value], allow_offset: bool) -> Result<Self> {
        let base = args
            .first()
            .and_then(Value::symbol)
            .filter(|base| ["source", "target", "today"].contains(base))
            .ok_or(error("Loki 日期基准必须为 source、target 或 today"))?;
        if allow_offset && let [_, Value::String(offset)] = args {
            let raw = offset.strip_prefix('+').ok_or(error("Loki 日期间隔必须为 +正整数及 d、w、m 或 y"))?;
            let digits = raw.bytes().take_while(u8::is_ascii_digit).count();
            let count = raw[..digits].parse::<i64>().ok().filter(|count| *count > 0)
                .ok_or(error("Loki 日期间隔必须为正整数"))?;
            let unit = &raw[digits..];
            if !["d", "w", "m", "y"].contains(&unit) {
                return Err(error("Loki 日期间隔单位必须为 d、w、m 或 y"));
            }
            return Ok(Self { base, weekdays: Vec::new(), offset: Some((count, unit)) });
        }
        let mut weekdays = Vec::new();
        for arg in &args[1..] {
            let day =
                arg.symbol()
                    .and_then(|day| {
                        ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
                            .iter()
                            .position(|name| *name == day)
                    })
                    .ok_or(error("Loki 星期必须为 mon 至 sun 的小写符号"))? as u32;
            if !weekdays.contains(&day) {
                weekdays.push(day);
            }
        }
        if weekdays.is_empty() {
            return Err(error("Loki 星期集合不能为空"));
        }
        Ok(Self { base, weekdays, offset: None })
    }
}

impl Context<'_> {
    fn loki_date(
        &self,
        rule: &Rule<'_>,
        source: usize,
        target: usize,
        field: &str,
    ) -> Result<TaskPlanningEdit> {
        let raw = self.prop(
            if rule.base == "source" {
                source
            } else {
                target
            },
            field,
        )?;
        // 与 org-entry-get 一致，只从首个时间戳取得基准和时刻。
        let first = raw.as_deref().map(|raw| first_timestamp(raw).0);
        let base = if rule.base == "today" {
            self.now
        } else {
            time::read(first.ok_or(error("Loki 日期基准没有对应规划时间戳"))?)?.0
        };
        let next = if let Some((count, unit)) = rule.offset {
            time::add(base, count, unit)?
        } else {
            let mut next = time::add(base, 1, "d")?;
            while !rule.weekdays.contains(&next.weekday().num_days_from_sunday()) {
                next = time::add(next, 1, "d")?;
            }
            next
        };
        let clock = first
            .and_then(|raw| {
                raw.trim_end_matches(['>', ']'])
                    .split_whitespace()
                    .find(|part| part.as_bytes().get(2) == Some(&b':'))
            })
            .map(|clock| TaskPlanningTime {
                start: clock[..5].into(),
                end: clock.get(6..11).map(str::to_owned),
            });
        Ok(TaskPlanningEdit {
            date: next.format("%Y-%m-%d").to_string(),
            time: Some(clock),
        })
    }

    pub(super) fn loki_action(&mut self, call: &Call, source: usize, target: usize) -> Result<()> {
        let rule = Rule::parse(&call.args, call.name == "loki-spawn-next!")?;
        if call.name == "loki-spawn-next!" {
            return self.loki_spawn(&rule, source, target);
        }
        let scheduled = call.name == "loki-scheduled-next!";
        let field = if scheduled { "SCHEDULED" } else { "DEADLINE" };
        let edit = self.loki_date(&rule, source, target, field)?;
        let mut value = stamp(edit);
        if let Some(old) = self.prop(target, field)? {
            let (first, tail) = first_timestamp(&old);
            if !value.contains(':') && crate::model::task_repeat::has_hourly_repeater(first) {
                return Err(error("按小时重复的时间戳必须保留时刻"));
            }
            for modifier in first
                .trim_end_matches(['>', ']'])
                .split_whitespace()
                .filter(|part| part.starts_with(['+', '-']) || part.starts_with(".+"))
            {
                value.insert_str(value.len() - 1, &format!(" {modifier}"));
            }
            value.push_str(tail);
        }
        self.modify(
            target,
            if scheduled {
                super::TaskModification::Schedule(Some(value.into()))
            } else {
                super::TaskModification::Deadline(Some(value.into()))
            },
        )
    }

    fn loki_spawn(&mut self, rule: &Rule<'_>, source: usize, target: usize) -> Result<()> {
        let date = self.loki_date(rule, source, target, "SCHEDULED")?;
        let node = self.node(target)?;
        let reminder = crate::filter::property_time(
            &super::metadata_node(self.file, &node), crate::model::properties::REMINDER_PROPERTY,
        );
        let reminder_offset = if let Some((_, reminder)) = reminder {
            // 提醒属于复制目标；目标没有计划时，以动作的自然日／来源计划作为基准。
            let base = crate::model::task_state::planning_start_time(self.file, &node, SyntaxKind::PLANNING_SCHEDULED)
                .or_else(|| {
                    if rule.base == "today" {
                        Local.from_local_datetime(&self.now.date().and_time(NaiveTime::MIN)).earliest()
                            .map(|time| time.timestamp_millis())
                    } else {
                        self.node(source).ok().and_then(|source| {
                            crate::model::task_state::planning_start_time(self.file, &source, SyntaxKind::PLANNING_SCHEDULED)
                        })
                    }
                }).ok_or(error("Loki 后继提醒缺少有效日期基准"))?;
            Some(reminder.checked_sub(base).ok_or(error("Loki 后继提醒时间超出有效日期范围"))?)
        } else { None };
        let state = node.todo_keyword();
        let state = self
            .file
            .todo
            .workflows
            .iter()
            .find(|flow| {
                flow.states
                    .iter()
                    .any(|item| Some(item.name.as_str()) == state.as_deref())
            })
            .and_then(|flow| {
                flow.states
                    .iter()
                    .find(|item| !self.file.todo.is_done(&item.name))
            })
            .map(|item| item.name.clone())
            .or_else(|| self.file.todo.pending_keywords.first().cloned())
            .ok_or(error("Loki 后继没有可用的待办状态"))?;
        let nodes = self.file.path_headlines();
        let after = nodes[self.ordinals[target]].0.clone();
        let parent = node
            .syntax()
            .ancestors()
            .skip(1)
            .filter_map(orgize::ast::Headline::cast)
            .next()
            .and_then(|parent| {
                nodes
                    .iter()
                    .find(|(_, item)| start(item) == start(&parent))
                    .map(|(path, _)| path.clone())
            })
            .unwrap_or_else(|| self.file.full_path());
        let mut creation = TaskCreation::new(
            TaskPosition {
                parent,
                after: Some(after),
            },
            next_title(node.title_raw().trim_end()),
        );
        creation.state = Some(state);
        creation.priority = node.priority().map(|value| value.to_string());
        creation.tags = self.own_tags(target)?;
        creation.scheduled = Some(stamp(date));
        let trigger = self.prop(target, "TRIGGER")?;
        let inserted =
            crate::model::task_operation_executor::create(self.file, &creation, self.now)?;
        let ordinal = self
            .file
            .path_headlines()
            .iter()
            .position(|(_, node)| start(node) == inserted)
            .ok_or(error("Loki 新建后继无法定位"))?;
        for current in &mut self.ordinals {
            if *current >= ordinal {
                *current += 1;
            }
        }
        let next = self.ordinals.len();
        self.ordinals.push(ordinal);
        if let Some(trigger) = trigger {
            self.set_property(next, "TRIGGER", &trigger)?;
        }
        if let Some(offset) = reminder_offset {
            let node = self.node(next)?;
            let reminder = crate::model::task_state::planning_start_time(self.file, &node, SyntaxKind::PLANNING_SCHEDULED)
                .and_then(|base| base.checked_add(offset))
                .ok_or(error("Loki 后继提醒时间超出有效日期范围"))?;
            self.modify(next, super::TaskModification::SetReminder(Some(reminder)))?;
        }
        // 新增待办后，完成的祖先必须恢复，统计与其他状态修改遵循同一规则。
        self.reopen_ancestors(next)
    }
}

use orgize::rowan::ast::AstNode;
