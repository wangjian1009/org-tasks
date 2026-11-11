use super::*;
use crate::CoreError;
/// 同步测试通过统一操作组生成待上传的任务，不另建领域写入入口。
pub(crate) async fn append_fixture(
    repo: &mut OrgRepo,
    path: &str,
    title: &str,
) -> Result<(), CoreError> {
    let mut workspace = OrgWorkspace::new(vec![repo.clone()])?;
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
        queue_repo_ids: vec![repo.id.clone()],
        ..Default::default()
    };
    workspace.execute_task_operations(&group).await?;
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
