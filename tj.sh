#!/bin/bash
# 铁酱脚本的入口菜单。
# 用法: curl -fL https://raw.githubusercontent.com/teijiang/sh/main/tj.sh -o tj.sh && bash tj.sh
# shortcut: 同目录已有文件则直接运行且不覆盖；要拉最新版先删掉对应 sh。

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

BASE="https://raw.githubusercontent.com/teijiang/sh/main"
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

files=(
  cker.sh
  fix-debian12-13_cve-2026-99999.sh
  hy2tj.sh
  benchx.sh
  clear.sh
  fio.sh
)
labels=(
  "更换 Debian 12/13 内核"
  "更换 Debian 12/13 内核，修复cve_2026-99999漏洞"
  "hy2 最新一键脚本，输出二维码"
  "快速测试 GB5 评分"
  "快速清理系统"
  "硬盘经典测试"
)

[ "${#files[@]}" -eq "${#labels[@]}" ] || { echo "菜单配置不一致" >&2; exit 1; }

run_one() {
  name="$1"
  path="$here/$name"
  if [ ! -f "$path" ]; then
    command -v curl >/dev/null 2>&1 || { echo "缺少 curl，且本地没有 $name" >&2; return 1; }
    [ -w "$here" ] || { echo "目录不可写，无法下载: $here" >&2; return 1; }
    echo "下载 $name ..."
    curl -fL "$BASE/$name" -o "$path.partial" && mv "$path.partial" "$path" || {
      rm -f "$path.partial"
      echo "下载失败: $BASE/$name" >&2
      return 1
    }
  fi
  echo
  echo ">>> $name"
  bash "$path"
}

while true; do
  echo
  echo "======== debian12-13 tj脚本菜单 ========"
  i=1
  while [ "$i" -le "${#files[@]}" ]; do
    printf '  %d) %s  %s\n' "$i" "${files[$((i - 1))]}" "${labels[$((i - 1))]}"
    i=$((i + 1))
  done
  echo "  0) 退出"
  printf '请选择: '
  if ! read -r choice; then
    echo
    exit 0
  fi
  case "$choice" in
    0|q|Q) exit 0 ;;
    ""|*[!0-9]*) echo "无效选择"; continue ;;
  esac
  n=$((10#$choice))
  if [ "$n" -lt 1 ] || [ "$n" -gt "${#files[@]}" ]; then
    echo "无效选择"
    continue
  fi
  run_one "${files[$((n - 1))]}" || echo "失败，退出码: $?"
done
