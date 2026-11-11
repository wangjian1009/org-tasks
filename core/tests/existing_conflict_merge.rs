//! 旧冲突材料与普通主树的并发变化分别协调，重放不得丢失或重复候选。
use org_tasks_core::{OrgFile, merge};

fn point(id: &str, body: &str, nl: &str) -> String {
    format!(
        "** 候选{nl}:PROPERTIES:{nl}:CONFILICT_ID: {id}{nl}:END:{nl}#+CONFLICT_REASON: modify{nl}*** TODO 任务{nl}:PROPERTIES:{nl}:ID: task{nl}:END:{nl}{body}{nl}"
    )
}

fn document(main: &str, points: &[String], nl: &str) -> Vec<u8> {
    if points.is_empty() {
        return main.as_bytes().to_vec();
    }
    format!(
        "{main}{nl}* 同步冲突 :CONFLICT:ARCHIVE:{nl}{}",
        points.concat()
    )
    .into_bytes()
}

fn parsed(bytes: &[u8]) -> OrgFile {
    OrgFile::new("merge".into(), "content.org".into(), bytes.to_vec()).unwrap()
}

#[test]
fn point_membership_covers_all_base_local_remote_combinations() {
    for nl in ["\n", "\r\n"] {
        let main = format!("* TODO 主树{nl}未修改");
        let present = document(&main, &[point("old", "不可修改的材料", nl)], nl);
        let absent = document(&main, &[], nl);
        // 明确列出全部八种成员关系，包含新增去重和双方解决后不恢复。
        for (base_has, local_has, remote_has, expected_has) in [
            (false, false, false, false),
            (false, false, true, true),
            (false, true, false, true),
            (false, true, true, true),
            (true, false, false, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, true),
        ] {
            let choose = |exists| if exists { &present } else { &absent };
            let base = choose(base_has);
            let local = choose(local_has);
            let remote = choose(remote_has);
            let expected = choose(expected_has);
            let output = merge(base, local, remote).unwrap();
            assert_eq!(&output, expected);
            assert_eq!(merge(base, local, &output).unwrap(), output);
            assert_eq!(merge(&output, &output, &output).unwrap(), output);
        }
    }
}

#[test]
fn both_sides_resolve_old_point_and_merge_their_main_results() {
    for nl in ["\n", "\r\n"] {
        for same_choice in [false, true] {
            let main = format!("* TODO 任务{nl}:PROPERTIES:{nl}:ID: task{nl}:END:{nl}基线正文{nl}");
            let base = document(&main, &[point("old", "旧候选", nl)], nl);
            let local = main.replace("基线正文", "本地解决结果").into_bytes();
            let remote = if same_choice {
                local.clone()
            } else {
                main.replace("基线正文", "远端解决结果").into_bytes()
            };
            let output = merge(&base, &local, &remote).unwrap();
            let file = parsed(&output);
            let ids = file.conflict_ids();
            assert!(!ids.iter().any(|id| id == "old"), "旧冲突始终保持解决");
            if same_choice {
                assert_eq!(output, local);
                assert!(!file.has_conflict());
            } else {
                assert_eq!(ids.len(), 1, "不兼容的主树结果产生一个新冲突");
                assert!(output.starts_with(&remote));
                assert!(String::from_utf8_lossy(&output).contains("本地解决结果"));
                assert_eq!(file.conflicts().unwrap().len(), 1);
            }
            assert_eq!(merge(&base, &local, &output).unwrap(), output);
            assert_eq!(merge(&output, &output, &output).unwrap(), output);
        }
    }
}

#[test]
fn independent_main_edits_and_point_resolutions_merge_together() {
    let main = "* TODO A\n原始 A\n* TODO B\n原始 B\n";
    let old_a = point("a", "旧候选 A", "\n");
    let old_b = point("b", "旧候选 B", "\n");
    let base = document(main, &[old_a.clone(), old_b.clone()], "\n");
    let local_point = point("local", "本地新增候选", "\n");
    let remote_point = point("remote", "远端新增候选", "\n");
    let local = document(
        &main.replace("原始 A", "本地修改 A"),
        &[old_b, local_point.clone()],
        "\n",
    );
    let remote = document(
        &main.replace("原始 B", "远端修改 B"),
        &[old_a, remote_point.clone()],
        "\n",
    );
    let expected = document(
        &main
            .replace("原始 A", "本地修改 A")
            .replace("原始 B", "远端修改 B"),
        &[remote_point, local_point],
        "\n",
    );
    let output = merge(&base, &local, &remote).unwrap();
    assert_eq!(output, expected);
    assert_eq!(merge(&base, &local, &output).unwrap(), output);
}
