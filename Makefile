# Org Tasks - HarmonyOS 应用编译安装 Makefile

# DevEco Studio 工具链路径
DEVECO_HOME    := /Applications/DevEco-Studio.app/Contents
NODE_HOME      := $(DEVECO_HOME)/tools/node
HVIGOR_HOME    := $(DEVECO_HOME)/tools/hvigor
OHPM           := $(DEVECO_HOME)/tools/ohpm/bin/ohpm
HDC            := $(DEVECO_HOME)/sdk/default/openharmony/toolchains/hdc
HVIGORW        := $(HVIGOR_HOME)/bin/hvigorw

# SDK 路径。DevEco Studio 6.1 的内置 HarmonyOS SDK 位于此目录。
# 可通过环境变量或命令行覆盖，例如 make build DEVECO_SDK_HOME=/path/to/sdk。
DEVECO_SDK_HOME ?= $(DEVECO_HOME)/sdk

# 环境变量
export NODE_HOME
export DEVECO_SDK_HOME
export PATH := $(NODE_HOME)/bin:$(HVIGOR_HOME)/bin:$(OHPM):$(HDC):$(PATH)

# 构建产物
HAP_DIR := entry/build/default/outputs/default

# 应用信息（根据实际项目修改）
BUNDLE_NAME := com.example.orgtasks
ABILITY_NAME := EntryAbility

.PHONY: all clean install install-only run deploy log log-all deps check-sdk help

# 默认目标：编译
all: build

# 安装依赖
deps:
	@echo ">>> 安装依赖..."
	cd $(CURDIR) && $(OHPM) install

# HarmonyOS 6.1.1 的 Hvigor 通过 sdk-pkg.json 发现已安装的组合 SDK。
check-sdk:
	@test -d "$(DEVECO_SDK_HOME)" || { echo "未找到 HarmonyOS SDK: $(DEVECO_SDK_HOME)"; exit 1; }
	@find "$(DEVECO_SDK_HOME)" -maxdepth 2 -name 'sdk-pkg.json' -print -quit | grep -q . || { \
		echo "HarmonyOS SDK 安装不完整或与当前 DevEco Studio 不兼容: $(DEVECO_SDK_HOME)"; \
		echo "请在 DevEco Studio 的 Tools > SDK Manager > SDK > HarmonyOS 中重新安装 6.1.1 (API 24) 的 SDK 组件。"; \
		exit 1; \
	}

# 编译 Debug 包
build: deps check-sdk
	@echo ">>> 编译 Debug 包..."
	cd $(CURDIR) && $(HVIGORW) assembleHap --mode module -p product=default -p buildMode=debug -p debuggable=true --no-daemon

# 编译 Release 包
release: deps check-sdk
	@echo ">>> 编译 Release 包..."
	cd $(CURDIR) && $(HVIGORW) assembleHap --mode module -p product=default -p buildMode=release --no-daemon

# 安装到设备
install: build
	@echo ">>> 检查设备连接..."
	@$(HDC) list targets | grep -q . || { echo "未检测到设备，请连接 USB 并开启调试"; exit 1; }
	@hap_file="$$(find "$(HAP_DIR)" -maxdepth 1 -type f -name '*-signed.hap' -print -quit)"; \
		test -n "$$hap_file" || { echo "未找到已签名 HAP，请先在 DevEco Studio 配置 default 调试签名。"; exit 1; }; \
		echo ">>> 安装应用: $$hap_file"; \
		$(HDC) install -r "$$hap_file"

# 仅安装（不重新编译）
install-only:
	@echo ">>> 检查设备连接..."
	@$(HDC) list targets | grep -q . || { echo "未检测到设备"; exit 1; }
	@hap_file="$$(find "$(HAP_DIR)" -maxdepth 1 -type f -name '*-signed.hap' -print -quit)"; \
		test -n "$$hap_file" || { echo "未找到已签名 HAP，请先在 DevEco Studio 配置 default 调试签名。"; exit 1; }; \
		echo ">>> 安装应用: $$hap_file"; \
		$(HDC) install -r "$$hap_file"

# 启动应用
run:
	@echo ">>> 启动应用..."
	$(HDC) shell aa start -a $(ABILITY_NAME) -b $(BUNDLE_NAME)

# 编译 + 安装 + 启动
deploy: install run

# 查看日志
log:
	$(HDC) shell hilog | grep -i "org"

# 查看完整日志
log-all:
	$(HDC) shell hilog

# 清理构建产物
clean:
	@echo ">>> 清理构建产物..."
	cd $(CURDIR) && $(HVIGORW) clean --no-daemon
	rm -rf entry/build
	rm -rf build

# 重启应用
restart:
	@echo ">>> 停止应用..."
	-$(HDC) shell aa force-stop $(BUNDLE_NAME)
	@sleep 1
	@echo ">>> 启动应用..."
	$(HDC) shell aa start -a $(ABILITY_NAME) -b $(BUNDLE_NAME)

# 卸载应用
uninstall:
	@echo ">>> 卸载应用..."
	-$(HDC) uninstall $(BUNDLE_NAME)

# 查看设备列表
devices:
	$(HDC) list targets

# 帮助
help:
	@echo "可用目标:"
	@echo "  make deps          安装依赖"
	@echo "  make build         编译 Debug 包"
	@echo "  make release       编译 Release 包"
	@echo "  make install       编译并安装到设备"
	@echo "  make install-only  仅安装（不编译）"
	@echo "  make run           启动应用"
	@echo "  make deploy        编译 + 安装 + 启动"
	@echo "  make restart       重启应用"
	@echo "  make uninstall     卸载应用"
	@echo "  make log           查看应用日志"
	@echo "  make log-all       查看全部日志"
	@echo "  make devices       查看已连接设备"
	@echo "  make clean         清理构建产物"
