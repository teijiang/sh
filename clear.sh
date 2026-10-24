#!/usr/bin/env bash
# Debian/Ubuntu 磁盘清理脚本（较安全版）

set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/root/cleanup-backup}"
TIMESTAMP="$(date +%F.%H-%M-%S)"
LOG_BACKUP="$BACKUP_DIR/journal-$TIMESTAMP.tar.gz"

KEEP_JOURNAL_TIME="${KEEP_JOURNAL_TIME:-7d}"
KEEP_JOURNAL_SIZE="${KEEP_JOURNAL_SIZE:-500M}"
TMP_DAYS="${TMP_DAYS:-3}"
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

log()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERR ] %s\n' "$*" >&2; exit 1; }

confirm_action() {
    local prompt="$1"
    local default="$2"
    local answer
    local choices="[Y/n]"

    if [[ "$default" == "no" ]]; then
        choices="[y/N]"
    fi

    while true; do
        if ! read -r -p "$prompt $choices " answer; then
            printf '\n' >&2
            die "无法读取交互输入，请在终端中运行此脚本"
        fi

        case "${answer,,}" in
            "")
                if [[ "$default" == "yes" ]]; then
                    return 0
                fi
                return 1
                ;;
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                warn "请输入 y 或 n，直接回车使用括号中的默认选项"
                ;;
        esac
    done
}

confirm_yes_default() {
    confirm_action "$1" yes
}

confirm_no_default() {
    confirm_action "$1" no
}

trap 'die "脚本执行失败，出错位置：第 $LINENO 行"' ERR

[[ $EUID -eq 0 ]] || die "请使用 root 权限或 sudo 运行"

command -v apt-get >/dev/null || die "未找到 apt-get，当前系统可能不是 Debian/Ubuntu"

[[ "$APT_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || die "APT_LOCK_TIMEOUT 必须是秒数"

APT_LOCK_OPTIONS=(-o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT")

mkdir -p "$BACKUP_DIR"

show_disk() {
    log "当前磁盘使用情况："
    df -h /
    echo
    df -ih /
}

backup_journal() {
    if [[ -d /var/log/journal ]]; then
        # 回车默认跳过备份，后续仍会清理 journal。
        if ! confirm_no_default "是否备份 systemd journal 到 $LOG_BACKUP？"; then
            log "跳过 journal 备份"
            return
        fi

        log "备份 systemd journal 到 $LOG_BACKUP"
        if ! tar --warning=no-file-changed -czf "$LOG_BACKUP" /var/log/journal 2>/dev/null; then
            warn "journal 备份失败，继续执行清理"
        fi
    else
        log "/var/log/journal 不存在，跳过 journal 备份"
    fi
}

clean_apt() {
    log "清理 APT 缓存和无用依赖"
    log "APT/Dpkg 锁被占用时最多等待 ${APT_LOCK_TIMEOUT} 秒"

    # GRUB 是启动链的一部分，避免被 autoremove 当作孤立依赖删除。
    local -a installed_grub_packages=()
    mapfile -t installed_grub_packages < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null |
            awk -F '\t' '$2 == "installed" && $1 ~ /^grub/ {print $1}'
    )
    if ((${#installed_grub_packages[@]})); then
        log "保护已安装的 GRUB 包，避免自动清理误删"
        DEBIAN_FRONTEND=noninteractive apt-mark "${APT_LOCK_OPTIONS[@]}" manual "${installed_grub_packages[@]}" >/dev/null
    fi

    DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPTIONS[@]}" update
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPTIONS[@]}" autoremove --purge -y
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPTIONS[@]}" autoclean -y
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPTIONS[@]}" clean

    log "清理残留 rc 配置包（跳过 GRUB）"
    local -a residual_packages=()
    mapfile -t residual_packages < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null |
            awk -F '\t' '$2 == "config-files" && $1 !~ /^grub/ {print $1}'
    )
    if ((${#residual_packages[@]})); then
        DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_OPTIONS[@]}" purge -y "${residual_packages[@]}"
    else
        log "没有需要清理的残留配置包"
    fi
}

clean_journal() {
    if command -v journalctl >/dev/null 2>&1; then
        log "清理 journald：保留最近 $KEEP_JOURNAL_TIME，且总大小不超过 $KEEP_JOURNAL_SIZE"
        journalctl --disk-usage || true
        journalctl --vacuum-time="$KEEP_JOURNAL_TIME" || true
        journalctl --vacuum-size="$KEEP_JOURNAL_SIZE" || true
        journalctl --disk-usage || true
    fi
}

clean_logs() {
    log "清理压缩旧日志与截断超大日志"
    find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete 2>/dev/null || true

    find /var/log -type f -size +100M ! -name "wtmp" ! -name "btmp" ! -name "lastlog" \
        -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true
}

clean_tmp() {
    log "清理 $TMP_DAYS 天前的临时文件"
    find /tmp /var/tmp -xdev -mindepth 1 -mtime +"$TMP_DAYS" -exec rm -rf -- {} + 2>/dev/null || true
}

clean_crash_dumps() {
    log "清理崩溃转储"
    rm -rf /var/crash/* 2>/dev/null || true
    rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true
}

clean_user_cache() {
    if ! confirm_yes_default "是否清理普通用户与 root 的缓存目录？"; then
        log "跳过用户缓存清理"
        return
    fi

    log "清理普通用户与 root 的缓存目录"
    find /home -mindepth 2 -maxdepth 2 -type d -name ".cache" -exec rm -rf -- {}/* \; 2>/dev/null || true
    rm -rf /root/.cache/* 2>/dev/null || true
}

clean_npm_cache() {
    if ! confirm_yes_default "是否清理 npm 包下载缓存？"; then
        log "跳过 npm 缓存清理"
        return
    fi

    local home_dir cache_dir found_cache=0

    if command -v npm >/dev/null 2>&1; then
        for home_dir in /root /home/*; do
            [[ -d "$home_dir" ]] || continue
            cache_dir="$(env -u NPM_CONFIG_CACHE -u NPM_CONFIG_USERCONFIG HOME="$home_dir" npm config get cache 2>/dev/null || true)"
            if [[ "$cache_dir" == /* && "$cache_dir" != "/" && -d "$cache_dir" ]]; then
                log "清理 npm 缓存：$cache_dir"
                if env -u NPM_CONFIG_CACHE -u NPM_CONFIG_USERCONFIG HOME="$home_dir" npm cache clean --force; then
                    found_cache=1
                else
                    warn "npm 缓存清理失败：$cache_dir"
                fi
            fi
        done
    fi

    # 即使 npm 使用自定义配置，也清理默认位置中可能残留的缓存。
    for cache_dir in /root/.npm /home/*/.npm; do
        [[ -d "$cache_dir" ]] || continue
        log "清理 npm 缓存：$cache_dir"
        find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || \
            warn "npm 缓存清理失败：$cache_dir"
        found_cache=1
    done

    if ((found_cache == 0)); then
        log "未检测到 npm 缓存"
    fi
}

clean_pnpm_store() {
    if ! confirm_yes_default "是否清理 pnpm 未使用的包缓存？"; then
        log "跳过 pnpm store 清理"
        return
    fi

    local home_dir store_dir found_store=0

    if command -v pnpm >/dev/null 2>&1; then
        for home_dir in /root /home/*; do
            [[ -d "$home_dir" ]] || continue
            store_dir="$(env HOME="$home_dir" pnpm store path 2>/dev/null || true)"
            if [[ "$store_dir" == /* && "$store_dir" != "/" && -d "$store_dir" ]]; then
                log "清理 pnpm 未使用的包：$store_dir"
                if env HOME="$home_dir" pnpm store prune; then
                    found_store=1
                else
                    warn "pnpm store 清理失败：$store_dir"
                fi
            fi
        done
    fi

    # pnpm 不在当前 PATH 中时，清空常见的 store 缓存位置。
    if ((found_store == 0)); then
        for store_dir in \
            /root/.local/share/pnpm/store /home/*/.local/share/pnpm/store \
            /root/.pnpm-store /home/*/.pnpm-store; do
            [[ -d "$store_dir" ]] || continue
            log "清空 pnpm 包缓存：$store_dir"
            find "$store_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || \
                warn "pnpm 包缓存清理失败：$store_dir"
            found_store=1
        done
    fi

    if ((found_store == 0)); then
        log "未检测到 pnpm store 缓存"
    fi
}

clean_node_download_cache() {
    if ! confirm_yes_default "是否清理 Node.js 下载缓存（nvm、node-gyp）？"; then
        log "跳过 Node.js 下载缓存清理"
        return
    fi

    local cache_dir found_cache=0

    for cache_dir in \
        /root/.nvm/.cache /home/*/.nvm/.cache \
        /root/.cache/node-gyp /home/*/.cache/node-gyp; do
        [[ -d "$cache_dir" ]] || continue
        log "清理 Node.js 下载缓存：$cache_dir"
        find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || \
            warn "Node.js 下载缓存清理失败：$cache_dir"
        found_cache=1
    done

    if ((found_cache == 0)); then
        log "未检测到 Node.js 下载缓存"
    fi
}

clean_go_module_cache() {
    if ! confirm_yes_default "是否清理 Go 模块下载缓存？"; then
        log "跳过 Go 模块缓存清理"
        return
    fi

    local home_dir module_cache found_cache=0

    if command -v go >/dev/null 2>&1; then
        for home_dir in /root /home/*; do
            [[ -d "$home_dir" ]] || continue
            module_cache="$(env -u GOMODCACHE -u GOPATH -u GOENV HOME="$home_dir" go env GOMODCACHE 2>/dev/null || true)"
            if [[ "$module_cache" == /* && "$module_cache" != "/" && -d "$module_cache" ]]; then
                log "清理 Go 模块下载缓存：$module_cache"
                if env -u GOMODCACHE -u GOPATH -u GOENV HOME="$home_dir" go clean -modcache; then
                    found_cache=1
                else
                    warn "Go 模块下载缓存清理失败：$module_cache"
                fi
            fi
        done
    fi

    # 即使 Go 使用自定义配置，也清理默认位置中可能残留的缓存。
    for module_cache in /root/go/pkg/mod /home/*/go/pkg/mod; do
        [[ -d "$module_cache" ]] || continue
        log "清理 Go 模块下载缓存：$module_cache"
        find "$module_cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || \
            warn "Go 模块下载缓存清理失败：$module_cache"
        found_cache=1
    done

    if ((found_cache == 0)); then
        log "未检测到 Go 模块下载缓存"
    fi
}

clean_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "未检测到 Docker，跳过"
        return
    fi

    log "清理 Docker 停止容器、无用镜像和构建缓存"
    docker container prune -f || true
    docker image prune -af || true
    docker builder prune -af || true
    docker network prune -f || true

    if confirm_yes_default "是否删除未使用的 Docker 卷？"; then
        warn "启用 Docker 卷清理：将删除未使用卷"
        docker volume prune -af || true
    else
        log "跳过 Docker 卷清理"
    fi
}

clean_build_cache() {
    if ! confirm_yes_default "是否清理编译缓存（Go、ccache、sccache）？"; then
        log "跳过编译缓存清理"
        return
    fi

    local found_cache=0
    local home_dir go_cache cache_dir

    if command -v go >/dev/null 2>&1; then
        for home_dir in /root /home/*; do
            [[ -d "$home_dir" ]] || continue
            go_cache="$(env -u GOCACHE -u GOENV HOME="$home_dir" go env GOCACHE 2>/dev/null || true)"
            if [[ -n "$go_cache" && "$go_cache" != "off" && -d "$go_cache" ]]; then
                log "清理 Go 编译缓存：$go_cache"
                if ! env -u GOCACHE -u GOENV HOME="$home_dir" go clean -cache; then
                    warn "Go 编译缓存清理失败：$go_cache"
                fi
                found_cache=1
            fi
        done
    else
        # 即使当前没有安装 Go，也清理常见的遗留 Go build cache。
        for cache_dir in /root/.cache/go-build /home/*/.cache/go-build; do
            [[ -d "$cache_dir" ]] || continue
            log "清理 Go 编译缓存：$cache_dir"
            find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || \
                warn "Go 编译缓存清理失败：$cache_dir"
            found_cache=1
        done
    fi

    for cache_dir in \
        /var/cache/ccache /root/.cache/ccache /home/*/.cache/ccache \
        /var/cache/sccache /root/.cache/sccache /home/*/.cache/sccache; do
        [[ -d "$cache_dir" ]] || continue
        log "清理编译缓存：$cache_dir"
        find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || \
            warn "编译缓存清理失败：$cache_dir"
        found_cache=1
    done

    if ((found_cache == 0)); then
        log "未检测到 Go、ccache 或 sccache 编译缓存"
    fi
}

clean_snap_if_any() {
    if command -v snap >/dev/null 2>&1; then
        log "检测到 snap，列出已禁用旧修订版（如存在）"
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r name rev; do
            snap remove "$name" --revision="$rev" || true
        done
    fi
}

list_large_files() {
    if ! confirm_yes_default "是否列出大于 100M 的文件？"; then
        log "跳过大文件列表"
        return
    fi

    log "查找根文件系统中大于 100M 的普通文件（按大小降序）"
    local large_files
    large_files="$(
        find / -xdev -type f -size +100M -printf '%s\t%p\n' 2>/dev/null |
            sort -nr |
            awk -F '\t' '{printf "%.1f MiB\t%s\n", $1 / 1048576, $2}' || true
    )"

    if [[ -n "$large_files" ]]; then
        printf '%s\n' "$large_files"
    else
        log "未找到大于 100M 的文件"
    fi
}

main() {
    show_disk
    backup_journal
    clean_apt
    clean_journal
    clean_logs
    clean_tmp
    clean_crash_dumps
    clean_user_cache
    clean_npm_cache
    clean_pnpm_store
    clean_node_download_cache
    clean_go_module_cache
    clean_build_cache
    clean_docker
    clean_snap_if_any
    log "清理完成"
    show_disk
    list_large_files
}

main "$@"
