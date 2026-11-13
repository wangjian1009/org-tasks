# entry 模块规范

本文件适用于 `entry/` 及其子目录。项目级规范、Rust 架构约束、文档规范与提交规范见父目录 `AGENTS.md`。

## 核心约束

- ArkTS 只负责界面与平台接入，不解析 Org、不实现同步规则；默认不再次过滤任务，今天、随时、某天和备忘的共享标签筛选条仅筛选本页已加载快照，作为展示层例外。
- Core 请求必须通过 bridge 在工作线程执行，不阻塞 ArkUI；跨语言接口保持 Rust 对象边界，参数使用结构化对象。
- 修改 bridge 时同时更新 Rust、`src/main/cpp/napi_init.cpp`、`src/main/cpp/types/liborg_tasks_harmony/index.d.ts`、ArkTS wrapper、调用方与接口设计。
- 仓库与凭据身份保持稳定；真实密码只通过 `CredentialService` 存入 Asset Store。

目录职责、线程、对象映射和平台约束见 [架构设计](../docs/架构设计.org)；修改 bridge 或配置前分别遵循 [Rust bridge 设计](<../docs/harmony/Rust bridge设计.org>) 和 [配置项设计](../docs/harmony/配置项设计.org)。修改配置项、保存位置或凭据处理时，同步更新配置项设计。

## 布局与设计同步

修改页面布局、侧边栏入口位置或交互范围时，必须同步更新 `docs/harmony/设计文件索引.org` 中对应功能的当前 Harmony 画板（源文件位于 `design/当前实现/`，共享规范位于 `design/规范/`）、`docs/harmony/UI导航设计.org` 和手机应用功能清单；不能仅修改实现或仅添加说明。

## 构建与设备

使用根目录 `make help` 查阅命令；常用 `make build`、`make deploy`、`make devices` 和 `make log`。本机环境见根目录 `AGENTS.local.md`。
