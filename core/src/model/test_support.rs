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
        .files()
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
