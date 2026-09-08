#include <cstdint>
#include <chrono>
#include <string>
#include <vector>

#include "napi/native_api.h"

extern "C" int32_t org_tasks_harmony_initialize(const char* data_dir);
extern "C" int32_t org_tasks_harmony_record_sync(const char* repo_id, const char* record_id,
    int64_t started_at, int64_t finished_at, bool succeeded);
extern "C" void org_tasks_harmony_free_string(char* value);
extern "C" uint64_t org_tasks_harmony_workspace_open(const char* root_directory);
extern "C" bool org_tasks_harmony_workspace_retain(uint64_t handle);
extern "C" void org_tasks_harmony_workspace_release(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_repo_ids(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_snapshot(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_search(uint64_t handle, const char* expression);
extern "C" char* org_tasks_harmony_workspace_sync_webdav(uint64_t handle, const char* webdav_url,
    const char* username, const char* password, int64_t started_at);
extern "C" char* org_tasks_harmony_repo_snapshot(uint64_t workspace_handle, const char* repo_id);

namespace {
struct InitializeWork {
    std::string data_dir;
    int32_t result = -2;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct RecordSyncWork {
    std::string repo_id;
    std::string record_id;
    int64_t started_at = 0;
    int64_t finished_at = 0;
    bool succeeded = false;
    int32_t result = -2;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceWrap {
    uint64_t handle = 0;
};

struct RepoWrap {
    uint64_t workspace_handle = 0;
    std::string id;
};

struct OpenWorkspaceWork {
    std::string root_directory;
    uint64_t handle = 0;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceStringWork {
    uint64_t handle = 0;
    std::string first;
    std::string second;
    std::string third;
    int64_t started_at = 0;
    std::string response;
    enum class Operation { Snapshot, Search, Sync } operation = Operation::Snapshot;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceReposWork {
    uint64_t handle = 0;
    std::vector<std::string> ids;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct RepoSnapshotWork {
    uint64_t workspace_handle = 0;
    std::string id;
    std::string response;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

napi_ref workspace_constructor = nullptr;
napi_ref repo_constructor = nullptr;

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

napi_value CreateWorkspaceObject(napi_env env, uint64_t handle)
{
    napi_value constructor;
    if (napi_get_reference_value(env, workspace_constructor, &constructor) != napi_ok) {
        return nullptr;
    }
    napi_value argument;
    napi_create_double(env, static_cast<double>(handle), &argument);
    napi_value object;
    if (napi_new_instance(env, constructor, 1, &argument, &object) != napi_ok) {
        return nullptr;
    }
    return object;
}

napi_value CreateRepoObject(napi_env env, uint64_t workspace_handle, const std::string& id)
{
    napi_value constructor;
    if (napi_get_reference_value(env, repo_constructor, &constructor) != napi_ok) {
        return nullptr;
    }
    napi_value arguments[2];
    napi_create_double(env, static_cast<double>(workspace_handle), &arguments[0]);
    napi_create_string_utf8(env, id.c_str(), id.size(), &arguments[1]);
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

void ResolveOrReject(napi_env env, napi_status status, int32_t result, napi_deferred deferred,
    const char* message)
{
    if (status != napi_ok || result != 0) {
        napi_value text;
        napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, deferred, error);
        return;
    }
    napi_value value;
    napi_create_int32(env, result, &value);
    napi_resolve_deferred(env, deferred, value);
}

void ExecuteInitialize(napi_env, void* data)
{
    auto* work = static_cast<InitializeWork*>(data);
    work->result = org_tasks_harmony_initialize(work->data_dir.c_str());
}

void CompleteInitialize(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<InitializeWork*>(data);
    ResolveOrReject(env, status, work->result, work->deferred, "Rust 同步记录服务初始化失败");
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteRecordSync(napi_env, void* data)
{
    auto* work = static_cast<RecordSyncWork*>(data);
    work->result = org_tasks_harmony_record_sync(work->repo_id.c_str(), work->record_id.c_str(),
        work->started_at, work->finished_at, work->succeeded);
}

void CompleteRecordSync(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<RecordSyncWork*>(data);
    ResolveOrReject(env, status, work->result, work->deferred, "Rust 同步记录服务未能保存同步结果");
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteOpenWorkspace(napi_env, void* data)
{
    auto* work = static_cast<OpenWorkspaceWork*>(data);
    work->handle = org_tasks_harmony_workspace_open(work->root_directory.c_str());
}

void CompleteOpenWorkspace(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<OpenWorkspaceWork*>(data);
    if (status != napi_ok || work->handle == 0) {
        napi_value text;
        napi_create_string_utf8(env, "core workspace 打开失败", NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value workspace = CreateWorkspaceObject(env, work->handle);
        if (workspace == nullptr) {
            org_tasks_harmony_workspace_release(work->handle);
            napi_value text;
            napi_create_string_utf8(env, "无法创建 Workspace 对象", NAPI_AUTO_LENGTH, &text);
            napi_value error;
            napi_create_error(env, nullptr, text, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else {
            napi_resolve_deferred(env, work->deferred, workspace);
        }
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteWorkspaceString(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceStringWork*>(data);
    switch (work->operation) {
        case WorkspaceStringWork::Operation::Snapshot:
            work->response = TakeRustString(org_tasks_harmony_workspace_snapshot(work->handle));
            break;
        case WorkspaceStringWork::Operation::Search:
            work->response = TakeRustString(org_tasks_harmony_workspace_search(work->handle, work->first.c_str()));
            break;
        case WorkspaceStringWork::Operation::Sync:
            work->response = TakeRustString(org_tasks_harmony_workspace_sync_webdav(
                work->handle, work->first.c_str(), work->second.c_str(), work->third.c_str(), work->started_at));
            break;
    }
}

void CompleteWorkspaceString(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceStringWork*>(data);
    if (status != napi_ok || work->response.empty()) {
        napi_value text;
        napi_create_string_utf8(env, "core workspace 操作失败", NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result;
        napi_create_string_utf8(env, work->response.c_str(), work->response.size(), &result);
        napi_resolve_deferred(env, work->deferred, result);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteWorkspaceRepos(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceReposWork*>(data);
    std::string ids = TakeRustString(org_tasks_harmony_workspace_repo_ids(work->handle));
    size_t start = 0;
    while (start < ids.size()) {
        const size_t end = ids.find('\n', start);
        const size_t length = (end == std::string::npos ? ids.size() : end) - start;
        if (length > 0) {
            work->ids.push_back(ids.substr(start, length));
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
}

void CompleteWorkspaceRepos(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceReposWork*>(data);
    if (status != napi_ok) {
        napi_value text;
        napi_create_string_utf8(env, "读取 workspace 仓库失败", NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result;
        napi_create_array_with_length(env, work->ids.size(), &result);
        for (size_t index = 0; index < work->ids.size(); ++index) {
            if (!org_tasks_harmony_workspace_retain(work->handle)) {
                continue;
            }
            napi_value repo = CreateRepoObject(env, work->handle, work->ids[index]);
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
    work->response = TakeRustString(org_tasks_harmony_repo_snapshot(work->workspace_handle, work->id.c_str()));
}

void CompleteRepoSnapshot(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<RepoSnapshotWork*>(data);
    if (status != napi_ok || work->response.empty()) {
        napi_value text;
        napi_create_string_utf8(env, "读取 Repo 快照失败", NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result;
        napi_create_string_utf8(env, work->response.c_str(), work->response.size(), &result);
        napi_resolve_deferred(env, work->deferred, result);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value Initialize(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_error(env, nullptr, "initialize 需要 1 个参数");
        return nullptr;
    }
    auto* work = new InitializeWork();
    if (!ReadString(env, args[0], &work->data_dir)) {
        delete work;
        napi_throw_error(env, nullptr, "initialize 参数无效");
        return nullptr;
    }
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 initialize Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksInitialize", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteInitialize, CompleteInitialize, work, &work->work) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Rust 初始化任务");
        return nullptr;
    }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Rust 初始化任务");
        return nullptr;
    }
    return promise;
}

napi_value RecordSync(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 5) {
        napi_throw_error(env, nullptr, "recordSync 需要 5 个参数");
        return nullptr;
    }
    auto* work = new RecordSyncWork();
    double started_at = 0;
    double finished_at = 0;
    if (!ReadString(env, args[0], &work->repo_id) || !ReadString(env, args[1], &work->record_id) ||
        napi_get_value_double(env, args[2], &started_at) != napi_ok ||
        napi_get_value_double(env, args[3], &finished_at) != napi_ok ||
        napi_get_value_bool(env, args[4], &work->succeeded) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "recordSync 参数无效");
        return nullptr;
    }
    work->started_at = static_cast<int64_t>(started_at);
    work->finished_at = static_cast<int64_t>(finished_at);

    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 recordSync Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksRecordSync", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRecordSync, CompleteRecordSync, work, &work->work) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Rust 同步记录任务");
        return nullptr;
    }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Rust 同步记录任务");
        return nullptr;
    }
    return promise;
}

napi_value WorkspaceConstructor(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1) {
        napi_throw_error(env, nullptr, "Workspace 不能直接构造");
        return nullptr;
    }
    auto* workspace = new WorkspaceWrap();
    if (!ReadHandle(env, args[0], &workspace->handle) ||
        napi_wrap(env, self, workspace, FinalizeWorkspace, nullptr, nullptr) != napi_ok) {
        delete workspace;
        napi_throw_error(env, nullptr, "Workspace handle 无效");
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
    if (!ReadHandle(env, args[0], &repo->workspace_handle) || !ReadString(env, args[1], &repo->id) ||
        napi_wrap(env, self, repo, FinalizeRepo, nullptr, nullptr) != napi_ok) {
        delete repo;
        napi_throw_error(env, nullptr, "Repo handle 无效");
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

napi_value QueueWorkspaceString(napi_env env, WorkspaceStringWork* work, const char* name)
{
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Workspace Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWorkspaceString, CompleteWorkspaceString, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace 请求");
        return nullptr;
    }
    return promise;
}

napi_value OpenWorkspace(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_error(env, nullptr, "openWorkspace 需要 1 个参数");
        return nullptr;
    }
    auto* work = new OpenWorkspaceWork();
    if (!ReadString(env, args[0], &work->root_directory)) {
        delete work;
        napi_throw_error(env, nullptr, "openWorkspace 参数无效");
        return nullptr;
    }
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 openWorkspace Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksOpenWorkspace", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteOpenWorkspace, CompleteOpenWorkspace, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace 打开任务");
        return nullptr;
    }
    return promise;
}

napi_value WorkspaceSnapshot(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (!UnwrapWorkspace(env, info, &workspace, &self)) return nullptr;
    auto* work = new WorkspaceStringWork();
    work->handle = workspace->handle;
    work->operation = WorkspaceStringWork::Operation::Snapshot;
    return QueueWorkspaceString(env, work, "OrgTasksWorkspaceSnapshot");
}

napi_value WorkspaceSearch(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace.search 参数无效");
        return nullptr;
    }
    auto* work = new WorkspaceStringWork();
    if (!ReadString(env, args[0], &work->first)) {
        delete work;
        napi_throw_error(env, nullptr, "Workspace.search 表达式无效");
        return nullptr;
    }
    work->handle = workspace->handle;
    work->operation = WorkspaceStringWork::Operation::Search;
    return QueueWorkspaceString(env, work, "OrgTasksWorkspaceSearch");
}

napi_value WorkspaceSyncWebDav(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 3 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&workspace)) != napi_ok || workspace->handle == 0) {
        napi_throw_error(env, nullptr, "Workspace.syncWebDav 参数无效");
        return nullptr;
    }
    auto* work = new WorkspaceStringWork();
    if (!ReadString(env, args[0], &work->first) || !ReadString(env, args[1], &work->second) ||
        !ReadString(env, args[2], &work->third)) {
        delete work;
        napi_throw_error(env, nullptr, "Workspace.syncWebDav 参数无效");
        return nullptr;
    }
    work->handle = workspace->handle;
    work->started_at = static_cast<int64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
    work->operation = WorkspaceStringWork::Operation::Sync;
    return QueueWorkspaceString(env, work, "OrgTasksWorkspaceSyncWebDav");
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
    napi_value id;
    napi_create_string_utf8(env, repo->id.c_str(), repo->id.size(), &id);
    return id;
}

napi_value RepoSnapshot(napi_env env, napi_callback_info info)
{
    RepoWrap* repo = nullptr;
    napi_value self;
    if (!UnwrapRepo(env, info, &repo, &self)) return nullptr;
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->id = repo->id;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Repo.snapshot Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksRepoSnapshot", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Repo.snapshot 请求");
        return nullptr;
    }
    return promise;
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor workspace_descriptors[] = {
        {"repos", nullptr, WorkspaceRepos, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshot", nullptr, WorkspaceSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"search", nullptr, WorkspaceSearch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"syncWebDav", nullptr, WorkspaceSyncWebDav, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value workspace_class;
    napi_define_class(env, "Workspace", NAPI_AUTO_LENGTH, WorkspaceConstructor, nullptr,
        sizeof(workspace_descriptors) / sizeof(workspace_descriptors[0]), workspace_descriptors, &workspace_class);
    napi_create_reference(env, workspace_class, 1, &workspace_constructor);
    napi_set_named_property(env, exports, "Workspace", workspace_class);

    napi_property_descriptor repo_descriptors[] = {
        {"id", nullptr, RepoId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshot", nullptr, RepoSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value repo_class;
    napi_define_class(env, "Repo", NAPI_AUTO_LENGTH, RepoConstructor, nullptr,
        sizeof(repo_descriptors) / sizeof(repo_descriptors[0]), repo_descriptors, &repo_class);
    napi_create_reference(env, repo_class, 1, &repo_constructor);
    napi_set_named_property(env, exports, "Repo", repo_class);

    napi_property_descriptor descriptors[] = {
        {"initialize", nullptr, Initialize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordSync", nullptr, RecordSync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openWorkspace", nullptr, OpenWorkspace, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
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
