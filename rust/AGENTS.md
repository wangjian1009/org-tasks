# Rust 架构规范

## 目标

`rust/` 是 Org Tasks 的进程内 Rust 数据服务。它采用六边形架构，确保领域逻辑可脱离 HarmonyOS、HTTP 服务器和具体数据库独立编译、测试与复用。

## 目录与依赖方向

```text
rust/
  core/       领域模型、用例、端口和平台无关的 action 定义
  harmony/    HarmonyOS/N-API 访问与持久化适配层
  http/       RESTful HTTP 请求、响应与 CSV 持久化适配层
```

依赖只能从外向内：`harmony -> core`、`http -> core`。`core` 不得依赖 `harmony`、`http`、ArkTS、N-API、HarmonyOS SDK、网络库、数据库库或文件系统库。

## 核心层

`core` 负责：

- 任务、文件、同步作业、冲突和执行租约等领域数据结构。
- 新建任务、创建/合并同步作业、认领执行租约等用例。
- 校验、幂等、状态迁移和 action 计划。
- `CoreStore` 等端口 trait，只定义持久化所需语义。所有 I/O 方法返回 `Send Future`，领域用例以 `async` 方式调用。

`core` 不负责：密码、WebDAV URL、HTTP 请求、日历写入、后台调度、日志输出、线程创建、JSON 编解码和磁盘落盘。

所有时间以 `TimestampMs`（Unix epoch 毫秒）表示；外部生成的 ID 与幂等键必须是非空 UUID 字符串。密码、Authorization header 和完整远端文件内容不得出现在 core 的公开模型、错误或 checkpoint 中。

## 适配层

`harmony` 将 ArkTS/N-API 传入的结构化请求映射为 core 用例调用。当前 C++ N-API bridge 位于 `entry/src/main/cpp/`，通过 `napi_create_async_work` 调用 `harmony` 导出的 C FFI；Rust 核心仍不可感知 N-API 类型。

当前 bridge 提供 `initialize(dataDir)`、`queueSync` 与 `finishSync`：ArkTS 传入 `context.filesDir`，`harmony::FileCoreStore` 在该应用私有目录保存版本化状态快照。它在临时文件写入和 `sync_all` 成功后原子替换正式文件，并以 `CoreStore` 注入服务；平台同步在 `finally` 中回传作业终态，持久化实现不进入 `core` crate。

C++ bridge 使用 `napi_create_async_work` 在后台 worker 中初始化和调用 Rust。`core`、`harmony` 与 `http` 的服务入口均为异步接口；Rust 不访问 ArkTS 对象或 UI 线程。

`http` 将 REST method、path、query 和 body 映射为相同的 core 用例；它不拥有业务规则。`http::CsvCoreStore` 是可选的外部持久化实现，保存到宿主指定目录的 CSV 快照；实际 HTTP server、TLS 和认证由其外层宿主负责。

`CsvCoreStore` 的目录由 `current.csv` manifest 与 `snapshots/<generation>/tasks.csv`、`task_tags.csv`、`jobs.csv`、`outbox.csv` 组成。它先写入完整新快照，再原子替换 manifest；宿主将 `CsvCoreStore::open(data_dir)` 注入 `HttpApi::new(store)`。

适配层只保存短生命周期输入，不保存密码。平台 I/O 的结果应通过 core 定义的 action 回执返回给服务。

## 变更要求

- 新增领域能力时，先修改 `core` 模型和用例，再在两个适配层增加映射。
- 新增持久化实现必须位于独立目录或应用宿主中，通过 `CoreStore` 注入；不能倒灌进 `core`。
- 所有 core 状态变迁应有单元测试。适配层至少测试路由/请求映射和错误映射。
- 文档说明使用中文；代码标识符、协议名和 API 字段保持英文。
