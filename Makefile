# Org Tasks - HarmonyOS 应用编译安装 Makefile

# DevEco Studio 工具链路径
DEVECO_HOME    := /Applications/DevEco-Studio.app/Contents
NODE_HOME      := $(DEVECO_HOME)/tools/node
HVIGOR_HOME    := $(DEVECO_HOME)/tools/hvigor
OHPM           := $(DEVECO_HOME)/tools/ohpm/bin/ohpm
HDC            := $(DEVECO_HOME)/sdk/default/openharmony/toolchains/hdc
HVIGORW        := $(HVIGOR_HOME)/bin/hvigorw
# 默认选择 HDC 列表中的唯一设备；多设备场景仍可通过 HDC_TARGET 显式覆盖。
HDC_TARGET     ?= $$( $(HDC) list targets | awk 'NR == 1 { print $$1 }' )
HDC_DEVICE     := $(HDC) $(if $(HDC_TARGET),-t $(HDC_TARGET))

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

.PHONY: all build release clean install install-only run deploy log log-all deps check-sdk docs-export icons setup-hooks help

# 默认目标：编译
all: build

# 安装依赖
deps:
	@echo ">>> 安装依赖..."
	cd $(CURDIR) && $(OHPM) install --all

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
	@"$(NODE_HOME)/bin/node" scripts/build-hap.cjs debug "$(DEVECO_HOME)"

# 编译 Release 包
release: deps check-sdk
	@echo ">>> 编译 Release 包..."
	@"$(NODE_HOME)/bin/node" scripts/build-hap.cjs release "$(DEVECO_HOME)"

# 安装到设备
install: build
	@echo ">>> 检查设备连接..."
	@$(HDC) list targets | grep -q . || { echo "未检测到设备，请连接 USB 并开启调试"; exit 1; }
	@hap_file="$$(find "$(HAP_DIR)" -maxdepth 1 -type f -name '*-signed.hap' -print -quit)"; \
		test -n "$$hap_file" || { echo "未找到已签名 HAP，请先执行 make build。"; exit 1; }; \
		echo ">>> 安装应用: $$hap_file"; \
		$(HDC_DEVICE) install -r "$$hap_file"

# 仅安装（不重新编译）
install-only:
	@echo ">>> 检查设备连接..."
	@$(HDC) list targets | grep -q . || { echo "未检测到设备"; exit 1; }
	@hap_file="$$(find "$(HAP_DIR)" -maxdepth 1 -type f -name '*-signed.hap' -print -quit)"; \
		test -n "$$hap_file" || { echo "未找到已签名 HAP，请先执行 make build。"; exit 1; }; \
		echo ">>> 安装应用: $$hap_file"; \
		$(HDC_DEVICE) install -r "$$hap_file"

# 启动应用
run:
	@echo ">>> 启动应用..."
	$(HDC_DEVICE) shell aa start -a $(ABILITY_NAME) -b $(BUNDLE_NAME)

# 编译 + 安装 + 启动
deploy: install run

# 查看日志
log:
	$(HDC_DEVICE) shell hilog | grep -i "org"

# 查看完整日志
log-all:
	$(HDC_DEVICE) shell hilog

# 清理构建产物
clean:
	@echo ">>> 清理构建产物..."
	cd $(CURDIR) && $(HVIGORW) clean --no-daemon
	rm -rf entry/build
	rm -rf build

# 重启应用
restart:
	@echo ">>> 停止应用..."
	-$(HDC_DEVICE) shell aa force-stop $(BUNDLE_NAME)
	@sleep 1
	@echo ">>> 启动应用..."
	$(HDC_DEVICE) shell aa start -a $(ABILITY_NAME) -b $(BUNDLE_NAME)

# 卸载应用
uninstall:
	@echo ">>> 卸载应用..."
	-$(HDC_DEVICE) uninstall $(BUNDLE_NAME)

# 查看设备列表
devices:
	$(HDC) list targets

# 根据 Org 导出设置创建输出目录。
# 仅接受位于 output/ 下的相对路径，避免文档设置意外创建仓库外目录。
docs-export:
	@set -eu; \
	normalize_path() { \
		printf '%s\n' "$$1" | awk -F/ '{ \
			for (i = 1; i <= NF; i++) { \
				part = $$i; \
				if (part == "" || part == ".") continue; \
				if (part == "..") { \
					if (count == 0) exit 1; \
					count--; \
				} else { \
					parts[++count] = part; \
				} \
			} \
			for (i = 1; i <= count; i++) { \
				printf "%s%s", (i == 1 ? "" : "/"), parts[i]; \
			} \
			print ""; \
		}'; \
	}; \
	find docs -type f -name '*.org' -print | while IFS= read -r org_file; do \
		awk ' \
			/^[[:space:]]*#[+]EXPORT_FILE_NAME:[[:space:]]*/ { \
				path = $$0; \
				sub(/^[[:space:]]*#[+]EXPORT_FILE_NAME:[[:space:]]*/, "", path); \
				print path; \
			} \
			/:file[[:space:]]+/ { \
				path = $$0; \
				sub(/^.*:file[[:space:]]+/, "", path); \
				sub(/[[:space:]].*$$/, "", path); \
				print path; \
			}' "$$org_file" | while IFS= read -r export_file; do \
			[ -n "$$export_file" ] || continue; \
			case "$$export_file" in \
				/*) echo "拒绝绝对导出路径: $$export_file" >&2; exit 1 ;; \
			esac; \
			export_path="$$(normalize_path "$$(dirname "$$org_file")/$$export_file")" \
				|| { echo "无法归一化导出路径: $$export_file" >&2; exit 1; }; \
			case "$$export_path" in \
				output/*) mkdir -p "$$(dirname "$$export_path")" ;; \
				*) echo "拒绝 output 目录外的导出路径: $$export_file" >&2; exit 1 ;; \
			esac; \
		done; \
	done
	@echo ">>> 已按 Org 导出设置创建 output/docs 下的目录"

# 重新生成应用使用的两套 HarmonyOS 图标资源。
icons:
	@echo ">>> 导出 HarmonyOS App 图标..."
	@python3 scripts/export-harmony-icons.py

# 启用 WorkTree 配置 hook，使新 WorkTree 自动链接主工作树的 AGENTS.local.md。
setup-hooks:
	@./scripts/install-git-hooks.sh

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
	@echo "  make deploy       部署到唯一连接设备（多设备时可设置 HDC_TARGET）"
	@echo "  make docs-export  按 Org 设置创建 output/docs 下的导出目录"
	@echo "  make clean         清理构建产物"
	@echo "  make icons         导出 HarmonyOS App 图标资源"
	@echo "  make setup-hooks   启用 WorkTree 本地配置软链接 hook"
