#include <cstdint>
#include <chrono>
#include <string>
#include <vector>

#include "napi/native_api.h"

extern "C" void org_tasks_harmony_free_string(char* value);
extern "C" uint64_t org_tasks_harmony_workspace_create();
extern "C" bool org_tasks_harmony_workspace_retain(uint64_t handle);
extern "C" void org_tasks_harmony_workspace_release(uint64_t handle);
extern "C" char* org_tasks_harmony_workspace_repo_ids(uint64_t handle);
extern "C" int32_t org_tasks_harmony_workspace_load(uint64_t handle);
extern "C" int32_t org_tasks_harmony_workspace_add_repo(uint64_t handle, const char* root_directory);
extern "C" char* org_tasks_harmony_workspace_search(uint64_t handle, const char* expression);
extern "C" uint64_t org_tasks_harmony_webdav_sync_policy_create(const char* webdav_url,
    const char* username, const char* password);
extern "C" bool org_tasks_harmony_webdav_sync_policy_retain(uint64_t handle);
extern "C" void org_tasks_harmony_webdav_sync_policy_release(uint64_t handle);
extern "C" char* org_tasks_harmony_repo_sync(uint64_t workspace_handle, const char* repo_id,
    uint64_t policy_handle, int64_t started_at);
extern "C" char* org_tasks_harmony_repo_snapshot(uint64_t workspace_handle, const char* repo_id);

namespace {
struct WorkspaceWrap {
    uint64_t handle = 0;
};

struct RepoWrap {
    uint64_t workspace_handle = 0;
    std::string id;
};

struct WebDavSyncPolicyWrap {
    uint64_t handle = 0;
};

struct WorkspaceStringWork {
    uint64_t handle = 0;
    std::string expression;
    std::string response;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceLoadWork {
    uint64_t handle = 0;
    int32_t result = -1;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

struct WorkspaceAddRepoWork {
    uint64_t handle = 0;
    std::string root_directory;
    int32_t result = -1;
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
    uint64_t policy_handle = 0;
    std::string response;
    enum class Operation { Snapshot, Sync } operation = Operation::Snapshot;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

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

void FinalizeWebDavSyncPolicy(napi_env, void* data, void*)
{
    auto* policy = static_cast<WebDavSyncPolicyWrap*>(data);
    if (policy->handle != 0) {
        org_tasks_harmony_webdav_sync_policy_release(policy->handle);
    }
    delete policy;
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

void ExecuteWorkspaceString(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceStringWork*>(data);
    work->response = TakeRustString(org_tasks_harmony_workspace_search(
        work->handle, work->expression.c_str()));
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
        if (!ParseJson(env, work->response, &result)) {
            napi_value text;
            napi_create_string_utf8(env, "core workspace 响应格式无效", NAPI_AUTO_LENGTH, &text);
            napi_value error;
            napi_create_error(env, nullptr, text, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else {
            napi_resolve_deferred(env, work->deferred, result);
        }
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteWorkspaceLoad(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceLoadWork*>(data);
    work->result = org_tasks_harmony_workspace_load(work->handle);
}

void CompleteWorkspaceLoad(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceLoadWork*>(data);
    if (status != napi_ok || work->result != 0) {
        napi_value text;
        napi_create_string_utf8(env, "Workspace.load 失败", NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value value;
        napi_get_undefined(env, &value);
        napi_resolve_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteWorkspaceAddRepo(napi_env, void* data)
{
    auto* work = static_cast<WorkspaceAddRepoWork*>(data);
    work->result = org_tasks_harmony_workspace_add_repo(work->handle, work->root_directory.c_str());
}

void CompleteWorkspaceAddRepo(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<WorkspaceAddRepoWork*>(data);
    if (status != napi_ok || work->result != 0) {
        napi_value text;
        napi_create_string_utf8(env, "Workspace.addRepo 失败", NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value value;
        napi_get_undefined(env, &value);
        napi_resolve_deferred(env, work->deferred, value);
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
    switch (work->operation) {
        case RepoSnapshotWork::Operation::Snapshot:
            work->response = TakeRustString(org_tasks_harmony_repo_snapshot(
                work->workspace_handle, work->id.c_str()));
            break;
        case RepoSnapshotWork::Operation::Sync:
            work->response = TakeRustString(org_tasks_harmony_repo_sync(work->workspace_handle,
                work->id.c_str(), work->policy_handle, static_cast<int64_t>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::system_clock::now().time_since_epoch()).count())));
            break;
    }
}

void CompleteRepoSnapshot(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<RepoSnapshotWork*>(data);
    if (work->policy_handle != 0) {
        org_tasks_harmony_webdav_sync_policy_release(work->policy_handle);
    }
    if (status != napi_ok || work->response.empty()) {
        napi_value text;
        napi_create_string_utf8(env,
            work->operation == RepoSnapshotWork::Operation::Snapshot ? "读取 Repo 快照失败" : "Repo 同步失败",
            NAPI_AUTO_LENGTH, &text);
        napi_value error;
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value result;
        if (!ParseJson(env, work->response, &result)) {
            napi_value text;
            napi_create_string_utf8(env, "Repo 响应格式无效", NAPI_AUTO_LENGTH, &text);
            napi_value error;
            napi_create_error(env, nullptr, text, &error);
            napi_reject_deferred(env, work->deferred, error);
        } else {
            napi_resolve_deferred(env, work->deferred, result);
        }
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
    if (!ReadHandle(env, args[0], &repo->workspace_handle) || !ReadString(env, args[1], &repo->id) ||
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
    auto* policy = new WebDavSyncPolicyWrap();
    policy->handle = org_tasks_harmony_webdav_sync_policy_create(
        webdav_url.c_str(), username.c_str(), password.c_str());
    if (policy->handle == 0 || napi_wrap(env, self, policy, FinalizeWebDavSyncPolicy, nullptr, nullptr) != napi_ok) {
        if (policy->handle != 0) {
            org_tasks_harmony_webdav_sync_policy_release(policy->handle);
        }
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
    if (napi_unwrap(env, value, reinterpret_cast<void**>(policy)) != napi_ok || (*policy)->handle == 0) {
        napi_throw_error(env, nullptr, "WebDavSyncPolicy 已关闭");
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
    if (!ReadString(env, args[0], &work->expression)) {
        delete work;
        napi_throw_error(env, nullptr, "Workspace.search 表达式无效");
        return nullptr;
    }
    work->handle = workspace->handle;
    return QueueWorkspaceString(env, work, "OrgTasksWorkspaceSearch");
}

napi_value WorkspaceLoad(napi_env env, napi_callback_info info)
{
    WorkspaceWrap* workspace = nullptr;
    napi_value self;
    if (!UnwrapWorkspace(env, info, &workspace, &self)) return nullptr;
    auto* work = new WorkspaceLoadWork();
    work->handle = workspace->handle;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Workspace.load Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksWorkspaceLoad", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteWorkspaceLoad, CompleteWorkspaceLoad, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Workspace.load 请求");
        return nullptr;
    }
    return promise;
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

napi_value RepoSync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    RepoWrap* repo = nullptr;
    WebDavSyncPolicyWrap* policy = nullptr;
    napi_value self;
    if (napi_get_cb_info(env, info, &argc, args, &self, nullptr) != napi_ok || argc != 1 ||
        napi_unwrap(env, self, reinterpret_cast<void**>(&repo)) != napi_ok || repo->workspace_handle == 0 ||
        !UnwrapWebDavSyncPolicy(env, args[0], &policy)) {
        napi_throw_error(env, nullptr, "Repo.sync 参数无效");
        return nullptr;
    }
    if (!org_tasks_harmony_webdav_sync_policy_retain(policy->handle)) {
        napi_throw_error(env, nullptr, "WebDavSyncPolicy 已关闭");
        return nullptr;
    }
    auto* work = new RepoSnapshotWork();
    work->workspace_handle = repo->workspace_handle;
    work->id = repo->id;
    work->policy_handle = policy->handle;
    work->operation = RepoSnapshotWork::Operation::Sync;
    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        org_tasks_harmony_webdav_sync_policy_release(work->policy_handle);
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Repo.sync Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksRepoSync", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteRepoSnapshot, CompleteRepoSnapshot, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) napi_delete_async_work(env, work->work);
        org_tasks_harmony_webdav_sync_policy_release(work->policy_handle);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Repo.sync 请求");
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
        {"addRepo", nullptr, WorkspaceAddRepo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"load", nullptr, WorkspaceLoad, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"search", nullptr, WorkspaceSearch, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value workspace_class;
    napi_define_class(env, "Workspace", NAPI_AUTO_LENGTH, WorkspaceConstructor, nullptr,
        sizeof(workspace_descriptors) / sizeof(workspace_descriptors[0]), workspace_descriptors, &workspace_class);
    napi_set_named_property(env, exports, "Workspace", workspace_class);

    napi_property_descriptor repo_descriptors[] = {
        {"id", nullptr, RepoId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshot", nullptr, RepoSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sync", nullptr, RepoSync, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_value repo_class;
    napi_define_class(env, "Repo", NAPI_AUTO_LENGTH, RepoConstructor, nullptr,
        sizeof(repo_descriptors) / sizeof(repo_descriptors[0]), repo_descriptors, &repo_class);
    napi_create_reference(env, repo_class, 1, &repo_constructor);
    napi_set_named_property(env, exports, "Repo", repo_class);

    napi_value webdav_sync_policy_class;
    napi_define_class(env, "WebDavSyncPolicy", NAPI_AUTO_LENGTH, WebDavSyncPolicyConstructor, nullptr,
        0, nullptr, &webdav_sync_policy_class);
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
