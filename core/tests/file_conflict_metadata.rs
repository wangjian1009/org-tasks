mod support;
use org_tasks_core::{OrgFile, OrgRepo, merge};
#[tokio::test]
async fn file_conflict_state_comes_from_real_node_tags_not_headers_or_block_literals() {
    let file = OrgFile::new(
        "r".into(),
        "a.org".into(),
        "#+title: Name\r\n* Normal\r\n* 同步冲突 :CONFLICT:\r\n** Point\r\n"
            .as_bytes()
            .to_vec(),
    )
    .unwrap();
    assert_eq!(file.title().as_deref(), Some("Name"));
    assert!(file.has_conflict());
    let mut repo = OrgRepo::new("/unused/metadata".into()).unwrap();
    { let value = file; support::push_file(&mut repo, value); };
    let metadata = serde_json::to_value(&repo.file_metadata().await.unwrap()[0]).unwrap();
    assert_eq!(metadata["hasConflict"], true);
    assert_eq!(metadata["taskCount"], 1);
    for source in [
        "#+CONFLICT: true\n* A\n",
        "* A :conflict:\n",
        "#+begin_src org\n,* A :CONFLICT:\n#+end_src\n",
        "* A\n:PROPERTIES:\n:CONFLICT: true\n:END:\n",
    ] {
        assert!(
            !OrgFile::new("r".into(), "a.org".into(), source.as_bytes().to_vec())
                .unwrap()
                .has_conflict(),
            "{source}"
        );
    }
}
#[test]
fn merge_generates_one_container_and_no_additional_file_header() {
    let base = b"#+TITLE: Name\n* A\nbase\n";
    let local = b"#+TITLE: Local\n* A\nlocal\n";
    let remote = b"#+TITLE: Remote\n* A\nremote\n";
    let result = merge(base, local, remote).unwrap();
    assert!(result.starts_with(remote));
    let text = String::from_utf8(result.clone()).unwrap();
    assert_eq!(text.matches("* 同步冲突 :CONFLICT:").count(), 1);
    assert!(!text.contains("#+CONFLICT:"));
    assert_eq!(merge(base, local, &result).unwrap(), result);
}
