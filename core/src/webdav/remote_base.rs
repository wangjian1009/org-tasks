//! 不可变的远端快照与本地合并祖先；远端发布独立于工作文件事务。
use super::transaction::{self, Plan};
use crate::{CoreError, LocalFileVersion, RemoteFileVersion};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use tokio::fs;

const INDEX: &str = ".sync/remote_base/current.json";
const GENERATIONS: &str = ".sync/remote_base/generations";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Entry {
    revision: String,
    pub version: RemoteFileVersion,
    hash: Option<String>,
    sync_id: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Index {
    version: u32,
    origin: String,
    #[serde(default)]
    generation: Option<String>,
    #[serde(default)]
    local: Option<String>,
    entries: BTreeMap<String, Entry>,
}

#[derive(Serialize, Deserialize)]
struct Manifest {
    version: u32,
    origin: String,
    entries: BTreeMap<String, Entry>,
}

#[derive(Clone, Default)]
pub(crate) struct Snapshot {
    id: Option<String>,
    entries: BTreeMap<String, Entry>,
    contents: BTreeMap<String, Option<Vec<u8>>>,
    paths: BTreeMap<String, String>,
    controls: BTreeMap<String, Vec<u8>>,
}

pub(crate) struct Update {
    pub path: String,
    pub bytes: Option<Vec<u8>>,
    pub version: RemoteFileVersion,
    pub sync_id: String,
}

pub(crate) struct Store {
    index: Index,
    original: Option<Vec<u8>>,
    remote: Snapshot,
    ancestor: Snapshot,
}

fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, CoreError> {
    serde_json::to_vec(value).map_err(|_| CoreError::InvalidState("无法编码远端基线"))
}
fn invalid(message: &str) -> CoreError {
    CoreError::Store(message.into())
}
fn io(error: std::io::Error) -> CoreError {
    invalid(&format!("无法保存远端基线: {error}"))
}
fn validate_revision(value: &str) -> Result<(), CoreError> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Err(invalid("远端基线版本号无效"));
    }
    Ok(())
}
fn generation_path(id: &str) -> Result<String, CoreError> {
    validate_revision(id)?;
    Ok(format!("{GENERATIONS}/{id}"))
}
fn file_path(id: &str, path: &str) -> Result<String, CoreError> {
    super::validate_path(path)?;
    Ok(format!("{}/files/{path}", generation_path(id)?))
}

async fn read_index(root: &Path) -> Result<(Option<Vec<u8>>, Index), CoreError> {
    let original = transaction::read(root, INDEX).await?;
    let index = original
        .as_deref()
        .map(serde_json::from_slice::<Index>)
        .transpose()
        .map_err(|_| invalid("远端基线索引无效"))?
        .unwrap_or(Index {
            version: 2,
            ..Default::default()
        });
    if index.version != 2 {
        return Err(CoreError::InvalidState(
            "远端基线格式已改变，请重置仓库后重新同步",
        ));
    }
    Ok((original, index))
}

async fn manifest(root: &Path, id: &str, origin: &str) -> Result<Manifest, CoreError> {
    let bytes = transaction::read(root, &format!("{}/manifest.json", generation_path(id)?))
        .await?
        .ok_or_else(|| invalid("远端基线清单丢失"))?;
    let value: Manifest =
        serde_json::from_slice(&bytes).map_err(|_| invalid("远端基线清单无效"))?;
    if value.version != 1 || value.origin != origin {
        return Err(invalid("远端基线清单版本或来源不一致"));
    }
    for (path, entry) in &value.entries {
        super::validate_path(path)?;
        if entry.revision != id {
            return Err(invalid("远端基线清单引用了其他目录"));
        }
    }
    Ok(value)
}

async fn load_snapshot(
    root: &Path,
    id: Option<String>,
    entries: BTreeMap<String, Entry>,
) -> Result<Snapshot, CoreError> {
    let mut result = Snapshot {
        id,
        entries,
        ..Default::default()
    };
    for (path, entry) in &result.entries {
        super::validate_path(path)?;
        let source = file_path(
            result
                .id
                .as_deref()
                .ok_or_else(|| invalid("远端基线缺少目录"))?,
            path,
        )?;
        if result.id.is_some() {
            let metadata_path = format!("{source}.meta.json");
            let metadata = transaction::read(root, &metadata_path)
                .await?
                .ok_or_else(|| invalid("基线文件的同级版本元数据丢失"))?;
            let actual: Entry = serde_json::from_slice(&metadata)
                .map_err(|_| invalid("基线文件的同级版本元数据无效"))?;
            if actual != *entry {
                return Err(invalid("基线文件的 ETag 元数据与清单不一致"));
            }
            result.controls.insert(metadata_path, metadata);
        }
        let bytes = if entry.hash.is_some() || result.id.is_none() {
            transaction::read(root, &source)
                .await?
                .ok_or_else(|| invalid("远端基线正文或删除标记丢失"))?
        } else {
            Vec::new()
        };
        if let Some(hash) = &entry.hash {
            if *hash != LocalFileVersion::from_bytes(&bytes).content_hash {
                return Err(invalid("远端基线正文与版本不一致"));
            }
            if result.id.is_some() && entry.version.size.is_some_and(|v| v != bytes.len() as i64) {
                return Err(invalid("基线文件长度与版本元数据不一致"));
            }
            result.contents.insert(path.clone(), Some(bytes));
            result.paths.insert(path.clone(), source);
        } else {
            if !bytes.is_empty() {
                return Err(invalid("远端删除基线标记必须为空"));
            }
            result.contents.insert(path.clone(), None);
        }
    }
    if let Some(id) = &result.id {
        let path = format!("{}/manifest.json", generation_path(id)?);
        result.controls.insert(
            path.clone(),
            transaction::read(root, &path)
                .await?
                .ok_or_else(|| invalid("远端基线清单丢失"))?,
        );
    }
    Ok(result)
}

impl Store {
    pub async fn load(root: &Path, origin: &str) -> Result<Self, CoreError> {
        let (original, mut index) = read_index(root).await?;
        if original.is_some() && index.origin != origin {
            return Err(CoreError::InvalidState(
                "仓库远端地址或账号已改变，不能继续使用原远端基线",
            ));
        }
        index.origin = origin.into();
        let (remote, ancestor) = if original.is_some() {
            let id = index
                .generation
                .as_ref()
                .ok_or_else(|| invalid("远端基线缺少当前目录"))?;
            let value = manifest(root, id, origin).await?;
            if value.entries != index.entries {
                return Err(invalid("远端基线索引与清单不一致"));
            }
            let remote = load_snapshot(root, Some(id.clone()), value.entries).await?;
            let local = index
                .local
                .as_ref()
                .ok_or_else(|| invalid("远端基线缺少本地合并祖先"))?;
            let ancestor = if Some(local) == remote.id.as_ref() {
                remote.clone()
            } else {
                let value = manifest(root, local, origin).await?;
                load_snapshot(root, Some(local.clone()), value.entries).await?
            };
            (remote, ancestor)
        } else {
            (Snapshot::default(), Snapshot::default())
        };
        Ok(Self {
            index,
            original,
            remote,
            ancestor,
        })
    }

    pub fn sources(&self) -> BTreeMap<String, Option<Vec<u8>>> {
        self.ancestor.contents.clone()
    }
    pub fn state(&self, path: &str) -> Option<&Option<Vec<u8>>> {
        self.ancestor.contents.get(path)
    }
    pub fn remote_state(&self, path: &str) -> Option<&Option<Vec<u8>>> {
        self.remote.contents.get(path)
    }
    pub fn version(&self, path: &str) -> Option<&RemoteFileVersion> {
        self.remote.entries.get(path).map(|e| &e.version)
    }
    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.ancestor
            .contents
            .keys()
            .chain(self.remote.contents.keys())
    }
    pub fn guard(&self, plan: &mut Plan) {
        plan.guards.push((INDEX.into(), self.original.clone()));
        for snapshot in [&self.ancestor, &self.remote] {
            plan.guards.extend(
                snapshot
                    .controls
                    .iter()
                    .map(|(p, b)| (p.clone(), Some(b.clone()))),
            );
            for (path, source) in &snapshot.paths {
                plan.guards
                    .push((source.clone(), snapshot.contents[path].clone()));
            }
        }
    }

    // 调用者持有同步锁；目录未发布前只有本轮能访问，正文只创建、不原地改写。
    async fn build(
        &self,
        root: &Path,
        source: &Snapshot,
        updates: Vec<Update>,
    ) -> Result<Snapshot, CoreError> {
        let mut next = source.clone();
        for update in updates {
            super::validate_path(&update.path)?;
            let hash = update
                .bytes
                .as_deref()
                .map(|v| LocalFileVersion::from_bytes(v).content_hash);
            if next
                .entries
                .get(&update.path)
                .is_some_and(|e| e.hash == hash && e.version == update.version)
            {
                continue;
            }
            next.entries.insert(
                update.path.clone(),
                Entry {
                    revision: String::new(),
                    version: update.version,
                    hash,
                    sync_id: update.sync_id,
                },
            );
            next.contents.insert(update.path, update.bytes);
        }
        if next.entries == source.entries && source.id.is_some() {
            return Ok(source.clone());
        }
        if self.remote.id.is_some()
            && next.entries.len() == self.remote.entries.len()
            && next.entries.iter().all(|(p, e)| {
                self.remote
                    .entries
                    .get(p)
                    .is_some_and(|r| e.hash == r.hash && e.version == r.version)
            })
        {
            return Ok(self.remote.clone());
        }
        let id = crate::model::service::generate_repo_id()?;
        let directory = generation_path(&id)?;
        transaction::ensure_directory(root, GENERATIONS).await?;
        fs::create_dir(root.join(&directory)).await.map_err(io)?;
        let mut parents = BTreeSet::new();
        next.paths.clear();
        next.controls.clear();
        for (path, entry) in &mut next.entries {
            entry.revision = id.clone();
            let destination = file_path(&id, path)?;
            let parent = Path::new(&destination).parent().unwrap().to_str().unwrap();
            transaction::ensure_directory(root, parent).await?;
            let metadata = encode(entry)?;
            let metadata_path = format!("{destination}.meta.json");
            crate::model::write_intent::write_new(&root.join(&metadata_path), &metadata).await?;
            next.controls.insert(metadata_path, metadata);
            parents.insert(parent.to_owned());
            let Some(bytes) = &next.contents[path] else {
                continue;
            };
            let mut linked = false;
            for old in [source, &self.remote, &self.ancestor] {
                if old.contents.get(path).and_then(|v| v.as_deref()) != Some(bytes.as_slice()) {
                    continue;
                }
                if let Some(previous) = old.paths.get(path) {
                    let previous = transaction::target(root, previous).await?;
                    // 文件系统不支持硬链接时退回创建独立副本。
                    linked = fs::hard_link(previous, root.join(&destination))
                        .await
                        .is_ok();
                    if linked {
                        break;
                    }
                }
            }
            if !linked {
                crate::model::write_intent::write_new(&root.join(&destination), bytes).await?;
            }
            parents.insert(parent.to_owned());
            next.paths.insert(path.clone(), destination);
        }
        for parent in parents.iter().rev() {
            transaction::sync_dir(&root.join(parent)).await?;
        }
        let value = Manifest {
            version: 1,
            origin: self.index.origin.clone(),
            entries: next.entries.clone(),
        };
        let manifest_path = format!("{directory}/manifest.json");
        let manifest_bytes = encode(&value)?;
        crate::model::write_intent::write_new(&root.join(&manifest_path), &manifest_bytes).await?;
        next.controls.insert(manifest_path, manifest_bytes);
        transaction::sync_dir(&root.join(&directory)).await?;
        transaction::sync_dir(&root.join(GENERATIONS)).await?;
        next.id = Some(id);
        Ok(next)
    }

    pub async fn prepare_remote(
        &self,
        root: &Path,
        updates: Vec<Update>,
    ) -> Result<Snapshot, CoreError> {
        self.build(root, &self.remote, updates).await
    }

    // 发布远端事实不读取或写入工作文件；旧祖先与新远端在同一原子索引中发布。
    pub async fn publish(&mut self, root: &Path, remote: Snapshot) -> Result<(), CoreError> {
        if transaction::read(root, INDEX).await? != self.original {
            return Err(CoreError::InvalidState("远端基线在发布期间改变"));
        }
        let ancestor = self.build(root, &self.ancestor, Vec::new()).await?;
        let index = Index {
            version: 2,
            origin: self.index.origin.clone(),
            generation: remote.id.clone(),
            local: ancestor.id.clone(),
            entries: remote.entries.clone(),
        };
        let bytes = encode(&index)?;
        if self.original.as_ref() != Some(&bytes) {
            transaction::atomic_write(&transaction::target(root, INDEX).await?, &bytes).await?;
        }
        self.index = index;
        self.original = Some(bytes);
        self.remote = remote;
        self.ancestor = ancestor;
        Ok(())
    }

    // 本地事务只推进已处理路径的合并祖先；被过滤路径保留原祖先。
    pub async fn stage_applied(
        &self,
        root: &Path,
        paths: &[String],
        plan: &mut Plan,
    ) -> Result<(), CoreError> {
        let updates = paths
            .iter()
            .map(|path| Update {
                path: path.clone(),
                bytes: self.remote.contents[path].clone(),
                version: self.remote.entries[path].version.clone(),
                sync_id: self.remote.entries[path].sync_id.clone(),
            })
            .collect();
        let local = self.build(root, &self.ancestor, updates).await?;
        let mut index = self.index.clone();
        index.local = local.id;
        self.guard(plan);
        plan.set(root, INDEX.into(), Some(encode(&index)?)).await
    }

    // 仅在取得同步锁后、构造新目录之前回收；当前远端和本地祖先始终保留。
    pub async fn cleanup(&self, root: &Path) -> Result<(), CoreError> {
        let directory = root.join(GENERATIONS);
        let mut entries = match fs::read_dir(&directory).await {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(io(e)),
        };
        while let Some(entry) = entries.next_entry().await.map_err(io)? {
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| invalid("基线目录名编码无效"))?;
            validate_revision(&name)?;
            if !entry.file_type().await.map_err(io)?.is_dir() {
                return Err(invalid("基线目录类型无效"));
            }
            if self.remote.id.as_ref() != Some(&name) && self.ancestor.id.as_ref() != Some(&name) {
                fs::remove_dir_all(entry.path()).await.map_err(io)?;
            }
        }
        transaction::sync_dir(&directory).await
    }
}

/// 在仓库锁内复用本批 Org 字节；通知只读取索引，不扫描基线正文。
pub(crate) async fn local_changes_from_files(
    root: &Path,
    files: &[crate::OrgFile],
) -> Result<bool, CoreError> {
    let (_, index) = read_index(root).await?;
    let current = files
        .iter()
        .map(|f| {
            (
                f.path.as_str(),
                LocalFileVersion::from_bytes(f.source_bytes()).content_hash,
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut paths = current
        .keys()
        .map(|p| (*p).to_owned())
        .collect::<BTreeSet<_>>();
    paths.extend(index.entries.keys().cloned());
    let mut changed = false;
    for path in paths {
        super::validate_path(&path)?;
        let hash = if path.ends_with(".org") {
            current.get(path.as_str()).cloned()
        } else {
            transaction::read(root, &path)
                .await?
                .as_deref()
                .map(|b| LocalFileVersion::from_bytes(b).content_hash)
        };
        changed |= hash.as_ref() != index.entries.get(&path).and_then(|e| e.hash.as_ref());
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn repository() -> (crate::OrgRepo, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "org-snapshot-{}",
            crate::model::service::generate_repo_id().unwrap()
        ));
        fs::create_dir(&root).await.unwrap();
        let mut repo = crate::OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<crate::webdav::WebDavSyncPolicy>()
            .await
            .unwrap();
        (repo, root)
    }
    fn update(path: &str, text: Option<&str>) -> Update {
        Update {
            path: path.into(),
            bytes: text.map(|v| v.as_bytes().to_vec()),
            version: RemoteFileVersion {
                etag: text.map(|v| format!("\"{v}\"")),
                modified_at: None,
                size: text.map(|v| v.len() as i64),
            },
            sync_id: "fixture".into(),
        }
    }
    async fn apply(store: &Store, root: &Path, paths: &[&str]) {
        let mut plan = Plan::default();
        store
            .stage_applied(
                root,
                &paths.iter().map(|v| (*v).into()).collect::<Vec<_>>(),
                &mut plan,
            )
            .await
            .unwrap();
        plan.commit(root).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unchanged_files_link_only_immutable_snapshots_and_preserve_the_old_ancestor() {
        use std::os::unix::fs::MetadataExt;
        let (_, root) = repository().await;
        let mut store = Store::load(&root, "origin").await.unwrap();
        let first = store
            .prepare_remote(
                &root,
                vec![
                    update("a.org", Some("A")),
                    update("nested/b.org", Some("B")),
                ],
            )
            .await
            .unwrap();
        store.publish(&root, first).await.unwrap();
        apply(&store, &root, &["a.org", "nested/b.org"]).await;
        let mut store = Store::load(&root, "origin").await.unwrap();
        let old_path = root.join(&store.remote.paths["a.org"]);
        fs::write(root.join("a.org"), b"A").await.unwrap();
        let next = store
            .prepare_remote(&root, vec![update("nested/b.org", Some("changed"))])
            .await
            .unwrap();
        assert_eq!(
            fs::metadata(&old_path).await.unwrap().ino(),
            fs::metadata(root.join(&next.paths["a.org"]))
                .await
                .unwrap()
                .ino()
        );
        assert_ne!(
            fs::metadata(root.join("a.org")).await.unwrap().ino(),
            fs::metadata(&old_path).await.unwrap().ino()
        );
        store.publish(&root, next).await.unwrap();
        fs::write(root.join("a.org"), b"edited").await.unwrap();
        let reopened = Store::load(&root, "origin").await.unwrap();
        assert_eq!(
            reopened.remote_state("a.org").unwrap().as_deref(),
            Some(b"A".as_slice())
        );
        assert_eq!(
            reopened.state("nested/b.org").unwrap().as_deref(),
            Some(b"B".as_slice())
        );
        assert_eq!(
            reopened.remote_state("nested/b.org").unwrap().as_deref(),
            Some(b"changed".as_slice())
        );
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn unpublished_generations_are_ignored_and_cleanup_preserves_both_live_references() {
        let (_, root) = repository().await;
        let mut store = Store::load(&root, "origin").await.unwrap();
        let first = store
            .prepare_remote(&root, vec![update("a.org", Some("A"))])
            .await
            .unwrap();
        store.publish(&root, first).await.unwrap();
        let abandoned = store
            .prepare_remote(&root, vec![update("a.org", Some("unpublished"))])
            .await
            .unwrap();
        let id = abandoned.id.unwrap();
        let reopened = Store::load(&root, "origin").await.unwrap();
        assert_eq!(
            reopened.remote_state("a.org").unwrap().as_deref(),
            Some(b"A".as_slice())
        );
        reopened.cleanup(&root).await.unwrap();
        assert!(!root.join(generation_path(&id).unwrap()).exists());
        assert!(
            root.join(generation_path(reopened.remote.id.as_ref().unwrap()).unwrap())
                .exists()
        );
        assert!(
            root.join(generation_path(reopened.ancestor.id.as_ref().unwrap()).unwrap())
                .exists()
        );
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn filtered_paths_keep_their_own_merge_ancestor_and_deletions_differ_from_empty_files() {
        let (_, root) = repository().await;
        let mut store = Store::load(&root, "origin").await.unwrap();
        let first = store
            .prepare_remote(
                &root,
                vec![update("a.org", Some("A")), update("b.org", Some("B"))],
            )
            .await
            .unwrap();
        store.publish(&root, first).await.unwrap();
        apply(&store, &root, &["a.org", "b.org"]).await;
        let mut store = Store::load(&root, "origin").await.unwrap();
        let next = store
            .prepare_remote(
                &root,
                vec![update("a.org", Some("")), update("b.org", None)],
            )
            .await
            .unwrap();
        store.publish(&root, next).await.unwrap();
        apply(&store, &root, &["a.org"]).await;
        let reopened = Store::load(&root, "origin").await.unwrap();
        assert_eq!(
            reopened.state("a.org").unwrap().as_deref(),
            Some(b"".as_slice())
        );
        assert_eq!(
            reopened.state("b.org").unwrap().as_deref(),
            Some(b"B".as_slice())
        );
        assert_eq!(reopened.remote_state("b.org"), Some(&None));
        assert!(reopened.remote_state("unknown.org").is_none());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn etag_only_change_creates_paired_metadata_and_corrupted_sidecars_are_rejected() {
        let (_, root) = repository().await;
        let mut store = Store::load(&root, "origin").await.unwrap();
        let first = store
            .prepare_remote(&root, vec![update("a.org", Some("same"))])
            .await
            .unwrap();
        store.publish(&root, first).await.unwrap();
        let mut changed = update("a.org", Some("same"));
        changed.version.etag = Some("\"new-etag\"".into());
        let next = store.prepare_remote(&root, vec![changed]).await.unwrap();
        store.publish(&root, next).await.unwrap();
        let reopened = Store::load(&root, "origin").await.unwrap();
        assert_eq!(
            reopened.version("a.org").unwrap().etag.as_deref(),
            Some("\"new-etag\"")
        );
        let metadata = root.join(format!("{}.meta.json", reopened.remote.paths["a.org"]));
        let mut entry: Entry = serde_json::from_slice(&fs::read(&metadata).await.unwrap()).unwrap();
        entry.version.etag = Some("\"wrong\"".into());
        fs::write(&metadata, encode(&entry).unwrap()).await.unwrap();
        assert!(Store::load(&root, "origin").await.is_err());
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn obsolete_index_requires_reset_instead_of_implicit_migration() {
        let (mut repo, root) = repository().await;
        transaction::ensure_directory(&root, ".sync/remote_base")
            .await
            .unwrap();
        fs::write(
            root.join(INDEX),
            br#"{"version":1,"origin":"origin","entries":{}}"#,
        )
        .await
        .unwrap();
        assert!(Store::load(&root, "origin").await.is_err());
        repo.reset().await.unwrap();
        assert!(
            Store::load(&root, "origin")
                .await
                .unwrap()
                .remote
                .contents
                .is_empty()
        );
        fs::remove_dir_all(root).await.unwrap();
    }
}
