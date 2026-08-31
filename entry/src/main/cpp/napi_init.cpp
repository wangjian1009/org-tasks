#include <cstdint>
#include <string>

#include "napi/native_api.h"

extern "C" int32_t org_tasks_harmony_initialize(const char* data_dir);
extern "C" int32_t org_tasks_harmony_record_sync(const char* repo_id, const char* record_id,
    int64_t started_at, int64_t finished_at, bool succeeded);

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
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"initialize", nullptr, Initialize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordSync", nullptr, RecordSync, nullptr, nullptr, nullptr, napi_default, nullptr},
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
