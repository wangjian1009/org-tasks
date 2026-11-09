//! 最后确认的远端原文缓存；索引和正文只通过仓库事务一起提交。
use super::transaction::{self, Plan};
use crate::{CoreError, LocalFileVersion, RemoteFileVersion};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

const INDEX: &str = ".sync/remote_base/current.json";
#[derive(Clone, Debug, Serialize, Deserialize)]
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
    entries: BTreeMap<String, Entry>,
}
pub(crate) struct Store {
    index: Index,
    original: Option<Vec<u8>>,
    contents: BTreeMap<String, Option<Vec<u8>>>,
    guards: Vec<(String, Option<Vec<u8>>)>,
}
impl Store {
    pub async fn load(root: &Path, origin: &str) -> Result<Self, CoreError> {
        let original = transaction::read(root, INDEX).await?;
        let index = if let Some(bytes) = &original {
            let index: Index = serde_json::from_slice(bytes)
                .map_err(|_| CoreError::Store("远端基线索引无效".into()))?;
            if index.version != 1 {
                return Err(CoreError::InvalidState("不支持的远端基线版本"));
            }
            if index.origin != origin {
                return Err(CoreError::InvalidState(
                    "仓库远端地址或账号已改变，不能继续使用原远端基线",
                ));
            }
            index
        } else {
            Index {
                version: 1,
                origin: origin.into(),
                entries: BTreeMap::new(),
            }
        };
        let mut contents = BTreeMap::new();
        let mut guards = Vec::new();
        for (path, entry) in &index.entries {
            super::validate_path(path)?;
            validate_revision(&entry.revision)?;
            let bytes = transaction::read(root, &entry_path(path, entry)?)
                .await?
                .ok_or(CoreError::InvalidState("远端基线正文或删除标记丢失"))?;
            guards.push((entry_path(path, entry)?, Some(bytes.clone())));
            if let Some(hash) = &entry.hash {
                if *hash != LocalFileVersion::from_bytes(&bytes).content_hash {
                    return Err(CoreError::Store("远端基线正文与版本不一致".into()));
                }
                contents.insert(path.clone(), Some(bytes));
            } else {
                if !bytes.is_empty() {
                    return Err(CoreError::Store("远端删除基线标记必须为空".into()));
                }
                contents.insert(path.clone(), None);
            }
        }
        Ok(Self {
            index,
            original,
            contents,
            guards,
        })
    }
    pub fn sources(&self) -> BTreeMap<String, Option<Vec<u8>>> {
        self.contents.clone()
    }
    pub fn guard(&self, plan: &mut Plan) {
        plan.guards.extend(self.guards.clone());
        plan.guards.push((INDEX.into(), self.original.clone()));
    }
    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.contents.keys()
    }
    pub fn state(&self, path: &str) -> Option<&Option<Vec<u8>>> {
        self.contents.get(path)
    }
    pub fn version(&self, path: &str) -> Option<&RemoteFileVersion> {
        self.index.entries.get(path).map(|e| &e.version)
    }
    pub fn migrate(&mut self, path: String, bytes: Option<Vec<u8>>, version: RemoteFileVersion) {
        if !self.contents.contains_key(&path) {
            self.contents.insert(path.clone(), bytes);
            // 仅在本轮正式成功时写入迁移材料。
            self.index.entries.insert(
                path,
                Entry {
                    revision: "migration".into(),
                    version,
                    hash: None,
                    sync_id: String::new(),
                },
            );
        }
    }
    pub async fn stage(
        &mut self,
        root: &Path,
        path: &str,
        bytes: Option<Vec<u8>>,
        version: RemoteFileVersion,
        sync_id: &str,
        plan: &mut Plan,
    ) -> Result<(), CoreError> {
        let hash = bytes
            .as_deref()
            .map(|b| LocalFileVersion::from_bytes(b).content_hash);
        let reuse = self
            .index
            .entries
            .get(path)
            .is_some_and(|old| old.hash == hash && old.revision != "migration");
        let revision = if reuse {
            self.index.entries[path].revision.clone()
        } else {
            crate::model::service::generate_repo_id()?
        };
        let entry = Entry {
            revision,
            version,
            hash,
            sync_id: sync_id.into(),
        };
        if !reuse {
            plan.set(
                root,
                entry_path(path, &entry)?,
                Some(bytes.clone().unwrap_or_default()),
            )
            .await?;
        }
        self.index.entries.insert(path.into(), entry);
        self.contents.insert(path.into(), bytes);
        Ok(())
    }
    pub async fn finish(&self, root: &Path, plan: &mut Plan) -> Result<(), CoreError> {
        // 未处理／被过滤的迁移条目不提前变成正式基线。
        let mut index = self.index.clone();
        index.entries.retain(|_, e| e.revision != "migration");
        self.guard(plan);
        plan.set(
            root,
            INDEX.into(),
            Some(
                serde_json::to_vec(&index)
                    .map_err(|_| CoreError::InvalidState("无法编码远端基线"))?,
            ),
        )
        .await
    }
}
fn validate_revision(value: &str) -> Result<(), CoreError> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Err(CoreError::Store("远端基线版本号无效".into()));
    }
    Ok(())
}
fn entry_path(path: &str, entry: &Entry) -> Result<String, CoreError> {
    let name = Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or(CoreError::InvalidInput("远端基线文件名无效"))?;
    let name = if entry.hash.is_some() {
        name.into()
    } else {
        format!("{}.removed", name.strip_suffix(".org").unwrap_or(name))
    };
    Ok(format!(
        ".sync/remote_base/files/{path}/{}/{name}",
        entry.revision
    ))
}
