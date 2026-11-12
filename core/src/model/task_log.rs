//! 按 Org manual 的日志语义与默认 org-log-note-headings 投影真实 LOGBOOK。
use orgize::{
    SyntaxKind,
    ast::{Clock, Drawer, List, Timestamp},
    export::{Container, Event, TraversalContext, Traverser},
    rowan::ast::AstNode,
};
use regex::Regex;
use serde::Serialize;
use std::sync::OnceLock;

/// 只读日志值；时间为保留本地日历含义的 YYYY-MM-DD[ HH:MM]，不写回源文件。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum TaskLog {
    TaskStateChange {
        from: String,
        to: String,
        timestamp: String,
        note_html: String,
    },
    TaskNote {
        timestamp: String,
        note_html: String,
    },
    TaskClosingNote {
        timestamp: String,
        note_html: String,
    },
    TaskReschedule {
        previous: String,
        timestamp: String,
        note_html: String,
    },
    TaskScheduleRemoval {
        previous: String,
        timestamp: String,
        note_html: String,
    },
    TaskDeadlineChange {
        previous: String,
        timestamp: String,
        note_html: String,
    },
    TaskDeadlineRemoval {
        previous: String,
        timestamp: String,
        note_html: String,
    },
    TaskRefile {
        timestamp: String,
        note_html: String,
    },
    TaskClock {
        start: String,
        end: Option<String>,
        duration: Option<String>,
    },
    Other {
        html: String,
    },
}

impl crate::FilterTask {
    pub fn logs(&self) -> Vec<TaskLog> {
        task_logs(&orgize::Org::parse(self.body()))
    }
}

pub(super) fn task_logs(org: &orgize::Org) -> Vec<TaskLog> {
    struct Logs(Vec<TaskLog>);
    impl Traverser for Logs {
        fn event(&mut self, event: Event, ctx: &mut TraversalContext) {
            if let Event::Enter(Container::Drawer(drawer)) = event {
                if drawer.name().eq_ignore_ascii_case("LOGBOOK") {
                    self.0.extend(drawer_logs(&drawer));
                }
                // 不从其他 drawer 的嵌套内容猜测日志。
                ctx.skip();
            }
        }
    }
    let mut logs = Logs(Vec::new());
    org.traverse(&mut logs);
    logs.0
}

fn drawer_logs(drawer: &Drawer) -> Vec<TaskLog> {
    let mut logs = Vec::new();
    for node in drawer
        .syntax()
        .children()
        .filter(|node| node.kind() == SyntaxKind::DRAWER_CONTENT)
        .flat_map(|node| node.children())
    {
        if let Some(list) = List::cast(node.clone()) {
            for item in list.items() {
                if item.checkbox().is_some() || item.tag().next().is_some() {
                    logs.push(other(&item.raw()));
                    continue;
                }
                let content = item
                    .syntax()
                    .children()
                    .find(|node| node.kind() == SyntaxKind::LIST_ITEM_CONTENT);
                let log = content.and_then(|content| {
                    let raw = content.to_string();
                    let (heading, rest) = raw.split_once('\n').unwrap_or((&raw, ""));
                    let indent = " ".repeat(item.indent() + item.bullet().len());
                    let note = rest
                        .lines()
                        .map(|line| line.strip_prefix(&indent).unwrap_or(line))
                        .collect::<Vec<_>>()
                        .join("\n");
                    parse_heading(heading.trim_end_matches('\r'), &note)
                });
                logs.push(log.unwrap_or_else(|| other(&item.raw())));
            }
        } else if let Some(clock) = Clock::cast(node.clone()) {
            let parsed = clock.value().and_then(|value| {
                let start = time_label(&value, false)?;
                let end = if value.is_range() {
                    Some(time_label(&value, true)?)
                } else {
                    None
                };
                Some(TaskLog::TaskClock {
                    start,
                    end,
                    duration: clock.duration().map(|value| value.to_string()),
                })
            });
            logs.push(parsed.unwrap_or_else(|| other(&clock.raw())));
        } else {
            let raw = node.to_string();
            if !raw.trim().is_empty() {
                logs.push(other(&raw));
            }
        }
    }
    logs
}

fn other(raw: &str) -> TaskLog {
    TaskLog::Other {
        html: super::render::render_fragment(raw),
    }
}

fn parse_heading(heading: &str, note: &str) -> Option<TaskLog> {
    static STATE: OnceLock<Regex> = OnceLock::new();
    static NOTE: OnceLock<Regex> = OnceLock::new();
    static PLANNING: OnceLock<Regex> = OnceLock::new();
    let heading = heading
        .trim_end()
        .strip_suffix("\\\\")
        .unwrap_or(heading)
        .trim_end();
    let note_html = || super::render::render_fragment(note);
    if let Some(captures) = STATE
        .get_or_init(|| {
            Regex::new(r#"^State\s+"([^"]*)"\s+from\s+"([^"]*)"\s+(\[[^\]]+\])$"#).unwrap()
        })
        .captures(heading)
    {
        return Some(TaskLog::TaskStateChange {
            to: captures[1].into(),
            from: captures[2].into(),
            timestamp: parse_time(&captures[3])?,
            note_html: note_html(),
        });
    }
    if let Some(captures) = NOTE
        .get_or_init(|| {
            Regex::new(r"^(Note taken on|CLOSING NOTE|Refiled on)\s+(\[[^\]]+\])$").unwrap()
        })
        .captures(heading)
    {
        let timestamp = parse_time(&captures[2])?;
        let note_html = note_html();
        return Some(match &captures[1] {
            "Note taken on" => TaskLog::TaskNote {
                timestamp,
                note_html,
            },
            "CLOSING NOTE" => TaskLog::TaskClosingNote {
                timestamp,
                note_html,
            },
            _ => TaskLog::TaskRefile {
                timestamp,
                note_html,
            },
        });
    }
    if let Some(captures) = PLANNING.get_or_init(|| Regex::new(
        r"^(Rescheduled from|Not scheduled, was|New deadline from|Removed deadline, was)\s+([<\[].+[>\]])\s+on\s+(\[[^\]]+\])$"
    ).unwrap()).captures(heading) {
        // previous 保留重复器等完整日期信息；仅验证其确实是时间戳。
        parse_time(&captures[2])?;
        let previous = captures[2].into();
        let timestamp = parse_time(&captures[3])?;
        let note_html = note_html();
        return Some(match &captures[1] {
            "Rescheduled from" => TaskLog::TaskReschedule { previous, timestamp, note_html },
            "Not scheduled, was" => TaskLog::TaskScheduleRemoval { previous, timestamp, note_html },
            "New deadline from" => TaskLog::TaskDeadlineChange { previous, timestamp, note_html },
            _ => TaskLog::TaskDeadlineRemoval { previous, timestamp, note_html },
        });
    }
    None
}

fn parse_time(raw: &str) -> Option<String> {
    let org = orgize::Org::parse(raw);
    let timestamp = org.first_node::<Timestamp>()?;
    (timestamp.raw().trim() == raw).then_some(())?;
    time_label(&timestamp, false)
}

fn time_label(timestamp: &Timestamp, end: bool) -> Option<String> {
    let (year, month, day, hour, minute) = if end {
        (
            timestamp.year_end()?,
            timestamp.month_end()?,
            timestamp.day_end()?,
            timestamp.hour_end(),
            timestamp.minute_end(),
        )
    } else {
        (
            timestamp.year_start()?,
            timestamp.month_start()?,
            timestamp.day_start()?,
            timestamp.hour_start(),
            timestamp.minute_start(),
        )
    };
    let date = chrono::NaiveDate::from_ymd_opt(
        year.parse().ok()?,
        month.parse().ok()?,
        day.parse().ok()?,
    )?;
    let mut label = date.to_string();
    match (hour, minute) {
        (Some(hour), Some(minute)) => {
            let time =
                chrono::NaiveTime::from_hms_opt(hour.parse().ok()?, minute.parse().ok()?, 0)?;
            label.push_str(&time.format(" %H:%M").to_string());
        }
        (None, None) => {}
        _ => return None,
    }
    Some(label)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn logs(source: &str) -> Vec<TaskLog> {
        task_logs(&orgize::Org::parse(source))
    }

    #[test]
    fn standard_org_headers_keep_types_notes_and_source_order() {
        let parsed = logs(concat!(
            ":LOGBOOK:\n",
            "- State \"等待\"       from \"\"           [2026-11-13 Fri 09:05] \\\\\n",
            "  *说明* [[https://example.com][链接]]\n",
            "  - 子列表\n",
            "- Note taken on [2026-11-12 Thu] \\\\\n",
            "  第一行\n",
            "  第二行\n",
            "- CLOSING NOTE [2026-11-11 Wed 08:00] \\\\\n",
            "  已结束\n",
            "- Rescheduled from \"not a timestamp\" on [2026-11-10 Tue]\n",
            "- Rescheduled from <2026-11-10 Tue +1w> on [2026-11-09 Mon]\n",
            "- Not scheduled, was [2026-11-08 Sun] on [2026-11-07 Sat]\n",
            "- New deadline from [2026-11-06 Fri] on [2026-11-05 Thu]\n",
            "- Removed deadline, was [2026-11-04 Wed] on [2026-11-03 Tue]\n",
            "- Refiled on [2026-11-02 Mon 23:59]\n",
            ":END:\n",
        ));
        assert_eq!(parsed.len(), 9);
        let TaskLog::TaskStateChange {
            from,
            to,
            timestamp,
            note_html,
        } = &parsed[0]
        else {
            panic!("状态日志类型错误: {:?}", parsed[0]);
        };
        assert_eq!(
            (from.as_str(), to.as_str(), timestamp.as_str()),
            ("", "等待", "2026-11-13 09:05")
        );
        assert!(note_html.contains("<b>说明</b>"));
        assert!(note_html.contains("链接</a>"));
        assert!(note_html.contains("子列表"));
        let TaskLog::TaskNote {
            timestamp,
            note_html,
        } = &parsed[1]
        else {
            panic!("笔记类型错误");
        };
        assert_eq!(timestamp, "2026-11-12");
        assert!(note_html.contains("第一行\n第二行"));
        assert!(matches!(&parsed[2], TaskLog::TaskClosingNote { .. }));
        assert!(matches!(&parsed[3], TaskLog::Other { .. }));
        assert!(
            matches!(&parsed[4], TaskLog::TaskReschedule { previous, .. } if previous == "<2026-11-10 Tue +1w>")
        );
        assert!(matches!(&parsed[5], TaskLog::TaskScheduleRemoval { .. }));
        assert!(matches!(&parsed[6], TaskLog::TaskDeadlineChange { .. }));
        assert!(matches!(&parsed[7], TaskLog::TaskDeadlineRemoval { .. }));
        assert!(matches!(&parsed[8], TaskLog::TaskRefile { .. }));
        let json = serde_json::to_value(&parsed[0]).unwrap();
        assert_eq!(json["type"], "taskStateChange");
        assert!(json["noteHtml"].as_str().unwrap().contains("说明"));
    }

    #[test]
    fn clocks_include_running_closed_and_cross_day_intervals() {
        let parsed = logs(concat!(
            ":LOGBOOK:\n",
            "CLOCK: [2026-11-12 Thu 23:30]--[2026-11-13 Fri 01:00] =>  1:30\n",
            "CLOCK: [2026-11-13 Fri 08:00]\n",
            ":END:\n",
        ));
        assert_eq!(
            parsed,
            vec![
                TaskLog::TaskClock {
                    start: "2026-11-12 23:30".into(),
                    end: Some("2026-11-13 01:00".into()),
                    duration: Some("1:30".into())
                },
                TaskLog::TaskClock {
                    start: "2026-11-13 08:00".into(),
                    end: None,
                    duration: None
                },
            ]
        );
    }

    #[test]
    fn checkbox_and_descriptive_items_keep_their_original_semantics() {
        let parsed = logs(":LOGBOOK:\n- [ ] Note taken on [2026-11-13 Fri]\n- context :: Note taken on [2026-11-13 Fri]\n:END:\n");
        assert_eq!(parsed.len(), 2);
        assert!(parsed.iter().all(|log| matches!(log, TaskLog::Other { .. })));
        let TaskLog::Other { html } = &parsed[0] else { unreachable!() };
        assert!(html.contains("checkbox"));
    }

    #[test]
    fn unknown_invalid_and_literal_content_is_preserved_without_false_logs() {
        let parsed = logs(concat!(
            "#+begin_src org\n:LOGBOOK:\n- Note taken on [2026-11-01 Sun]\n:END:\n#+end_src\n",
            "#+begin_example\n:LOGBOOK:\n- Note taken on [2026-11-01 Sun]\n:END:\n#+end_example\n",
            ":logbook:\n",
            "- State \"DONE\" from \"TODO\" [2026-11-13 Fri 25:99] \\\\\n",
            "  无效时间的附注\n",
            "- 自定义说明 *保留*\n",
            "普通文字 <script>alert(1)</script>\n",
            ":END:\n",
            ":LOGBOOK:\n- Note taken on [2026-11-13 Fri]\n:END:\n",
        ));
        assert_eq!(parsed.len(), 4);
        let TaskLog::Other { html } = &parsed[0] else {
            panic!("无效时间应保留原文");
        };
        assert!(html.contains("25:99") && html.contains("无效时间的附注"));
        let TaskLog::Other { html } = &parsed[1] else {
            panic!("自定义日志应保留原文");
        };
        assert!(html.contains("<b>保留</b>"));
        let TaskLog::Other { html } = &parsed[2] else {
            panic!("普通文字应保留");
        };
        assert!(html.contains("普通文字") && !html.contains("<script>"));
        assert!(matches!(parsed[3], TaskLog::TaskNote { .. }));
    }
}
