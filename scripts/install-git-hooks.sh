#!/bin/sh

# 将仓库内可版本化的 hook 目录应用到当前 clone。

set -eu

repository_root=$(git rev-parse --show-toplevel)
cd "$repository_root"
git config core.hooksPath scripts/git-hooks
echo "已启用 Git hooks: scripts/git-hooks"
