use org_tasks_core::{OrgFile, OrgRepo, merge};

#[test]
fn scans_title_and_conflict_only_from_document_header() {
    let file = OrgFile::new(
        "repo".into(),
        "A.org".into(),
        b"#+title: Name\r\n#+conflict: true\r\n* TODO A\r\n#+CONFLICT: false\r\n".to_vec(),
    )
    .unwrap();
    assert_eq!(file.title().as_deref(), Some("Name"));
    assert!(file.has_conflict());
    let mut repo = OrgRepo::new("/unused/metadata".into()).unwrap();
    repo.files.push(file);
    let value = serde_json::to_value(&repo.file_metadata()[0]).unwrap();
    assert_eq!(value["hasConflict"], true);
    for source in [
        "#+CONFLICT: false\n",
        "* A\n#+CONFLICT: true\n",
        "#+begin_src org\n#+CONFLICT: true\n#+end_src\n",
    ] {
        assert!(
            !OrgFile::new("r".into(), "A.org".into(), source.as_bytes().to_vec())
                .unwrap()
                .has_conflict()
        );
    }
}

#[test]
fn merge_generates_one_header_marker_and_clears_stale_markers() {
    let base = b"* TODO A\n:PROPERTIES:\n:ID: a\n:END:\nbase\n";
    let local = String::from_utf8(base.to_vec())
        .unwrap()
        .replace("base", "local");
    let remote = String::from_utf8(base.to_vec())
        .unwrap()
        .replace("base", "remote");
    let result = merge(base, local.as_bytes(), remote.as_bytes()).unwrap();
    assert!(result.starts_with(b"#+CONFLICT: true\n"));
    assert_eq!(merge(base, local.as_bytes(), &result).unwrap(), result);
    let clean = b"#+TITLE: Name\n#+CONFLICT: true\n#+CONFLICT: false\n* TODO A\n";
    assert_eq!(
        merge(clean, clean, clean).unwrap(),
        b"#+TITLE: Name\n* TODO A\n"
    );
}
