use super::*;
fn normalized(source: &str) -> Vec<String> {
    let mut lines = Vec::new();
    let mut planning = Vec::new();
    let mut properties: Option<Vec<String>> = None;
    for line in source.lines() {
        let is_planning = ["SCHEDULED:", "DEADLINE:", "CLOSED:"]
            .iter()
            .any(|s| line.trim_start().starts_with(s));
        if !is_planning && !planning.is_empty() {
            planning.sort();
            lines.append(&mut planning);
        }
        if line.trim() == ":PROPERTIES:" {
            properties = Some(Vec::new());
            lines.push(line.into());
            continue;
        }
        if let Some(props) = &mut properties {
            if line.trim() == ":END:" {
                props.sort();
                lines.extend(props.iter().cloned());
                properties = None;
                lines.push(line.into());
            } else if let Some((key, value)) = line.trim().trim_start_matches(':').split_once(':') {
                props.push(format!("{}:{}", key.to_ascii_uppercase(), value.trim()));
            }
            continue;
        }
        if ["SCHEDULED:", "DEADLINE:", "CLOSED:"]
            .iter()
            .any(|s| line.trim_start().starts_with(s))
        {
            let mut at = ["SCHEDULED:", "DEADLINE:", "CLOSED:"]
                .iter()
                .filter_map(|s| line.find(s))
                .collect::<Vec<_>>();
            at.sort_unstable();
            at.push(line.len());
            for pair in at.windows(2) {
                planning.push(line[pair[0]..pair[1]].trim().into());
            }
        } else {
            lines.push(line.trim_end().into());
        }
    }
    planning.sort();
    lines.append(&mut planning);
    lines
}
#[test]
fn local_triggers_match_org_edna_reference() {
    check_reference(include_str!("../../../tests/data/task_trigger_emacs.json"));
}

#[test]
fn loki_triggers_match_emacs_extension() {
    check_reference(include_str!("../../../tests/data/loki_trigger_emacs.json"));
}

#[test]
fn loki_spawn_accepts_relative_intervals_and_preserves_the_selected_clock() {
    for (base, offset, planning, expected) in [
        ("today", "+6m", "", "<2027-05-19 Wed>"),
        ("today", "+6m", "SCHEDULED: <2026-08-31 Mon 09:00-10:30 -2d>\n", "<2027-05-19 Wed 09:00-10:30>"),
        ("source", "+6m", "SCHEDULED: <2026-08-31 Mon 09:00>\n", "<2027-03-03 Wed 09:00>"),
        ("target", "+1m", "SCHEDULED: <2026-12-31 Thu>\n", "<2027-01-31 Sun>"),
        ("today", "+2w", "", "<2026-12-03 Thu>"),
        ("today", "+3d", "", "<2026-11-22 Sun>"),
        ("source", "+1y", "SCHEDULED: <2024-02-29 Thu>\n", "<2025-03-01 Sat>"),
    ] {
        let rule = format!("self loki-spawn-next!({base} \"{offset}\")");
        let source = format!("* TODO Task\n{planning}:PROPERTIES:\n:TRIGGER: {rule}\n:KEEP: source\n:END:\n正文  \n* Tail\n保留  \n");
        let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
        let now = NaiveDateTime::parse_from_str("2026-11-19 12:34", "%Y-%m-%d %H:%M").unwrap();
        Context::new(&mut file, now, 0).todo(0, Some("DONE")).unwrap();
        let nodes = file.nodes();
        assert_eq!(nodes.len(), 3);
        assert!(nodes[0].is_done(), "{}", std::str::from_utf8(file.source_bytes()).unwrap());
        assert!(!nodes[1].is_done());
        assert_eq!(nodes[1].property("TRIGGER"), Some(rule.as_str()));
        assert_eq!(nodes[1].property("KEEP"), None);
        assert_eq!(nodes[1].property("ID"), None);
        let after = std::str::from_utf8(file.source_bytes()).unwrap();
        assert!(after.contains(&format!("正文  \n* TODO Task\nSCHEDULED: {expected}\n")), "{rule}\n{after}");
        assert!(after.ends_with("* Tail\n保留  \n"));
        assert_eq!(after.matches("正文").count(), 1);
    }
}

#[test]
fn loki_spawn_preserves_the_targets_reminder_clock_and_day_offset() {
    for (trigger, planning, reminder, expected) in [
        ("self loki-spawn-next!(today \"+6m\")", "<2026-11-10 Tue 10:00>", "[2026-11-10 Tue 09:00]", "[2027-05-19 Wed 09:00]"),
        ("self loki-spawn-next!(source mon wed fri)", "<2026-11-13 Fri 10:00>", "[2026-11-13 Fri 09:30]", "[2026-11-16 Mon 09:30]"),
        ("self loki-spawn-next!(target \"+1d\")", "<2026-11-13 Fri 10:00-11:00>", "[2026-11-13 Fri 11:30]", "[2026-11-14 Sat 11:30]"),
        ("self loki-spawn-next!(target \"+1d\")", "<2026-11-13 Fri>", "[2026-11-12 Thu 23:30]", "[2026-11-13 Fri 23:30]"),
        ("self loki-spawn-next!(target \"+1d\")", "<2026-03-07 Sat 10:00>", "[2026-03-07 Sat 10:00]", "[2026-03-08 Sun 10:00]"),
        ("self loki-spawn-next!(target \"+1d\")", "<2026-10-31 Sat 10:00>", "[2026-10-31 Sat 10:00]", "[2026-11-01 Sun 10:00]"),
    ] {
        let source = format!("* TODO Task\r\nSCHEDULED: {planning}\r\n:PROPERTIES:\r\n:TRIGGER: {trigger}\r\n:REMIND_AT: {reminder}\r\n:KEEP: source\r\n:END:\r\n正文  \r\n* Tail\r\n");
        let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
        let now = NaiveDateTime::parse_from_str("2026-11-19 12:34", "%Y-%m-%d %H:%M").unwrap();
        Context::new(&mut file, now, 0).todo(0, Some("DONE")).unwrap();
        let nodes = file.nodes();
        assert_eq!(nodes[0].property("REMIND_AT"), Some(reminder));
        assert_eq!(nodes[1].property("REMIND_AT"), Some(expected), "{trigger}");
        assert_eq!(nodes[1].property("KEEP"), None);
        assert_eq!(nodes[1].property("ID"), None);
        assert!(std::str::from_utf8(file.source_bytes()).unwrap().ends_with("* Tail\r\n"));
    }
}

#[test]
fn loki_spawn_source_base_uses_the_targets_reminder_not_the_sources() {
    let source = "* TODO Task\nSCHEDULED: <2026-11-01 Sun 15:00>\n:PROPERTIES:\n:TRIGGER: next-sibling loki-spawn-next!(source \"+6m\")\n:REMIND_AT: [2026-11-01 Sun 04:00]\n:END:\n* TODO Target\nSCHEDULED: <2026-11-10 Tue 10:00>\n:PROPERTIES:\n:REMIND_AT: [2026-11-10 Tue 09:00]\n:END:\n* Tail\n";
    let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
    let now = NaiveDateTime::parse_from_str("2026-11-19 12:34", "%Y-%m-%d %H:%M").unwrap();
    Context::new(&mut file, now, 0).todo(0, Some("DONE")).unwrap();
    let nodes = file.nodes();
    assert_eq!(nodes[2].property("REMIND_AT"), Some("[2027-05-01 Sat 09:00]"));
    assert_eq!(nodes[1].property("REMIND_AT"), Some("[2026-11-10 Tue 09:00]"));
}

#[test]
fn loki_spawn_does_not_invent_invalid_or_missing_reminders() {
    let now = NaiveDateTime::parse_from_str("2026-11-19 12:34", "%Y-%m-%d %H:%M").unwrap();
    for property in ["", ":REMIND_AT: wrong\n", ":REMIND_AT: [2026-11-19]--[2026-11-20]\n"] {
        let source = format!("* TODO Task\nSCHEDULED: <2026-11-19 Thu 10:00>\n:PROPERTIES:\n:TRIGGER: self loki-spawn-next!(today \"+6m\")\n{property}:END:\n");
        let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
        Context::new(&mut file, now, 0).todo(0, Some("DONE")).unwrap();
        assert_eq!(file.nodes()[1].reminder_at(), None);
        assert_eq!(file.nodes()[1].property("REMIND_AT"), None);
    }
}

#[test]
fn loki_spawn_without_a_schedule_keeps_the_reminders_offset_from_the_rule_base() {
    let now = NaiveDateTime::parse_from_str("2026-11-19 12:34", "%Y-%m-%d %H:%M").unwrap();
    let source = "* TODO Task\n:PROPERTIES:\n:TRIGGER: self loki-spawn-next!(today \"+6m\")\n:REMIND_AT: [2026-11-19 Thu 09:00]\n:END:\n";
    let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
    Context::new(&mut file, now, 0).todo(0, Some("DONE")).unwrap();
    assert_eq!(file.nodes()[1].property("REMIND_AT"), Some("[2027-05-19 Wed 09:00]"));

    let source = "* TODO Task\nSCHEDULED: <2026-11-13 Fri 10:00>\n:PROPERTIES:\n:TRIGGER: next-sibling loki-spawn-next!(source \"+6m\")\n:REMIND_AT: [2026-11-13 Fri 03:00]\n:END:\n* TODO Target\n:PROPERTIES:\n:REMIND_AT: [2026-11-13 Fri 09:30]\n:END:\n";
    let mut file = OrgFile::new("repo".into(), "tasks.org".into(), source.as_bytes().to_vec()).unwrap();
    Context::new(&mut file, now, 0).todo(0, Some("DONE")).unwrap();
    assert_eq!(file.nodes()[2].property("REMIND_AT"), Some("[2027-05-13 Thu 09:30]"));
}

fn check_reference(json: &str) {
    let data: serde_json::Value = serde_json::from_str(json).unwrap();
    let now =
        NaiveDateTime::parse_from_str(data["now"].as_str().unwrap(), "%Y-%m-%d %H:%M").unwrap();
    let mut failures = Vec::new();
    let mut names = std::collections::BTreeSet::new();
    assert!(!data["cases"].as_array().unwrap().is_empty());
    for case in data["cases"].as_array().unwrap() {
        assert!(
            names.insert(case["name"].as_str().unwrap()),
            "参考样例名称重复"
        );
        assert!(
            !case["expected"].as_str().unwrap().is_empty(),
            "参考输出不能为空"
        );
        let source = case["source"].as_str().unwrap();
        let mut file = OrgFile::with_todo_defaults_and_setup(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
            super::super::TodoConfig::default(),
            "#+PRIORITIES: A C B\n".into(),
        )
        .unwrap();
        let actions = case["actions"]
            .as_array()
            .cloned()
            .unwrap_or_else(|| vec![case["state"].clone()]);
        if case.get("steps").is_some() {
            assert_eq!(
                case["steps"].as_array().unwrap().len(),
                actions.len(),
                "{} 参考步骤不完整",
                case["name"]
            );
        }
        for (step, action) in actions.iter().enumerate() {
            let title = action
                .get("title")
                .or_else(|| case.get("title"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Task");
            let state = if action.is_object() {
                action["state"].as_str()
            } else {
                action.as_str()
            };
            let occurrence = action
                .get("occurrence")
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(1) as usize;
            let node = file
                .path_headlines()
                .into_iter()
                .filter(|(_, node)| node.title_raw().trim() == title)
                .nth(occurrence - 1)
                .unwrap()
                .1;
            let index = file
                .path_headlines()
                .iter()
                .position(|(_, n)| start(n) == start(&node))
                .unwrap();
            let offset = data["utcOffset"].as_i64().unwrap() as i32;
            match Context::new(&mut file, now, offset).todo(index, state) {
                Err(error) => {
                    failures.push(format!("{} 第 {} 步: {error}", case["name"], step + 1));
                    break;
                }
                Ok(()) => {
                    let actual = std::str::from_utf8(file.source_bytes()).unwrap();
                    let expected = case
                        .get("steps")
                        .map(|steps| &steps[step])
                        .unwrap_or(&case["expected"])
                        .as_str()
                        .unwrap();
                    if normalized(actual) != normalized(expected) {
                        failures.push(format!(
                            "{} 第 {} 步:\n实际:\n{actual}\n预期:\n{expected}",
                            case["name"],
                            step + 1
                        ));
                        break;
                    }
                }
            }
        }
    }

    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn oracle_comparison_keeps_planning_fields_attached_to_their_headline() {
    let before = "* A\nSCHEDULED: <2026-11-01 Sun>\n* B\nSCHEDULED: <2026-11-02 Mon>\n";
    let swapped = "* A\nSCHEDULED: <2026-11-02 Mon>\n* B\nSCHEDULED: <2026-11-01 Sun>\n";
    assert_ne!(normalized(before), normalized(swapped));
    assert_eq!(
        normalized("* A\nSCHEDULED: <2026-11-01 Sun> DEADLINE: <2026-11-02 Mon>\n"),
        normalized("* A\nDEADLINE: <2026-11-02 Mon>\nSCHEDULED: <2026-11-01 Sun>\n")
    );
}
