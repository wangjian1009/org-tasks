//! 同步提交后的回调端口；通知模块订阅它，不依赖 UI 或宿主运行时。
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SyncCommitted {
    Repository {
        root_directory: String,
        repo_id: String,
        operation_id: Option<String>,
        files: Option<Vec<super::FileDataChange>>,
        changes: Vec<super::TaskDataChange>,
    },
}
type Callback = Arc<dyn Fn(&SyncCommitted) + Send + Sync>;

// 基线可能先于工作文件发布；错误返回同样需要使调用方的通知快照失效。
pub(crate) struct CompletionNotice(super::OrgRepo);
impl CompletionNotice {
    pub(crate) fn new(repo: &super::OrgRepo) -> Self {
        Self(repo.clone())
    }
}
impl Drop for CompletionNotice {
    fn drop(&mut self) {
        publish(&self.0);
    }
}
static OBSERVERS: OnceLock<Mutex<BTreeMap<u64, Callback>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn observers() -> &'static Mutex<BTreeMap<u64, Callback>> {
    OBSERVERS.get_or_init(Default::default)
}

pub(crate) struct SyncSubscription(u64);
impl Drop for SyncSubscription {
    fn drop(&mut self) {
        if let Ok(mut callbacks) = observers().lock() {
            callbacks.remove(&self.0);
        }
    }
}
pub(crate) fn subscribe(callback: Callback) -> SyncSubscription {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    observers()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, callback);
    SyncSubscription(id)
}
pub(crate) fn publish(repo: &super::OrgRepo) {
    publish_operation(repo, None);
}
pub(crate) fn publish_operation(repo: &super::OrgRepo, operation_id: Option<&str>) {
    publish_changes(repo, operation_id, None, Vec::new());
}
pub(crate) fn publish_changes(
    repo: &super::OrgRepo,
    operation_id: Option<&str>,
    files: Option<Vec<super::FileDataChange>>,
    changes: Vec<super::TaskDataChange>,
) {
    publish_event(SyncCommitted::Repository {
        root_directory: repo.root_directory.clone(),
        repo_id: repo.id.clone(),
        operation_id: operation_id.map(str::to_owned),
        files,
        changes,
    });
}
fn publish_event(event: SyncCommitted) {
    let callbacks = observers()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .values()
        .cloned()
        .collect::<Vec<_>>();
    for callback in callbacks {
        callback(&event);
    }
}
