//! 真实仓库操作的统一入口；调用方持有锁期间按需读盘。
use std::path::Path;

use crate::{
    CoreError,
    webdav::{session, transaction},
};

pub(crate) async fn enter(root: &Path, expected_id: &str) -> Result<transaction::Guard, CoreError> {
    let guard = transaction::lock(root).await?;
    recover(root, expected_id).await?;
    Ok(guard)
}

/// 跨仓库操作按固定顺序取得锁后复用检查，避免再次获取同一把锁。
pub(crate) async fn recover(root: &Path, expected_id: &str) -> Result<(), CoreError> {
    let id = super::service::read_repo_id(&root.join(".sync/id"))
        .await
        .map_err(|error| CoreError::Store(format!("无法校验仓库身份: {error}")))?;
    if expected_id.is_empty() || id != expected_id {
        return Err(CoreError::InvalidState("仓库身份已改变，请重新打开"));
    }
    session::recover(root).await
}
