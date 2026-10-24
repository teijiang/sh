#!/bin/sh

# Debian kernel switch helper.  v0.1
# 查询可用 linux-image 内核包，输入索引安装指定版本，并可选择清理旧内核镜像和 headers（含 -common）。
# 无参数时先选菜单：1 安装内核，2 自己选包删除并切换启动内核。


set -eu

APT_GET="${APT_GET:-apt-get}"
APT_CACHE="${APT_CACHE:-apt-cache}"

die() {
    echo "错误: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

confirm() {
    prompt="$1"
    default="${2:-n}"

    if [ "$default" = "y" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    printf "%s %s " "$prompt" "$suffix"
    read -r answer
    answer="${answer:-$default}"

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_version_filter() {
    filter="$1"
    flavour="$2"

    case "$filter" in
        linux-image-*) filter="${filter#linux-image-}" ;;
        linux-headers-*) filter="${filter#linux-headers-}" ;;
    esac

    case "$filter" in
        *-cloud-amd64) filter="${filter%-cloud-amd64}" ;;
        *-rt-amd64) filter="${filter%-rt-amd64}" ;;
        *-cloud-arm64) filter="${filter%-cloud-arm64}" ;;
        *-rt-arm64) filter="${filter%-rt-arm64}" ;;
        *-amd64) filter="${filter%-amd64}" ;;
        *-686-pae) filter="${filter%-686-pae}" ;;
        *-armmp-lpae) filter="${filter%-armmp-lpae}" ;;
        *-armmp) filter="${filter%-armmp}" ;;
        *-arm64) filter="${filter%-arm64}" ;;
        *-686) filter="${filter%-686}" ;;
        *-"$flavour") filter="${filter%-"$flavour"}" ;;
    esac

    # 6.12.x / 6.12.* -> 6.12.  以便匹配 6.12.107+deb13-amd64
    case "$filter" in
        *.[xX]|*.\*)
            filter="${filter%.*}."
            ;;
    esac

    printf "%s\n" "$filter"
}

print_installed_kernels() {
    echo
    echo "已安装的内核镜像包:"
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'linux-image-*' 2>/dev/null \
        | awk '$1 == "ii" && $2 ~ /^linux-image-[0-9]/ && $2 !~ /-unsigned$/ {print $2 "\t" $3}' \
        | sort -V \
        | while IFS="$(printf '\t')" read -r pkg ver; do
            headers_pkg="$(headers_package_for_image "$pkg")"
            printf "  %s  %s\n" "$pkg" "$ver"
            if package_is_installed "$headers_pkg"; then
                printf "    headers: %s (已安装)\n" "$headers_pkg"
            else
                printf "    headers: 未安装 %s\n" "$headers_pkg"
            fi
        done || true

    echo
    echo "已安装的内核 headers 包:"
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'linux-headers-*' 2>/dev/null \
        | awk '$1 == "ii" && $2 ~ /^linux-headers-[0-9]/ {print "  " $2 "  " $3}' \
        | sort -V || true
}

headers_package_for_image() {
    printf "%s\n" "$1" | sed 's/^linux-image-/linux-headers-/'
}

common_headers_for_image() {
    hdr_release="${1#linux-image-}"
    case "$hdr_release" in
        *-cloud-amd64) hdr_flavour=cloud-amd64 ;;
        *-rt-amd64) hdr_flavour=rt-amd64 ;;
        *-cloud-arm64) hdr_flavour=cloud-arm64 ;;
        *-rt-arm64) hdr_flavour=rt-arm64 ;;
        *-amd64) hdr_flavour=amd64 ;;
        *-686-pae) hdr_flavour=686-pae ;;
        *-armmp-lpae) hdr_flavour=armmp-lpae ;;
        *-armmp) hdr_flavour=armmp ;;
        *-arm64) hdr_flavour=arm64 ;;
        *-686) hdr_flavour=686 ;;
        *) return 0 ;;
    esac
    hdr_abi="${hdr_release%-"$hdr_flavour"}"
    case "$hdr_abi" in
        [0-9]*.[0-9]*.[0-9]*) printf "linux-headers-%s-common\n" "$hdr_abi" ;;
    esac
}

# shortcut: 不删 linux-headers-amd64 / linux-headers-6.12-amd64 这类滚动元包，kbuild 交给后面的 autoremove；这两类也要删时再加规则。
is_versioned_headers() {
    case "$1" in
        linux-headers-[0-9]*.[0-9]*.[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

self_check_headers_filter() {
    [ "$(common_headers_for_image linux-image-6.12.113+deb13-amd64)" = "linux-headers-6.12.113+deb13-common" ] \
        || die "self-check: trixie common"
    [ "$(common_headers_for_image linux-image-6.1.0-54-amd64)" = "linux-headers-6.1.0-54-common" ] \
        || die "self-check: bookworm common"
    [ "$(common_headers_for_image linux-image-6.1.0-21-cloud-amd64)" = "linux-headers-6.1.0-21-common" ] \
        || die "self-check: cloud common"
    [ -z "$(common_headers_for_image linux-image-6.12-amd64)" ] || die "self-check: 元包不应有 common"
    is_versioned_headers linux-headers-6.12.113+deb13-common || die "self-check: trixie common 应删除"
    is_versioned_headers linux-headers-6.1.0-54-amd64 || die "self-check: bookworm headers 应删除"
    is_versioned_headers linux-headers-6.12-amd64 && die "self-check: 滚动元包不应删除"
    is_versioned_headers linux-headers-6.1-cloud-amd64 && die "self-check: cloud 元包不应删除"
    echo "self-check ok"
    exit 0
}

package_is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

package_is_available() {
    "$APT_CACHE" show "$1" >/dev/null 2>&1
}

kernel_package_for_release() {
    release="$1"
    pkg="linux-image-$release"

    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        printf "%s\n" "$pkg"
    fi
}

detect_kernel_flavour() {
    release="$1"

    if [ -n "${KERNEL_FLAVOUR:-}" ]; then
        printf "%s\n" "$KERNEL_FLAVOUR"
        return 0
    fi

    case "$release" in
        *-cloud-amd64) printf "%s\n" "cloud-amd64" ;;
        *-rt-amd64) printf "%s\n" "rt-amd64" ;;
        *-amd64) printf "%s\n" "amd64" ;;
        *-686-pae) printf "%s\n" "686-pae" ;;
        *-686) printf "%s\n" "686" ;;
        *-cloud-arm64) printf "%s\n" "cloud-arm64" ;;
        *-rt-arm64) printf "%s\n" "rt-arm64" ;;
        *-arm64) printf "%s\n" "arm64" ;;
        *-armmp-lpae) printf "%s\n" "armmp-lpae" ;;
        *-armmp) printf "%s\n" "armmp" ;;
        *)
            # 6.12.107+deb13-amd64 或 6.1.0-37-amd64
            stripped="$(printf "%s\n" "$release" | sed 's/^[0-9][0-9.]*+[^-]*-//; t; s/^[0-9][0-9.]*-[0-9][0-9]*-//')"
            if [ -n "$stripped" ] && [ "$stripped" != "$release" ]; then
                printf "%s\n" "$stripped"
            else
                dpkg --print-architecture
            fi
            ;;
    esac
}

available_kernel_packages() {
    flavour="$1"
    filter="$2"

    # pkgnames 避免 apt-cache search 的 $ 锚点把 name+description 一起匹配，
    # 也避免包名里的 +deb13 被当成正则量词。
    "$APT_CACHE" pkgnames 'linux-image-' \
        | awk -v flavour="$flavour" '
            $0 ~ /^linux-image-[0-9]/ &&
            $0 !~ /-dbg$/ &&
            $0 !~ /-unsigned$/ {
                suffix = "-" flavour
                n = length($0)
                f = length(suffix)
                if (n < f || substr($0, n - f + 1) != suffix) next
                extra = "-cloud" suffix
                el = length(extra)
                if (n >= el && substr($0, n - el + 1) == extra) next
                extra = "-rt" suffix
                el = length(extra)
                if (n >= el && substr($0, n - el + 1) == extra) next
                print
            }
        ' \
        | awk -v filter="$filter" '
            function version_match(rest, filter,   n, nextc) {
                n = length(filter)
                if (n == 0) return 1
                if (substr(rest, 1, n) != filter) return 0
                if (length(rest) == n) return 1
                if (substr(filter, n, 1) == ".") return 1
                nextc = substr(rest, n + 1, 1)
                return (nextc !~ /[0-9]/)
            }
            {
                if (filter == "") {
                    print
                    next
                }
                rest = $0
                sub(/^linux-image-/, "", rest)
                if (filter ~ /^[0-9]/) {
                    if (version_match(rest, filter)) print
                } else if (index(rest, filter)) {
                    print
                }
            }
        ' \
        | sort -V \
        | uniq
}

print_search_hint() {
    flavour="$1"
    filter="$2"

    echo >&2
    echo "没有找到匹配的内核包。" >&2
    echo "内核类型: $flavour" >&2
    if [ -n "$filter" ]; then
        echo "版本关键字: $filter" >&2
    fi
    echo >&2
    echo "Debian 实际包名类似 linux-image-6.12.107+deb13-amd64，" >&2
    echo "不能直接安装 linux-image-6.12.x-amd64 这种占位包名。" >&2
    echo >&2
    echo "当前缓存中的内核包示例:" >&2
    "$APT_CACHE" pkgnames 'linux-image-' 2>/dev/null \
        | awk '/^linux-image-[0-9]/ && $0 !~ /-dbg$/ && $0 !~ /-unsigned$/ {print}' \
        | sort -V \
        | awk '{a[NR]=$0} END {s=NR-7; if (s<1) s=1; for (i=s; i<=NR; i++) print "  " a[i]}' >&2 || true
}

select_kernel_package() {
    flavour="$1"
    filter="$2"
    tmp_file="$3"

    available_kernel_packages "$flavour" "$filter" > "$tmp_file"

    if [ ! -s "$tmp_file" ]; then
        return 1
    fi

    count="$(awk 'END {print NR}' "$tmp_file")"
    latest="$(awk 'END {print}' "$tmp_file")"

    echo >&2
    echo "可安装的内核包:" >&2
    awk '{printf "  [%d] %s\n", NR, $0}' "$tmp_file" >&2
    echo "  最新版本: $latest" >&2

    while :; do
        printf "\n请输入要安装的索引号 (1-%s，直接回车选择最新): " "$count" >&2
        read -r index

        if [ -z "$index" ]; then
            printf "%s\n" "$latest"
            return 0
        fi

        case "$index" in
            *[!0-9]*)
                echo "请输入数字索引。 " >&2
                continue
                ;;
        esac

        selected="$(awk -v n="$index" 'NR == n {print; found=1} END {exit found ? 0 : 1}' "$tmp_file")" || {
            echo "索引超出范围。 " >&2
            continue
        }

        printf "%s\n" "$selected"
        return 0
    done
}

install_matching_headers() {
    image_pkg="$1"
    headers_pkg="$(headers_package_for_image "$image_pkg")"

    if package_is_installed "$headers_pkg"; then
        echo "匹配的 headers 包已安装: $headers_pkg"
        return 0
    fi

    if package_is_available "$headers_pkg"; then
        echo "正在补装匹配的 headers 包: $headers_pkg"
        "$APT_GET" install -y "$headers_pkg"
    else
        echo "警告: 未找到匹配的 headers 包: $headers_pkg"
        return 1
    fi

    if package_is_installed "$headers_pkg"; then
        echo "已安装 headers 包: $headers_pkg"
        return 0
    fi

    echo "警告: headers 包安装后仍未检测到: $headers_pkg"
    return 1
}

repair_missing_headers() {
    missing_file="$1"
    : > "$missing_file"

    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 2>/dev/null \
        | awk '$1 == "ii" && $2 ~ /^linux-image-[0-9]/ && $2 !~ /-unsigned$/ {print $2}' \
        | sort -V \
        | while read -r image_pkg; do
            headers_pkg="$(headers_package_for_image "$image_pkg")"
            if package_is_installed "$headers_pkg"; then
                continue
            fi
            if package_is_available "$headers_pkg"; then
                printf "%s\n" "$headers_pkg"
            else
                echo "警告: $image_pkg 缺少 headers，且软件源中没有 $headers_pkg" >&2
            fi
        done > "$missing_file" || true

    if [ ! -s "$missing_file" ]; then
        return 0
    fi

    echo
    echo "发现已安装内核缺少 headers:"
    awk '{print "  " $0}' "$missing_file"

    if confirm "是否现在补装这些 headers 包?" "y"; then
        xargs "$APT_GET" install -y < "$missing_file"
        print_installed_kernels
    else
        echo "已跳过 headers 补装。"
    fi
}

choose_purge() {
    list_file="$1"
    chosen_file="$2"
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 'linux-headers-*' 2>/dev/null \
        | awk '($1 == "ii" || $1 == "rc") && ($2 ~ /^linux-image-[0-9]/ || $2 ~ /^linux-headers-[0-9]/) {print $2}' \
        | sort -V -u > "$list_file" || true
    if [ ! -s "$list_file" ]; then
        echo "没有已安装的内核包。"
        return 1
    fi

    echo
    echo "已安装的内核包。输入编号删除，多个用空格或逗号，直接回车取消:"
    awk -v run="$(uname -r)" '{
        mark = index($0, run) ? "  <-- 当前内核" : ""
        printf "  [%d] %s%s\n", NR, $0, mark
    }' "$list_file"
    printf "删除哪些: "
    read -r picks || return 1
    if [ -z "$picks" ]; then
        echo "已取消。"
        return 1
    fi

    picks="$(printf '%s\n' "$picks" | tr ',' ' ')"
    : > "$chosen_file"
    for n in $picks; do
        case "$n" in
            ""|*[!0-9]*)
                echo "无效编号: $n" >&2
                return 1
                ;;
        esac
        pkg="$(awk -v n="$n" 'NR == n {print; found=1} END {exit found ? 0 : 1}' "$list_file")" || {
            echo "编号超出范围: $n" >&2
            return 1
        }
        printf '%s\n' "$pkg" >> "$chosen_file"
    done
    sort -u -o "$chosen_file" "$chosen_file"
    if [ ! -s "$chosen_file" ]; then
        echo "没有选中任何包。"
        return 1
    fi

    echo
    echo "将要 purge 的包:"
    awk '{print "  " $0}' "$chosen_file"
    running_image="linux-image-$(uname -r)"
    if grep -qxF "$running_image" "$chosen_file"; then
        echo "包含当前正在运行的内核。删掉后这次还能跑，再重启就不能回到这个版本。"
    fi
    confirm "确认删除上面这些包?" "n" || {
        echo "已取消。"
        return 1
    }
    if ! xargs "$APT_GET" purge -y < "$chosen_file"; then
        echo "删除失败。" >&2
        return 1
    fi
    "$APT_GET" autoremove -y || true
    echo "删除完成。"
}

grub_entry_for() {
    rel="$1"
    cfg="$2"
    awk -v rel="$rel" '
        function title(line,   q, n, a, i, dq) {
            q = sprintf("%c", 39)
            i = index(line, q)
            dq = index(line, "\"")
            if (i && (dq == 0 || i < dq)) {
                n = split(line, a, q)
                return a[2]
            }
            n = split(line, a, "\"")
            return a[2]
        }
        /^submenu[[:space:]]/ { subm = title($0); next }
        /^menuentry[[:space:]]/ { subm = ""; }
        /^[[:space:]]*menuentry[[:space:]]/ {
            t = title($0)
            if (t != "" && index(t, rel)) {
                if (subm != "" && $0 ~ /^[[:space:]]/) print subm ">" t
                else print t
                exit
            }
        }
    ' "$cfg"
}

switch_boot_kernel() {
    list_file="$1"
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*' 2>/dev/null \
        | awk '$1 == "ii" && $2 ~ /^linux-image-[0-9]/ && $2 !~ /-unsigned$/ && $2 !~ /-dbg$/ {print $2}' \
        | sort -V > "$list_file" || true
    if [ ! -s "$list_file" ]; then
        echo "没有可切换的已安装内核。"
        return 1
    fi

    echo
    echo "切换下次启动到哪个内核:"
    awk -v run="linux-image-$(uname -r)" '{
        mark = ($0 == run) ? "  <-- 正在运行" : ""
        printf "  [%d] %s%s\n", NR, $0, mark
    }' "$list_file"
    printf "请输入编号，直接回车不切换: "
    read -r index || return 1
    if [ -z "$index" ]; then
        echo "未切换启动项。"
        return 0
    fi
    case "$index" in
        *[!0-9]*)
            echo "请输入数字编号。" >&2
            return 1
            ;;
    esac
    boot_pkg="$(awk -v n="$index" 'NR == n {print; found=1} END {exit found ? 0 : 1}' "$list_file")" || {
        echo "编号超出范围。" >&2
        return 1
    }

    release="${boot_pkg#linux-image-}"
    cfg=/boot/grub/grub.cfg
    if [ ! -f "$cfg" ]; then
        echo "没有 $cfg，无法切换启动项。" >&2
        return 1
    fi
    entry="$(grub_entry_for "$release" "$cfg" || true)"
    if [ -z "$entry" ] && command -v update-grub >/dev/null 2>&1; then
        echo "GRUB 菜单里还没有 $release，正在更新菜单..."
        update-grub
        entry="$(grub_entry_for "$release" "$cfg" || true)"
    fi
    if [ -z "$entry" ]; then
        echo "GRUB 菜单里没有找到 $release，没有改默认启动项。" >&2
        return 1
    fi
    if [ ! -f /etc/default/grub ]; then
        echo "没有 /etc/default/grub，无法设置默认启动项。" >&2
        return 1
    fi
    awk -v entry="$entry" '
        BEGIN { found = 0 }
        /^GRUB_DEFAULT=/ {
            gsub(/"/, "\\\\"", entry)
            print "GRUB_DEFAULT=\"" entry "\""
            found = 1
            next
        }
        { print }
        END {
            if (!found) {
                gsub(/"/, "\\\\"", entry)
                print "GRUB_DEFAULT=\"" entry "\""
            }
        }
    ' /etc/default/grub > /etc/default/grub.cker.tmp
    mv /etc/default/grub.cker.tmp /etc/default/grub
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    fi
    echo "下次启动将使用: $entry"
}

drop_boot_purge() {
    if [ ! -f /etc/systemd/system/cker-purge-after-reboot.service ] && [ ! -f /var/lib/cker/purge-after-reboot ]; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now cker-purge-after-reboot.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/cker-purge-after-reboot.service /var/lib/cker/purge-after-reboot
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    echo "已去掉开机删除。"
}

main() {
    if [ "${1:-}" = "--self-check" ]; then
        self_check_headers_filter
    fi

    need_cmd awk
    need_cmd grep
    need_cmd sort
    need_cmd uname
    need_cmd dpkg
    need_cmd dpkg-query
    need_cmd id
    need_cmd mktemp
    need_cmd sed
    need_cmd xargs
    need_cmd "$APT_GET"
    need_cmd "$APT_CACHE"

    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 运行，例如: sudo sh $0"
    fi

    if [ "${1:-}" = "--purge-after-reboot" ]; then
        drop_boot_purge
        exit 0
    fi
    drop_boot_purge

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        [ "${ID:-}" = "debian" ] || echo "警告: 此脚本主要适用于 Debian。当前检测到: ${PRETTY_NAME:-unknown}"
    fi

    running_release="$(uname -r)"
    running_pkg="$(kernel_package_for_release "$running_release" || true)"
    flavour="$(detect_kernel_flavour "$running_release")"

    [ -n "$flavour" ] || die "无法从 uname -r 检测内核类型: $running_release"
    [ -n "$running_pkg" ] || running_pkg="linux-image-$running_release"

    echo "当前运行内核: $running_release"
    echo "检测到内核类型: $flavour"
    print_installed_kernels

    if [ $# -eq 0 ]; then
        while true; do
            echo
            echo "1) 安装或更换内核"
            echo "2) 选择删除内核包，并切换启动内核"
            echo "0) 退出"
            printf "请选择: "
            read -r choice || exit 0
            case "$choice" in
                0|q|Q) exit 0 ;;
                1) break ;;
                2)
                    tmp_old="$(mktemp)"
                    trap 'rm -f "$tmp_old" "$tmp_old.chosen"' EXIT INT TERM
                    if choose_purge "$tmp_old" "$tmp_old.chosen"; then
                        switch_boot_kernel "$tmp_old"
                    fi
                    exit 0
                    ;;
                *) echo "无效选择" ;;
            esac
        done
    fi

    echo
    if [ $# -gt 0 ]; then
        version_filter="$1"
        echo "使用版本关键字: $version_filter"
    else
        printf "请输入版本关键字过滤内核包 (例如 6.12 或 6.12.x)，直接回车则列出所有匹配 %s 的内核: " "$flavour"
        read -r version_filter
    fi
    normalized_filter="$(normalize_version_filter "$version_filter" "$flavour")"
    if [ -n "$version_filter" ] && [ "$normalized_filter" != "$version_filter" ]; then
        echo "已将版本关键字规范化为: $normalized_filter"
    fi
    version_filter="$normalized_filter"

    echo
    echo "正在更新 apt 软件包索引..."
    "$APT_GET" update

    tmp_list="$(mktemp)"
    tmp_old="$(mktemp)"
    tmp_missing="$(mktemp)"
    trap 'rm -f "$tmp_list" "$tmp_old" "$tmp_old.chosen" "$tmp_missing"' EXIT INT TERM

    repair_missing_headers "$tmp_missing"

    if ! selected_pkg="$(select_kernel_package "$flavour" "$version_filter" "$tmp_list")"; then
        print_search_hint "$flavour" "$version_filter"
        die "没有找到匹配的内核包。请换一个版本关键字，或检查 apt 源。"
    fi

    headers_pkg="$(headers_package_for_image "$selected_pkg")"

    echo
    echo "已选择内核包: $selected_pkg"
    if package_is_available "$headers_pkg"; then
        echo "将同时安装 headers 包: $headers_pkg"
    else
        echo "警告: 未找到匹配的 headers 包: $headers_pkg"
    fi
    if ! confirm "现在安装这个内核包吗?" "y"; then
        echo "已取消。"
        exit 0
    fi

    if package_is_available "$headers_pkg"; then
        "$APT_GET" install -y "$selected_pkg" "$headers_pkg"
    else
        "$APT_GET" install -y "$selected_pkg"
    fi
    install_matching_headers "$selected_pkg" || true

    if command -v update-grub >/dev/null 2>&1; then
        echo
        echo "正在更新 GRUB 菜单..."
        update-grub
    fi

    print_installed_kernels

    echo
    echo "可以自己选要删除的包，直接回车跳过。"
    if choose_purge "$tmp_old" "$tmp_old.chosen"; then
        switch_boot_kernel "$tmp_old"
    fi

    echo
    echo "完成。需要重启后才会使用新安装的内核。"
    echo "重启前建议执行以下检查:"
    echo "  dpkg-query -W -f='\${Package}\t\${Version}\n' 'linux-image-*' | sort -V"
    echo "  dpkg-query -W -f='\${Package}\t\${Version}\n' 'linux-headers-*' | sort -V"
    echo "  grep menuentry /boot/grub/grub.cfg | grep 'Linux'"
}

main "$@"
