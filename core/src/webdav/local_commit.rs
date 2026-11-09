//! 将一轮成功同步的本地变化集中提交，失败时撤回本轮已应用且未被外部修改的文件。
use super::*;
use std::path::{Path, PathBuf};
use tokio::fs;

#[derive(Clone, Debug)]
pub(crate) struct LocalSyncChange {
    pub path: String,
    pub before: Option<Vec<u8>>,
    pub after: Option<Vec<u8>>,
}

pub(crate) async fn read_local(root: &Path, path: &str) -> Result<Option<Vec<u8>>, CoreError> {
    let target = crate::model::write_intent::task_target(root, path).await?;
    crate::model::write_intent::read_optional(&target).await
}

async fn prepare(
    root: &Path,
    change: &LocalSyncChange,
) -> Result<(PathBuf, Option<PathBuf>), CoreError> {
    let target = crate::model::write_intent::task_target(root, &change.path).await?;
    if read_local(root, &change.path).await? != change.before {
        return Err(CoreError::InvalidState(
            "同步期间本地文件已修改，未应用下载或删除",
        ));
    }
    let temporary = if let Some(bytes) = &change.after {
        let path = target.with_file_name(format!(
            ".{}.tmp",
            crate::model::service::generate_repo_id()?
        ));
        crate::model::write_intent::write_new(&path, bytes).await?;
        Some(path)
    } else {
        None
    };
    Ok((target, temporary))
}

pub(crate) async fn commit_local(
    root: &Path,
    changes: &[LocalSyncChange],
) -> Result<(), CoreError> {
    let mut prepared = Vec::new();
    for change in changes {
        match prepare(root, change).await {
            Ok(paths) => prepared.push(paths),
            Err(error) => {
                cleanup(&prepared).await;
                return Err(error);
            }
        }
    }
    for (index, (target, temporary)) in prepared.iter().enumerate() {
        let result = async {
            if read_local(root, &changes[index].path).await? != changes[index].before {
                return Err(CoreError::InvalidState("同步期间本地文件已修改，停止应用"));
            }
            if let Some(temporary) = temporary {
                fs::rename(temporary, target).await.map_err(io)?;
            } else if changes[index].before.is_some() {
                fs::remove_file(target).await.map_err(io)?;
            }
            Ok(())
        }
        .await;
        if let Err(error) = result {
            let rollback = rollback_local(root, &changes[..index]).await;
            cleanup(&prepared).await;
            rollback?;
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) async fn rollback_local(
    root: &Path,
    changes: &[LocalSyncChange],
) -> Result<(), CoreError> {
    for change in changes.iter().rev() {
        // 外部编辑不属于本轮写入，不能在回滚时覆盖。
        if read_local(root, &change.path).await? != change.after {
            return Err(CoreError::Store(
                "本地文件在同步提交后被外部修改，无法撤回该文件".into(),
            ));
        }
        let reverse = LocalSyncChange {
            path: change.path.clone(),
            before: change.after.clone(),
            after: change.before.clone(),
        };
        let (target, temporary) = prepare(root, &reverse).await?;
        if let Some(temporary) = temporary {
            fs::rename(temporary, target).await.map_err(io)?;
        } else if reverse.before.is_some() {
            fs::remove_file(target).await.map_err(io)?;
        }
    }
    Ok(())
}

async fn cleanup(prepared: &[(PathBuf, Option<PathBuf>)]) {
    for (_, temporary) in prepared {
        if let Some(path) = temporary {
            let _ = fs::remove_file(path).await;
        }
    }
}
fn io(e: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法提交本地同步文件：{e}"))
}
