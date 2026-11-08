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
- Git 提交信息用修改的功能点进行描述

## 项目概述

Org Tasks 是一个 HarmonyOS NEXT 应用，用于展示和操作 org-mode 任务。

技术栈为 ArkTS + ArkUI、Rust 领域核心与 C++ N-API bridge；使用 DevEco Studio、hvigorw 和 Makefile 构建。

## 核心架构约束

- Cargo workspace 由 `core`、`harmony` 和 `http` 组成；依赖方向只能是 `harmony -> core` 和 `http -> core`。
- 领域规则、解析、查询与同步统一由 `core` 实现；宿主和 bridge 只做接入，不复制领域逻辑。新增能力先修改 `core`，再由宿主接入。
- `OrgFile` 使用 `orgize` 无损语法树，语义以 Emacs `org-element.el` 为准；未修改文件和局部编辑未涉及的字节必须保持原样。
- UI 组装通用查询、维护交互并展示结果，默认不再次过滤任务；今天、随时、某天的共享标签筛选条仅在展示层筛选本页已加载快照，作为明确例外。Core 不持有页面或控件专属语义。
- 仓库身份与同步记录由 Core 管理；凭据留在宿主安全存储，不进入日志或同步记录。

模块职责、异步运行时、查询参数与持久化边界统一见 [架构设计](docs/架构设计.org)。修改对应模块前，必须查阅下列专项设计并保持实现与设计一致。

| 修改范围 | 设计依据 |
| --- | --- |
| 核心 API、领域模型 | [接口文档](docs/core/接口文档.org)、[数据模型](docs/core/数据模型.org)；模型变化同步更新说明与内嵌 TikZ UML 源码 |
| 同步与持久化 | [WebDAV 同步能力设计](<docs/core/WebDAV 同步能力设计.org>)、[目录结构设计](docs/core/目录结构设计.org) |
| 任务查询 | [查询语言设计](docs/core/查询语言设计.org) |
| Harmony bridge 与配置 | [Rust bridge 设计](<docs/harmony/Rust bridge设计.org>)、[配置项设计](docs/harmony/配置项设计.org) |
| HTTP 宿主 | [服务命令行设计](docs/http/服务命令行设计.org) |
| 手机 UI | [entry 模块规范](entry/AGENTS.md)、[UI 导航设计](docs/harmony/UI导航设计.org)、[手机应用功能清单](docs/手机应用功能清单.org) |

手机应用用户可见的功能、入口或交付状态变化必须同步更新功能清单；Core、CLI、HTTP 和测试程序的能力不记入该清单。

## 常用操作

```bash
make help          # 查看所有命令
make build         # 编译 Debug 包
make deploy        # 编译 + 安装 + 启动
make log           # 查看应用日志
make devices       # 查看已连接设备
```

本机工具路径与环境变量见 `AGENTS.local.md`。
