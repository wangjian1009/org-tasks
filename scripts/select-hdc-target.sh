#!/bin/sh
# 只向标准输出返回设备 ID，诊断信息写入标准错误，供 Makefile 安全选择目标。
set -eu

hdc_bin=$1
requested_target=${2:-}
physical_only=${3:-}

fail() {
  echo "$*" >&2
  exit 1
}

target_list=$("$hdc_bin" list targets) || fail '读取 HDC 设备列表失败。'
target_list=$(printf '%s\n' "$target_list" | tr -d '\r' | awk 'NF == 1 && $1 != "[Empty]" { print $1 }')

is_physical() {
  # 按设备属性识别，避免把通过 TCP 连接的真机误判为模拟器。
  model=$("$hdc_bin" -t "$1" shell param get const.product.model) || return 1
  model=$(printf '%s' "$model" | tr -d '\r\n')
  case "$model" in
    ''|*[Ee][Mm][Uu][Ll][Aa][Tt][Oo][Rr]*|\[Fail\]*) return 1 ;;
    *) return 0 ;;
  esac
}

if [ -n "$requested_target" ]; then
  printf '%s\n' "$target_list" | awk -v target="$requested_target" '
    $0 == target { found = 1 }
    END { exit !found }
  ' || fail "指定设备未连接：$requested_target"
  if [ "$physical_only" = '--physical' ]; then
    is_physical "$requested_target" || fail "make deploy 仅支持真机，指定目标不是可确认的真机：$requested_target"
  fi
  printf '%s\n' "$requested_target"
  exit 0
fi

selected_target=''
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if is_physical "$candidate"; then
    [ -z "$selected_target" ] || fail '检测到多台真机，请通过 HDC_TARGET 指定目标。'
    selected_target=$candidate
  fi
done <<EOF
$target_list
EOF

[ -n "$selected_target" ] || fail '未检测到真机，请连接真机并开启调试。'
printf '%s\n' "$selected_target"
