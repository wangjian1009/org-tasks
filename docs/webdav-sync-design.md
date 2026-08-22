# WebDAV 文件同步设计

## 目标

本设计用于在导入日历前，将 WebDAV 仓库中的 org 文件同步到应用私有缓存；同时可靠地发布手机端新增任务。参考 Orgzly Revived 的版本化仓库和同步决策思路，但不依赖其源代码，具体实现保持为 HarmonyOS ArkTS 与后续 Rust 核心服务。

## 范围

首版支持：WebDAV 目录中的 `.org` 文件、目录列举、下载、上传、创建目录、重命名、远端删除检测、Basic 认证、HTTPS、文件级冲突检测、离线 outbox 和后台同步。

首版不支持：Git 式行级合并、Dropbox 等非 WebDAV 仓库类型、远端变更推送通知。Digest 认证、递归目录遍历和完整的通用文件编辑上传属于后续能力。

## 配置

| 配置项 | 说明 |
|---|---|
| `webdavEnabled` | 是否以 WebDAV 作为 org 文件来源。 |
| `webdavUrl` | WebDAV 根目录 URL，而非单个文件 URL。 |
| `webdavUsername` | WebDAV 用户名。 |
| `webdavPassword` | 密码或应用专用密码，只存入 Asset Store。 |
| `webdavAllowHttp` | 明文 HTTP 显式确认开关，默认 `false`。 |
| `webdavIncludeSubdirectories` | 是否递归列举子目录。 |
| `webdavIgnorePatterns` | 本地忽略规则，可兼容 `.orgzlyignore`。 |

设置页面必须校验 URL、用户名、密码和 `inboxFile` 后缀，提供“测试 WebDAV 连接”。认证、TLS、网络和 HTTP 状态错误必须分开显示。密码不能写入 Preferences、日志、错误信息或同步状态文件。

## 本地存储

WebDAV 缓存必须使用应用私有目录，不能依赖用户配置的共享目录。Rust 核心服务落地后，文件内容与元数据分别保存：

```text
<context.filesDir>/org-tasks-core/
  cache/                         远端 org 文件的物化缓存
  org-tasks.sqlite               文件、任务、outbox、作业和冲突元数据
```

缓存可以在一次完整且成功的同步后重建。outbox 是本地用户意图，列举或下载失败时绝不能删除。

## 文件版本状态

每个同步过的文件保存以下版本信息：

```ts
interface WebDavFileState {
  relativePath: string
  remoteUrl: string
  remoteEtag?: string
  remoteMtime?: number
  remoteSize?: number
  localSha256: string
  lastSyncedAt: number
  syncState: 'synced' | 'local_changed' | 'remote_changed' | 'remote_deleted' | 'conflict'
}
```

优先使用 `ETag`；服务器未提供时使用远端修改时间和大小。`localSha256` 用于检测缓存自上次确认同步后的变化。传输失败时保留上次确认记录，只有所有相关远端操作成功后才更新元数据。

## WebDAV 协议操作

| 意图 | 请求 | 成功条件 | 约束 |
|---|---|---|---|
| 测试或列举仓库 | `PROPFIND`，`Depth: 1` | `207 Multi-Status` | 解析 href、collection、ETag、修改时间和大小。 |
| 下载文件 | `GET` | `200 OK` | 写入临时文件并原子替换缓存。 |
| 创建目录 | `MKCOL` | `201` 或已存在 | 从根到叶创建缺失父目录。 |
| 上传新文件 | `PUT` + `If-None-Match: *` | `201`、`200` 或 `204` | 禁止意外覆盖新建远端文件。 |
| 更新已有文件 | `PUT` + `If-Match: <etag>` | `200` 或 `204` | `412` 是冲突。 |
| 重命名 | `MOVE` + `Destination` + `Overwrite: F` | `201` 或 `204` | 不覆盖目标。 |
| 删除 | `DELETE` | `204` | 仅显式用户删除可执行。 |

对已知远端文件绝不能使用无条件 `PUT`，否则手机可能覆盖桌面端在上次读取后提交的修改。

## 同步流程

手动同步、前台触发和 WorkScheduler 后台同步必须通过 Rust `sync-jobs` 与 `execution-leases` 串行化；不能各自直接执行网络流程。

1. ArkTS 校验配置和网络可用性，从 Asset Store 临时读取密码。
2. 创建或合并 `POST /v1/sync-jobs` 资源。
3. Rust 读取文件状态和 outbox，通过 `POST /v1/execution-leases` 生成 action 计划。
4. ArkTS 对仓库执行 `PROPFIND`。完整列举失败时不得做远端删除判断。
5. 下载远端新文件或远端版本已变化的文件，临时写入并原子替换缓存。
6. 对完整列举中消失的已知文件标记 `remote_deleted`，保留缓存和日历事件，等待用户选择。
7. 刷新 `inbox.org`：先 `GET` 最新内容与 ETag，追加 outbox 中的条目，再使用 `If-Match` 条件 `PUT`。成功后仅确认已上传条目。
8. 对其他本地修改的文件，根据本地哈希和上次远端版本决定上传、下载或创建冲突。
9. Rust 用事务提交文件状态、任务投影和作业 checkpoint。
10. 只有确认的完整本地视图成功解析后，才计划并执行 CalendarKit 同步。

## 同步决策

| 自上次确认后本地状态 | 远端状态 | 操作 |
|---|---|---|
| 未变化 | 未变化 | 不传输。 |
| 未变化 | 已变化 | 下载并更新状态。 |
| 已变化 | 未变化 | 条件上传并更新状态。 |
| 已变化 | 已变化 | 创建冲突，保留双方内容。 |
| 存在 | 已删除 | 标记远端删除，保留本地版本，等待用户处理。 |
| 缺失 | 存在 | 下载为新缓存文件。 |
| 缺失 | 缺失 | 只有用户显式确认后才移除状态。 |

冲突解决必须提供：保留本地并条件上传、保留远端并替换缓存、以冲突文件名保存本地版本、暂不处理。界面应显示双方时间戳与 ETag。

## 手机端新增任务

WebDAV 模式下新增任务不能直接修改远端 `inbox.org`：

1. ArkTS 格式化 org entry 并创建 `POST /v1/tasks`。
2. Rust 在同一事务中保存 `outbox_entries` 和 `add_task` 作业。
3. 后续同步 action 获取远端 `inbox.org` 和 ETag。
4. ArkTS 追加 outbox 内容并使用条件 `PUT` 上传。
5. 成功后 Rust 确认对应 outbox 条目；失败时保留条目并按重试策略运行。

因此离线创建的任务在应用重启后仍可上传，且不会覆盖桌面端后来写入的 inbox 内容。

## 后台、重试与 UI

WorkScheduler 只负责唤醒应用并创建或认领作业，不直接保存同步状态。作业状态为 `queued`、`running`、`retry_wait`、`blocked`、`completed` 或 `failed`。

- 网络超时和 5xx：指数退避，例如 1、5、15、60 分钟。
- `401`/`403`：标记 `blocked`，要求用户更新凭据。
- TLS 错误：标记失败并保留本地数据。
- `412`：创建冲突，不重试无条件上传。
- 解析失败：保留现有日历事件，不生成删除 action。
- 应用中断：执行租约过期后由下一次初始化或后台唤醒恢复。

UI 至少应显示连接、下载、上传 pending 任务、导入日历、完成统计以及认证、TLS、网络、解析和冲突错误。页面通过 `/v1/service-status` 和 `/v1/changes` 获取状态，Rust 不直接操作 UI。

## 安全要求

- 声明 `ohos.permission.INTERNET`，默认仅接受 HTTPS。
- 密码使用 Asset Store 持久化，设备首次解锁后可供后台同步读取。
- 不记录带凭据的 URL、Authorization header、密码或完整响应内容。
- 缓存、数据库和 outbox 只放在应用私有目录。
- 推荐用户使用坚果云或 Nextcloud 的应用专用密码。

## 测试矩阵

自动化测试至少覆盖：

1. 连接校验：正常仓库、`401`、TLS 失败、目录不存在、超时。
2. `PROPFIND` 解析：根目录、子目录、编码文件名、绝对和相对 href、忽略规则。
3. 下载与上传：UTF-8 内容、新文件、修改文件、缺失文件、临时写入失败。
4. 条件写入：`If-Match` 成功与 `412` 冲突。
5. 离线新增任务：跨进程重启后仍存在且恰好上传一次。
6. 决策表的全部状态以及远端删除。
7. 手动与后台同步不能重叠。
8. 列举或解析失败不会触发日历删除。

真机联调使用独立的坚果云或 Nextcloud 测试目录。从电脑和手机两端分别创建、修改、重命名和删除文件，确认任何一端的编辑不会被另一端静默覆盖。
