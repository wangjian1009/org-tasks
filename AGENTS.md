# AGENTS.md

本文件为在此仓库中工作的 AI 代理提供协作规范。

## 文档规范

- 项目中的文档说明、设计决策、注释性段落和面向用户的文本使用中文。
- 代码、命令、路径、协议名、API 名称、字段名和技术专有名词保留其原始英文形式。
- 项目文档统一使用 Org 格式，放置于 `docs/*.org`；不得新增 Markdown 文档。
- UML 使用 LaTeX `TikZ` 与 `tikz-uml` 绘制，与说明紧邻的 `\begin{tikzpicture}` 源码内嵌维护；不保留独立 `.puml` 或 `.tex` 文件。
- 测试程序的功能、子命令和参数不得写入项目文档；通过程序的 `-h` 或 `--help` 发现和验证。

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
├── Cargo.toml                         # Rust workspace 配置
├── core/                              # 本地 OrgRepo 管理、解析与同步核心库
├── harmony/                           # HarmonyOS 手机上的仓库维护能力
├── http/                              # Rust Web App 宿主
├── entry/                             # HarmonyOS 应用模块，详见 entry/AGENTS.md
```

## Rust 架构决策

- 仓库根目录是 Cargo workspace，成员为 `core`、`harmony` 和 `http`。
- `core` 是独立的本地仓库核心库，依赖方向只能是 `harmony -> core` 和 `http -> core`；禁止反向依赖或适配层之间的依赖。
- `core::model` 负责 `OrgRepo` 的本地目录扫描、org 文件解析、保真编辑与同步记录数据维护；`core::webdav` 实现 `SyncPolicy`，负责 WebDAV 文件传输、下载写回、条件写入和同步记录生成。`SyncPolicy` 是后续接入其他同步方式的扩展点。
- `OrgFile` 是单个完整 org 文件的根模型，使用 `orgize` 提供无损运行时语法树；解析、编辑、序列化和展示的语义必须以 Emacs 自带 `org-element.el` 为准。不得另建不兼容的项目解析 AST；未修改文件必须直接写回原始字节，局部编辑后不得改写未涉及的字节区间。
- `core/src/bin/org-tasks/` 是操作本地 `OrgRepo` 的命令行程序，使用 Tokio 作为异步运行时。`core::model` 的加载与同步控制器、`core::webdav` 的文件与 HTTP I/O 均运行于 Tokio；`http` 只提供 Web App 操作入口；`harmony` 提供 HarmonyOS 手机上的仓库维护入口。新增仓库或同步能力时先修改 `core`，再由宿主接入。
- Rust bridge 位于与 `http` 平级的 `harmony` 模块，负责将 Harmony 宿主请求转换为对 `core` 已有 API 的调用，并处理 N-API 参数编组、异步边界、结果投影与资源释放。bridge 不得重写 `OrgRepo`、`SyncPolicy`、WebDAV 或 org 解析算法；新增领域规则与可复用数据结构仍须先定义在 `core`。

HTTP 宿主 `org-tasks-httpd` 位于 `http/src/bin/`；其命令行、监听、认证、CSV 数据目录与并发约束见 `docs/http/服务命令行设计.org`。修改该宿主前必须遵循该文档。

Rust 核心 API、数据结构、WebDAV 同步能力、仓库内 `.sync` 目录布局、CSV 映射和规划模型见 `docs/core/`；实体关系的 TikZ UML 源码内嵌在 `docs/core/数据模型.org`。修改领域模型或同步记录持久化时必须同步更新说明和源码块。

仓库同步记录保存于 `OrgRepo` 根目录的 `.sync/`，其 `id` 文件是稳定的仓库标识来源；详细布局、恢复与隔离规则见 `docs/core/目录结构设计.org`。同步元数据、作业历史和 outbox 仅保存相对路径与变更检测信息，不保存绝对路径、完整文件或解析任务。按用户确认的冲突处理规则，完整本地冲突文件仅可备份到 `.sync/backups/<合并开始时间>/`，与同步记录分目录维护；备份不参与 Org 扫描或 WebDAV 传输。

## 手机应用功能清单

手机应用的功能范围、当前实现状态与验收要点统一维护于 `docs/手机应用功能清单.org`。修改手机应用中用户可见的功能、入口或交付状态时，必须同步更新该文档；Rust core、CLI、HTTP 宿主和测试程序的能力不记录在该清单中。

## 常用操作

### 编译安装
```bash
make help          # 查看所有命令
make build         # 编译 Debug 包
make deploy        # 编译 + 安装 + 启动
make log           # 查看应用日志
make devices       # 查看已连接设备
```

## 本地设置

本机工具路径与环境变量见 `AGENTS.local.md`。
