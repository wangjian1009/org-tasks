use std::path::{Path, PathBuf};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;

use super::{LocalFileVersion, OrgFileEdit, OrgRepo, apply_edit, editor::position_at};
use crate::{CoreError, filter::tasks_from_repo};

/// 宿主提交的任务创建参数，仅在调用期间使用。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewTask {
    pub heading: String,
    pub scheduled: String,
    pub deadline: String,
    pub tags: Vec<String>,
    pub priority: String,
}

/// 待上传文件的写入意图；任务正文只存在于原始 org 文件中。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OrgRepoWriteIntent {
    pub relative_path: String,
    pub content_hash: String,
}

impl LocalFileVersion {
    pub fn from_bytes(source: &[u8]) -> Self {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in source {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Self {
            content_hash: format!("{hash:016x}"),
        }
    }
}

impl OrgRepo {
    /// 保留既有字节，在指定 org 文件末尾追加任务，并可登记待上传意图。
    pub async fn create_task(
        &mut self,
        path: &str,
        task: &NewTask,
        queue_upload: bool,
    ) -> Result<(), CoreError> {
        if self.id.is_empty() {
            return Err(CoreError::InvalidState("仓库尚未加载"));
        }
        validate_task_path(path)?;
        let content = task.render()?;
        let target = task_target(Path::new(&self.root_directory), path).await?;
        let original = read_optional(&target).await?;
        let mut file = self.parse_file(path.into(), original.clone().unwrap_or_default())?;
        let newline = if file.source_bytes().windows(2).any(|pair| pair == b"\r\n") {
            "\r\n"
        } else {
            "\n"
        };
        let separator = if !file.source_bytes().is_empty() && !file.source_bytes().ends_with(b"\n")
        {
            newline
        } else {
            ""
        };
        let offset = file.source_bytes().len() + separator.len();
        let anchor = position_at(file.source_bytes(), file.source_bytes().len());
        apply_edit(
            &mut file,
            OrgFileEdit::InsertAt {
                anchor,
                content: format!("{separator}{}", content.replace('\n', newline)).into_bytes(),
            },
        )?;
        let projection = OrgRepo {
            id: self.id.clone(),
            root_directory: self.root_directory.clone(),
            files: vec![file.clone()],
        };
        if !tasks_from_repo(&projection).iter().any(|item| {
            item.byte_offset as usize == offset
                && item.title == task.heading.trim()
                && item.state.as_deref() == Some("TODO")
        }) {
            return Err(CoreError::InvalidInput(
                "标题不能包含隐式 Org 属性，且目标文件末尾必须允许新增标题",
            ));
        }
        let nonce = super::service::generate_repo_id()?;
        let temporary = target.with_file_name(format!(".{nonce}.tmp"));
        write_new(&temporary, file.source_bytes()).await?;
        let intent_path = Path::new(&self.root_directory)
            .join(".sync/outbox")
            .join(format!("{nonce}.json"));
        let intent_temporary = intent_path.with_extension("tmp");
        let result = async {
            if queue_upload {
                let intent = OrgRepoWriteIntent {
                    relative_path: path.into(),
                    content_hash: LocalFileVersion::from_bytes(file.source_bytes()).content_hash,
                };
                fs::create_dir_all(intent_path.parent().unwrap())
                    .await
                    .map_err(store_error)?;
                let intent_bytes = serde_json::to_vec(&intent)
                    .map_err(|_| CoreError::InvalidState("无法序列化写入意图"))?;
                write_new(&intent_temporary, &intent_bytes).await?;
                fs::rename(&intent_temporary, &intent_path)
                    .await
                    .map_err(store_error)?;
            }
            // 外部编辑或删除发生后，不能用旧快照覆盖文件。
            if read_optional(&target).await? != original {
                return Err(CoreError::InvalidState("目标文件已发生变化，请重试保存"));
            }
            fs::rename(&temporary, &target).await.map_err(store_error)?;
            Ok(())
        }
        .await;
        if let Err(error) = result {
            let _ = fs::remove_file(&temporary).await;
            if queue_upload {
                let _ = fs::remove_file(&intent_path).await;
                let _ = fs::remove_file(&intent_temporary).await;
            }
            return Err(error);
        }
        if let Some(index) = self.files.iter().position(|item| item.path == path) {
            self.files[index] = file;
        } else {
            self.files.push(file);
        }
        Ok(())
    }

    pub async fn pending_writes(&self) -> Result<Vec<OrgRepoWriteIntent>, CoreError> {
        Ok(self
            .write_intent_files()
            .await?
            .into_iter()
            .map(|(_, intent)| intent)
            .collect())
    }

    /// 仅在成功同步的版本仍与本地文件一致时确认上传，避免清除较新的保存。
    pub async fn acknowledge_write(
        &self,
        path: &str,
        version: &LocalFileVersion,
    ) -> Result<(), CoreError> {
        validate_task_path(path)?;
        let Some(file) = self.files.iter().find(|file| file.path == path) else {
            return Ok(());
        };
        if LocalFileVersion::from_bytes(file.source_bytes()) != *version {
            return Ok(());
        }
        let current = read_optional(&Path::new(&self.root_directory).join(path)).await?;
        if current
            .as_deref()
            .map(LocalFileVersion::from_bytes)
            .as_ref()
            != Some(version)
        {
            return Ok(());
        }
        for (intent_path, intent) in self.write_intent_files().await? {
            if intent.relative_path == path {
                fs::remove_file(intent_path).await.map_err(store_error)?;
            }
        }
        Ok(())
    }

    pub(crate) async fn acknowledge_deleted_write(&self, path: &str) -> Result<(), CoreError> {
        validate_task_path(path)?;
        if read_optional(&Path::new(&self.root_directory).join(path))
            .await?
            .is_some()
        {
            return Ok(());
        }
        for (intent_path, intent) in self.write_intent_files().await? {
            if intent.relative_path == path {
                fs::remove_file(intent_path).await.map_err(store_error)?;
            }
        }
        Ok(())
    }

    async fn write_intent_files(&self) -> Result<Vec<(PathBuf, OrgRepoWriteIntent)>, CoreError> {
        let directory = Path::new(&self.root_directory).join(".sync/outbox");
        let mut entries = match fs::read_dir(directory).await {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(store_error(error)),
        };
        let mut intents = Vec::new();
        while let Some(entry) = entries.next_entry().await.map_err(store_error)? {
            if !entry.file_type().await.map_err(store_error)?.is_file()
                || entry.path().extension().and_then(|value| value.to_str()) != Some("json")
            {
                continue;
            }
            let intent: OrgRepoWriteIntent =
                serde_json::from_slice(&fs::read(entry.path()).await.map_err(store_error)?)
                    .map_err(|_| CoreError::Store("outbox 写入意图 JSON 无效".into()))?;
            validate_task_path(&intent.relative_path)
                .map_err(|_| CoreError::Store("outbox 路径无效".into()))?;
            if intent.content_hash.len() != 16
                || !intent
                    .content_hash
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(CoreError::Store("outbox 内容哈希无效".into()));
            }
            intents.push((entry.path(), intent));
        }
        Ok(intents)
    }
}

impl NewTask {
    fn render(&self) -> Result<String, CoreError> {
        let heading = self.heading.trim();
        if heading.is_empty() || self.heading.chars().any(char::is_control) {
            return Err(CoreError::InvalidInput("任务标题不能为空或包含控制字符"));
        }
        if !matches!(self.priority.as_str(), "" | "A" | "B" | "C") {
            return Err(CoreError::InvalidInput("优先级必须为空或 A、B、C"));
        }
        for date in [&self.scheduled, &self.deadline] {
            if !date.is_empty()
                && (date.len() != 10 || NaiveDate::parse_from_str(date, "%Y-%m-%d").is_err())
            {
                return Err(CoreError::InvalidInput("日期必须是有效的 YYYY-MM-DD"));
            }
        }
        if self.tags.iter().any(|tag| {
            tag.is_empty()
                || !tag
                    .chars()
                    .all(|c| c.is_alphanumeric() || matches!(c, '_' | '@' | '#' | '%'))
        }) {
            return Err(CoreError::InvalidInput(
                "标签只能包含字母、数字、中文、_、@、#、%",
            ));
        }
        let priority = if self.priority.is_empty() {
            String::new()
        } else {
            format!("[#{}] ", self.priority)
        };
        let mut tags = Vec::new();
        for tag in &self.tags {
            if !tags.contains(tag) {
                tags.push(tag.clone());
            }
        }
        let tags = if tags.is_empty() {
            String::new()
        } else {
            format!(" :{}:", tags.join(":"))
        };
        let mut content = format!("* TODO {priority}{heading}{tags}\n");
        let mut planning = Vec::new();
        if !self.scheduled.is_empty() {
            planning.push(format!("SCHEDULED: <{}>", self.scheduled));
        }
        if !self.deadline.is_empty() {
            planning.push(format!("DEADLINE: <{}>", self.deadline));
        }
        if !planning.is_empty() {
            content.push_str(&format!("{}\n", planning.join(" ")));
        }
        Ok(content)
    }
}

fn validate_task_path(path: &str) -> Result<(), CoreError> {
    super::validate_relative_path(path)?;
    if path.split('/').next() == Some(".sync") || !path.ends_with(".org") {
        return Err(CoreError::InvalidInput(
            "任务目标必须是控制目录外的相对 .org 路径",
        ));
    }
    Ok(())
}

pub(super) async fn task_target(root: &Path, path: &str) -> Result<PathBuf, CoreError> {
    let mut target = root.to_path_buf();
    let parts = path.split('/').collect::<Vec<_>>();
    for (index, part) in parts.iter().enumerate() {
        target.push(part);
        match fs::symlink_metadata(&target).await {
            Ok(metadata)
                if metadata.file_type().is_symlink()
                    || (index + 1 < parts.len() && !metadata.is_dir())
                    || (index + 1 == parts.len() && !metadata.is_file()) =>
            {
                return Err(CoreError::InvalidInput(
                    "任务目标不能包含符号链接或非普通文件",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if index + 1 < parts.len() {
                    fs::create_dir(&target).await.map_err(store_error)?;
                }
            }
            Err(error) => return Err(store_error(error)),
        }
    }
    Ok(target)
}

pub(super) async fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, CoreError> {
    match fs::read(path).await {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(store_error(error)),
    }
}

pub(super) async fn write_new(path: &Path, content: &[u8]) -> Result<(), CoreError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .await
        .map_err(store_error)?;
    let result = async {
        file.write_all(content).await.map_err(store_error)?;
        file.sync_all().await.map_err(store_error)
    }
    .await;
    if result.is_err() {
        let _ = fs::remove_file(path).await;
    }
    result
}

fn store_error(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法保存任务或维护 outbox: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Filter, OrgWorkspace, webdav::WebDavSyncPolicy};

    async fn repo() -> OrgRepo {
        let root = std::env::temp_dir().join(format!(
            "org-tasks-create-{}",
            super::super::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        repo
    }

    #[tokio::test]
    async fn creation_preserves_bytes_and_projects_fields_after_reload() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        let original = "#+TITLE: 收件箱\r\n* TODO 原任务\r\n正文  ".as_bytes();
        fs::write(root.join("inbox.org"), original).await.unwrap();
        let task = NewTask {
            heading: "处理事务".into(),
            scheduled: "2026-10-12".into(),
            deadline: "2026-10-15".into(),
            priority: "A".into(),
            tags: vec!["工作".into(), "home".into(), "工作".into()],
        };
        repo.create_task("inbox.org", &task, true).await.unwrap();
        let bytes = fs::read(root.join("inbox.org")).await.unwrap();
        assert!(bytes.starts_with(original));
        assert!(bytes.ends_with("\r\n* TODO [#A] 处理事务 :工作:home:\r\nSCHEDULED: <2026-10-12> DEADLINE: <2026-10-15>\r\n".as_bytes()));
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        let workspace = OrgWorkspace::new(vec![repo.clone()]).unwrap();
        let tasks = workspace.search(&Filter::parse(""));
        let created = tasks.iter().find(|task| task.title == "处理事务").unwrap();
        assert_eq!(created.priority.as_deref(), Some("A"));
        assert_eq!(created.own_tags, ["工作", "home"]);
        assert_eq!(created.scheduled.unwrap().date.to_string(), "2026-10-12");
        assert_eq!(created.deadline.unwrap().date.to_string(), "2026-10-15");
        let intent = repo.pending_writes().await.unwrap().pop().unwrap();
        assert_eq!(
            intent.content_hash,
            LocalFileVersion::from_bytes(&bytes).content_hash
        );
        let intent_json = serde_json::to_string(&intent).unwrap();
        assert!(!intent_json.contains("处理事务"));
        assert!(!intent_json.contains(&repo.root_directory));
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn creates_nested_local_inbox_without_queue_and_keeps_other_files() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        fs::write(root.join("other.org"), b"* TODO Other\n")
            .await
            .unwrap();
        repo.create_task(
            "notes/inbox.org",
            &NewTask {
                heading: "New".into(),
                ..Default::default()
            },
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            fs::read(root.join("notes/inbox.org")).await.unwrap(),
            b"* TODO New\n"
        );
        assert_eq!(
            fs::read(root.join("other.org")).await.unwrap(),
            b"* TODO Other\n"
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn rejects_invalid_task_and_unsafe_path_without_changing_file() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        fs::write(root.join("inbox.org"), b"* TODO Existing\n")
            .await
            .unwrap();
        let valid = NewTask {
            heading: "New".into(),
            ..Default::default()
        };
        for path in [
            "../escape.org",
            "/tmp/escape.org",
            ".sync/inbox.org",
            "a/../inbox.org",
            "inbox.txt",
            "a\\inbox.org",
        ] {
            assert!(repo.create_task(path, &valid, true).await.is_err());
        }
        for invalid in [
            NewTask {
                heading: "\n* TODO Injected".into(),
                ..valid.clone()
            },
            NewTask {
                heading: "Title :implicit:".into(),
                ..valid.clone()
            },
            NewTask {
                scheduled: "2026-02-30".into(),
                ..valid.clone()
            },
            NewTask {
                deadline: "2026-1-1".into(),
                ..valid.clone()
            },
            NewTask {
                tags: vec!["not:one".into()],
                ..valid.clone()
            },
            NewTask {
                priority: "D".into(),
                ..valid.clone()
            },
        ] {
            assert!(repo.create_task("inbox.org", &invalid, true).await.is_err());
        }
        assert_eq!(
            fs::read(root.join("inbox.org")).await.unwrap(),
            b"* TODO Existing\n"
        );
        assert!(repo.pending_writes().await.unwrap().is_empty());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn older_upload_cannot_acknowledge_newer_task() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        let task = NewTask {
            heading: "First".into(),
            ..Default::default()
        };
        repo.create_task("inbox.org", &task, true).await.unwrap();
        let older = LocalFileVersion::from_bytes(repo.files[0].source_bytes());
        repo.create_task(
            "inbox.org",
            &NewTask {
                heading: "Second".into(),
                ..task
            },
            true,
        )
        .await
        .unwrap();
        repo.acknowledge_write("inbox.org", &older).await.unwrap();
        assert_eq!(repo.pending_writes().await.unwrap().len(), 2);
        let latest = LocalFileVersion::from_bytes(repo.files[0].source_bytes());
        repo.acknowledge_write("inbox.org", &latest).await.unwrap();
        assert!(repo.pending_writes().await.unwrap().is_empty());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn corrupt_outbox_fails_load_and_temporary_intents_are_ignored() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        fs::create_dir(root.join(".sync/outbox")).await.unwrap();
        fs::write(root.join(".sync/outbox/interrupted.tmp"), b"{")
            .await
            .unwrap();
        repo.load::<WebDavSyncPolicy>().await.unwrap();
        fs::write(root.join(".sync/outbox/invalid.json"), b"{")
            .await
            .unwrap();
        assert!(repo.load::<WebDavSyncPolicy>().await.is_err());
        fs::remove_dir_all(root).await.unwrap();
    }

    struct ConfirmingPolicy {
        success: bool,
    }

    impl super::super::SyncPolicy for ConfirmingPolicy {
        const KIND: &'static str = "webdav";
        type ContextDetail = serde_json::Value;
        type FileDetail = serde_json::Value;

        async fn synchronize(
            &self,
            context: &mut super::super::SyncContext<'_>,
            _history: &[super::super::OrgRepoSyncRecord],
            _cancellation: &super::super::SyncCancellation,
            _progress: &super::super::SyncProgressReporter,
        ) -> Result<super::super::OrgRepoSyncRecord, CoreError> {
            use super::super::{
                OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState,
                OrgRepoSyncRecord, OrgRepoSyncResult,
            };
            let mut record =
                OrgRepoSyncRecord::new(format!("mock-{}", context.started_at), context.started_at)?;
            record.append_file(
                OrgRepoSyncFileRecord::new(
                    "inbox.org".into(),
                    OrgRepoSyncFileAction::Uploaded,
                    if self.success {
                        OrgRepoSyncFileState::Synchronized
                    } else {
                        OrgRepoSyncFileState::Failed
                    },
                )?
                .with_local_version(Some(LocalFileVersion::from_bytes(
                    context.repo.files[0].source_bytes(),
                ))),
            )?;
            record.finish(
                if self.success {
                    OrgRepoSyncResult::Succeeded
                } else {
                    OrgRepoSyncResult::Failed
                },
                context.started_at,
            )?;
            Ok(record)
        }
    }

    #[tokio::test]
    async fn intent_is_consumed_only_after_success_and_history_commit() {
        use super::super::{SyncCancellation, SyncProgressReporter};
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        repo.create_task(
            "inbox.org",
            &NewTask {
                heading: "Offline".into(),
                ..Default::default()
            },
            true,
        )
        .await
        .unwrap();
        let cancellation = SyncCancellation::default();
        let progress = SyncProgressReporter::default();
        repo.sync(
            &ConfirmingPolicy { success: false },
            &[],
            1,
            &cancellation,
            &progress,
        )
        .await
        .unwrap();
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        // 即使上传成功，历史提交失败也不能消费意图。
        assert!(
            repo.sync(
                &ConfirmingPolicy { success: true },
                &[],
                1,
                &cancellation,
                &progress
            )
            .await
            .is_err()
        );
        assert_eq!(repo.pending_writes().await.unwrap().len(), 1);
        repo.sync(
            &ConfirmingPolicy { success: true },
            &[],
            2,
            &cancellation,
            &progress,
        )
        .await
        .unwrap();
        assert!(root.join(".sync/history/2.json").exists());
        assert!(repo.pending_writes().await.unwrap().is_empty());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_symlink_target() {
        let mut repo = repo().await;
        let root = PathBuf::from(&repo.root_directory);
        fs::create_dir(root.join("actual")).await.unwrap();
        std::os::unix::fs::symlink(root.join("actual"), root.join("linked")).unwrap();
        assert!(
            repo.create_task(
                "linked/inbox.org",
                &NewTask {
                    heading: "New".into(),
                    ..Default::default()
                },
                true
            )
            .await
            .is_err()
        );
        assert!(!root.join("actual/inbox.org").exists());
        fs::remove_dir_all(root).await.unwrap();
    }
}
