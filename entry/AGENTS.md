# entry 模块规范

本文件适用于 `entry/` 及其子目录。项目级规范、Rust 架构约束、文档规范与提交规范见父目录 `AGENTS.md`。

## 目录与职责

```
entry/
├── oh-package.json5                  # Harmony 模块依赖
└── src/main/
    ├── cpp/                           # CMake + C++ N-API bridge，链接 Rust 静态库
    ├── module.json5                   # 模块清单、权限和后台任务注册
    ├── resources/                     # 字符串、颜色、媒体和页面路由
    └── ets/
        ├── models/
        │   └── OrgTask.ets            # ArkTS 数据模型与应用配置
        ├── services/
        │   ├── CalendarSync.ets        # 系统日历同步
        │   ├── CredentialService.ets   # Asset Store 凭据
        │   ├── AppConfigService.ets    # Preferences 配置读取
        │   └── NativeCoreService.ets # core bridge 的对象与结构化响应
        ├── entryability/
        │   ├── EntryAbility.ets        # 应用入口与后台任务注册
        │   └── SyncWorkExtension.ets   # WorkScheduler 后台同步回调
        └── pages/
            ├── CalendarSync.ets       # 设置中的系统日历同步
            ├── AddTask.ets            # 新增任务
            ├── Files.ets              # 文件列表
            ├── FileDetail.ets         # 文件详情
            └── Settings.ets           # 仓库、日历与 WebDAV 设置
```

## 线程与 Bridge

ArkUI 线程不得执行 core 请求。C++ N-API bridge 必须使用 `napi_create_async_work` 在工作线程调用 Rust；ArkTS 通过 `NativeCoreService` 打开并持有 native `Workspace` / `Repo` / `WebDavSyncPolicy` 对象。ArkTS 不得解析 org 内容或重写 core 同步规则。

TS 领域接口必须遵循 `docs/harmony/Rust bridge设计.org` 中的“接口设计规范”和 Rust/TS 对照表：按 `Workspace -> Repo -> OrgFile` 访问对象，Rust 字段映射为属性，行为归属原领域对象，结构化参数直接使用 TS 对象，JSON 编组仅在 bridge 内部完成。新增或调整接口时同步更新该规范、N-API 声明、ArkTS wrapper 和全部调用方。

新增 N-API 方法时必须同时更新：

- `src/main/cpp/napi_init.cpp`
- `src/main/cpp/types/liborg_tasks_harmony/index.d.ts`
- 对应 ArkTS service

## 数据流

```
坚果云 WebDAV → NativeCoreService → harmony bridge → core OrgWorkspace
                                                        ↓
                                                  CalendarSync 写入系统日历
```

Rust core 的 `OrgRepo`、`OrgWorkspace`、`Filter`、`SyncPolicy` 与 WebDAV 同步能力是领域接口；ArkTS 仅承担页面、日历、凭据和调度 I/O。跨越这些边界时不得把密码、绝对目录或完整 org 内容写入 Rust 同步记录。

## 查询请求与过滤边界

界面需求由 UI 负责组装查询请求，查询逻辑统一由 Core 完成，界面不再做任务过滤。ArkTS 页面和 service 只能维护选择状态、组装 `TaskQuery`、显示返回的 `tasks` 与计数；不得按完成、分类、文件或父子关系重新筛选结果。收件箱和分类页面差异通过请求参数表达，Core 不增加页面专属字段。详见 `docs/core/查询语言设计.org` 与 `docs/harmony/Rust bridge设计.org`。

## 配置与保存

Harmony 的数据源配置、Preferences、Asset Store 凭据、core 状态与日历映射统一维护于 `docs/harmony/配置项设计.org`。修改配置项、保存位置或凭据处理方式时，必须同步更新该文档。

`repoId` 是同步记录与 WebDAV 凭据的稳定分区标识。修改目录或 WebDAV 地址时不得更改它。WebDAV 密码只能由 `CredentialService` 写入 Asset Store，不能放入 Preferences、日志或同步记录。

## 布局与设计同步

修改页面布局、侧边栏入口位置或交互范围时，必须同步更新 `design/Orgzly界面细节.fig` 中的当前 Harmony 画板、`docs/harmony/UI导航设计.org` 和手机应用功能清单；不能仅修改实现或仅添加说明。

## 构建与设备

前提条件：安装 DevEco Studio（提供 SDK、hvigorw、hdc、ohpm）；设备开启开发者模式和 USB 调试，并通过 `make devices` 确认连接。

- `make build`：编译 Debug HAP。
- `make deploy`：编译、安装并启动。
- `make log`：查看应用日志。

## HarmonyOS 注意事项

- `calendarManager` API 签名可能随 HarmonyOS 版本变化，修改前需对照当前 SDK。
- 文件路径需根据坚果云客户端实际同步目录处理。
- `resources/base/media/` 下的图标资源需单独提供。
- Release 包需要华为开发者账号签名。
- `BUNDLE_NAME` 在根目录 `Makefile` 中必须与实际应用包名一致。
