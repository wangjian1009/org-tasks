#include <cstdint>
#include <string>

#include "napi/native_api.h"

extern "C" int32_t org_tasks_harmony_queue_sync(const char* idempotency_key, const char* job_id,
    const char* reason, bool include_calendar, bool foreground, int64_t now);

namespace {
struct QueueSyncWork {
    std::string idempotency_key;
    std::string job_id;
    std::string reason;
    bool include_calendar = true;
    bool foreground = false;
    int64_t now = 0;
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

void ExecuteQueueSync(napi_env, void* data)
{
    auto* work = static_cast<QueueSyncWork*>(data);
    work->result = org_tasks_harmony_queue_sync(work->idempotency_key.c_str(), work->job_id.c_str(),
        work->reason.c_str(), work->include_calendar, work->foreground, work->now);
}

void CompleteQueueSync(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<QueueSyncWork*>(data);
    if (status != napi_ok || work->result != 0) {
        napi_value message;
        napi_create_string_utf8(env, "Rust 核心服务未能登记同步意图", NAPI_AUTO_LENGTH, &message);
        napi_value error;
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    } else {
        napi_value value;
        napi_create_int32(env, work->result, &value);
        napi_resolve_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value QueueSync(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) {
        napi_throw_error(env, nullptr, "无法读取 queueSync 参数");
        return nullptr;
    }
    if (argc != 6) {
        napi_throw_error(env, nullptr, "queueSync 需要 6 个参数");
        return nullptr;
    }

    auto* work = new QueueSyncWork();
    double now = 0;
    if (!ReadString(env, args[0], &work->idempotency_key) || !ReadString(env, args[1], &work->job_id) ||
        !ReadString(env, args[2], &work->reason) || napi_get_value_bool(env, args[3], &work->include_calendar) != napi_ok ||
        napi_get_value_bool(env, args[4], &work->foreground) != napi_ok || napi_get_value_double(env, args[5], &now) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "queueSync 参数无效");
        return nullptr;
    }
    work->now = static_cast<int64_t>(now);

    napi_value promise;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 queueSync Promise");
        return nullptr;
    }
    napi_value resource_name;
    if (napi_create_string_utf8(env, "OrgTasksQueueSync", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, ExecuteQueueSync, CompleteQueueSync, work, &work->work) != napi_ok) {
        delete work;
        napi_throw_error(env, nullptr, "无法创建 Rust 异步任务");
        return nullptr;
    }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        delete work;
        napi_throw_error(env, nullptr, "无法调度 Rust 异步任务");
        return nullptr;
    }
    return promise;
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"queueSync", nullptr, QueueSync, nullptr, nullptr, nullptr, napi_default, nullptr},
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
