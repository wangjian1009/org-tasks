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
    let data: serde_json::Value =
        serde_json::from_str(include_str!("../../../tests/data/task_trigger_emacs.json")).unwrap();
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
        let mut file = OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            source.as_bytes().to_vec(),
        )
        .unwrap();
        let actions = case["actions"]
            .as_array()
            .map(|values| {
                values
                    .iter()
                    .map(serde_json::Value::as_str)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| vec![case["state"].as_str()]);
        if case.get("steps").is_some() {
            assert_eq!(
                case["steps"].as_array().unwrap().len(),
                actions.len(),
                "{} 参考步骤不完整",
                case["name"]
            );
        }
        for (step, state) in actions.iter().enumerate() {
            let node = file
                .path_headlines()
                .into_iter()
                .find(|(_, node)| node.title_raw().trim() == "Task")
                .unwrap()
                .1;
            let index = file
                .path_headlines()
                .iter()
                .position(|(_, n)| start(n) == start(&node))
                .unwrap();
            let offset = data["utcOffset"].as_i64().unwrap() as i32;
            match (Context {
                file: &mut file,
                now,
                utc_offset: offset,
                steps: 0,
                stack: Vec::new(),
            })
            .todo(index, *state)
            {
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
