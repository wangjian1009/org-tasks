# AGENTS.md

本文件为在此仓库中工作的 AI 代理提供协作规范。

## 文档规范

- 项目中的文档说明、设计决策、注释性段落和面向用户的文本使用中文。
- 代码、命令、路径、协议名、API 名称、字段名和技术专有名词保留其原始英文形式。

## 提交规范

- Git 提交信息使用中文，遵循 Conventional Commits 的类型前缀，例如 `feat: 接入 Rust 核心服务`。

## 项目概述

Org Tasks 是一个 HarmonyOS NEXT 应用，用于将 org-mode 任务同步到系统日历。通过坚果云/Nextcloud WebDAV 将 org 文件同步到手机，应用解析后写入系统日历，并支持从手机新增任务写回 `inbox.org`。

## 技术栈

- **语言**: ArkTS（TypeScript 超集）+ Rust（领域核心）+ C++（N-API bridge）
- **UI 框架**: ArkUI（声明式 UI）
- **目标平台**: HarmonyOS NEXT（API 12）
- **构建工具**: hvigorw + Makefile
- **IDE**: DevEco Studio

## 目录结构

```
org-tasks/
├── Makefile                          # 编译安装脚本
├── build-profile.json5               # 项目构建配置
├── entry/
│   ├── oh-package.json5              # 模块依赖
│   └── src/main/
│       ├── cpp/                      # CMake + C++ N-API bridge，链接 Rust 静态库
│       ├── module.json5              # 模块清单（权限、后台任务注册）
│       ├── resources/                # 字符串、颜色、页面路由
│       └── ets/
│           ├── models/
│           │   └── OrgTask.ets       # 数据模型 + 应用配置
│           ├── services/
│           │   ├── OrgParser.ets     # org 文件解析器
│           │   ├── FileService.ets   # 文件读写
│           │   ├── CalendarSync.ets  # 系统日历同步
│           │   └── NativeCoreService.ets # 异步调用 Rust 核心服务
│           ├── entryability/
│           │   ├── EntryAbility.ets       # 应用入口，注册后台任务
│           │   └── SyncWorkExtension.ets  # WorkScheduler 后台同步回调
│           └── pages/
│               ├── Index.ets         # 主页（同步按钮 + 状态）
│               ├── AddTask.ets       # 新增任务
│               └── Settings.ets      # 设置（路径、间隔等）
```

`rust/` 是独立 Cargo workspace：`core` 保持平台无关，`harmony` 提供 FFI 访问适配，`http` 提供 RESTful 映射。Harmony 侧的 C++ N-API bridge 通过 `napi_create_async_work` 将 Rust 调用放到工作线程，避免阻塞 ArkUI 线程。

## 核心功能

| 功能 | 实现文件 | 说明 |
|------|---------|------|
| Org 解析 | `OrgParser.ets` | 解析 TODO/NEXT/WAIT/DONE/CNCL、SCHEDULED、DEADLINE、优先级、标签、进度 |
| 日历同步 | `CalendarSync.ets` | 调用 calendarManager API 写入系统日历 |
| 文件读写 | `FileService.ets` | 读取 org 目录，追加写入 inbox.org |
| 后台同步 | `SyncWorkExtension.ets` | WorkScheduler 定时触发，默认 15 分钟 |
| 新增任务 | `AddTask.ets` | 写入 inbox.org（路径可配置） |

## 数据流

```
坚果云 WebDAV → 本地目录 → OrgParser 解析 → CalendarSync 写入系统日历
                                                    ↓
新增任务 → FileService → inbox.org → 坚果云同步回电脑
```

## 常用操作

### 编译安装
```bash
make help          # 查看所有命令
make build         # 编译 Debug 包
make deploy        # 编译 + 安装 + 启动
make log           # 查看应用日志
make devices       # 查看已连接设备
```

### 前提条件
1. 安装 DevEco Studio（提供 SDK、hvigorw、hdc、ohpm）
2. 设备开启开发者模式（设置 → 关于手机 → 点击 7 次版本号）
3. 开启 USB 调试（设置 → 系统 → 开发者选项 → USB 调试）
4. USB 连接设备，`make devices` 确认连接

## 配置项

应用配置存储在 Preferences 中，可在设置页面修改：

| 配置 | 默认值 | 说明 |
|------|--------|------|
| orgDir | `/storage/.../CloudDrive/org-roam/tasks` | 坚果云同步的 org 目录 |
| inboxFile | `inbox.org` | 新增任务写入的文件 |
| calendarName | `Org Tasks` | 系统日历名称 |
| syncInterval | `15` | 自动同步间隔（分钟） |

## 注意事项

- `calendarManager` API 签名可能随 HarmonyOS 版本变化，需对照最新 SDK 调整
- 文件路径需根据坚果云客户端实际同步目录修改
- `resources/base/media/` 下的图标资源需手动提供
- Release 包需要华为开发者账号签名，首次需在 DevEco Studio 中配置
- `BUNDLE_NAME` 在 Makefile 中需与实际项目包名一致
