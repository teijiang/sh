#!/bin/bash
# 铁酱脚本的入口菜单。

# 各脚本版本。
#ver cker.sh 0.1
#ver fix-debian12-13_cve-2026-99999.sh 0.1
#ver hy2tj.sh 0.1
#ver benchx.sh 0.1
#ver clear.sh 0.1
#ver fio.sh 0.1
#ver tj.sh 0.1
MIN_VER=0.1

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

ver_line() {
  local src="${2:-$0}" name="$1" line v
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "#ver ${name} "*)
        v="${line#"#ver ${name} "}"
        v=${v%$'\r'}
        v="${v%%[[:space:]]*}"
        v="${v#v}"
        v="${v#V}"
        printf '%s\n' "$v"
        return 0
        ;;
    esac
  done < "$src"
  return 1
}

ver_of() {
  local v
  if v="$(ver_line "$@")"; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$MIN_VER"
  fi
}

# $1 是否大于 $2。版本按点分开的数字比，从最小的一段开始。
ver_gt() {
  local a b i n x y
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  n=${#a[@]}
  (( ${#b[@]} > n )) && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    x=${a[i]:-0}
    y=${b[i]:-0}
    x=${x//[^0-9]/}
    y=${y//[^0-9]/}
    x=${x:-0}
    y=${y:-0}
    if ((10#$x > 10#$y)); then
      return 0
    fi
    if ((10#$x < 10#$y)); then
      return 1
    fi
  done
  return 1
}

valid_script_name() {
  case "$1" in
    ""|.*|*"/"*|*" "*|*$'\n'*|*$'\r'*) return 1 ;;
    *.sh) return 0 ;;
    *) return 1 ;;
  esac
}

fetch_script() {
  local name="$1" dest part
  valid_script_name "$name" || { echo "脚本名非法: ${name:-空}" >&2; return 1; }
  dest="${here%/}/$name"
  [ "$(basename -- "$dest")" = "$name" ] || { echo "目标路径异常: $dest" >&2; return 1; }
  [ ! -d "$dest" ] || { echo "目标是目录，拒绝覆盖: $dest" >&2; return 1; }
  part="$(mktemp "${dest}.XXXXXX")" || { echo "mktemp 失败: $dest" >&2; return 1; }
  if curl -fL "$BASE/$name" -o "$part" && mv -T -- "$part" "$dest"; then
    return 0
  fi
  rm -f "$part"
  echo "下载失败: $BASE/$name" >&2
  return 1
}

self_check() {
  local f
  valid_script_name "" && { echo "self-check: 空文件名" >&2; exit 1; }
  valid_script_name ".partial" && { echo "self-check: .partial" >&2; exit 1; }
  valid_script_name "cker.sh" || { echo "self-check: cker.sh" >&2; exit 1; }
  valid_script_name "fix-debian12-13_cve-2026-99999.sh" || { echo "self-check: 长文件名" >&2; exit 1; }
  ver_gt 0.2 0.1 || { echo "self-check: 0.2 > 0.1" >&2; exit 1; }
  ver_gt 0.10 0.9 || { echo "self-check: 0.10 > 0.9" >&2; exit 1; }
  ver_gt 1.2.3 1.2 || { echo "self-check: 1.2.3 > 1.2" >&2; exit 1; }
  ver_gt 0.1 0.1 && { echo "self-check: 相等不应大于" >&2; exit 1; }
  ver_gt 0.1 0.2 && { echo "self-check: 0.1 > 0.2" >&2; exit 1; }
  ver_gt 0.9 0.10 && { echo "self-check: 0.9 > 0.10" >&2; exit 1; }
  ver_gt 1.2 1.2.0 && { echo "self-check: 1.2 > 1.2.0" >&2; exit 1; }
  for f in "${files[@]}" tj.sh; do
    ver_line "$f" >/dev/null || { echo "缺少 #ver $f" >&2; exit 1; }
    [[ "$(ver_of "$f")" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "版本号非法: $f" >&2; exit 1; }
  done
  [ "$(ver_of nosuch.sh)" = "$MIN_VER" ] || { echo "缺省版本不是 $MIN_VER" >&2; exit 1; }
  echo "self-check ok"
  exit 0
}

run_one() {
  local name="$1" path="${here%/}/$name"
  if [ ! -f "$path" ]; then
    command -v curl >/dev/null 2>&1 || { echo "缺少 curl，且本地没有 $name" >&2; return 1; }
    [ -w "$here" ] || { echo "目录不可写，无法下载: $here" >&2; return 1; }
    echo "下载 $name ..."
    fetch_script "$name" || return 1
  fi
  echo
  echo ">>> $name"
  bash "$path"
}

check_updates() {
  local tmp name lv rv status line sorted fail=0 has_ver=0 answer i part
  local -a names rows outdated loc rem
  command -v curl >/dev/null 2>&1 || { echo "缺少 curl" >&2; return 1; }
  command -v sort >/dev/null 2>&1 || { echo "缺少 sort" >&2; return 1; }
  tmp="$(mktemp)" || { echo "mktemp 失败" >&2; return 1; }
  echo "正在获取远端版本表 ..."
  curl -fL "$BASE/tj.sh" -o "$tmp" || { rm -f "$tmp"; echo "下载 tj.sh 失败" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "#ver "*) has_ver=1; break ;;
    esac
  done < "$tmp"
  if [ "$has_ver" -ne 1 ]; then
    rm -f "$tmp"
    echo "远端 tj.sh 没有 #ver 版本表，无法比较。请先把这份 tj.sh 推到仓库。"
    return 1
  fi

  names=("${files[@]}" tj.sh)
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    valid_script_name "$name" || { echo "菜单里的脚本名非法: ${name:-空}" >&2; rm -f "$tmp"; return 1; }
    loc[$i]="$(ver_of "$name" "$0")"
    rem[$i]="$(ver_of "$name" "$tmp")"
    [ -n "${loc[$i]}" ] || loc[$i]=$MIN_VER
    [ -n "${rem[$i]}" ] || rem[$i]=$MIN_VER
    rows+=("${loc[$i]} $i")
  done
  sorted="$(printf '%s\n' "${rows[@]}" | sort -V -s)" || {
    echo "版本排序失败" >&2
    rm -f "$tmp"
    return 1
  }
  echo
  echo "从最小版本号开始检查（缺省 $MIN_VER）："
  while read -r lv i; do
    [ -n "$i" ] || continue
    name="${names[$i]}"
    lv="${loc[$i]}"
    rv="${rem[$i]}"
    if ver_gt "$rv" "$lv"; then
      status="可更新"
      outdated+=("$name")
    elif ver_gt "$lv" "$rv"; then
      status="本地较新"
    else
      status="已是最新"
    fi
    printf '  %-42s 本地 v%-8s 远端 v%-8s %s\n' "$name" "$lv" "$rv" "$status"
  done <<< "$sorted"

  if [ "${#outdated[@]}" -eq 0 ]; then
    rm -f "$tmp"
    echo
    echo "没有可更新的脚本。"
    return 0
  fi

  echo
  echo "将下载覆盖:"
  for name in "${outdated[@]}"; do
    [ "$name" = "tj.sh" ] && continue
    echo "  $name"
  done
  echo "并覆盖本地 tj.sh 里的版本表。"
  printf '继续? [y/N] '
  if ! read -r answer; then
    echo
    rm -f "$tmp"
    return 0
  fi
  case "$answer" in
    y|Y) ;;
    *) rm -f "$tmp"; echo "已跳过。"; return 0 ;;
  esac
  [ -w "$here" ] || { echo "目录不可写: $here" >&2; rm -f "$tmp"; return 1; }

  for name in "${outdated[@]}"; do
    [ "$name" = "tj.sh" ] && continue
    echo "更新 $name ..."
    if fetch_script "$name"; then
      echo "已更新 $name"
    else
      fail=1
    fi
  done
  if [ "$fail" -ne 0 ]; then
    rm -f "$tmp"
    echo "有脚本更新失败，未覆盖 tj.sh。"
    return 1
  fi
  part="$(mktemp "${here%/}/tj.sh.XXXXXX")" || { echo "mktemp 失败" >&2; rm -f "$tmp"; return 1; }
  cp "$tmp" "$part" && mv -T -- "$part" "${here%/}/tj.sh" || {
    rm -f "$part" "$tmp"
    echo "覆盖 tj.sh 失败" >&2
    return 1
  }
  rm -f "$tmp"
  echo "tj.sh 已更新，请重新运行: bash \"$here/tj.sh\""
  exit 0
}

if [ "${1:-}" = "--self-check" ]; then
  self_check
fi

while true; do
  echo
  echo "======== debian12-13 tj脚本菜单 ========"
  i=1
  while [ "$i" -le "${#files[@]}" ]; do
    printf '  %d) [v%s] %s  %s\n' "$i" "$(ver_of "${files[$((i - 1))]}")" "${files[$((i - 1))]}" "${labels[$((i - 1))]}"
    i=$((i + 1))
  done
  echo "  999) 检查脚本更新"
  echo "  0) 退出"
  printf '请选择: '
  if ! read -r choice; then
    echo
    exit 0
  fi
  case "$choice" in
    0|q|Q) exit 0 ;;
    999) check_updates; continue ;;
    ""|*[!0-9]*) echo "无效选择"; continue ;;
  esac
  n=$((10#$choice))
  if [ "$n" -lt 1 ] || [ "$n" -gt "${#files[@]}" ]; then
    echo "无效选择"
    continue
  fi
  run_one "${files[$((n - 1))]}" || echo "失败，退出码: $?"
done
