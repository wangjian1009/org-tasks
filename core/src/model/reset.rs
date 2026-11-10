//! 显式重置本地仓库：保留身份与锁，以可恢复的目录移动清空其他内容。
use super::OrgRepo;
use crate::{CoreError, webdav::transaction};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::fs;

const WORK: &str = ".sync/reset";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    entries: Vec<String>,
}

fn io(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法重置或恢复仓库目录: {error}"))
}

async fn exists(path: &Path) -> Result<bool, CoreError> {
    match fs::symlink_metadata(path).await {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io(error)),
    }
}

fn sync(path: &Path) -> Result<(), CoreError> {
    std::fs::File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(io)
}

fn validate(entry: &str) -> Result<(), CoreError> {
    let parts = entry.split('/').collect::<Vec<_>>();
    crate::model::validate_relative_path(entry)?;
    let valid = (parts.len() == 1 && parts[0] != ".sync")
        || (parts.len() == 2
            && parts[0] == ".sync"
            && !["id", ".transaction.lock", "reset"].contains(&parts[1]));
    if !valid {
        return Err(CoreError::Store("重置日志包含非法目标".into()));
    }
    Ok(())
}

/// 调用者持有仓库锁；正式完成前还原，完成后只清理，不跟随暂存中的符号链接。
pub(crate) async fn recover(root: &Path) -> Result<(), CoreError> {
    let work = root.join(WORK);
    if !exists(&work).await? {
        return Ok(());
    }
    let meta = fs::symlink_metadata(&work).await.map_err(io)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(CoreError::Store("重置暂存路径不是安全目录".into()));
    }
    let path = work.join("journal.json");
    if !exists(&path).await? {
        // 日志写入前只允许空准备目录，不能丢弃来源不明的文件。
        let mut entries = fs::read_dir(&work).await.map_err(io)?;
        while let Some(entry) = entries.next_entry().await.map_err(io)? {
            if entry.file_name() != "items"
                || !entry.file_type().await.map_err(io)?.is_dir()
                || fs::read_dir(entry.path())
                    .await
                    .map_err(io)?
                    .next_entry()
                    .await
                    .map_err(io)?
                    .is_some()
            {
                return Err(CoreError::Store("重置暂存缺少有效日志".into()));
            }
        }
        fs::remove_dir_all(&work).await.map_err(io)?;
        return Ok(());
    }
    let journal: Journal = serde_json::from_slice(
        &transaction::read(root, &format!("{WORK}/journal.json"))
            .await?
            .ok_or(CoreError::InvalidState("重置日志丢失"))?,
    )
    .map_err(|_| CoreError::Store("重置日志无效".into()))?;
    if journal.version != 1 {
        return Err(CoreError::Store("不支持的重置日志版本".into()));
    }
    let items = fs::symlink_metadata(work.join("items")).await.map_err(io)?;
    if !items.is_dir() || items.file_type().is_symlink() {
        return Err(CoreError::Store("重置暂存内容不是安全目录".into()));
    }
    let mut seen = std::collections::BTreeSet::new();
    for entry in &journal.entries {
        validate(entry)?;
        if !seen.insert(entry) {
            return Err(CoreError::Store("重置日志目标重复".into()));
        }
    }
    let committed = transaction::read(root, &format!("{WORK}/committed")).await?;
    if let Some(marker) = committed {
        if marker != b"1\n" {
            return Err(CoreError::Store("重置完成标记无效".into()));
        }
    } else {
        for (i, entry) in journal.entries.iter().enumerate().rev() {
            let source = work.join(format!("items/{i}"));
            if exists(&source).await? {
                let target = root.join(entry);
                if exists(&target).await? {
                    return Err(CoreError::InvalidState(
                        "重置恢复时发现外部修改，已保留暂存内容",
                    ));
                }
                fs::rename(source, &target).await.map_err(io)?;
                sync(target.parent().unwrap())?;
            }
        }
    }
    fs::remove_dir_all(&work).await.map_err(io)?;
    sync(&root.join(".sync"))
}

impl OrgRepo {
    /// 清空本地内容、历史、基线与意图；身份、根目录和宿主配置保持不变，不访问远端。
    pub async fn reset(&mut self) -> Result<(), CoreError> {
        let root = Path::new(&self.root_directory);
        let meta = fs::symlink_metadata(root).await.map_err(io)?;
        if !meta.is_dir()
            || meta.file_type().is_symlink()
            || fs::canonicalize(root).await.map_err(io)?.parent().is_none()
        {
            return Err(CoreError::InvalidInput("不能重置此仓库根目录"));
        }
        let _guard = transaction::lock(root).await?;
        // 身份不可重建；拒绝过期句柄，避免清理已经更换身份的目录。
        transaction::read(root, ".sync/id")
            .await?
            .ok_or(CoreError::InvalidState("仓库尚未初始化"))?;
        let id = super::service::read_repo_id(&root.join(".sync/id"))
            .await
            .map_err(io)?;
        if !self.id.is_empty() && self.id != id {
            return Err(CoreError::InvalidState("仓库身份已改变，请重新打开"));
        }
        recover(root).await?;
        let mut targets = Vec::new();
        for directory in ["", ".sync"] {
            let mut entries = fs::read_dir(root.join(directory)).await.map_err(io)?;
            while let Some(entry) = entries.next_entry().await.map_err(io)? {
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| CoreError::InvalidInput("仓库包含非 UTF-8 文件名"))?;
                if (directory.is_empty() && name == ".sync")
                    || (directory == ".sync"
                        && ["id", ".transaction.lock"].contains(&name.as_str()))
                {
                    continue;
                }
                let relative = if directory.is_empty() {
                    name
                } else {
                    format!("{directory}/{name}")
                };
                validate(&relative)?;
                targets.push(relative);
            }
        }
        targets.sort();
        let work = root.join(WORK);
        fs::create_dir_all(work.join("items")).await.map_err(io)?;
        let journal = Journal {
            version: 1,
            entries: targets,
        };
        super::write_intent::write_new(
            &work.join("journal.json"),
            &serde_json::to_vec(&journal)
                .map_err(|_| CoreError::InvalidState("无法编码重置日志"))?,
        )
        .await?;
        sync(&work)?;
        sync(&root.join(".sync"))?;
        let result = async {
            for (i, entry) in journal.entries.iter().enumerate() {
                fs::rename(root.join(entry), work.join(format!("items/{i}")))
                    .await
                    .map_err(io)?;
                sync(root.join(entry).parent().unwrap())?;
                sync(&work.join("items"))?;
            }
            super::write_intent::write_new(&work.join("committed"), b"1\n").await?;
            sync(&work)
        }
        .await;
        if let Err(error) = result {
            // 完成标记的目录刷新失败仍属提交失败，撤销标记后按日志恢复旧内容。
            let marker = work.join("committed");
            if exists(&marker).await? {
                fs::remove_file(marker).await.map_err(io)?;
                sync(&work)?;
            }
            recover(root).await?;
            return Err(error);
        }
        self.id = id;
        self.files.clear();
        self.task_scan_rules = super::TaskScanRules::default();
        // 正式完成后清理失败留待下次加载，不把成功重置报告成失败。
        let _ = recover(root).await;
        super::sync_events::publish(self);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::webdav::WebDavSyncPolicy;

    async fn repository() -> (OrgRepo, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "org-reset-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into_owned()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        (repo, root)
    }

    #[tokio::test]
    async fn reset_preserves_identity_clears_everything_and_can_repair_invalid_history() {
        let (mut repo, root) = repository().await;
        let identity = fs::read(root.join(".sync/id")).await.unwrap();
        fs::create_dir_all(root.join("notes/deep/empty"))
            .await
            .unwrap();
        fs::write(root.join("notes/deep/A.org"), b"* TODO A\n")
            .await
            .unwrap();
        fs::write(root.join("binary.dat"), [0xff, 0]).await.unwrap();
        fs::write(root.join(".orgzlyignore"), "notes/\n")
            .await
            .unwrap();
        for dir in ["history", "remote_base", "outbox"] {
            fs::create_dir_all(root.join(format!(".sync/{dir}")))
                .await
                .unwrap();
            fs::write(root.join(format!(".sync/{dir}/broken.json")), b"not-json")
                .await
                .unwrap();
        }
        repo.reset().await.unwrap();
        assert_eq!(fs::read(root.join(".sync/id")).await.unwrap(), identity);
        assert!(repo.files.is_empty());
        assert!(repo.load::<WebDavSyncPolicy>().await.unwrap().is_empty());
        let mut entries = fs::read_dir(&root).await.unwrap();
        assert_eq!(
            entries.next_entry().await.unwrap().unwrap().file_name(),
            ".sync"
        );
        assert!(entries.next_entry().await.unwrap().is_none());
        let mut names = Vec::new();
        let mut entries = fs::read_dir(root.join(".sync")).await.unwrap();
        while let Some(entry) = entries.next_entry().await.unwrap() {
            names.push(entry.file_name());
        }
        names.sort();
        assert_eq!(
            names,
            [
                std::ffi::OsString::from(".transaction.lock"),
                std::ffi::OsString::from("history"),
                std::ffi::OsString::from("id")
            ]
        );
        repo.reset().await.unwrap();
        assert_eq!(fs::read(root.join(".sync/id")).await.unwrap(), identity);
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn reset_rejects_stale_identity_and_serializes_with_other_writers() {
        let (mut repo, root) = repository().await;
        fs::write(root.join("A.org"), b"keep").await.unwrap();
        let guard = transaction::lock(&root).await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), repo.reset())
                .await
                .is_err()
        );
        assert_eq!(fs::read(root.join("A.org")).await.unwrap(), b"keep");
        drop(guard);
        repo.id = "stale".into();
        assert!(repo.reset().await.is_err());
        assert_eq!(fs::read(root.join("A.org")).await.unwrap(), b"keep");
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn interrupted_reset_rolls_back_and_committed_reset_only_cleans() {
        let (mut repo, root) = repository().await;
        for committed in [false, true] {
            let work = root.join(WORK);
            fs::create_dir_all(work.join("items")).await.unwrap();
            fs::write(work.join("items/0"), b"original").await.unwrap();
            fs::write(
                work.join("journal.json"),
                br#"{"version":1,"entries":["A.org"]}"#,
            )
            .await
            .unwrap();
            if committed {
                fs::write(work.join("committed"), b"1\n").await.unwrap();
            }
            repo.load::<WebDavSyncPolicy>().await.unwrap();
            assert_eq!(root.join("A.org").exists(), !committed);
            if !committed {
                fs::remove_file(root.join("A.org")).await.unwrap();
            }
            assert!(!work.exists());
        }
        fs::remove_dir_all(root).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reset_removes_links_without_touching_external_targets() {
        let (mut repo, root) = repository().await;
        let external = root.with_file_name(format!("outside-{}", repo.id));
        fs::create_dir(&external).await.unwrap();
        fs::write(external.join("keep.org"), b"keep").await.unwrap();
        std::os::unix::fs::symlink(&external, root.join("link")).unwrap();
        repo.reset().await.unwrap();
        assert_eq!(fs::read(external.join("keep.org")).await.unwrap(), b"keep");
        assert!(!root.join("link").exists());
        fs::remove_dir_all(root).await.unwrap();
        fs::remove_dir_all(external).await.unwrap();
    }
}
