//! HarmonyOS 宿主的 core bridge。
//!
//! C++ N-API bridge 在工作线程调用本 crate。目录扫描、WebDAV 与仓库同步均由
//! core 执行；ArkTS 只持有 bridge 暴露的对象并渲染结构化数据。

mod bridge;

use std::ffi::{CStr, CString, c_char};

use org_tasks_core::CoreError;

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_free_string(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_create() -> u64 {
    bridge::create_workspace().unwrap_or_default()
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_retain(handle: u64) -> bool {
    bridge::retain_workspace(handle).is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_release(handle: u64) {
    bridge::release_workspace(handle);
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_repo_ids(handle: u64) -> *mut c_char {
    string_result(bridge::workspace_repo_ids(handle).map(|ids| ids.join("\n")))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_load(handle: u64) -> i32 {
    match bridge::workspace_load(handle) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_add_repo(
    handle: u64,
    root_directory: *const c_char,
) -> i32 {
    match read_c_string(root_directory)
        .and_then(|root_directory| bridge::workspace_add_repo(handle, root_directory))
    {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_search(
    handle: u64,
    expression: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(expression).and_then(|value| bridge::workspace_search_json(handle, value)),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_webdav_sync_policy_create(
    webdav_url: *const c_char,
    username: *const c_char,
    password: *const c_char,
) -> u64 {
    (|| {
        bridge::create_webdav_sync_policy(
            read_c_string(webdav_url)?,
            read_c_string(username)?,
            read_c_string(password)?,
        )
    })()
    .unwrap_or_default()
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_webdav_sync_policy_retain(handle: u64) -> bool {
    bridge::retain_webdav_sync_policy(handle).is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_webdav_sync_policy_release(handle: u64) {
    bridge::release_webdav_sync_policy(handle);
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_sync(
    workspace_handle: u64,
    repo_id: *const c_char,
    policy_handle: u64,
    started_at: i64,
) -> *mut c_char {
    string_result(read_c_string(repo_id).and_then(|repo_id| {
        bridge::repo_sync_json(workspace_handle, repo_id, policy_handle, started_at)
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_snapshot(
    workspace_handle: u64,
    repo_id: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(repo_id)
            .and_then(|value| bridge::repo_snapshot_json(workspace_handle, value)),
    )
}

fn string_result(result: Result<String, CoreError>) -> *mut c_char {
    result
        .and_then(|value| {
            CString::new(value)
                .map(CString::into_raw)
                .map_err(|_| CoreError::InvalidState("Harmony bridge 响应包含空字符"))
        })
        .unwrap_or(std::ptr::null_mut())
}

fn read_c_string(value: *const c_char) -> Result<String, CoreError> {
    if value.is_null() {
        return Err(CoreError::InvalidInput("Harmony 字符串参数不能为空"));
    }
    let value = unsafe { CStr::from_ptr(value) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|_| CoreError::InvalidInput("Harmony 字符串必须是 UTF-8"))
}
