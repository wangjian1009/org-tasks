# AGENTS.md

本文件为在此仓库中工作的 AI 代理提供协作规范。

## 文档规范

- 项目中的文档说明、设计决策、注释性段落和面向用户的文本使用中文。
- 代码、命令、路径、协议名、API 名称、字段名和技术专有名词保留其原始英文形式。
- 项目文档统一使用 Org 格式，放置于 `docs/*.org`；不得新增 Markdown 文档。
- UML 使用 LaTeX `TikZ` 与 `tikz-uml` 绘制，与说明紧邻的 `\begin{tikzpicture}` 源码内嵌维护；不保留独立 `.puml` 或 `.tex` 文件。

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
├── core/                              # 平台无关的 Rust 领域核心库
├── harmony/                           # HarmonyOS FFI 与持久化适配 crate
├── http/                              # Rust HTTP 服务可执行程序与适配 crate
├── entry/                             # HarmonyOS 应用模块，详见 entry/AGENTS.md
```

## Rust 架构决策

- 仓库根目录是 Cargo workspace，成员为 `core`、`harmony` 和 `http`。
- `core` 是独立的领域核心库，依赖方向只能是 `harmony -> core` 和 `http -> core`；禁止反向依赖或适配层之间的依赖。
- `core` 不得依赖 ArkTS、N-API、HarmonyOS SDK、HTTP/网络库、数据库库或文件系统库。`core::model` 包含领域模型、保真编辑、校验、状态约束、同步记录与 `OrgRepoLoader`、`OrgRepoParser`、`SyncPolicy`、`OrgRepoSyncRecordStore` 等端口；`core::webdav` 包含基于 `WebDavTransport` 端口的同步决策与条件写入编排。
- 新增领域能力时先修改 `core`，再由 `harmony` 和 `http` 分别适配；平台 I/O、具体 HTTP 客户端、认证、持久化实现与线程调度只能位于适配层或应用宿主。

HTTP 宿主 `org-tasks-httpd` 位于 `http/src/bin/`；其命令行、监听、认证、CSV 数据目录与并发约束见 `docs/http/服务命令行设计.org`。修改该宿主前必须遵循该文档。

Rust 核心 API、数据结构、WebDAV 同步能力、CSV 映射和规划模型见 `docs/core/`；实体关系的 TikZ UML 源码内嵌在 `docs/core/数据模型.org`。修改领域模型时必须同步更新说明和源码块。

持久化仅保存相对路径的同步变更检测元数据、作业历史和 outbox 写入意图；同步基准目录通过运行时请求传入，不保存绝对路径、完整文件或解析任务。

## 功能清单

项目功能范围、当前实现状态、验收要点与规划项统一维护于 `docs/功能清单.org`。修改用户可见功能、入口或交付状态时，必须同步更新该文档；本文件不重复维护功能明细。

## 常用操作

### 编译安装
```bash
make help          # 查看所有命令
make build         # 编译 Debug 包
make deploy        # 编译 + 安装 + 启动
make log           # 查看应用日志
make devices       # 查看已连接设备
```
