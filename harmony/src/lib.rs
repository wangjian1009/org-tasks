//! HarmonyOS 宿主的 core bridge。
//!
//! C++ N-API bridge 在工作线程调用本 crate。目录扫描、WebDAV 与仓库同步均由
//! core 执行；ArkTS 只持有 bridge 暴露的对象并渲染结构化数据。

mod bridge;

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};

use org_tasks_core::CoreError;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn clear_last_error() {
    LAST_ERROR.with(|value| *value.borrow_mut() = None);
}

fn remember_error(error: &CoreError) {
    let code = match error {
        CoreError::InvalidInput(_) => "invalidInput",
        CoreError::InvalidState(_) => "invalidState",
        CoreError::Store(_) => "store",
        CoreError::Preview { code, .. } => code,
    };
    let value = serde_json::json!({
        "code": code,
        "message": error.to_string(),
    })
    .to_string();
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(value));
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow()
            .as_deref()
            .and_then(|value| CString::new(value).ok())
            .map(CString::into_raw)
            .unwrap_or(std::ptr::null_mut())
    })
}

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
    clear_last_error();
    match bridge::create_workspace() {
        Ok(handle) => handle,
        Err(error) => {
            remember_error(&error);
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_retain(handle: u64) -> bool {
    clear_last_error();
    match bridge::retain_workspace(handle) {
        Ok(()) => true,
        Err(error) => {
            remember_error(&error);
            false
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_release(handle: u64) {
    bridge::release_workspace(handle);
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_repo_roots(handle: u64) -> *mut c_char {
    string_result(bridge::workspace_repo_roots(handle).map(|roots| roots.join("\n")))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_notifications(handle: u64) -> *mut c_char {
    string_result(bridge::workspace_notifications_json(handle))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_remove_repo(
    handle: u64,
    root_directory: *const c_char,
) -> i32 {
    clear_last_error();
    match read_c_string(root_directory)
        .and_then(|root_directory| bridge::workspace_remove_repo(handle, root_directory))
    {
        Ok(()) => 0,
        Err(error) => {
            remember_error(&error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_add_repo(
    handle: u64,
    root_directory: *const c_char,
) -> i32 {
    clear_last_error();
    match read_c_string(root_directory)
        .and_then(|root_directory| bridge::workspace_add_repo(handle, root_directory))
    {
        Ok(()) => 0,
        Err(error) => {
            remember_error(&error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_load(
    workspace_handle: u64,
    root_directory: *const c_char,
) -> i32 {
    clear_last_error();
    match read_c_string(root_directory)
        .and_then(|root_directory| bridge::repo_load(workspace_handle, root_directory))
    {
        Ok(()) => 0,
        Err(error) => {
            remember_error(&error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_reset(
    workspace_handle: u64,
    root_directory: *const c_char,
) -> i32 {
    clear_last_error();
    match read_c_string(root_directory)
        .and_then(|root_directory| bridge::repo_reset(workspace_handle, root_directory))
    {
        Ok(()) => 0,
        Err(error) => {
            remember_error(&error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_history(
    workspace_handle: u64,
    root_directory: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(root_directory)
            .and_then(|root| bridge::repo_history_json(workspace_handle, root)),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_history_detail(
    workspace_handle: u64,
    root_directory: *const c_char,
    sync_id: *const c_char,
) -> *mut c_char {
    string_result(read_c_string(root_directory).and_then(|root| {
        bridge::repo_history_detail_json(workspace_handle, root, read_c_string(sync_id)?)
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_id(
    workspace_handle: u64,
    root_directory: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(root_directory)
            .and_then(|root_directory| bridge::repo_id(workspace_handle, root_directory)),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_query(
    handle: u64,
    query_json: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(query_json).and_then(|query| bridge::workspace_query_json(handle, query)),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_webdav_test_connection(
    webdav_url: *const c_char,
    username: *const c_char,
    password: *const c_char,
) -> i32 {
    clear_last_error();
    let result = read_c_string(webdav_url).and_then(|url| {
        bridge::test_webdav_connection(url, read_c_string(username)?, read_c_string(password)?)
    });
    match result {
        Ok(()) => 0,
        Err(error) => {
            remember_error(&error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_sync(
    workspace_handle: u64,
    root_directory: *const c_char,
    webdav_url: *const c_char,
    username: *const c_char,
    password: *const c_char,
    options_json: *const c_char,
    monitor_handle: u64,
    started_at: i64,
) -> *mut c_char {
    string_result(read_c_string(root_directory).and_then(|root_directory| {
        bridge::repo_sync_json(
            workspace_handle,
            root_directory,
            read_c_string(webdav_url)?,
            read_c_string(username)?,
            read_c_string(password)?,
            read_c_string(options_json)?,
            monitor_handle,
            started_at,
        )
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_snapshot(
    workspace_handle: u64,
    root_directory: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(root_directory)
            .and_then(|value| bridge::repo_snapshot_json(workspace_handle, value)),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_load_files(
    workspace_handle: u64,
    root_directory: *const c_char,
    ignore_files_json: *const c_char,
) -> *mut c_char {
    string_result((|| {
        bridge::repo_load_files_json(workspace_handle, read_c_string(root_directory)?, read_c_string(ignore_files_json)?)
    })())
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_file_metadata(
    workspace_handle: u64,
    root_directory: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(root_directory)
            .and_then(|root| bridge::repo_file_metadata_json(workspace_handle, root)),
    )
}

fn string_result(result: Result<String, CoreError>) -> *mut c_char {
    clear_last_error();
    match result.and_then(|value| {
        CString::new(value)
            .map(CString::into_raw)
            .map_err(|_| CoreError::InvalidState("Harmony bridge 响应包含空字符"))
    }) {
        Ok(value) => value,
        Err(error) => {
            remember_error(&error);
            std::ptr::null_mut()
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_notifications_uses_existing_string_lifetime_and_error_contract() {
        let handle = org_tasks_harmony_workspace_create();
        let value = org_tasks_harmony_workspace_notifications(handle);
        assert!(!value.is_null());
        assert_eq!(unsafe { CStr::from_ptr(value) }.to_str().unwrap(), "[]");
        org_tasks_harmony_free_string(value);
        org_tasks_harmony_workspace_release(handle);
        assert!(org_tasks_harmony_workspace_notifications(u64::MAX).is_null());
        let error = org_tasks_harmony_last_error();
        let json: serde_json::Value =
            serde_json::from_str(unsafe { CStr::from_ptr(error) }.to_str().unwrap()).unwrap();
        assert_eq!(json["code"], "invalidInput");
        org_tasks_harmony_free_string(error);
    }

    #[test]
    fn ffi_error_retains_core_category_and_message() {
        let value = string_result(Err(CoreError::Store("仓库根目录不存在或不是目录".into())));
        assert!(value.is_null());

        let error = org_tasks_harmony_last_error();
        let error = unsafe { CStr::from_ptr(error) }.to_str().unwrap();
        let error: serde_json::Value = serde_json::from_str(error).unwrap();
        assert_eq!(error["code"], "store");
        assert!(
            error["message"]
                .as_str()
                .unwrap()
                .contains("仓库根目录不存在或不是目录")
        );
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_conflicts(
    handle: u64,
    root_directory: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(root_directory).and_then(|root| bridge::repo_conflicts_json(handle, root)),
    )
}


#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_set_todo_defaults(
    handle: u64,
    settings: *const c_char,
) -> i32 {
    clear_last_error();
    match read_c_string(settings)
        .and_then(|settings| bridge::workspace_set_todo_defaults(handle, settings))
    {
        Ok(()) => 0,
        Err(error) => {
            remember_error(&error);
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_file(
    handle: u64,
    root_directory: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    string_result(
        read_c_string(root_directory)
            .and_then(|root| bridge::repo_file_json(handle, root, read_c_string(path)?)),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_default_todo_settings() -> *mut c_char {
    string_result(
        serde_json::to_string(&org_tasks_core::TodoConfig::default().to_settings())
            .map_err(|_| CoreError::InvalidState("无法编码默认 TODO 设置")),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_default_sync_options() -> *mut c_char {
    string_result(
        serde_json::to_string(&org_tasks_core::default_sync_options())
            .map_err(|_| CoreError::InvalidState("无法编码默认同步参数")),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_normalize_sync_options(
    options_json: *const c_char,
) -> *mut c_char {
    string_result(read_c_string(options_json).and_then(|json| {
        let options: org_tasks_core::SyncOptions =
            serde_json::from_str(&json).map_err(|_| CoreError::InvalidInput("同步参数无效"))?;
        serde_json::to_string(&options.normalized()?)
            .map_err(|_| CoreError::InvalidState("无法编码同步参数"))
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_refile_targets(handle: u64, query_json: *const c_char) -> *mut c_char {
    string_result(read_c_string(query_json).and_then(|query| bridge::workspace_refile_targets_json(handle, query)))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_execute_task_operations(handle:u64,request:*const c_char)->*mut c_char{
    string_result(read_c_string(request).and_then(|request|bridge::workspace_execute_task_operations(handle,request)))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_task_merge_operations(handle: u64, request: *const c_char) -> *mut c_char {
    string_result(read_c_string(request).and_then(|request| bridge::workspace_task_merge_operations(handle, request)))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_full_path(handle:u64,root:*const c_char)->*mut c_char{
    string_result(read_c_string(root).and_then(|root|bridge::repo_full_path_json(handle,root)))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_repo_history_operation(handle: u64, root: *const c_char, request: *const c_char) -> *mut c_char {
    string_result(read_c_string(root).and_then(|root| bridge::repo_history_operation(handle, root, read_c_string(request)?)))
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_watch_notifications(handle:u64, monitor:u64)->u64 {
    clear_last_error();
    match bridge::workspace_watch_notifications(handle,monitor) {Ok(id)=>id,Err(e)=>{remember_error(&e);0}}
}
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_unwatch_notifications(id:u64) {bridge::workspace_unwatch_notifications(id);}
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_watch_data_changes(handle:u64, monitor:u64)->u64 {
    clear_last_error();
    match bridge::workspace_watch_data_changes(handle,monitor) {Ok(id)=>id,Err(e)=>{remember_error(&e);0}}
}
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_unwatch_data_changes(id:u64) {bridge::workspace_unwatch_data_changes(id);}
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_workspace_reload(handle:u64)->i32 {
    clear_last_error();
    match bridge::workspace_reload(handle) {Ok(())=>0,Err(e)=>{remember_error(&e);-1}}
}

#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_preview_operation(handle:u64, request:*const c_char)->*mut c_char {
    string_result(read_c_string(request).and_then(|request|bridge::workspace_preview_operation(handle,request)))
}
#[unsafe(no_mangle)]
pub extern "C" fn org_tasks_harmony_preview_release(handle:u64,id:*const c_char) {
    if let Ok(id)=read_c_string(id) {bridge::release_preview(handle,&id);}
}
