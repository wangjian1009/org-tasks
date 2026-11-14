#include <cstdint>
#include <cstring>
#include <chrono>
#include <algorithm>
#include <string>
#include <vector>

#include "napi/native_api.h"

// 仅接收 Rust bridge 返回且尚未释放的原始指针；不得改变字符串长度，只能释放一次。
extern "C" void org_tasks_harmony_free_string(char* value);
extern "C" char* org_tasks_harmony_last_error();
extern "C" uint64_t org_tasks_harmony_workspace_create();
extern "C" char* org_tasks_harmony_default_todo_settings();
extern "C" char* org_tasks_harmony_workspace_get_settings(uint64_t handle);
extern "C" int32_t org_tasks_harmony_workspace_set_settings(uint64_t handle, const char* settings);
extern "C" char* org_tasks_harmony_default_sync_options();
extern "C" char* org_tasks_harmony_normalize_sync_options(const char* options_json);
extern "C" int32_t org_tasks_harmony_workspace_set_todo_defaults(uint64_t handle, const char* settings);
extern "C" char* org_tasks_harmony_repo_file(uint64_t handle, const char* root, const char* path);
extern "C" bool org_tasks_harmony_workspace_retain(uint64_t handle);
extern "C" void org_tasks_harmony_workspace_release(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_repo_roots(uint64_t handle);
extern "C" uint64_t org_tasks_harmony_workspace_watch_notifications(uint64_t handle, uint64_t monitor);
extern "C" void org_tasks_harmony_workspace_unwatch_notifications(uint64_t subscription);
extern "C" int32_t org_tasks_harmony_workspace_reload(uint64_t handle);
extern "C" void org_tasks_harmony_notification_monitor_release(uint64_t monitor);
extern "C" uint64_t org_tasks_harmony_workspace_watch_data_changes(uint64_t handle, uint64_t monitor);
extern "C" void org_tasks_harmony_workspace_unwatch_data_changes(uint64_t subscription);
extern "C" void org_tasks_harmony_data_change_monitor_release(uint64_t monitor);
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
extern "C" char* org_tasks_harmony_preview_operation(uint64_t handle, const char* request);
extern "C" void org_tasks_harmony_preview_release(uint64_t handle, const char* id);
extern "C" char* org_tasks_harmony_workspace_execute_task_operations(uint64_t handle, const char* request);
extern "C" char* org_tasks_harmony_workspace_task_merge_operations(uint64_t handle, const char* request);
extern "C" char* org_tasks_harmony_repo_sync(uint64_t workspace_handle, const char* repo_id,
    const char* webdav_url, const char* username, const char* password, const char* options_json, uint64_t monitor_handle,
    int64_t started_at);
extern "C" char* org_tasks_harmony_repo_snapshot(uint64_t workspace_handle, const char* repo_id);
extern "C" char* org_tasks_harmony_repo_load_files(uint64_t workspace_handle, const char* root, const char* ignore_files_json);
extern "C" int32_t org_tasks_harmony_webdav_test_connection(
    const char* webdav_url, const char* username, const char* password);
extern "C" char* org_tasks_harmony_repo_conflicts(uint64_t handle, const char* root_directory);


namespace {
struct WorkspaceWrap {
    uint64_t handle = 0;
    uint64_t notification_subscription = 0;
    uint64_t notification_generation = 0;
    std::vector<uint64_t> data_change_subscriptions;
};

struct RepoWrap {
    uint64_t workspace_handle = 0;
    std::string root_directory;
};

struct OrgFileWrap {
    napi_ref data = nullptr;
    std::string source;
};

struct PreviewWrap {
    napi_ref data = nullptr;
    uint64_t handle = 0;
    std::string id;
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
    std::string preview_action;
    bool watch_notifications = false;
    bool watch_data_changes = false;
    bool reload = false;
    uint64_t monitor_handle = 0;
    uint64_t subscription_id = 0;
    uint64_t subscription_generation = 0;
    ~WorkspaceStringWork() {
        if (monitor_handle != 0) {
            if (watch_data_changes) org_tasks_harmony_data_change_monitor_release(monitor_handle);
            else org_tasks_harmony_notification_monitor_release(monitor_handle);
        }
    }
    bool refile_targets = false;
    bool execute_operations = false;
    bool merge_operations = false;
    bool todo_defaults = false;
    bool default_todo_settings = false;
    bool get_settings = false;
    bool set_settings = false;
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
    enum class Operation { Snapshot, Sync, Load, Reset, History, HistoryDetail, Conflicts, File, HistoryFile, LastEffectSync } operation = Operation::Snapshot;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

napi_ref repo_constructor = nullptr;
napi_ref file_constructor = nullptr;
napi_ref preview_constructor = nullptr;
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
    for (uint64_t subscription : workspace->data_change_subscriptions) {
        org_tasks_harmony_workspace_unwatch_data_changes(subscription);
    }
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

// 项目名由 Core 提供；Task 与文件元信息都只读取取得时的快照值。
napi_value SnapshotProject(napi_env env, napi_callback_info info)
{
    napi_value self, value;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr) != napi_ok ||
        napi_get_named_property(env, self, "projectName", &value) != napi_ok) {
        napi_throw_error(env, nullptr, "无法读取项目名称");
        return nullptr;
    }
    return value;
}

napi_value StateOption(napi_env env, napi_value options, napi_value category, const char* error = "状态分类无效")
{
    bool found = false; std::string name;
    if (!ReadString(env, category, &name) || napi_has_own_property(env, options, category, &found) != napi_ok || !found) {
        napi_throw_error(env, nullptr, error); return nullptr;
    }
    napi_value source, result; napi_valuetype type;
    if (napi_get_named_property(env, options, name.c_str(), &source) != napi_ok ||
        napi_typeof(env, source, &type) != napi_ok) return nullptr;
    if (type == napi_null) return source;
    if (napi_create_object(env, &result) != napi_ok) return nullptr;
    for (const char* field : {"name", "category"}) {
        napi_value value;
        if (napi_get_named_property(env, source, field, &value) != napi_ok ||
            napi_set_named_property(env, result, field, value) != napi_ok) return nullptr;
    }
    return result;
}

napi_value TaskTaskStateOf(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1], self, data, options; TaskWrap* task = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&task)) != napi_ok || task == nullptr ||
        napi_get_reference_value(env, task->data, &data) != napi_ok ||
        napi_get_named_property(env, data, "taskStateOptions", &options) != napi_ok) {
        napi_throw_error(env, nullptr, "Task.taskStateOf 参数无效"); return nullptr;
    }
    return StateOption(env, options, args[0]);
}

napi_value TaskTaskPriorityOf(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1], self, data, options; TaskWrap* task = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&task)) != napi_ok || task == nullptr ||
        napi_get_reference_value(env, task->data, &data) != napi_ok ||
        napi_get_named_property(env, data, "taskPriorityOptions", &options) != napi_ok) {
        napi_throw_error(env, nullptr, "Task.taskPriorityOf 参数无效"); return nullptr;
    }
    return StateOption(env, options, args[0], "优先级分类无效");
}

bool BindTaskSnapshotMethods(napi_env env, napi_value task)
{
    // ArkUI @Prop 会深拷贝字段与原型，但不会复制 napi_wrap。绑定函数保留原快照及其生命周期。
    // 方法必须可枚举才能随字段复制；JSON.stringify 仍会自动忽略函数。
    for (const char* name : {"taskStateOf", "taskPriorityOf", "isDone", "project"}) {
        napi_value method, bind, bound;
        if (napi_get_named_property(env, task, name, &method) != napi_ok ||
            napi_get_named_property(env, method, "bind", &bind) != napi_ok ||
            napi_call_function(env, method, bind, 1, &task, &bound) != napi_ok) return false;
        napi_property_descriptor property = {name, nullptr, nullptr, nullptr, nullptr, bound, napi_enumerable, nullptr};
        if (napi_define_properties(env, task, 1, &property) != napi_ok) return false;
    }
    return true;
}

struct MetadataStates { napi_ref options = nullptr; napi_ref priorities = nullptr; };
void FinalizeMetadataStates(napi_env env, void* data, void*)
{
    auto* states = static_cast<MetadataStates*>(data);
    if (states->options != nullptr) napi_delete_reference(env, states->options);
    if (states->priorities != nullptr) napi_delete_reference(env, states->priorities);
    delete states;
}

napi_value MetadataTaskStateOf(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1], self, options; MetadataStates* states = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&states)) != napi_ok || states == nullptr ||
        napi_get_reference_value(env, states->options, &options) != napi_ok) {
        napi_throw_error(env, nullptr, "FileMetadata.taskStateOf 参数无效"); return nullptr;
    }
    return StateOption(env, options, args[0]);
}

napi_value MetadataTaskPriorityOf(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1], self, options; MetadataStates* states = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&states)) != napi_ok || states == nullptr ||
        napi_get_reference_value(env, states->priorities, &options) != napi_ok) {
        napi_throw_error(env, nullptr, "FileMetadata.taskPriorityOf 参数无效"); return nullptr;
    }
    return StateOption(env, options, args[0], "优先级分类无效");
}

napi_value CreateTaskObject(napi_env env, napi_value data)
{
    napi_value constructor, result;
    if (napi_get_reference_value(env, task_constructor, &constructor) != napi_ok ||
        napi_new_instance(env, constructor, 1, &data, &result) != napi_ok) return nullptr;
    // id 为 Core 的明文逻辑路径；editContent 的 notesHtml、checklist 与重复信息原样透传。
    for (const char* name : {"id", "taskId", "fullPath", "fileVersion", "repoId", "heading", "category", "projectName", "headingParts", "state", "createdAt", "closedAt", "modifiedAt", "priority", "priorityOptions", "defaultPriority", "scheduled",
        "deadline", "tags", "ownTags", "inheritedTags", "supportTags", "editContent", "filePath", "fileName", "level", "body", "bodyFirstLine", "addressLinks", "bodyHtml", "logbookHtml", "logs", "progress", "hasList", "hasText", "isRepeating", "isHabit"}) {
        napi_value value;
        if (napi_get_named_property(env, data, name, &value) != napi_ok) return nullptr;
        napi_property_descriptor property = {name, nullptr, nullptr, nullptr, nullptr, value, napi_enumerable, nullptr};
        if (napi_define_properties(env, result, 1, &property) != napi_ok) return nullptr;
    }
    return BindTaskSnapshotMethods(env, result) ? result : nullptr;
}

bool ProjectTaskResult(napi_env env, napi_value result)
{
    napi_value source_tasks, tasks;
    uint32_t length = 0;
    if (napi_get_named_property(env, result, "tasks", &source_tasks) != napi_ok ||
        napi_get_array_length(env, source_tasks, &length) != napi_ok ||
        napi_create_array_with_length(env, length, &tasks) != napi_ok) return false;
    for (uint32_t index = 0; index < length; index++) {
        napi_value source;
        if (napi_get_element(env, source_tasks, index, &source) != napi_ok) return false;
        napi_value task = CreateTaskObject(env, source);
        if (task == nullptr || napi_set_element(env, tasks, index, task) != napi_ok) return false;
    }
    return napi_set_named_property(env, result, "tasks", tasks) == napi_ok;
}

bool ProjectFileResult(napi_env env, napi_value files)
{
    uint32_t length = 0;
    if (napi_get_array_length(env, files, &length) != napi_ok) return false;
    for (uint32_t index = 0; index < length; index++) {
        napi_value metadata, project_name, category, task_state_counts;
        if (napi_get_element(env, files, index, &metadata) != napi_ok ||
            napi_get_named_property(env, metadata, "projectName", &project_name) != napi_ok ||
            napi_get_named_property(env, metadata, "category", &category) != napi_ok ||
            napi_get_named_property(env, metadata, "taskStateCounts", &task_state_counts) != napi_ok) return false;
        napi_value options, priorities, key; bool deleted;
        auto* states = new MetadataStates();
        if (napi_get_named_property(env, metadata, "taskStateOptions", &options) != napi_ok ||
            napi_create_reference(env, options, 1, &states->options) != napi_ok ||
            napi_get_named_property(env, metadata, "taskPriorityOptions", &priorities) != napi_ok ||
            napi_create_reference(env, priorities, 1, &states->priorities) != napi_ok ||
            napi_wrap(env, metadata, states, FinalizeMetadataStates, nullptr, nullptr) != napi_ok) {
            FinalizeMetadataStates(env, states, nullptr); return false;
        }
        if (napi_create_string_utf8(env, "taskStateOptions", NAPI_AUTO_LENGTH, &key) != napi_ok ||
            napi_delete_property(env, metadata, key, &deleted) != napi_ok) return false;
        if (napi_create_string_utf8(env, "taskPriorityOptions", NAPI_AUTO_LENGTH, &key) != napi_ok ||
            napi_delete_property(env, metadata, key, &deleted) != napi_ok) return false;
        napi_property_descriptor properties[] = {
            {"taskPriorityOf", nullptr, MetadataTaskPriorityOf, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"taskStateOf", nullptr, MetadataTaskStateOf, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"projectName", nullptr, nullptr, nullptr, nullptr, project_name, napi_enumerable, nullptr},
            {"category", nullptr, nullptr, nullptr, nullptr, category, napi_enumerable, nullptr},
            // 状态、分类与计数来自 Core 同次文件快照，嵌套数组原样透传。
            {"taskStateCounts", nullptr, nullptr, nullptr, nullptr, task_state_counts, napi_enumerable, nullptr},
            {"project", nullptr, SnapshotProject, nullptr, nullptr, nullptr, napi_default, nullptr},
        };
        if (napi_define_properties(env, metadata, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) return false;
    }
    return true;
}

bool ProjectQueryResults(napi_env env, napi_value results)
{
    uint32_t length = 0;
    if (napi_get_array_length(env, results, &length) != napi_ok) return false;
    for (uint32_t index = 0; index < length; index++) {
        napi_value item, type, result;
        std::string kind;
        if (napi_get_element(env, results, index, &item) != napi_ok ||
            napi_get_named_property(env, item, "type", &type) != napi_ok || !ReadString(env, type, &kind) ||
            napi_get_named_property(env, item, "result", &result) != napi_ok) return false;
        if (kind == "task") { if (!ProjectTaskResult(env, result)) return false; }
        else if (kind == "file") { if (!ProjectFileResult(env, result)) return false; }
        else if (kind != "notification") return false;
    }
    return true;
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

struct DataChangeWatch { napi_threadsafe_function function = nullptr; };
void FinalizeDataChangeWatch(napi_env, void* data, void*) { delete static_cast<DataChangeWatch*>(data); }
extern "C" void org_tasks_harmony_data_change_update(uint64_t handle, const char* json)
{
    auto* watch = reinterpret_cast<DataChangeWatch*>(static_cast<uintptr_t>(handle));
    if (watch == nullptr || json == nullptr) return;
    auto* data = new std::string(json);
    if (napi_call_threadsafe_function(watch->function, data, napi_tsfn_nonblocking) != napi_ok) delete data;
}
extern "C" void org_tasks_harmony_data_change_monitor_release(uint64_t handle)
{
    auto* watch = reinterpret_cast<DataChangeWatch*>(static_cast<uintptr_t>(handle));
    if (watch != nullptr) napi_release_threadsafe_function(watch->function, napi_tsfn_release);
}

void FinalizePreview(napi_env env, void* data, void*)
{
    auto* preview = static_cast<PreviewWrap*>(data);
    if (preview->handle != 0) {
        org_tasks_harmony_preview_release(preview->handle, preview->id.c_str());
        org_tasks_harmony_workspace_release(preview->handle);
    }
    if (preview->data != nullptr) napi_delete_reference(env, preview->data);
    delete preview;
}

napi_value PreviewConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2], self, id;
    auto* preview = new PreviewWrap();
    bool retained = false;
    bool valid = napi_get_cb_info(env, info, &argc, args, &self, nullptr) == napi_ok && argc == 2 &&
        ReadHandle(env, args[1], &preview->handle) &&
        napi_get_named_property(env, args[0], "id", &id) == napi_ok && ReadString(env, id, &preview->id);
    if (valid) { retained = org_tasks_harmony_workspace_retain(preview->handle); valid = retained; }
    if (valid) valid = napi_create_reference(env, args[0], 1, &preview->data) == napi_ok &&
        napi_wrap(env, self, preview, FinalizePreview, nullptr, nullptr) == napi_ok;
    if (!valid) {
        if (!retained) preview->handle = 0;
        FinalizePreview(env, preview, nullptr);
        napi_throw_error(env, nullptr, "无法创建 ConflictPreview 对象"); return nullptr;
    }
    return self;
}

napi_value PreviewProperty(napi_env env, napi_callback_info info)
{
    napi_value self, data, value; void* property = nullptr; PreviewWrap* preview = nullptr;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, &property) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&preview)) != napi_ok || preview == nullptr ||
        napi_get_reference_value(env, preview->data, &data) != napi_ok ||
        napi_get_named_property(env, data, static_cast<const char*>(property), &value) != napi_ok) {
        napi_throw_error(env, nullptr, "预览对象无效"); return nullptr;
    }
    return value;
}

napi_value CreatePreviewObject(napi_env env, napi_value data, uint64_t handle)
{
    napi_value constructor, result, args[2] = {data, nullptr};
    if (napi_create_double(env, static_cast<double>(handle), &args[1]) != napi_ok ||
        napi_get_reference_value(env, preview_constructor, &constructor) != napi_ok ||
        napi_new_instance(env, constructor, 2, args, &result) != napi_ok) return nullptr;
    return result;
}

napi_value OrgFileConflicts(napi_env env, napi_callback_info info)
{
    // FileConflict 的候选 HTML 与主树展示锚点由 Core 编码，保持结构化字段原样透传。
    napi_value self, data, message, value; OrgFileWrap* file = nullptr; std::string error;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&file)) != napi_ok || file == nullptr ||
        napi_get_reference_value(env, file->data, &data) != napi_ok) return nullptr;
    napi_valuetype error_type = napi_undefined;
    if (napi_get_named_property(env, data, "conflictError", &message) == napi_ok &&
        napi_typeof(env, message, &error_type) == napi_ok && error_type == napi_object) {
        napi_value code_value, message_value; std::string code = "invalidState";
        if (napi_get_named_property(env, message, "code", &code_value) == napi_ok) ReadString(env, code_value, &code);
        if (napi_get_named_property(env, message, "message", &message_value) == napi_ok) ReadString(env, message_value, &error);
        napi_throw_error(env, code.c_str(), error.c_str()); return nullptr;
    }
    if (napi_get_named_property(env, data, "conflicts", &value) != napi_ok) return nullptr;
    return value;
}

bool SameTaskPath(napi_env env, napi_value a, napi_value b)
{
    for (const char* key : {"repoId", "file", "titles"}) {
        napi_value av, bv; std::string as, bs;
        if (napi_get_named_property(env, a, key, &av) != napi_ok || napi_get_named_property(env, b, key, &bv) != napi_ok ||
            !EncodeJson(env, av, &as) || !EncodeJson(env, bv, &bs) || as != bs) return false;
    }
    napi_value av, bv; uint32_t ai = 1, bi = 1;
    if (napi_get_named_property(env, a, "occurrence", &av) == napi_ok) napi_get_value_uint32(env, av, &ai);
    if (napi_get_named_property(env, b, "occurrence", &bv) == napi_ok) napi_get_value_uint32(env, bv, &bi);
    return ai == bi;
}

napi_value OrgFileNodes(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1], self, data, nodes, output; void* method = nullptr; OrgFileWrap* file = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, &method) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&file)) != napi_ok || file == nullptr ||
        napi_get_reference_value(env, file->data, &data) != napi_ok ||
        napi_get_named_property(env, data, "nodes", &nodes) != napi_ok) return nullptr;
    const bool single = std::string(static_cast<const char*>(method)) == "node";
    uint32_t length = 0; if (napi_get_array_length(env, nodes, &length) != napi_ok) return nullptr;
    if (single && argc != 1) { napi_throw_error(env, nullptr, "node 需要完整路径"); return nullptr; }
    if (!single && napi_create_array_with_length(env, length, &output) != napi_ok) return nullptr;
    for (uint32_t i = 0; i < length; i++) {
        napi_value node, path; if (napi_get_element(env, nodes, i, &node) != napi_ok) return nullptr;
        if (single) {
            if (napi_get_named_property(env, node, "fullPath", &path) == napi_ok && SameTaskPath(env, args[0], path)) return CreateTaskObject(env, node);
        } else {
            napi_value task = CreateTaskObject(env, node);
            if (task == nullptr || napi_set_element(env, output, i, task) != napi_ok) return nullptr;
        }
    }
    if (single) { napi_throw_error(env, nullptr, "标题路径已失效，请重新读取"); return nullptr; }
    return output;
}

void ExecuteWorkspaceString(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceStringWork*>(data);
    if (!work->preview_action.empty()) {
        work->response = TakeRustString(org_tasks_harmony_preview_operation(work->handle, work->expression.c_str()));
    } else if (work->watch_notifications) {
        uint64_t monitor = work->monitor_handle;
        work->monitor_handle = 0; // Rust 接管，即使注册失败也负责释放。
        work->subscription_id = org_tasks_harmony_workspace_watch_notifications(work->handle, monitor);
        if (work->subscription_id != 0) work->response = "{}";
    } else if (work->watch_data_changes) {
        uint64_t monitor = work->monitor_handle;
        work->monitor_handle = 0;
        work->subscription_id = org_tasks_harmony_workspace_watch_data_changes(work->handle, monitor);
        if (work->subscription_id != 0) work->response = std::to_string(work->subscription_id);
    } else if (work->reload) {
        if (org_tasks_harmony_workspace_reload(work->handle) == 0) work->response = "{}";

    } else if (work->refile_targets) {
        work->response = TakeRustString(org_tasks_harmony_workspace_refile_targets(work->handle, work->expression.c_str()));
    } else if (work->execute_operations) {
        work->response = TakeRustString(org_tasks_harmony_workspace_execute_task_operations(work->handle, work->expression.c_str()));
    } else if (work->merge_operations) {
        work->response = TakeRustString(org_tasks_harmony_workspace_task_merge_operations(work->handle, work->expression.c_str()));
    } else if (work->get_settings) {
        work->response = TakeRustString(org_tasks_harmony_workspace_get_settings(work->handle));
    } else if (work->set_settings) {
        if (org_tasks_harmony_workspace_set_settings(work->handle, work->expression.c_str()) == 0) work->response = "{}";
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
        } else if (work->watch_data_changes) {
            napi_create_uint32(env, static_cast<uint32_t>(work->subscription_id), &result);
            WorkspaceWrap* workspace = nullptr;
            napi_value owner;
            if (napi_get_reference_value(env, work->owner, &owner) == napi_ok &&
                napi_unwrap(env, owner, reinterpret_cast<void**>(&workspace)) == napi_ok &&
                workspace != nullptr) {
                workspace->data_change_subscriptions.push_back(work->subscription_id);
                work->subscription_id = 0;
            }
            napi_resolve_deferred(env, work->deferred, result);
        } else if (work->todo_defaults || work->set_settings || work->reload) {
            napi_get_undefined(env, &result);
            napi_resolve_deferred(env, work->deferred, result);
        } else if (!ParseJson(env, work->response, &result)) {
            napi_value text;
            napi_create_string_utf8(env, "core workspace 响应格式无效", NAPI_AUTO_LENGTH, &text);
            napi_value error;
            napi_create_error(env, nullptr, text, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else if (work->execute_operations) {
            napi_get_undefined(env, &result);
            napi_resolve_deferred(env, work->deferred, result);
        } else if (work->merge_operations) {
            napi_resolve_deferred(env, work->deferred, result);
        } else if (!work->preview_action.empty()) {
            napi_value projected = result;
            if (work->preview_action == "create") projected = CreatePreviewObject(env, result, work->handle);
            else if (work->preview_action == "file" || work->preview_action == "sourceFile" || work->preview_action == "fileAt") projected = CreateOrgFileObject(env, result);
            if (projected != nullptr) napi_resolve_deferred(env, work->deferred, projected);
            else RejectFileProjection(env, work->deferred);
        } else if (!work->refile_targets && !work->get_settings && !work->default_todo_settings && !work->default_sync_options && !work->normalize_sync_options) {
            if (ProjectQueryResults(env, result)) napi_resolve_deferred(env, work->deferred, result);
            else RejectFileProjection(env, work->deferred);
        } else {
            // REFILE 目标完整透传 Core 快照，保留 projectName 的 null 与空字符串语义。
            napi_resolve_deferred(env, work->deferred, result);
        }
    }
    if (work->subscription_id != 0) {
        if (work->watch_data_changes) org_tasks_harmony_workspace_unwatch_data_changes(work->subscription_id);
        else org_tasks_harmony_workspace_unwatch_notifications(work->subscription_id);
    }
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
        case RepoSnapshotWork::Operation::File:
            work->response = TakeRustString(org_tasks_harmony_repo_file(work->workspace_handle,
                work->root_directory.c_str(), work->task_path.c_str()));
            break;
        case RepoSnapshotWork::Operation::Conflicts:
            work->response = TakeRustString(org_tasks_harmony_repo_conflicts(
                work->workspace_handle, work->root_directory.c_str()));
            break;
        case RepoSnapshotWork::Operation::Snapshot:
            work->response = TakeRustString(org_tasks_harmony_repo_load_files(
                work->workspace_handle, work->root_directory.c_str(), work->task_json.c_str()));
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
        } else if (work->operation == RepoSnapshotWork::Operation::HistoryDetail) {
            napi_value files, backups; uint32_t length = 0, count = 0; bool valid = true;
            if (napi_get_named_property(env, result, "files", &files) != napi_ok ||
                napi_get_array_length(env, files, &length) != napi_ok || napi_create_array(env, &backups) != napi_ok) valid = false;
            for (uint32_t index = 0; valid && index < length; index++) {
                napi_value file, backup; napi_valuetype type;
                if (napi_get_element(env, files, index, &file) != napi_ok ||
                    napi_get_named_property(env, file, "backup", &backup) != napi_ok || napi_typeof(env, backup, &type) != napi_ok) { valid = false; break; }
                if (type != napi_null && napi_set_element(env, backups, count++, backup) != napi_ok) valid = false;
            }
            if (valid && ProjectFileResult(env, backups)) napi_resolve_deferred(env, work->deferred, result);
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

napi_value WorkspaceGetSettings(napi_env env, napi_callback_info info)
{
    napi_value self; WorkspaceWrap* workspace = nullptr;
    if (napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr) != napi_ok ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "Workspace.getSettings 对象无效"); return nullptr;
    }
    auto* work = new WorkspaceStringWork(); work->handle = workspace->handle; work->get_settings = true;
    return QueueWorkspaceString(env, work, "OrgTasksGetSettings", self);
}

napi_value WorkspaceSetSettings(napi_env env, napi_callback_info info)
{
    napi_value self; size_t argc = 1; napi_value args[1] = {nullptr}; WorkspaceWrap* workspace = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "Workspace.setSettings 参数无效"); return nullptr;
    }
    auto* work = new WorkspaceStringWork(); work->handle = workspace->handle; work->set_settings = true;
    if (!EncodeJson(env, args[0], &work->expression)) { delete work; napi_throw_error(env, nullptr, "CoreSettings 参数无效"); return nullptr; }
    return QueueWorkspaceString(env, work, "OrgTasksSetSettings", self);
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
napi_value WorkspaceWatchDataChanges(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1], self, name;
    WorkspaceWrap* workspace = nullptr;
    napi_valuetype type;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_typeof(env, args[0], &type) != napi_ok || type != napi_function ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "数据变化监控需要回调函数"); return nullptr;
    }
    auto* watch = new DataChangeWatch();
    if (napi_create_string_utf8(env, "OrgTasksDataChangeMonitor", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_threadsafe_function(env, args[0], nullptr, name, 0, 1, watch, FinalizeDataChangeWatch,
            nullptr, CallWebDavSyncMonitor, &watch->function) != napi_ok) {
        delete watch; napi_throw_error(env, nullptr, "无法创建数据变化监控"); return nullptr;
    }
    napi_unref_threadsafe_function(env, watch->function);
    auto* work = new WorkspaceStringWork();
    work->handle = workspace->handle;
    work->watch_data_changes = true;
    work->monitor_handle = reinterpret_cast<uintptr_t>(watch);
    return QueueWorkspaceString(env, work, "OrgTasksWatchDataChanges", self);
}
napi_value WorkspaceStopWatchingDataChanges(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1], result;
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    uint64_t subscription = 0;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        !ReadHandle(env, args[0], &subscription) ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "数据变化订阅 ID 无效"); return nullptr;
    }
    org_tasks_harmony_workspace_unwatch_data_changes(subscription);
    auto it = std::find(workspace->data_change_subscriptions.begin(), workspace->data_change_subscriptions.end(), subscription);
    if (it != workspace->data_change_subscriptions.end()) workspace->data_change_subscriptions.erase(it);
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


napi_value WorkspaceRefileTargets(napi_env env, napi_callback_info info)
{
    // titleParts 与目标路径通过既有工作线程的 JSON 响应完整透传。
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


napi_value PreviewRequest(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1], self, request, name, id; void* data = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, &self, &data) != napi_ok || data == nullptr) return nullptr;
    const std::string operation(static_cast<const char*>(data));
    auto* work = new WorkspaceStringWork(); work->preview_action = operation;
    if (napi_create_object(env, &request) != napi_ok || napi_create_string_utf8(env, operation.c_str(), NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_set_named_property(env, request, "operation", name) != napi_ok) { delete work; return nullptr; }
    const bool workspace_method = operation == "create" || operation == "configure" || operation == "fileAt";
    if (workspace_method) {
        WorkspaceWrap* workspace = nullptr;
        if (argc != 1 || napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
            delete work; napi_throw_error(env, nullptr, "预览请求参数无效"); return nullptr;
        }
        work->handle = workspace->handle;
        const char* field = operation == "create" ? "request" : operation == "configure" ? "root" : "path";
        if (napi_set_named_property(env, request, field, args[0]) != napi_ok) { delete work; return nullptr; }
    } else {
        PreviewWrap* preview = nullptr;
        if (napi_unwrap(env, self, reinterpret_cast<void**>(&preview)) != napi_ok || preview == nullptr ||
            ((operation == "finish" || operation == "project") && argc != 1)) { delete work; napi_throw_error(env, nullptr, "预览对象或参数无效"); return nullptr; }
        work->handle = preview->handle;
        if (napi_create_string_utf8(env, preview->id.c_str(), NAPI_AUTO_LENGTH, &id) != napi_ok ||
            napi_set_named_property(env, request, "previewId", id) != napi_ok ||
            (operation == "finish" && napi_set_named_property(env, request, "options", args[0]) != napi_ok) ||
            (operation == "project" && napi_set_named_property(env, request, "request", args[0]) != napi_ok)) { delete work; return nullptr; }
    }
    if (!EncodeJson(env, request, &work->expression)) { delete work; napi_throw_error(env, nullptr, "预览参数无法编组"); return nullptr; }
    return QueueWorkspaceString(env, work, "OrgTasksConflictPreview", self);
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

napi_value WorkspaceTaskMergeOperations(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr; napi_value self; size_t argc = 1; napi_value args[1];
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace == nullptr) {
        napi_throw_error(env, nullptr, "Workspace.taskMergeOperations 参数无效"); return nullptr;
    }
    auto* work = new WorkspaceStringWork(); work->handle = workspace->handle; work->merge_operations = true;
    if (!EncodeJson(env, args[0], &work->expression)) { delete work; napi_throw_error(env, nullptr, "记录合并参数无效"); return nullptr; }
    return QueueWorkspaceString(env, work, "OrgTasksTaskMergeOperations", self);
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

napi_value RepoLoadFiles(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* work = new RepoSnapshotWork();
    work->task_json = "[]";
    if (argc == 1) {
        napi_valuetype argument_type;
        bool is_array = false;
        if (napi_typeof(env, args[0], &argument_type) != napi_ok ||
            (argument_type != napi_undefined &&
             (napi_is_array(env, args[0], &is_array) != napi_ok || !is_array || !EncodeJson(env, args[0], &work->task_json)))) {
            delete work;
            napi_throw_type_error(env, nullptr, "Repo.loadFiles 需要仓库相对路径数组");
            return nullptr;
        }
    }
    work->workspace_handle = repo->workspace_handle;
    work->root_directory = repo->root_directory;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建文件读取 Promise");
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
        napi_throw_error(env, nullptr, "无法调度文件读取请求");
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
    // triggerReason 与过滤规则作为结构化参数透传，由 Core 校验枚举并写入历史。
    if (argc == 3 && (napi_typeof(env, args[2], &options_type) != napi_ok ||
        (options_type != napi_undefined && (options_type != napi_object ||
            !EncodeJson(env, args[2], &work->sync_options_json))))) {
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
        // 原型允许拷贝器以赋值建立同名实例函数；正式快照上的绑定函数仍只读。
        {"taskPriorityOf", nullptr, TaskTaskPriorityOf, nullptr, nullptr, nullptr, napi_default_method, nullptr},
        {"taskStateOf", nullptr, TaskTaskStateOf, nullptr, nullptr, nullptr, napi_default_method, nullptr},
        {"isDone", nullptr, TaskIsDone, nullptr, nullptr, nullptr, napi_default_method, nullptr},
        {"project", nullptr, SnapshotProject, nullptr, nullptr, nullptr, napi_default_method, nullptr},
    };
    napi_value task_class;
    napi_define_class(env, "Task", NAPI_AUTO_LENGTH, TaskConstructor, nullptr,
        sizeof(task_descriptors) / sizeof(task_descriptors[0]), task_descriptors, &task_class);
    napi_create_reference(env, task_class, 1, &task_constructor);
    napi_set_named_property(env, exports, "Task", task_class);
    napi_property_descriptor file_descriptors[] = {
        {"conflicts", nullptr, OrgFileConflicts, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nodes", nullptr, OrgFileNodes, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("nodes")},
        {"node", nullptr, OrgFileNodes, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("node")},
        {"insertionPositions", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("insertionPositions")},
        {"editableNodePaths", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("editableNodePaths")},
        {"fullPath", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("fullPath")},
        {"fileVersion", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("fileVersion")},
        {"repoId", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("repoId")},
        {"path", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("path")},
        {"todo", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("todo")},
        {"category", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("category")},
        {"title", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("title")},
        {"titleParts", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("titleParts")},
        {"hasConflict", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("hasConflict")},
        {"conflictIds", nullptr, nullptr, OrgFileProperty, nullptr, nullptr, napi_default, const_cast<char*>("conflictIds")},
        {"project", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("projectName")},
        {"renderDocumentHtml", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("documentHtml")},
        {"documentSections", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("documentSections")},
        {"fileTags", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("fileTags")},
        {"specialTags", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("specialTags")},
        {"renderHtml", nullptr, OrgFileProperty, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("renderedHtml")},
        {"sourceBytes", nullptr, OrgFileSourceBytes, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value file_class;
    napi_define_class(env, "OrgFile", NAPI_AUTO_LENGTH, OrgFileConstructor, nullptr,
        sizeof(file_descriptors) / sizeof(file_descriptors[0]), file_descriptors, &file_class);
    napi_create_reference(env, file_class, 1, &file_constructor);
    napi_set_named_property(env, exports, "OrgFile", file_class);
    napi_property_descriptor preview_descriptors[] = {
        {"id", nullptr, nullptr, PreviewProperty, nullptr, nullptr, napi_default, const_cast<char*>("id")},
        {"sourcePath", nullptr, nullptr, PreviewProperty, nullptr, nullptr, napi_default, const_cast<char*>("sourcePath")},
        {"sourceVersion", nullptr, nullptr, PreviewProperty, nullptr, nullptr, napi_default, const_cast<char*>("sourceVersion")},
        {"conflictId", nullptr, nullptr, PreviewProperty, nullptr, nullptr, napi_default, const_cast<char*>("conflictId")},
        {"fullPath", nullptr, nullptr, PreviewProperty, nullptr, nullptr, napi_default, const_cast<char*>("fullPath")},
        {"file", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("file")},
        {"sourceFile", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("sourceFile")},
        {"conflicts", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("conflicts")},
        {"changes", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("changes")},
        {"project", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("project")},
        {"finish", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("finish")},
        {"discard", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("discard")},
    };
    napi_value preview_class;
    napi_define_class(env, "ConflictPreview", NAPI_AUTO_LENGTH, PreviewConstructor, nullptr,
        sizeof(preview_descriptors) / sizeof(preview_descriptors[0]), preview_descriptors, &preview_class);
    napi_create_reference(env, preview_class, 1, &preview_constructor);
    napi_set_named_property(env, exports, "ConflictPreview", preview_class);
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
        {"setPreviewRoot", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("configure")},
        {"createConflictPreview", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("create")},
        {"fileAt", nullptr, PreviewRequest, nullptr, nullptr, nullptr, napi_default, const_cast<char*>("fileAt")},
        {"getSettings", nullptr, WorkspaceGetSettings, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSettings", nullptr, WorkspaceSetSettings, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTodoDefaults", nullptr, WorkspaceSetTodoDefaults, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"repos", nullptr, WorkspaceRepos, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"addRepo", nullptr, WorkspaceAddRepo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeRepo", nullptr, WorkspaceRemoveRepo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"refileTargets", nullptr, WorkspaceRefileTargets, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"executeTaskOperations", nullptr, WorkspaceExecuteTaskOperations, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"taskMergeOperations", nullptr, WorkspaceTaskMergeOperations, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"query", nullptr, WorkspaceQuery, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"watchNotifications", nullptr, WorkspaceWatchNotifications, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopWatchingNotifications", nullptr, WorkspaceStopWatchingNotifications, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"watchDataChanges", nullptr, WorkspaceWatchDataChanges, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopWatchingDataChanges", nullptr, WorkspaceStopWatchingDataChanges, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reload", nullptr, WorkspaceReload, nullptr, nullptr, nullptr, napi_default, nullptr},
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
        {"loadFiles", nullptr, RepoLoadFiles, nullptr, nullptr, nullptr, napi_default, nullptr},
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
