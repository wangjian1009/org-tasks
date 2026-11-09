//! 同步提交后的回调端口；通知模块订阅它，不依赖 UI 或宿主运行时。
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SyncCommitted {
    pub root_directory: String,
    pub repo_id: String,
}
type Callback = Arc<dyn Fn(&SyncCommitted) + Send + Sync>;
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
    let callbacks = observers()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .values()
        .cloned()
        .collect::<Vec<_>>();
    let event = SyncCommitted {
        root_directory: repo.root_directory.clone(),
        repo_id: repo.id.clone(),
    };
    for callback in callbacks {
        callback(&event);
    }
}
