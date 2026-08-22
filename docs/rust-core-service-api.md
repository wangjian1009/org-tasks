# Rust 核心数据服务 API v1

## 当前实现状态

当前 Harmony 应用已通过 `entry/src/main/cpp/` 的 C++ N-API bridge 接入 Rust。ArkTS 的 `NativeCoreService.recordSyncIntent` 调用 `queueSync`，C++ 使用 `napi_create_async_work` 在工作线程执行 Rust FFI，因此不会阻塞 ArkUI 线程。该入口只接收同步元数据，不传入 WebDAV URL、密码或远端文件内容。

当前 `harmony` 适配器使用进程内易失 `SessionStore` 创建或合并 `sync` 作业，现有 ArkTS WebDAV 与 CalendarKit 流程继续执行。以下接口是完整持久化数据服务的 v1 目标契约；SQLite、执行租约、action 回执和完整资源接口尚未接入 Harmony bridge。

## 目标与边界

`orgTasksCore` 是运行在应用进程内的 Rust 数据服务。它管理任务、文件元数据、同步作业、离线 outbox、冲突和 SQLite 持久化状态；ArkTS 管理 ArkUI、WorkScheduler、WebDAV HTTP、CalendarKit、Preferences 和 Asset Store。

Rust 只处理领域数据和同步决策，不能从原生工作线程访问 ArkTS 对象、UI 状态、日历、网络或安全凭据。WebDAV 密码只由 ArkTS 从 Asset Store 临时读取，不能进入 Rust 数据库、请求、日志或错误信息。

## 进程内 REST 传输

接口采用 RESTful 资源模型，但不启动 HTTP 服务、不监听端口。ArkTS 通过一条异步 N-API 入口调用；C++ N-API 层将 UTF-8 JSON 传给 Rust，再将结果包装为 Promise。

```ts
interface OrgTasksCore {
  request<T>(request: CoreRequest): Promise<CoreResponse<T>>
}

type HttpMethod = 'GET' | 'POST' | 'PATCH' | 'DELETE'

interface CoreRequest {
  requestId: string
  method: HttpMethod
  path: string
  query?: Record<string, string>
  body?: unknown
}

interface CoreResponse<T> {
  apiVersion: 1
  requestId: string
  status: 200 | 201 | 202 | 204 | 400 | 404 | 409 | 423 | 500 | 503
  data?: T
  error?: CoreError
}

interface CoreError {
  code: CoreErrorCode
  message: string
  retryable: boolean
  details?: Record<string, string | number | boolean>
}
```

`requestId` 用于链路追踪。每个创建资源请求还必须带 `idempotencyKey`（UUID），用于重试去重。预期的业务失败通过 `status` 和 `error` 返回；仅 JSON 编解码或 N-API 桥接故障会 reject Promise。

## 生命周期资源

| 方法 | 路径 | 请求体 | 成功响应 |
|---|---|---|---|
| `POST` | `/v1/service-instances` | `ServiceInitialization` | `201 ServiceInfo` |
| `POST` | `/v1/service-migrations` | `MigrationRequest` | `200 MigrationResult` |
| `DELETE` | `/v1/service-instances/current` | 无 | `204` |

```ts
interface ServiceInitialization {
  dataDir: string
  schemaVersion: number
}

interface ServiceInfo {
  schemaVersion: number
  serviceState: 'ready' | 'migration_required'
  pendingJobs: number
  runningJobId?: string
}

interface MigrationRequest { targetSchemaVersion: number }
interface MigrationResult {
  fromVersion: number
  toVersion: number
  migrated: boolean
}
```

`dataDir` 必须是应用私有目录，例如 `context.filesDir + '/org-tasks-core'`。初始化会打开 SQLite、校验完整性并回收过期执行租约；不会访问网络或日历。删除当前服务实例只关闭数据库句柄，不删除用户数据。

## 核心资源

```ts
type TaskState = 'TODO' | 'NEXT' | 'WAIT' | 'DONE' | 'CNCL'
type JobState = 'queued' | 'running' | 'retry_wait' | 'blocked' | 'completed' | 'failed'
type JobType = 'sync' | 'add_task' | 'retry_job' | 'resolve_conflict' | 'rebuild_calendar' | 'refresh_local_index'
type ConflictState = 'open' | 'resolved' | 'dismissed'

interface TaskRecord {
  id: string
  filePath: string
  heading: string
  todoState: TaskState
  priority?: 'A' | 'B' | 'C'
  scheduledAt?: number
  deadlineAt?: number
  tags: string[]
  body: string
  progress?: number
  sourceRevision: string
  updatedAt: number
}

interface FileRecord {
  path: string
  contentHash: string
  remoteEtag?: string
  remoteMtime?: number
  remoteSize?: number
  lastSyncedAt?: number
  syncState: 'synced' | 'local_changed' | 'remote_changed' | 'remote_deleted' | 'conflict'
}

interface JobRecord {
  id: string
  idempotencyKey: string
  type: JobType
  state: JobState
  priority: 'foreground' | 'background'
  reason: string
  attemptCount: number
  nextRunAt?: number
  createdAt: number
  updatedAt: number
  error?: CoreError
}

interface ConflictRecord {
  id: string
  filePath: string
  state: ConflictState
  localRevision?: string
  remoteRevision?: string
  createdAt: number
  message: string
}
```

时间均为 Unix epoch 毫秒。`sourceRevision` 与 `contentHash` 均为小写 SHA-256 十六进制字符串。

## Rust 持久化模型

SQLite 是元数据和工作流的真相来源；下载到的 org 文件保存于 `<dataDir>/cache/<path>`，不重复存为 SQLite blob。outbox 直接存入 SQLite，避免离线新增任务因文件写入中断而丢失。

```rust
pub type TimestampMs = i64;
pub type Sha256 = String;
pub type TaskId = String;
pub type JobId = String;
pub type ExecutionId = String;
pub type ConflictId = String;

pub struct FileRecord {
    pub path: String,
    pub cache_path: String,
    pub content_hash: Sha256,
    pub remote_etag: Option<String>,
    pub remote_mtime: Option<TimestampMs>,
    pub remote_size: Option<i64>,
    pub last_synced_at: Option<TimestampMs>,
    pub sync_state: FileSyncState,
}

pub struct TaskRecord {
    pub id: TaskId,
    pub file_path: String,
    pub heading: String,
    pub todo_state: TodoState,
    pub scheduled_at: Option<TimestampMs>,
    pub deadline_at: Option<TimestampMs>,
    pub tags: Vec<String>,
    pub source_revision: Sha256,
    pub updated_at: TimestampMs,
}

pub struct CalendarBinding {
    pub task_id: TaskId,
    pub calendar_name: String,
    pub event_id: i64,
    pub event_fingerprint: Sha256,
    pub synced_at: TimestampMs,
}

pub struct OutboxEntry {
    pub id: String,
    pub target_path: String,
    pub org_entry: String,
    pub content_hash: Sha256,
    pub created_at: TimestampMs,
}

pub struct SyncJob {
    pub id: JobId,
    pub idempotency_key: String,
    pub kind: JobKind,
    pub state: JobState,
    pub checkpoint: JobCheckpoint,
    pub attempt_count: u32,
    pub next_run_at: Option<TimestampMs>,
}

pub struct ExecutionLease {
    pub id: ExecutionId,
    pub job_id: JobId,
    pub worker_id: String,
    pub lease_expires_at: TimestampMs,
    pub actions: Vec<PlatformAction>,
}

pub struct ConflictRecord {
    pub id: ConflictId,
    pub file_path: String,
    pub local_revision: Option<Sha256>,
    pub remote_revision: Option<String>,
    pub state: ConflictState,
}
```

| 表 | 主键 | 责任 |
|---|---|---|
| `service_meta` | `key` | schema 版本、变更游标、最近成功同步时间 |
| `files` | `path` | 远端版本和缓存文件元数据 |
| `tasks` | `id` | 解析后的任务投影 |
| `calendar_bindings` | `task_id` | 任务到日历事件的映射 |
| `outbox_entries` | `id` | 未确认上传的本地任务意图 |
| `sync_jobs` | `id` | 作业、重试、错误和 checkpoint |
| `execution_leases` | `id` | 已认领 action 计划及其过期时间 |
| `conflicts` | `id` | 未解决的本地/远端分歧 |
| `change_log` | `cursor` | UI 增量刷新所需的变更 |

`TaskRecord` 是 `FileRecord` 的解析投影；某文件成功解析后应在一个事务中替换该文件的任务。`CalendarBinding` 只在 ArkTS 回报日历 action 成功后更新。`OutboxEntry` 只在条件上传被远端确认后删除。

## 变更资源

每个写操作都创建持久化资源，不提供泛化的 `submit(command)` 接口。

| 方法 | 路径 | 请求体 | 成功响应 |
|---|---|---|---|
| `POST` | `/v1/tasks` | `CreateTaskRequest` | `201 TaskCreation` |
| `POST` | `/v1/sync-jobs` | `CreateSyncJobRequest` | `201 JobRecord`；可合并时为 `200` |
| `POST` | `/v1/job-retry-requests` | `CreateJobRetryRequest` | `201 JobRecord` |
| `POST` | `/v1/conflict-resolutions` | `CreateConflictResolutionRequest` | `201 ConflictResolution` |
| `POST` | `/v1/calendar-rebuild-jobs` | `CreateJobRequest` | `201 JobRecord` |
| `POST` | `/v1/local-index-refresh-jobs` | `CreateJobRequest` | `201 JobRecord` |

```ts
interface CreateResourceRequest {
  idempotencyKey: string
  reason: string
  priority?: 'foreground' | 'background'
}

interface NewTask {
  heading: string
  scheduledAt?: number
  deadlineAt?: number
  tags?: string[]
  priority?: 'A' | 'B' | 'C'
}

interface CreateTaskRequest extends CreateResourceRequest { task: NewTask }
interface CreateSyncJobRequest extends CreateResourceRequest { includeCalendar: boolean }
interface CreateJobRetryRequest extends CreateResourceRequest { jobId: string }
interface CreateJobRequest extends CreateResourceRequest {}
interface CreateConflictResolutionRequest extends CreateResourceRequest {
  conflictId: string
  resolution: 'keep_local' | 'keep_remote' | 'save_local_copy' | 'dismiss'
}

interface TaskCreation { task: TaskRecord; job: JobRecord }
interface ConflictResolution {
  id: string
  conflictId: string
  resolution: 'keep_local' | 'keep_remote' | 'save_local_copy' | 'dismiss'
  job: JobRecord
  createdAt: number
}
```

重复同一 `idempotencyKey` 必须返回原资源，绝不能重复追加任务。新的同步作业可与既有 `queued` 或 `running` 同步作业合并。

## 执行租约资源

Rust 生成平台 action，ArkTS 执行 WebDAV 和 CalendarKit 操作后再提交回执。这样既避免 Rust 原生线程直接调用平台 API，也支持进程被杀后的恢复。

| 方法 | 路径 | 请求体 | 成功响应 |
|---|---|---|---|
| `POST` | `/v1/execution-leases` | `CreateExecutionLeaseRequest` | `201 Execution`；无待执行作业时为 `204` |
| `GET` | `/v1/execution-leases/{executionId}` | 无 | `200 Execution` |
| `PATCH` | `/v1/execution-leases/{executionId}` | `CompleteExecutionLeaseRequest` | `200 ExecutionCompletion` |

```ts
interface CreateExecutionLeaseRequest { workerId: string; now: number }
interface Execution {
  id: string
  jobId: string
  leaseExpiresAt: number
  actions: PlatformAction[]
}
interface CompleteExecutionLeaseRequest {
  state: 'completed'
  completedAt: number
  results: PlatformActionResult[]
}
interface ExecutionCompletion { job: JobRecord; nextExecutionAvailable: boolean }
```

创建租约会原子认领一个到期作业。v1 只允许一个未过期租约。ArkTS 在创建资源、应用回到前台和 WorkScheduler 回调后创建租约，按顺序执行 action，最后仅 PATCH 一次。若中断，初始化时回收过期租约并重试。

## 平台 action 与回执

```ts
type PlatformAction = WebDavListAction | WebDavGetAction | WebDavPutAction | CalendarUpsertAction | CalendarDeleteAction
interface ActionBase { id: string; idempotencyKey: string }
interface WebDavListAction extends ActionBase { type: 'webdav_list'; directoryUrl: string; depth: 1 }
interface WebDavGetAction extends ActionBase { type: 'webdav_get'; path: string }
interface WebDavPutAction extends ActionBase {
  type: 'webdav_put'; path: string; content: string
  precondition: { kind: 'if_match'; etag: string } | { kind: 'if_none_match' }
}
interface CalendarUpsertAction extends ActionBase { type: 'calendar_upsert'; task: TaskRecord; existingEventId?: number }
interface CalendarDeleteAction extends ActionBase { type: 'calendar_delete'; eventId: number; taskId: string }

interface PlatformActionResult {
  actionId: string
  idempotencyKey: string
  outcome: 'succeeded' | 'failed' | 'conflict' | 'not_found'
  result?: Record<string, unknown>
  error?: PlatformError
}
interface PlatformError {
  category: 'network' | 'authentication' | 'tls' | 'permission' | 'calendar' | 'validation' | 'unknown'
  code?: number
  message: string
  retryable: boolean
}
```

WebDAV 写操作必须使用 `If-Match` 或 `If-None-Match`，不得对已知远端文件执行无条件 `PUT`。`412` 必须创建冲突资源，不得自动覆盖。日历 action 必须以 `task.id` 作为事件 identifier，恢复时将已应用 action 回报为 `succeeded`。

## 查询资源

| 方法 | 路径 | 查询参数 | 成功响应 |
|---|---|---|---|
| `GET` | `/v1/service-status` | 无 | `200 ServiceStatus` |
| `GET` | `/v1/tasks` | `state`、`filePath`、`limit`、`cursor` | `200 Page<TaskRecord>` |
| `GET` | `/v1/tasks/{taskId}` | 无 | `200 TaskRecord` |
| `GET` | `/v1/files` | `state`、`limit`、`cursor` | `200 Page<FileRecord>` |
| `GET` | `/v1/files/{path}` | 无 | `200 FileRecord` |
| `GET` | `/v1/conflicts` | `state`、`limit`、`cursor` | `200 Page<ConflictRecord>` |
| `GET` | `/v1/conflicts/{conflictId}` | 无 | `200 ConflictRecord` |
| `GET` | `/v1/sync-jobs` | `state`、`limit`、`cursor` | `200 Page<JobRecord>` |
| `GET` | `/v1/sync-jobs/{jobId}` | 无 | `200 JobRecord` |
| `GET` | `/v1/changes` | `after`、`limit` | `200 ChangeFeed` |

```ts
interface ServiceStatus {
  latestCompletedSyncAt?: number
  activeJob?: JobRecord
  pendingJobs: number
  pendingOutboxEntries: number
  openConflicts: number
  lastError?: CoreError
  changeCursor: number
}
interface Page<T> { items: T[]; nextCursor?: string }
interface ChangeFeed { cursor: number; changes: DomainChange[] }
interface DomainChange {
  cursor: number
  kind: 'task' | 'file' | 'job' | 'conflict' | 'status'
  id: string
  operation: 'created' | 'updated' | 'deleted'
}
```

路径中的文件名必须逐段 percent-encode；Rust 解码一次后拒绝空段、`.`、`..` 和反斜杠。Rust 不直接回调 ArkTS，页面可见期间或后台执行结束后由 ArkTS 轮询 `/v1/changes`。

## 错误、并发与版本

| 状态码 | 含义 | 常见 `code` |
|---|---|---|
| `400` | 请求体或查询参数无效 | `invalid_request` |
| `404` | 资源不存在 | `not_found` |
| `409` | 幂等键、版本或冲突状态不匹配 | `conflict` |
| `423` | 资源等待用户处理 | `operation_blocked` |
| `500` | 不可恢复的原生或数据库故障 | `internal`、`database_corrupt` |
| `503` | 临时锁冲突或服务不可用 | `busy`、`database_unavailable` |

```ts
type CoreErrorCode =
  | 'not_initialized' | 'invalid_request' | 'unsupported_schema'
  | 'database_unavailable' | 'database_corrupt' | 'not_found'
  | 'conflict' | 'lease_lost' | 'busy' | 'action_result_invalid'
  | 'operation_blocked' | 'internal'
```

创建变更资源和 PATCH 执行租约必须使用 SQLite 事务。读取或解析失败时不得生成日历删除 action；新增任务必须先持久化 outbox；前台同步只能提高已排队作业的优先级，不能与后台同步并发执行。`apiVersion` 固定为 `1`，删除字段、改变枚举含义或持久化语义时必须升级为 v2 并提供数据库迁移。
