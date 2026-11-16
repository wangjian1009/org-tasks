use crate::OrgWorkspace;
use super::*;
use crate::CoreError;
/// 同步测试通过统一操作组生成任务，再显式准备旧上传意图以验证同步兼容性。
pub(crate) async fn append_fixture(
    repo: &mut OrgRepo,
    path: &str,
    title: &str,
) -> Result<(), CoreError> {
    let mut workspace = OrgWorkspace::start(vec![repo.clone()]).await?;
    let parent = TaskPath::file(repo.id.clone(), path.into());
    let after = repo
        .load_files(&[]).await?
        .iter()
        .find(|file| file.path == path)
        .and_then(|file| {
            file.path_headlines()
                .into_iter()
                .filter(|(_, node)| node.level() == 1)
                .last()
                .map(|(path, _)| path)
        });
    let mut creation = TaskCreation::new(TaskPosition { parent, after }, title.into());
    creation.state = Some("TODO".into());
    let group = TaskOperationGroup {
        operations: vec![TaskOperation::Creation(creation)],
        ..Default::default()
    };
    workspace.execute_task_operations(&group).await?;
    let changed = &workspace.task_operation_history.entries.last().unwrap().fallback_group.files[0];
    let directory = std::path::Path::new(&repo.root_directory).join(".sync/outbox");
    tokio::fs::create_dir_all(&directory).await.map_err(|error| CoreError::Store(error.to_string()))?;
    let intent = OrgRepoWriteIntent {
        relative_path: path.into(),
        content_hash: LocalFileVersion::from_bytes(changed.after.as_bytes()).content_hash,
    };
    super::write_intent::write_new(&directory.join(format!("{}.json", super::service::generate_repo_id()?)),
        &serde_json::to_vec(&intent).unwrap()).await?;
    *repo = workspace.repos.remove(0);
    Ok(())
}

use crate as core_types;
include!("../../tests/support/disk.rs");

// 按仓库计数，允许并行测试验证真实访问路径没有重复加锁或加载。
fn access_counts() -> &'static std::sync::Mutex<std::collections::BTreeMap<std::path::PathBuf, [usize; 2]>> {
    static COUNTS: std::sync::OnceLock<std::sync::Mutex<std::collections::BTreeMap<std::path::PathBuf, [usize; 2]>>> = std::sync::OnceLock::new();
    COUNTS.get_or_init(Default::default)
}

pub(crate) fn record_access(root: &std::path::Path, kind: usize) {
    let root = std::fs::canonicalize(root).unwrap();
    access_counts().lock().unwrap().entry(root).or_default()[kind] += 1;
}

pub(crate) fn repository_accesses(root: &str) -> [usize; 2] {
    let root = std::fs::canonicalize(root).unwrap();
    access_counts().lock().unwrap().get(&root).copied().unwrap_or_default()
}

fn file_counts() -> &'static std::sync::Mutex<std::collections::BTreeMap<std::path::PathBuf, [usize; 2]>> {
    static COUNTS: std::sync::OnceLock<std::sync::Mutex<std::collections::BTreeMap<std::path::PathBuf, [usize; 2]>>> = std::sync::OnceLock::new();
    COUNTS.get_or_init(Default::default)
}

pub(crate) fn record_file_access(path: &std::path::Path, kind: usize) {
    let path = std::fs::canonicalize(path.parent().unwrap()).unwrap_or_else(|_| path.parent().unwrap().to_owned()).join(path.file_name().unwrap());
    file_counts().lock().unwrap().entry(path).or_default()[kind] += 1;
}

pub(crate) fn file_accesses(path: &std::path::Path) -> [usize; 2] {
    let path = std::fs::canonicalize(path.parent().unwrap()).unwrap_or_else(|_| path.parent().unwrap().to_owned()).join(path.file_name().unwrap());
    file_counts().lock().unwrap().get(&path).copied().unwrap_or_default()
}
