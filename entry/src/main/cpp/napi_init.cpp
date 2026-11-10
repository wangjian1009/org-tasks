#include <cstdint>
#include <cstring>
#include <chrono>
#include <string>
#include <vector>

#include "napi/native_api.h"

extern "C" void org_tasks_harmony_free_string(char* value);
extern "C" char* org_tasks_harmony_last_error();
extern "C" uint64_t org_tasks_harmony_workspace_create();
extern "C" char* org_tasks_harmony_default_todo_settings();
extern "C" char* org_tasks_harmony_default_sync_options();
extern "C" char* org_tasks_harmony_normalize_sync_options(const char* options_json);
extern "C" int32_t org_tasks_harmony_workspace_set_todo_defaults(uint64_t handle, const char* settings);
extern "C" char* org_tasks_harmony_repo_file(uint64_t handle, const char* root, const char* path);
extern "C" bool org_tasks_harmony_workspace_retain(uint64_t handle);
extern "C" void org_tasks_harmony_workspace_release(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_repo_roots(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_notifications(uint64_t handle);
extern "C" uint64_t org_tasks_harmony_workspace_watch_notifications(uint64_t handle, uint64_t monitor);
extern "C" void org_tasks_harmony_workspace_unwatch_notifications(uint64_t subscription);
extern "C" int32_t org_tasks_harmony_workspace_reload(uint64_t handle);
extern "C" void org_tasks_harmony_notification_monitor_release(uint64_t monitor);
extern "C" int32_t org_tasks_harmony_workspace_remove_repo(uint64_t handle, const char* root_directory);
extern "C" int32_t org_tasks_harmony_workspace_add_repo(uint64_t handle, const char* root_directory);
extern "C" int32_t org_tasks_harmony_repo_load(uint64_t workspace_handle, const char* root_directory);
extern "C" int32_t org_tasks_harmony_repo_reset(uint64_t workspace_handle, const char* root_directory);
extern "C" char* org_tasks_harmony_repo_history(uint64_t workspace_handle, const char* root_directory);
extern "C" char* org_tasks_harmony_repo_history_operation(uint64_t handle, const char* root, const char* request);
extern "C" char* org_tasks_harmony_repo_history_detail(uint64_t workspace_handle, const char* root_directory, const char* sync_id);
extern "C" char* org_tasks_harmony_repo_full_path(uint64_t handle, const char* root);
extern "C" char* org_tasks_harmony_repo_id(uint64_t workspace_handle, const char* root_directory);
extern "C" char* org_tasks_harmony_workspace_query(uint64_t handle, const char* query_json);
extern "C" char* org_tasks_harmony_workspace_refile_targets(uint64_t handle, const char* query_json);
extern "C" char* org_tasks_harmony_workspace_execute_task_operations(uint64_t handle, const char* request);
extern "C" char* org_tasks_harmony_repo_sync(uint64_t workspace_handle, const char* repo_id,
    const char* webdav_url, const char* username, const char* password, const char* options_json, uint64_t monitor_handle,
    int64_t started_at);
extern "C" char* org_tasks_harmony_repo_snapshot(uint64_t workspace_handle, const char* repo_id);
extern "C" char* org_tasks_harmony_repo_file_metadata(uint64_t workspace_handle, const char* root_directory);
extern "C" int32_t org_tasks_harmony_webdav_test_connection(
    const char* webdav_url, const char* username, const char* password);
extern "C" char* org_tasks_harmony_repo_conflicts(uint64_t handle, const char* root_directory);


namespace {
struct WorkspaceWrap {
    uint64_t handle = 0;
    uint64_t notification_subscription = 0;
    uint64_t notification_generation = 0;
};

struct RepoWrap {
    uint64_t workspace_handle = 0;
    std::string root_directory;
};

struct OrgFileWrap {
    napi_ref data = nullptr;
    std::string source;
};

struct TaskWrap {
    napi_ref data = nullptr;
    bool is_done = false;
};

struct WebDavSyncPolicyWrap {
    std::string webdav_url;
    std::string username;
    std::string password;
};

struct WebDavConnectionWork {
    std::string webdav_url;
    std::string username;
    std::string password;
    std::string error;
    int32_t result = -1;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceStringWork {
    bool notifications = false;
    bool watch_notifications = false;
    bool reload = false;
    uint64_t monitor_handle = 0;
    uint64_t subscription_id = 0;
    uint64_t subscription_generation = 0;
    ~WorkspaceStringWork() { if (monitor_handle != 0) org_tasks_harmony_notification_monitor_release(monitor_handle); }
    bool refile_targets = false;
    bool execute_operations = false;
    bool todo_defaults = false;
    bool default_todo_settings = false;
    bool default_sync_options = false;
    bool normalize_sync_options = false;
    napi_ref owner = nullptr;
    uint64_t handle = 0;
    std::string expression;
    std::string response;
    std::string error;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceAddRepoWork {
    uint64_t handle = 0;
    std::string root_directory;
    int32_t result = -1;
    std::string error;
    enum class Operation { Add, Remove } operation = Operation::Add;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceReposWork {
    uint64_t handle = 0;
    std::vector<std::string> roots;
    std::string error;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct RepoSnapshotWork {
    uint64_t workspace_handle = 0;
    std::string root_directory;
    std::string webdav_url;
    std::string username;
    std::string password;
    std::string sync_options_json;
    napi_threadsafe_function monitor = nullptr;
    std::string response;
    std::string error;
    std::string task_path;
    std::string task_json;
    napi_ref owner = nullptr;
    napi_ref related_owner = nullptr;
    enum class Operation { Snapshot, Sync, Load, Reset, History, HistoryDetail, Conflicts, File, FileMetadata, HistoryFile, LastEffectSync } operation = Operation::Snapshot;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

napi_ref repo_constructor = nullptr;
napi_ref file_constructor = nullptr;
napi_ref task_constructor = nullptr;

bool ReadString(napi_env env, napi_value value, std::string* result)
{
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    result->resize(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &(*result)[0], result->size(), &copied) != napi_ok) {
        return false;
    }
    result->resize(copied);
    return true;
}

bool ReadHandle(napi_env env, napi_value value, uint64_t* handle)
{
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || number <= 0) {
        return false;
    }
    *handle = static_cast<uint64_t>(number);
    return true;
}

void FinalizeWorkspace(napi_env, void* data, void*)
{
    auto* workspace = static_cast<WorkspaceWrap*>(data);
    org_tasks_harmony_workspace_unwatch_notifications(workspace->notification_subscription);
    if (workspace->handle != 0) {
        org_tasks_harmony_workspace_release(workspace->handle);
    }
    delete workspace;
}

void FinalizeRepo(napi_env, void* data, void*)
{
    auto* repo = static_cast<RepoWrap*>(data);
    if (repo->workspace_handle != 0) {
        org_tasks_harmony_workspace_release(repo->workspace_handle);
    }
    delete repo;
}

void FinalizeWebDavSyncPolicy(napi_env, void* data, void*)
{
    auto* policy = static_cast<WebDavSyncPolicyWrap*>(data);
    delete policy;
}

napi_value CreateRepoObject(napi_env env, uint64_t workspace_handle, const std::string& root_directory)
{
    napi_value constructor;
    if (napi_get_reference_value(env, repo_constructor, &constructor) != napi_ok) {
        return nullptr;
    }
    napi_value arguments[2];
    napi_create_double(env, static_cast<double>(workspace_handle), &arguments[0]);
    napi_create_string_utf8(env, root_directory.c_str(), root_directory.size(), &arguments[1]);
    napi_value object;
    if (napi_new_instance(env, constructor, 2, arguments, &object) != napi_ok) {
        return nullptr;
    }
    return object;
}

std::string TakeRustString(char* value)
{
    if (value == nullptr) {
        return {};
    }
    std::string result(value);
    org_tasks_harmony_free_string(value);
    return result;
}

std::string TakeRustError()
{
    return TakeRustString(org_tasks_harmony_last_error());
}

bool ParseJson(napi_env env, const std::string& source, napi_value* result)
{
    napi_value input;
    napi_value global;
    napi_value json;
    napi_value parse;
    return napi_create_string_utf8(env, source.c_str(), source.size(), &input) == napi_ok &&
        napi_get_global(env, &global) == napi_ok &&
        napi_get_named_property(env, global, "JSON", &json) == napi_ok &&
        napi_get_named_property(env, json, "parse", &parse) == napi_ok &&
        napi_call_function(env, json, parse, 1, &input, result) == napi_ok;
}

bool EncodeJson(napi_env env, napi_value value, std::string* result)
{
    napi_value global, json, stringify, encoded;
    return napi_get_global(env, &global) == napi_ok &&
        napi_get_named_property(env, global, "JSON", &json) == napi_ok &&
        napi_get_named_property(env, json, "stringify", &stringify) == napi_ok &&
        napi_call_function(env, json, stringify, 1, &value, &encoded) == napi_ok &&
        ReadString(env, encoded, result);
}

void FinalizeOrgFile(napi_env env, void* data, void*)
{
    auto* file = static_cast<OrgFileWrap*>(data);
    if (file->data != nullptr) napi_delete_reference(env, file->data);
    delete file;
}

napi_value OrgFileConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self, source;
    auto* file = new OrgFileWrap();
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_get_named_property(env, args[0], "source", &source) != napi_ok ||
        !ReadString(env, source, &file->source) ||
        napi_create_reference(env, args[0], 1, &file->data) != napi_ok ||
        napi_wrap(env, self, file, FinalizeOrgFile, nullptr, nullptr) != napi_ok) {
        if (file->data != nullptr) napi_delete_reference(env, file->data);
        delete file;
        napi_throw_error(env, nullptr, "无法创建 OrgFile 对象");
        return nullptr;
    }
    return self;
}

napi_value OrgFileProperty(napi_env env, napi_callback_info info)
{
    napi_value self, data, value;
    void* property = nullptr;
    OrgFileWrap* file = nullptr;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, &property) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&file)) != napi_ok || file == nullptr ||
        napi_get_reference_value(env, file->data, &data) != napi_ok ||
        napi_get_named_property(env, data, static_cast<const char*>(property), &value) != napi_ok) {
        napi_throw_error(env, nullptr, "无法读取 OrgFile 属性");
        return nullptr;
    }
    return value;
}

napi_value OrgFileSourceBytes(napi_env env, napi_callback_info info)
{
    napi_value self, buffer, result;
    OrgFileWrap* file = nullptr;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&file)) != napi_ok || file == nullptr) {
        napi_throw_error(env, nullptr, "OrgFile.sourceBytes 对象无效");
        return nullptr;
    }
    void* bytes = nullptr;
    if (napi_create_arraybuffer(env, file->source.size(), &bytes, &buffer) != napi_ok) return nullptr;
    if (!file->source.empty()) std::memcpy(bytes, file->source.data(), file->source.size());
    if (napi_create_typedarray(env, napi_uint8_array, file->source.size(), buffer, 0, &result) != napi_ok) return nullptr;
    return result;
}

napi_value CreateOrgFileObject(napi_env env, napi_value data)
{
    napi_value constructor, result;
    if (napi_get_reference_value(env, file_constructor, &constructor) != napi_ok ||
        napi_new_instance(env, constructor, 1, &data, &result) != napi_ok) return nullptr;
    return result;
}

void FinalizeTask(napi_env env, void* data, void*)
{
    auto* task = static_cast<TaskWrap*>(data);
    if (task->data != nullptr) napi_delete_reference(env, task->data);
    delete task;
}

napi_value TaskConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self, done;
    auto* task = new TaskWrap();
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_get_named_property(env, args[0], "isDone", &done) != napi_ok ||
        napi_get_value_bool(env, done, &task->is_done) != napi_ok ||
        napi_create_reference(env, args[0], 1, &task->data) != napi_ok ||
        napi_wrap(env, self, task, FinalizeTask, nullptr, nullptr) != napi_ok) {
        if (task->data != nullptr) napi_delete_reference(env, task->data);
        delete task;
        napi_throw_error(env, nullptr, "无法创建 Task 对象");
        return nullptr;
    }
    return self;
}

napi_value TaskIsDone(napi_env env, napi_callback_info info)
{
    napi_value self, result;
    TaskWrap* task = nullptr;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&task)) != napi_ok || task == nullptr) {
        napi_throw_error(env, nullptr, "Task.isDone 对象无效");
        return nullptr;
    }
    napi_get_boolean(env, task->is_done, &result);
    return result;
}

napi_value CreateTaskObject(napi_env env, napi_value data)
{
    napi_value constructor, result;
    if (napi_get_reference_value(env, task_constructor, &constructor) != napi_ok ||
        napi_new_instance(env, constructor, 1, &data, &result) != napi_ok) return nullptr;
    // id 为 Core 的明文逻辑路径；headingParts 含链接与可空 count，嵌套结构原样透传，不在 bridge 解析标题。
    for (const char* name : {"id", "taskId", "fullPath", "fileVersion", "repoId", "heading", "category", "headingParts", "todoState", "todoKind", "isCancelled", "createdAt", "modifiedAt", "priority", "scheduled",
        "deadline", "tags", "ownTags", "inheritedTags", "supportTags", "editContent", "filePath", "fileName", "level", "body", "bodyFirstLine", "addressLinks", "bodyHtml", "logbookHtml", "progress", "hasList", "hasText", "isRepeating"}) {
        napi_value value;
        if (napi_get_named_property(env, data, name, &value) != napi_ok) return nullptr;
        napi_property_descriptor property = {name, nullptr, nullptr, nullptr, nullptr, value, napi_enumerable, nullptr};
        if (napi_define_properties(env, result, 1, &property) != napi_ok) return nullptr;
    }
    return result;
}

void RejectFileProjection(napi_env env, napi_deferred deferred)
{
    bool pending = false;
    napi_value error;
    if (napi_is_exception_pending(env, &pending) == napi_ok && pending &&
        napi_get_and_clear_last_exception(env, &error) == napi_ok) {
        napi_reject_deferred(env, deferred, error);
    } else {
        napi_value message;
        napi_create_string_utf8(env, "无法创建文件对象", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, deferred, error);
    }
}

void RejectCoreError(napi_env env, napi_deferred deferred, const std::string& source, const char* fallback)
{
    std::string message = fallback;
    std::string code = "bridge";
    napi_value payload;
    if (!source.empty() && ParseJson(env, source, &payload)) {
        napi_value value;
        if (napi_get_named_property(env, payload, "message", &value) == napi_ok) {
            ReadString(env, value, &message);
        }
        if (napi_get_named_property(env, payload, "code", &value) == napi_ok) {
            ReadString(env, value, &code);
        }
    }
    napi_value text;
    napi_create_string_utf8(env, message.c_str(), message.size(), &text);
    napi_value error;
    napi_create_error(env, nullptr, text, &error);
    napi_value code_value;
    napi_create_string_utf8(env, code.c_str(), code.size(), &code_value);
    napi_set_named_property(env, error, "code", code_value);
    napi_reject_deferred(env, deferred, error);
}

void CallWebDavSyncMonitor(napi_env env, napi_value callback, void*, void* data)
{
    auto* source = static_cast<std::string*>(data);
    if (env != nullptr && callback != nullptr) {
        napi_value event;
        if (ParseJson(env, *source, &event)) {
            napi_value receiver;
            napi_get_undefined(env, &receiver);
            napi_value ignored;
            napi_call_function(env, receiver, callback, 1, &event, &ignored);
        }
    }
    delete source;
}

extern "C" void org_tasks_harmony_webdav_sync_monitor_event(uint64_t monitor_handle,
    const char* event_json)
{
    auto* work = reinterpret_cast<RepoSnapshotWork*>(static_cast<uintptr_t>(monitor_handle));
    if (work == nullptr || work->monitor == nullptr || event_json == nullptr) return;
    auto* event = new std::string(event_json);
    if (napi_call_threadsafe_function(work->monitor, event, napi_tsfn_nonblocking) != napi_ok) {
        delete event;
    }
}

struct NotificationWatch { napi_threadsafe_function function = nullptr; };
void FinalizeNotificationWatch(napi_env, void* data, void*) { delete static_cast<NotificationWatch*>(data); }
extern "C" void org_tasks_harmony_notification_update(uint64_t handle, const char* json)
{
    auto* watch = reinterpret_cast<NotificationWatch*>(static_cast<uintptr_t>(handle));
    auto* data = new std::string(json);
    if (napi_call_threadsafe_function(watch->function, data, napi_tsfn_nonblocking) != napi_ok) delete data;
}
extern "C" void org_tasks_harmony_notification_monitor_release(uint64_t handle)
{
    auto* watch = reinterpret_cast<NotificationWatch*>(static_cast<uintptr_t>(handle));
    if (watch != nullptr) napi_release_threadsafe_function(watch->function, napi_tsfn_release);
}

void ExecuteWorkspaceString(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceStringWork*>(data);
    if (work->watch_notifications) {
        uint64_t monitor = work->monitor_handle;
        work->monitor_handle = 0; // Rust 接管，即使注册失败也负责释放。
        work->subscription_id = org_tasks_harmony_workspace_watch_notifications(work->handle, monitor);
        if (work->subscription_id != 0) work->response = "{}";
    } else if (work->reload) {
        if (org_tasks_harmony_workspace_reload(work->handle) == 0) work->response = "{}";
    } else if (work->notifications) {
        work->response = TakeRustString(org_tasks_harmony_workspace_notifications(work->handle));
    } else if (work->refile_targets) {
        work->response = TakeRustString(org_tasks_harmony_workspace_refile_targets(work->handle, work->expression.c_str()));
    } else if (work->execute_operations) {
        work->response = TakeRustString(org_tasks_harmony_workspace_execute_task_operations(work->handle, work->expression.c_str()));
    } else if (work->default_todo_settings) {
        work->response = TakeRustString(org_tasks_harmony_default_todo_settings());
    } else if (work->default_sync_options) {
        work->response = TakeRustString(org_tasks_harmony_default_sync_options());
    } else if (work->normalize_sync_options) {
        work->response = TakeRustString(org_tasks_harmony_normalize_sync_options(work->expression.c_str()));
    } else if (work->todo_defaults) {
        if (org_tasks_harmony_workspace_set_todo_defaults(work->handle, work->expression.c_str()) == 0) work->response = "{}";
    } else {
        work->response = TakeRustString(org_tasks_harmony_workspace_query(work->handle, work->expression.c_str()));
    }
    if (work->response.empty()) work->error = TakeRustError();
}

void CompleteWorkspaceString(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceStringWork*>(data);
    if (status != napi_ok || work->response.empty()) {
        RejectCoreError(env, work->deferred, work->error, "core workspace 操作失败");
    } else {
        napi_value result;
        if (work->watch_notifications) {
            napi_value owner;
            WorkspaceWrap* workspace = nullptr;
            if (napi_get_reference_value(env, work->owner, &owner) == napi_ok &&
                napi_unwrap(env, owner, reinterpret_cast<void**>(&workspace)) == napi_ok &&
                workspace != nullptr && workspace->notification_generation == work->subscription_generation) {
                org_tasks_harmony_workspace_unwatch_notifications(workspace->notification_subscription);
                workspace->notification_subscription = work->subscription_id;
                work->subscription_id = 0;
            }
            napi_get_undefined(env, &result);
            napi_resolve_deferred(env, work->deferred, result);
        } else if (work->todo_defaults || work->reload) {
            napi_get_undefined(env, &result);
            napi_resolve_deferred(env, work->deferred, result);
        } else if (!ParseJson(env, work->response, &result)) {
            napi_value text;
            napi_create_string_utf8(env, "core workspace 响应格式无效", NAPI_AUTO_LENGTH, &text);
            napi_value error;
            napi_create_error(env, nullptr, text, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else if (!work->notifications && !work->refile_targets && !work->default_todo_settings && !work->default_sync_options && !work->normalize_sync_options) {
            napi_value tasks;
            napi_value source_tasks = result;
            bool valid = napi_get_named_property(env, result, "tasks", &source_tasks) == napi_ok;
            uint32_t length = 0;
            valid = valid && napi_get_array_length(env, source_tasks, &length) == napi_ok &&
                napi_create_array_with_length(env, length, &tasks) == napi_ok;
            for (uint32_t index = 0; valid && index < length; index++) {
                napi_value source;
                valid = napi_get_element(env, source_tasks, index, &source) == napi_ok;
                if (!valid) break;
                napi_value task = CreateTaskObject(env, source);
                valid = task != nullptr && napi_set_element(env, tasks, index, task) == napi_ok;
            }
            if (valid) valid = napi_set_named_property(env, result, "tasks", tasks) == napi_ok;
            if (valid) napi_resolve_deferred(env, work->deferred, result);
            else RejectFileProjection(env, work->deferred);
        } else {
            napi_resolve_deferred(env, work->deferred, result);
        }
    }
    if (work->subscription_id != 0) org_tasks_harmony_workspace_unwatch_notifications(work->subscription_id);
    if (work->owner != nullptr) napi_delete_reference(env, work->owner);
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteWorkspaceAddRepo(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceAddRepoWork*>(data);
    work->result = work->operation == WorkspaceAddRepoWork::Operation::Add
        ? org_tasks_harmony_workspace_add_repo(work->handle, work->root_directory.c_str())
        : org_tasks_harmony_workspace_remove_repo(work->handle, work->root_directory.c_str());
    if (work->result != 0) work->error = TakeRustError();
}

void CompleteWorkspaceAddRepo(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceAddRepoWork*>(data);
    if (status != napi_ok || work->result != 0) {
        RejectCoreError(env, work->deferred, work->error,
            work->operation == WorkspaceAddRepoWork::Operation::Add ? "Workspace.addRepo 失败" : "Workspace.removeRepo 失败");
    } else {
        if (work->operation == WorkspaceAddRepoWork::Operation::Remove) {
            napi_value value;
            napi_get_undefined(env, &value);
            napi_resolve_deferred(env, work->deferred, value);
        } else if (!org_tasks_harmony_workspace_retain(work->handle)) {
            RejectCoreError(env, work->deferred, TakeRustError(), "无法创建 Repo 对象");
        } else {
            napi_value repo = CreateRepoObject(env, work->handle, work->root_directory);
            if (repo == nullptr) {
                org_tasks_harmony_workspace_release(work->handle);
                napi_value text;
                napi_create_string_utf8(env, "无法创建 Repo 对象", NAPI_AUTO_LENGTH, &text);
                napi_value error;
                napi_create_error(env, nullptr, text, &error);
                napi_reject_deferred(env, work->deferred, error);
            } else {
                napi_resolve_deferred(env, work->deferred, repo);
            }
        }
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteWorkspaceRepos(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceReposWork*>(data);
    std::string roots = TakeRustString(org_tasks_harmony_workspace_repo_roots(work->handle));
    size_t start = 0;
    while (start < roots.size()) {
        const size_t end = roots.find('\n', start);
        const size_t length = (end == std::string::npos ? roots.size() : end) - start;
        if (length > 0) {
            work->roots.push_back(roots.substr(start, length));
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
}

void CompleteWorkspaceRepos(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceReposWork*>(data);
    if (status != napi_ok || !work->error.empty()) {
        RejectCoreError(env, work->deferred, work->error, "读取 workspace 仓库失败");
    } else {
        napi_value result;
        napi_create_array_with_length(env, work->roots.size(), &result);
        for (size_t index = 0; index < work->roots.size(); ++index) {
            if (!org_tasks_harmony_workspace_retain(work->handle)) {
                continue;
            }
            napi_value repo = CreateRepoObject(env, work->handle, work->roots[index]);
            if (repo == nullptr) {
                org_tasks_harmony_workspace_release(work->handle);
                continue;
            }
            napi_set_element(env, result, index, repo);
        }
        napi_resolve_deferred(env, work->deferred, result);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteRepoSnapshot(napi_env, void* data)
{
    auto* work = static_cast<RepoSnapshotWork*>(data);
    switch (work->operation) {
        case RepoSnapshotWork::Operation::LastEffectSync:
        case RepoSnapshotWork::Operation::HistoryFile:
            work->response = TakeRustString(org_tasks_harmony_repo_history_operation(work->workspace_handle,
                work->root_directory.c_str(), work->task_json.c_str()));
            break;
        case RepoSnapshotWork::Operation::FileMetadata:
            work->response = TakeRustString(org_tasks_harmony_repo_file_metadata(
                work->workspace_handle, work->root_directory.c_str()));
            break;
        case RepoSnapshotWork::Operation::File:
            work->response = TakeRustString(org_tasks_harmony_repo_file(work->workspace_handle,
                work->root_directory.c_str(), work->task_path.c_str()));
            break;
        case RepoSnapshotWork::Operation::Conflicts:
            work->response = TakeRustString(org_tasks_harmony_repo_conflicts(
                work->workspace_handle, work->root_directory.c_str()));
            break;
        case RepoSnapshotWork::Operation::Snapshot:
            work->response = TakeRustString(org_tasks_harmony_repo_snapshot(
                work->workspace_handle, work->root_directory.c_str()));
            break;
        case RepoSnapshotWork::Operation::History:
            // 透传 Core 的执行结果、传输方向与冲突摘要，继续在 worker 内读取历史。
            work->response = TakeRustString(org_tasks_harmony_repo_history(
                work->workspace_handle, work->root_directory.c_str()));
            break;
        case RepoSnapshotWork::Operation::HistoryDetail:
            work->response = TakeRustString(org_tasks_harmony_repo_history_detail(
                work->workspace_handle, work->root_directory.c_str(), work->task_path.c_str()));
            break;
        case RepoSnapshotWork::Operation::Sync:
            work->response = TakeRustString(org_tasks_harmony_repo_sync(work->workspace_handle,
                work->root_directory.c_str(), work->webdav_url.c_str(), work->username.c_str(), work->password.c_str(),
                work->sync_options_json.c_str(),
                work->monitor == nullptr ? 0 : reinterpret_cast<uintptr_t>(work), static_cast<int64_t>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::system_clock::now().time_since_epoch()).count())));
            break;
        case RepoSnapshotWork::Operation::Reset:
            if (org_tasks_harmony_repo_reset(work->workspace_handle, work->root_directory.c_str()) == 0) {
                work->response = "{}";
            }
            break;
        case RepoSnapshotWork::Operation::Load:
            if (org_tasks_harmony_repo_load(work->workspace_handle, work->root_directory.c_str()) == 0) {
                work->response = "{}";
            }
            break;
    }
    if (work->response.empty()) work->error = TakeRustError();
}

void CompleteRepoSnapshot(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<RepoSnapshotWork*>(data);
    if (status != napi_ok || work->response.empty()) {
        RejectCoreError(env, work->deferred, work->error,
            work->operation == RepoSnapshotWork::Operation::Snapshot ? "读取 Repo 快照失败" :
            work->operation == RepoSnapshotWork::Operation::Sync ? "Repo 同步失败" :
            work->operation == RepoSnapshotWork::Operation::FileMetadata ? "读取文件元信息失败" :
            work->operation == RepoSnapshotWork::Operation::Load ? "Repo.load 失败" :
            work->operation == RepoSnapshotWork::Operation::Reset ? "Repo.reset 失败" :
            work->operation == RepoSnapshotWork::Operation::History ? "读取同步历史失败" :
            work->operation == RepoSnapshotWork::Operation::HistoryDetail ? "读取同步详情失败" : "处理同步合并失败");
    } else {
        napi_value result;
        if (work->operation == RepoSnapshotWork::Operation::Load ||
            work->operation == RepoSnapshotWork::Operation::Reset) {
            napi_get_undefined(env, &result);
            napi_resolve_deferred(env, work->deferred, result);
        } else if (!ParseJson(env, work->response, &result)) {
            napi_value text;
            napi_create_string_utf8(env, "Repo 响应格式无效", NAPI_AUTO_LENGTH, &text);
            napi_value error;
            napi_create_error(env, nullptr, text, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else if (work->operation == RepoSnapshotWork::Operation::File || work->operation == RepoSnapshotWork::Operation::HistoryFile) {
            napi_value file = CreateOrgFileObject(env, result);
            if (file != nullptr) napi_resolve_deferred(env, work->deferred, file);
            else RejectFileProjection(env, work->deferred);
        } else if (work->operation == RepoSnapshotWork::Operation::Snapshot) {
            napi_value files, objects;
            uint32_t length = 0;
            if (napi_get_named_property(env, result, "files", &files) == napi_ok &&
                napi_get_array_length(env, files, &length) == napi_ok &&
                napi_create_array_with_length(env, length, &objects) == napi_ok) {
                bool valid = true;
                for (uint32_t index = 0; index < length; index++) {
                    napi_value data;
                    if (napi_get_element(env, files, index, &data) != napi_ok) { valid = false; break; }
                    napi_value file = CreateOrgFileObject(env, data);
                    if (file == nullptr || napi_set_element(env, objects, index, file) != napi_ok) { valid = false; break; }
                }
                if (valid) napi_resolve_deferred(env, work->deferred, objects);
                else RejectFileProjection(env, work->deferred);
            } else RejectFileProjection(env, work->deferred);
        } else {
            napi_resolve_deferred(env, work->deferred, result);
        }
    }
    if (work->owner != nullptr) napi_delete_reference(env, work->owner);
    if (work->related_owner != nullptr) napi_delete_reference(env, work->related_owner);
    if (work->monitor != nullptr) {
        napi_release_threadsafe_function(work->monitor, napi_tsfn_release);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value WorkspaceConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, nullptr, &self, nullptr) != napi_ok || argc != 0) {
        napi_throw_error(env, nullptr, "Workspace 不接受构造参数");
        return nullptr;
    }
    auto* workspace = new WorkspaceWrap();
    workspace->handle = org_tasks_harmony_workspace_create();
    if (workspace->handle == 0 || napi_wrap(env, self, workspace, FinalizeWorkspace, nullptr, nullptr) != napi_ok) {
        if (workspace->handle != 0) {
            org_tasks_harmony_workspace_release(workspace->handle);
        }
        delete workspace;
        napi_throw_error(env, nullptr, "无法创建 Workspace");
        return nullptr;
    }
    return self;
}

napi_value RepoConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 2) {
        napi_throw_error(env, nullptr, "Repo 不能直接构造");
        return nullptr;
    }
    auto* repo = new RepoWrap();
    if (!ReadHandle(env, args[0], &repo->workspace_handle) || !ReadString(env, args[1], &repo->root_directory) ||
        napi_wrap(env, self, repo, FinalizeRepo, nullptr, nullptr) != napi_ok) {
        delete repo;
        napi_throw_error(env, nullptr, "Repo handle 无效");
        return nullptr;
    }
    return self;
}

napi_value WebDavSyncPolicyConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 3) {
        napi_throw_error(env, nullptr, "WebDavSyncPolicy 需要 3 个参数");
        return nullptr;
    }
    std::string webdav_url;
    std::string username;
    std::string password;
    if (!ReadString(env, args[0], &webdav_url) || !ReadString(env, args[1], &username) ||
        !ReadString(env, args[2], &password)) {
        napi_throw_error(env, nullptr, "WebDavSyncPolicy 参数无效");
        return nullptr;
    }
    auto* policy = new WebDavSyncPolicyWrap { webdav_url, username, password };
    if (napi_wrap(env, self, policy, FinalizeWebDavSyncPolicy, nullptr, nullptr) != napi_ok) {
        delete policy;
        napi_throw_error(env, nullptr, "无法创建 WebDavSyncPolicy");
        return nullptr;
    }
    return self;
}

bool UnwrapWorkspace(napi_env env, napi_callback_info info, WorkspaceWrap** workspace, napi_value* self)
{
    size_t argc = 0;
    if (napi_get_cb_info(env, info, &argc, nullptr, self, nullptr) != napi_ok ||
        napi_unwrap(env, *self, reinterpret_cast<void**>(workspace)) != napi_ok || (*workspace)->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace 已关闭");
        return false;
    }
    return true;
}

bool UnwrapRepo(napi_env env, napi_callback_info info, RepoWrap** repo, napi_value* self)
{
    size_t argc = 0;
    if (napi_get_cb_info(env, info, &argc, nullptr, self, nullptr) != napi_ok ||
        napi_unwrap(env, *self, reinterpret_cast<void**>(repo)) != napi_ok || (*repo)->workspace_handle == 0) {
        napi_throw_error(env, nullptr, "Repo 已关闭");
        return false;
    }
    return true;
}

bool UnwrapWebDavSyncPolicy(napi_env env, napi_value value, WebDavSyncPolicyWrap** policy)
{
    if (napi_unwrap(env, value, reinterpret_cast<void**>(policy)) != napi_ok) {
        napi_throw_error(env, nullptr, "WebDavSyncPolicy 已关闭");
        return false;
    }
    return true;
}

void ExecuteWebDavConnection(napi_env, void* data)
{
    auto* work = static_cast<WebDavConnectionWork*>(data);
    work->result = org_tasks_harmony_webdav_test_connection(
        work->webdav_url.c_str(), work->username.c_str(), work->password.c_str());
    if (work->result != 0) work->error = TakeRustError();
}

void CompleteWebDavConnection(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WebDavConnectionWork*>(data);
    if (status != napi_ok || work->result != 0) {
        RejectCoreError(env, work->deferred, work->error, "WebDAV 连接测试失败");
    } else {
        napi_value result;
        napi_get_undefined(env, &result);
        napi_resolve_deferred(env, work->deferred, result);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value WebDavTestConnection(napi_env env, napi_callback_info info)
{
    size_t argc = 0;
    napi_value self;
    WebDavSyncPolicyWrap* policy = nullptr;
    if (napi_get_cb_info(env, info, &argc, nullptr, &self, nullptr) != napi_ok ||
        !UnwrapWebDavSyncPolicy(env, self, &policy)) return nullptr;
    // 参数复制到 worker；测试不持有或修改 workspace、Repo 和配置存储。
    auto* work = new WebDavConnectionWork();
    work->webdav_url = policy->webdav_url;
    work->username = policy->username;
    work->password = policy->password;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建连接测试 Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksWebDavConnection", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWebDavConnection, CompleteWebDavConnection, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度连接测试");
        return nullptr;
    }
    return promise;
}

napi_value QueueWorkspaceString(napi_env env, WorkspaceStringWork* work, const char* name, napi_value self)
{
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Workspace Promise");
        return nullptr;
    }
    napi_value resource_name;
    if ((!work->default_todo_settings && !work->default_sync_options && !work->normalize_sync_options && napi_create_reference(env, self, 1, &work->owner) != napi_ok) ||
        napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWorkspaceString, CompleteWorkspaceString, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->owner != nullptr) napi_delete_reference(env, work->owner);
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace 请求");
        return nullptr;
    }
    return promise;
}


napi_value WorkspaceQuery(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self;
    WorkspaceWrap* workspace = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr || workspace->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace.query 参数无效");
        return nullptr;
    }
    auto* work = new WorkspaceStringWork();
    if (!EncodeJson(env, args[0], &work->expression)) {
        delete work;
        napi_throw_error(env, nullptr, "任务查询参数无效");
        return nullptr;
    }
    work->handle = workspace->handle;
    return QueueWorkspaceString(env, work, "OrgTasksWorkspaceQuery", self);
}

napi_value DefaultTodoSettings(napi_env env, napi_callback_info info)
{
    napi_value self; size_t argc = 0;
    if (napi_get_cb_info(env, info, &argc, nullptr, &self, nullptr) != napi_ok) return nullptr;
    auto* work = new WorkspaceStringWork(); work->default_todo_settings = true;
    return QueueWorkspaceString(env, work, "OrgTasksDefaultTodoSettings", self);
}

napi_value DefaultSyncOptions(napi_env env, napi_callback_info info)
{
    napi_value self; size_t argc = 0;
    if (napi_get_cb_info(env, info, &argc, nullptr, &self, nullptr) != napi_ok) return nullptr;
    auto* work = new WorkspaceStringWork(); work->default_sync_options = true;
    return QueueWorkspaceString(env, work, "OrgTasksDefaultSyncOptions", self);
}

napi_value NormalizeSyncOptions(napi_env env, napi_callback_info info)
{
    napi_value self;
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1) {
        napi_throw_error(env, nullptr, "同步参数无效");
        return nullptr;
    }
    auto* work = new WorkspaceStringWork();
    work->normalize_sync_options = true;
    if (!EncodeJson(env, args[0], &work->expression)) {
        delete work;
        napi_throw_error(env, nullptr, "同步参数无效");
        return nullptr;
    }
    return QueueWorkspaceString(env, work, "OrgTasksNormalizeSyncOptions", self);
}

napi_value WorkspaceWatchNotifications(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1], self, name;
    WorkspaceWrap* workspace = nullptr;
    napi_valuetype type;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_typeof(env, args[0], &type) != napi_ok || type != napi_function ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "通知监控需要回调函数"); return nullptr;
    }
    auto* watch = new NotificationWatch();
    if (napi_create_string_utf8(env, "OrgTasksNotificationMonitor", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1, watch, FinalizeNotificationWatch,
            nullptr, CallWebDavSyncMonitor, &watch->function) != napi_ok) {
        delete watch; napi_throw_error(env, nullptr, "无法创建通知监控"); return nullptr;
    }
    napi_unref_threadsafe_function(env, watch->function);
    auto* work = new WorkspaceStringWork();
    work->handle = workspace->handle;
    work->watch_notifications = true;
    work->monitor_handle = reinterpret_cast<uintptr_t>(watch);
    work->subscription_generation = ++workspace->notification_generation;
    return QueueWorkspaceString(env, work, "OrgTasksWatchNotifications", self);
}
napi_value WorkspaceStopWatchingNotifications(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr;
    napi_value self, result;
    if (!UnwrapWorkspace(env, info, &workspace, &self)) return nullptr;
    ++workspace->notification_generation;
    org_tasks_harmony_workspace_unwatch_notifications(workspace->notification_subscription);
    workspace->notification_subscription = 0;
    napi_get_undefined(env, &result); return result;
}
napi_value WorkspaceReload(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (!UnwrapWorkspace(env, info, &workspace, &self)) return nullptr;
    auto* work = new WorkspaceStringWork(); work->handle = workspace->handle; work->reload = true;
    return QueueWorkspaceString(env, work, "OrgTasksWorkspaceReload", self);
}

napi_value WorkspaceNotifications(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (!UnwrapWorkspace(env, info, &workspace, &self)) return nullptr;
    auto* work = new WorkspaceStringWork();
    work->handle = workspace->handle;
    work->notifications = true;
    return QueueWorkspaceString(env, work, "OrgTasksNotifications", self);
}

napi_value WorkspaceRefileTargets(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr; napi_value self; size_t argc = 2; napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc > 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "Workspace.refileTargets 参数无效"); return nullptr;
    }
    auto* work = new WorkspaceStringWork(); work->handle = workspace->handle; work->refile_targets = true;
    work->expression = "{}";
    napi_valuetype query_type = napi_undefined;
    if (argc == 1 && (napi_typeof(env, args[0], &query_type) != napi_ok ||
        (query_type != napi_undefined && !EncodeJson(env, args[0], &work->expression)))) {
        delete work; napi_throw_error(env, nullptr, "放置目标查询参数无效"); return nullptr;
    }
    return QueueWorkspaceString(env, work, "OrgTasksRefileTargets", self);
}

napi_value WorkspaceExecuteTaskOperations(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr; napi_value self; size_t argc = 1; napi_value args[1];
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "Workspace.executeTaskOperations 参数无效"); return nullptr;
    }
    auto* work = new WorkspaceStringWork(); work->handle = workspace->handle; work->execute_operations = true;
    if (!EncodeJson(env, args[0], &work->expression)) { delete work; napi_throw_error(env, nullptr, "任务整理参数无效"); return nullptr; }
    return QueueWorkspaceString(env, work, "OrgTasksExecuteTaskOperations", self);
}

napi_value WorkspaceSetTodoDefaults(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1] = {nullptr}; napi_value self;
    WorkspaceWrap* workspace = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr || workspace->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace.setTodoDefaults 参数无效"); return nullptr;
    }
    auto* work = new WorkspaceStringWork();
    if (!ReadString(env, args[0], &work->expression) || work->expression.find('\0') != std::string::npos) {
        delete work; napi_throw_error(env, nullptr, "TODO 默认设置必须是文本"); return nullptr;
    }
    work->todo_defaults = true; work->handle = workspace->handle;
    return QueueWorkspaceString(env, work, "OrgTasksTodoDefaults", self);
}

napi_value WorkspaceAddRepo(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace.addRepo 参数无效");
        return nullptr;
    }
    auto* work = new WorkspaceAddRepoWork();
    if (!ReadString(env, args[0], &work->root_directory)) {
        delete work;
        napi_throw_error(env, nullptr, "Workspace.addRepo 路径无效");
        return nullptr;
    }
    work->handle = workspace->handle;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Workspace.addRepo Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksWorkspaceAddRepo", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWorkspaceAddRepo, CompleteWorkspaceAddRepo, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace.addRepo 请求");
        return nullptr;
    }
    return promise;
}

napi_value WorkspaceRemoveRepo(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace.removeRepo 参数无效");
        return nullptr;
    }
    auto* work = new WorkspaceAddRepoWork();
    if (!ReadString(env, args[0], &work->root_directory)) {
        delete work;
        napi_throw_error(env, nullptr, "Workspace.removeRepo 路径无效");
        return nullptr;
    }
    work->handle = workspace->handle;
    work->operation = WorkspaceAddRepoWork::Operation::Remove;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Workspace.removeRepo Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksWorkspaceRemoveRepo", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWorkspaceAddRepo, CompleteWorkspaceAddRepo, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace.removeRepo 请求");
        return nullptr;
    }
    return promise;
}

napi_value WorkspaceRepos(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (!UnwrapWorkspace(env, info, &workspace, &self)) return nullptr;
    auto* work = new WorkspaceReposWork();
    work->handle = workspace->handle;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Workspace.repos Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksWorkspaceRepos", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWorkspaceRepos, CompleteWorkspaceRepos, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace.repos 请求");
        return nullptr;
    }
    return promise;
}

napi_value RepoId(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    std::string id = TakeRustString(org_tasks_harmony_repo_id(
        repo->workspace_handle, repo->root_directory.c_str()));
    napi_value value;
    napi_create_string_utf8(env, id.c_str(), id.size(), &value);
    return value;
}

napi_value RepoFullPath(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr; napi_value self, result;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    std::string json = TakeRustString(org_tasks_harmony_repo_full_path(repo->workspace_handle, repo->root_directory.c_str()));
    if (json.empty() || !ParseJson(env, json, &result)) { napi_throw_error(env, nullptr, "读取仓库完整路径失败"); return nullptr; }
    return result;
}

napi_value RepoRootDirectory(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    napi_value value;
    napi_create_string_utf8(env, repo->root_directory.c_str(), repo->root_directory.size(), &value);
    return value;
}

napi_value RepoFiles(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    void* metadata = nullptr;
    napi_get_cb_info(env, info, nullptr, nullptr, nullptr, &metadata);
    auto* work = new RepoSnapshotWork();
    if (metadata != nullptr) work->operation = RepoSnapshotWork::Operation::FileMetadata;
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Repo.files Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_reference(env, self, 1, &work->owner) != napi_ok ||
        napi_create_string_utf8(env, "OrgTasksRepoSnapshot", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->owner != nullptr) napi_delete_reference(env, work->owner);
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Repo.files 请求");
        return nullptr;
    }
    return promise;
}

napi_value RepoLoad(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->operation = RepoSnapshotWork::Operation::Load;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Repo.load Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_reference(env, self, 1, &work->owner) != napi_ok ||
        napi_create_string_utf8(env, "OrgTasksRepoLoad", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->owner != nullptr) napi_delete_reference(env, work->owner);
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Repo.load 请求");
        return nullptr;
    }
    return promise;
}
napi_value RepoReset(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->operation = RepoSnapshotWork::Operation::Reset;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Repo.reset Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_reference(env, self, 1, &work->owner) != napi_ok ||
        napi_create_string_utf8(env, "OrgTasksRepoReset", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->owner != nullptr) napi_delete_reference(env, work->owner);
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Repo.reset 请求");
        return nullptr;
    }
    return promise;
}

napi_value QueueMergeWork(napi_env env, napi_value self, RepoSnapshotWork* work);

napi_value RepoHistory(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->operation = RepoSnapshotWork::Operation::History;
    return QueueMergeWork(env, self, work);
}

napi_value RepoHistoryOperation(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self;
    void* method = nullptr;
    RepoWrap* repo = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, &method) != napi_ok ||
        (argc != 1 && (method == nullptr || std::strcmp(static_cast<const char*>(method), "lastEffectSync") != 0)) ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&repo)) != napi_ok || repo == nullptr) {
        napi_throw_error(env, nullptr, "历史文件参数无效"); return nullptr;
    }
    const char* operation = static_cast<const char*>(method);
    napi_value request, value;
    napi_create_object(env, &request);
    napi_create_string_utf8(env, operation, NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, request, "operation", value);
    if (std::strcmp(operation, "lastEffectSync") != 0) {
        for (const char* key : {"syncId", "path"}) {
            if (napi_get_named_property(env, args[0], key, &value) != napi_ok) return nullptr;
            napi_set_named_property(env, request, key, value);
        }
        if (std::strcmp(operation, "file") == 0) {
            napi_get_named_property(env, args[0], "resolved", &value);
            napi_set_named_property(env, request, "resolved", value);
        }
    }
    auto* work = new RepoSnapshotWork();
    if (!EncodeJson(env, request, &work->task_json)) { delete work; napi_throw_error(env, nullptr, "历史文件参数无法编组"); return nullptr; }
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->operation = std::strcmp(operation, "file") == 0 ? RepoSnapshotWork::Operation::HistoryFile
        : RepoSnapshotWork::Operation::LastEffectSync;
    return QueueMergeWork(env, self, work);
}

napi_value RepoHistoryDetail(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self;
    RepoWrap* repo = nullptr;
    std::string sync_id;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&repo)) != napi_ok || repo == nullptr ||
        !ReadString(env, args[0], &sync_id)) {
        napi_throw_error(env, nullptr, "Repo.historyDetail 需要同步记录 ID");
        return nullptr;
    }
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->task_path = sync_id;
    work->operation = RepoSnapshotWork::Operation::HistoryDetail;
    return QueueMergeWork(env, self, work);
}

napi_value RepoSync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    RepoWrap* repo = nullptr;
    WebDavSyncPolicyWrap* policy = nullptr;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc < 1 || argc > 3 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&repo)) != napi_ok || repo == nullptr || repo->workspace_handle == 0 ||
        !UnwrapWebDavSyncPolicy(env, args[0], &policy)) {
        napi_throw_error(env, nullptr, "Repo.sync 参数无效");
        return nullptr;
    }
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->webdav_url = policy->webdav_url;
    work->username = policy->username;
    work->password = policy->password;
    work->operation = RepoSnapshotWork::Operation::Sync;
    napi_valuetype monitor_type = napi_undefined;
    if (argc >= 2 && napi_typeof(env, args[1], &monitor_type) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "Repo.sync monitor 参数无效");
        return nullptr;
    }
    if (monitor_type != napi_undefined) {
        napi_value resource_name;
        if (monitor_type != napi_function ||
            napi_create_string_utf8(env, "OrgTasksWebDavSyncMonitor", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
            napi_create_threadsafe_function(env, args[1], nullptr, resource_name, 0, 1, nullptr, nullptr,
                nullptr, CallWebDavSyncMonitor, &work->monitor) != napi_ok) {
            delete work;
            napi_throw_error(env, nullptr, "Repo.sync monitor 参数无效");
            return nullptr;
        }
    }
    napi_valuetype options_type = napi_undefined;
    if (argc == 3 && (napi_typeof(env, args[2], &options_type) != napi_ok ||
        (options_type != napi_undefined && !EncodeJson(env, args[2], &work->sync_options_json)))) {
        if (work->monitor != nullptr) napi_release_threadsafe_function(work->monitor, napi_tsfn_abort);
        delete work;
        napi_throw_error(env, nullptr, "Repo.sync 同步参数无效");
        return nullptr;
    }
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        if (work->monitor != nullptr) napi_release_threadsafe_function(work->monitor, napi_tsfn_abort);
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Repo.sync Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_reference(env, self, 1, &work->owner) != napi_ok ||
        napi_create_string_utf8(env, "OrgTasksRepoSync", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->owner != nullptr) napi_delete_reference(env, work->owner);
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        if (work->monitor != nullptr) napi_release_threadsafe_function(work->monitor, napi_tsfn_abort);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Repo.sync 请求");
        return nullptr;
    }
    return promise;
}

napi_value QueueMergeWork(napi_env env, napi_value self, RepoSnapshotWork* work)
{
    napi_value promise;
    napi_value resource_name;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
        napi_create_reference(env, self, 1, &work->owner) != napi_ok ||
        napi_create_string_utf8(env, "OrgTasksRepoMerge", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->owner != nullptr) napi_delete_reference(env, work->owner);
        if (work->related_owner != nullptr) napi_delete_reference(env, work->related_owner);
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度任务冲突请求");
        return nullptr;
    }
    return promise;
}

napi_value RepoFile(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self;
    RepoWrap* repo = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&repo)) != napi_ok || repo == nullptr || repo->workspace_handle == 0) {
        napi_throw_error(env, nullptr, "Repo.file 参数无效");
        return nullptr;
    }
    auto* work = new RepoSnapshotWork();
    if (!ReadString(env, args[0], &work->task_path) || work->task_path.find('\0') != std::string::npos) {
        delete work;
        napi_throw_error(env, nullptr, "Org 文件路径无效");
        return nullptr;
    }
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->operation = RepoSnapshotWork::Operation::File;
    return QueueMergeWork(env, self, work);
}

napi_value RepoConflicts(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    work->operation = RepoSnapshotWork::Operation::Conflicts;
    return QueueMergeWork(env, self, work);
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor task_descriptors[] = {
        {"isDone", nullptr, TaskIsDone, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value task_class;
    napi_define_class(env, "Task", NAPI_AUTO_LENGTH, TaskConstructor, nullptr,
        sizeof(task_descriptors) / sizeof(task_descriptors[0]), task_descriptors, &task_class);
    napi_create_reference(env, task_class, 1, &task_constructor);
    napi_set_named_property(env, exports, "Task", task_class);
    napi_property_descriptor file_descriptors[] = {
        {"fullPath", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("fullPath")},
        {"fileVersion", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("fileVersion")},
        {"repoId", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("repoId")},
        {"path", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("path")},
        {"todo", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("todo")},
        {"category", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("category")},
        {"title", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("title")},
        {"titleParts", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("titleParts")},
        {"hasConflict", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("hasConflict")},
        {"renderHtml", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("renderedHtml")},
        {"sourceBytes", nullptr, OrgFileSourceBytes, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value file_class;
    napi_define_class(env, "OrgFile", NAPI_AUTO_LENGTH, OrgFileConstructor, nullptr,
        sizeof(file_descriptors) / sizeof(file_descriptors[0]), file_descriptors, &file_class);
    napi_create_reference(env, file_class, 1, &file_constructor);
    napi_set_named_property(env, exports, "OrgFile", file_class);
    napi_value default_todo_settings;
    napi_create_function(env, "defaultTodoSettings", NAPI_AUTO_LENGTH, DefaultTodoSettings, nullptr, &default_todo_settings);
    napi_set_named_property(env, exports, "defaultTodoSettings", default_todo_settings);
    napi_value default_sync_options;
    napi_create_function(env, "defaultSyncOptions", NAPI_AUTO_LENGTH, DefaultSyncOptions, nullptr, &default_sync_options);
    napi_set_named_property(env, exports, "defaultSyncOptions", default_sync_options);
    napi_value normalize_sync_options;
    napi_create_function(env, "normalizeSyncOptions", NAPI_AUTO_LENGTH, NormalizeSyncOptions, nullptr, &normalize_sync_options);
    napi_set_named_property(env, exports, "normalizeSyncOptions", normalize_sync_options);
    napi_property_descriptor workspace_descriptors[] = {
        {"setTodoDefaults", nullptr, WorkspaceSetTodoDefaults, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"repos", nullptr, WorkspaceRepos, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"addRepo", nullptr, WorkspaceAddRepo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeRepo", nullptr, WorkspaceRemoveRepo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"refileTargets", nullptr, WorkspaceRefileTargets, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"executeTaskOperations", nullptr, WorkspaceExecuteTaskOperations, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"query", nullptr, WorkspaceQuery, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"watchNotifications", nullptr, WorkspaceWatchNotifications, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopWatchingNotifications", nullptr, WorkspaceStopWatchingNotifications, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reload", nullptr, WorkspaceReload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"notifications", nullptr, WorkspaceNotifications, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value workspace_class;
    napi_define_class(env, "Workspace", NAPI_AUTO_LENGTH, WorkspaceConstructor, nullptr,
        sizeof(workspace_descriptors) / sizeof(workspace_descriptors[0]), workspace_descriptors, &workspace_class);
    napi_set_named_property(env, exports, "Workspace", workspace_class);

    napi_property_descriptor repo_descriptors[] = {
        {"file", nullptr, RepoFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"id", nullptr, nullptr, RepoId, nullptr, nullptr, napi_default, nullptr},
        {"fullPath", nullptr, nullptr, RepoFullPath, nullptr, nullptr, napi_default, nullptr},
        {"rootDirectory", nullptr, nullptr, RepoRootDirectory, nullptr, nullptr, napi_default, nullptr},
        {"load", nullptr, RepoLoad, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reset", nullptr, RepoReset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"history", nullptr, RepoHistory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastEffectSync", nullptr, RepoHistoryOperation, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("lastEffectSync")},
        {"historyFile", nullptr, RepoHistoryOperation, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("file")},
        {"historyDetail", nullptr, RepoHistoryDetail, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"files", nullptr, RepoFiles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fileMetadata", nullptr, RepoFiles, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("metadata")},
        {"sync", nullptr, RepoSync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"conflicts", nullptr, RepoConflicts, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value repo_class;
    napi_define_class(env, "Repo", NAPI_AUTO_LENGTH, RepoConstructor, nullptr,
        sizeof(repo_descriptors) / sizeof(repo_descriptors[0]), repo_descriptors, &repo_class);
    napi_create_reference(env, repo_class, 1, &repo_constructor);
    napi_set_named_property(env, exports, "Repo", repo_class);

    napi_value webdav_sync_policy_class;
    napi_property_descriptor policy_descriptors[] = {
        {"testConnection", nullptr, WebDavTestConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_class(env, "WebDavSyncPolicy", NAPI_AUTO_LENGTH, WebDavSyncPolicyConstructor, nullptr,
        sizeof(policy_descriptors) / sizeof(policy_descriptors[0]), policy_descriptors, &webdav_sync_policy_class);
    napi_set_named_property(env, exports, "WebDavSyncPolicy", webdav_sync_policy_class);

    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "org_tasks_harmony",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterOrgTasksHarmonyModule(void)
{
    napi_module_register(&module);
}
