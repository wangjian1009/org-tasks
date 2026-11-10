// 文件型测试数据位于临时仓库，生命周期随测试线程结束，不在仓库对象中保存正文。
struct FixtureDirectory(std::path::PathBuf);
impl Drop for FixtureDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
thread_local! {
    static FIXTURE_ROOTS: std::cell::RefCell<std::collections::BTreeMap<String, FixtureDirectory>> = Default::default();
}
pub fn id(value: &str) -> String {
    if value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return value.into();
    }
    let hash = core_types::LocalFileVersion::from_bytes(value.as_bytes()).content_hash;
    format!(
        "{}-{}-4{}-8{}-{}",
        &hash[..8],
        &hash[8..12],
        &hash[..3],
        &hash[3..6],
        &hash[..12]
    )
}
fn ensure_root(repo: &mut core_types::OrgRepo) {
    repo.id = id(if repo.id.is_empty() {
        "fixture"
    } else {
        &repo.id
    });
    if std::fs::read_to_string(std::path::Path::new(&repo.root_directory).join(".sync/id"))
        .is_ok_and(|id| id.trim() == repo.id && !repo.id.is_empty())
    {
        return;
    }
    let key = repo.root_directory.clone();
    let root = FIXTURE_ROOTS.with(|roots| {
        let mut roots = roots.borrow_mut();
        roots
            .entry(key)
            .or_insert_with(|| {
                static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                let root = std::env::temp_dir().join(format!(
                    "org-files-fixture-{}-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                ));
                std::fs::create_dir(&root).unwrap();
                FixtureDirectory(root)
            })
            .0
            .clone()
    });
    repo.root_directory = root.to_string_lossy().into_owned();
    if repo.id.is_empty() {
        repo.id = "fixture".into();
    }
    std::fs::create_dir_all(root.join(".sync")).unwrap();
    std::fs::write(root.join(".sync/id"), format!("{}\n", repo.id)).unwrap();
}
fn org_paths(root: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut paths = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in std::fs::read_dir(directory).unwrap() {
            let entry = entry.unwrap();
            if entry.file_name() == ".sync" {
                continue;
            }
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                pending.push(entry.path());
            } else if kind.is_file() && entry.path().extension().is_some_and(|value| value == "org")
            {
                paths.push(entry.path());
            }
        }
    }
    paths.sort();
    paths
}
pub fn with_files(
    mut repo: core_types::OrgRepo,
    files: Vec<core_types::OrgFile>,
    rules: core_types::TaskScanRules,
) -> core_types::OrgRepo {
    write_files(&mut repo, files);
    set_rules(&mut repo, rules);
    repo
}
pub fn write_files(repo: &mut core_types::OrgRepo, files: Vec<core_types::OrgFile>) {
    ensure_root(repo);
    for path in org_paths(std::path::Path::new(&repo.root_directory)) {
        std::fs::remove_file(path).unwrap();
    }
    for file in files {
        push_file(repo, file);
    }
}
pub fn push_file(repo: &mut core_types::OrgRepo, file: core_types::OrgFile) {
    ensure_root(repo);
    let path = std::path::Path::new(&repo.root_directory).join(&file.path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, file.source_bytes()).unwrap();
}
pub fn clear_files(repo: &mut core_types::OrgRepo) {
    write_files(repo, Vec::new());
}
pub fn replace_file(repo: &mut core_types::OrgRepo, index: usize, file: core_types::OrgFile) {
    ensure_root(repo);
    let paths = org_paths(std::path::Path::new(&repo.root_directory));
    if let Some(path) = paths.get(index) {
        std::fs::remove_file(path).unwrap();
    }
    push_file(repo, file);
}
pub fn set_rules(repo: &mut core_types::OrgRepo, rules: core_types::TaskScanRules) {
    ensure_root(repo);
    let root = std::path::Path::new(&repo.root_directory);
    let source = org_paths(root)
        .iter()
        .filter_map(|path| {
            let relative = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            rules.excludes(&relative).then(|| format!("/{relative}\n"))
        })
        .collect::<String>();
    std::fs::write(root.join(".orgzlyignore"), source).unwrap();
}
