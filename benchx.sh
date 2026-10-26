#!/bin/bash
# VPS 性能快速检测脚本 v0.2
# by tj 机组(teijiang,远古巨瘦,钻舰队长,鸡贼王，石巨人,牛头人)带领claude、dp3出品
# CPU 项改为 cpubench（Go）。综合指数是五项 ops/s 的几何平均，不是 GB5；拿到对照机器后再校准。

echo -e "\033[1;34m===== 站长 VPS 性能快速检测 v0.2 =====\033[0m"
echo "专注检测：IO性能、CPU（cpubench）、内存带宽、超售程度"
echo "预计耗时：约 90 秒（CPU 默认 3 次取中位数；首次会下载 Go 工具链）"
 
# 全局变量
declare -gi DISK_IOPS=0
declare -gi MEMORY_BANDWIDTH=0
declare -gi CPU_SINGLE_SCORE=0
declare -gi CPU_MULTI_SCORE=0
declare -g NETWORK_LATENCY="0"
declare -g actual_efficiency=0
declare -g CPU_SCALE="0"
declare -g STEAL_PCT="0"
declare -gi CPU_BENCH_OK=0
# 每项时长和重复次数。例：CPU_BENCH_DURATION=2s CPU_BENCH_REPS=1 bash benchx.sh
declare -g CPU_BENCH_DURATION="${CPU_BENCH_DURATION:-1s}"
declare -gi CPU_BENCH_REPS="${CPU_BENCH_REPS:-3}"
declare -g GO_TOOLCHAIN="${GO_TOOLCHAIN:-go1.22.10}"
declare -g DISK_IOPS_STR="0"    # 字符串存储综合评分
declare -g read_iops_formatted="0"   # 字符串存储原始IOPS值
declare -g write_bw_formatted="0"    # 字符串存储原始带宽值
declare -gi  cores=1
# 工具安装
install_tools() {
    local tools_needed=""
    command -v fio &>/dev/null || tools_needed="$tools_needed fio"
    command -v sysbench &>/dev/null || tools_needed="$tools_needed sysbench"
    command -v bc &>/dev/null || tools_needed="$tools_needed bc"
    command -v jq &>/dev/null || tools_needed="$tools_needed jq"
    command -v curl &>/dev/null || tools_needed="$tools_needed curl"
    
    if [[ -n "$tools_needed" ]]; then
        echo "安装必要工具: $tools_needed"
        if command -v apt-get &>/dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y $tools_needed >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y $tools_needed >/dev/null 2>&1
        fi
    fi
}

# 数值格式化
format_number() {
    local num=$1
    # 移除非数字字符
    num_str=$(echo "$num" | tr -cd '0-9')
    [[ -z "$num_str" ]] && echo "0" && return
    
    # 直接使用字符串处理大数值
    echo "$num_str" | awk '{printf "%'\''d", $1}'
     
}

# 安全的浮点数比较
float_compare() {
    local val1=$1
    local op=$2  
    local val2=$3
    echo "$val1 $op $val2" | bc -l 2>/dev/null || echo 0
} 
 
# 优先用脚本同目录的 cpubench.go，否则从本文件末尾的嵌入副本抽出。
ensure_go() {
    local arch tar root url tmp unpack download_ok
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *)
            echo "不支持的 CPU 架构: $(uname -m)"
            return 1
            ;;
    esac

    export GOTOOLCHAIN=local
    for root in "/opt/${GO_TOOLCHAIN}" "${HOME:-/tmp}/.${GO_TOOLCHAIN}"; do
        if [[ -x "${root}/bin/go" ]]; then
            export GOROOT="$root"
            export PATH="${root}/bin:${PATH}"
            hash -r
            return 0
        fi
    done

    if command -v go >/dev/null 2>&1 && go version 2>/dev/null | grep -q "${GO_TOOLCHAIN} "; then
        return 0
    fi

    root="${HOME:-/tmp}/.${GO_TOOLCHAIN}"
    if mkdir -p /opt >/dev/null 2>&1 && [[ -w /opt ]]; then
        root="/opt/${GO_TOOLCHAIN}"
    fi

    tar="${GO_TOOLCHAIN}.linux-${arch}.tar.gz"
    tmp="/tmp/${tar}"
    echo "下载固定 Go 工具链 ${GO_TOOLCHAIN}（各机器必须同版本才能比分数）..."
    download_ok=0
    for url in \
        "https://mirrors.aliyun.com/golang/${tar}" \
        "https://mirrors.cloud.tencent.com/go/${tar}" \
        "https://go.dev/dl/${tar}"
    do
        echo "  尝试 ${url}"
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 2 --connect-timeout 20 -o "$tmp" "$url" && download_ok=1 && break
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$tmp" "$url" && download_ok=1 && break
        else
            echo "没有 curl 或 wget，无法下载 Go"
            break
        fi
    done
    if [[ "$download_ok" -ne 1 ]]; then
        if command -v go >/dev/null 2>&1; then
            echo "工具链下载失败，改用系统 Go：$(go version 2>/dev/null)。换机器对比时分数可能不可比。"
            return 0
        fi
        echo "无法下载 ${GO_TOOLCHAIN}，也没有系统 Go。"
        return 1
    fi

    unpack="/tmp/${GO_TOOLCHAIN}-unpack"
    rm -rf "$unpack" "$root"
    mkdir -p "$unpack" || return 1
    tar -C "$unpack" -xzf "$tmp" || return 1
    mkdir -p "$(dirname "$root")" || return 1
    mv "$unpack/go" "$root" || return 1
    rm -rf "$unpack" "$tmp"
    export GOROOT="$root"
    export PATH="${root}/bin:${PATH}"
    hash -r
    return 0
}

prepare_cpubench_source() {
    local dest_dir="/tmp/cpubench-src"
    local script_dir self
    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"
    self="${BASH_SOURCE[0]}"
    script_dir=$(cd "$(dirname "$self")" 2>/dev/null && pwd)
    if [[ -n "$script_dir" && -f "${script_dir}/cpubench.go" ]]; then
        cp "${script_dir}/cpubench.go" "${dest_dir}/cpubench.go"
    elif [[ -f "./cpubench.go" ]]; then
        cp "./cpubench.go" "${dest_dir}/cpubench.go"
    elif [[ -f "$self" ]]; then
        awk '
            $0 == "#__CPUBENCH_GO__" { p = 1; next }
            $0 == "#__CPUBENCH_END__" { p = 0 }
            p { print }
        ' "$self" > "${dest_dir}/cpubench.go"
    fi
    if ! grep -q '^package main' "${dest_dir}/cpubench.go" 2>/dev/null; then
        echo "找不到 cpubench.go。请和 benchx.sh 放在一起，或使用带嵌入源码的脚本。"
        return 1
    fi
}

build_cpubench() {
    ensure_go || return 1
    prepare_cpubench_source || return 1
    echo "编译 cpubench ($(go version 2>/dev/null))..."
    if ! (
        cd /tmp/cpubench-src || exit 1
        export GO111MODULE=on
        export GOPROXY=off
        export GOSUMDB=off
        export CGO_ENABLED=0
        export GOTOOLCHAIN=local
        rm -f go.mod go.sum
        go mod init cpubench >/dev/null 2>&1 || exit 1
        go build -ldflags="-s -w" -o /tmp/cpubench .
    ); then
        echo "cpubench 编译失败"
        return 1
    fi
    [[ -x /tmp/cpubench ]]
}

# ==================== 虚拟化检测 ====================
detect_virtualization() {
    echo -e "\n\033[1;35m[系统信息] 虚拟化技术检测\033[0m"
    
    local virt_type="未知"
    
    # 检测容器环境
    if [ -f /proc/1/cgroup ]; then
        if grep -qi "docker" /proc/1/cgroup; then
            virt_type="Docker"
        elif grep -qi "kubepods" /proc/1/cgroup; then
            virt_type="Kubernetes"
        elif grep -qi "lxc" /proc/1/cgroup; then
            virt_type="LXC"
        fi
    fi
    
    # 检测虚拟机环境
    if [[ "$virt_type" == "未知" ]]; then
        if [[ -f /proc/cpuinfo ]]; then
            if grep -qi "hypervisor" /proc/cpuinfo; then
                if dmesg | grep -qi "kvm"; then
                    virt_type="KVM"
                elif dmesg | grep -qi "vmware"; then
                    virt_type="VMware"
                elif dmesg | grep -qi "xen"; then
                    virt_type="Xen"
                elif dmesg | grep -qi "microsoft hv"; then
                    virt_type="Hyper-V"
                else
                    virt_type="虚拟化 (类型未知)"
                fi
            else
                virt_type="物理机"
            fi
        fi
    fi

    # 使用systemd检测
    if [[ "$virt_type" == "未知" ]]; then
        if command -v systemd-detect-virt &>/dev/null; then
            local sysd_virt=$(systemd-detect-virt)
            [[ "$sysd_virt" != "none" ]] && virt_type="$sysd_virt"
        fi
    fi
    
    echo "虚拟化技术: $virt_type"
}

# ==================== 1. 磁盘IO性能测试 ====================
test_disk_performance() {
    echo -e "\n\033[1;34m[磁盘测试] 建站IO密集型模式测试\033[0m"
    local test_file="/tmp/wp_io_test.bin"
    local result_file="/tmp/fio_result.json"
    
    # 清理可能的旧文件
    rm -f "$test_file" "$result_file" 2>/dev/null
    
    # 建站典型IO密集型模式：4K随机读写 + 64K顺序写
    echo "测试随机4K读取（数据库查询模式）..."
    fio --name=wp_db_read --filename="$test_file" --rw=randread --bs=4k \
        --size=200M --runtime=8 --direct=1 --numjobs=4 --group_reporting \
        --output-format=json --output="$result_file" >/dev/null 2>&1
    
    # 改进的解析逻辑
    local read_iops=0
    if [[ -f "$result_file" ]]; then
        if command -v jq &>/dev/null; then
            read_iops=$(jq '.jobs[0].read.iops' "$result_file" 2>/dev/null | cut -d. -f1)
        else
            read_iops=$(grep -o '"iops":[0-9.]*' "$result_file" | head -1 | cut -d: -f2 | cut -d. -f1)
        fi
    fi
    [[ -z "$read_iops" ]] || ! [[ "$read_iops" =~ ^[0-9]+$ ]] && read_iops=0
    
    echo "测试64K顺序写入（媒体上传模式）..."
    fio --name=wp_media_write --filename="$test_file" --rw=write --bs=64k \
        --size=200M --runtime=5 --direct=1 --numjobs=2 --group_reporting \
        --output-format=json --output="$result_file" >/dev/null 2>&1
    
    local write_bw=0
    if [[ -f "$result_file" ]]; then
        if command -v jq &>/dev/null; then
            write_bw=$(jq '.jobs[0].write.bw' "$result_file" 2>/dev/null | cut -d. -f1)
        else
            write_bw=$(grep -o '"bw":[0-9.]*' "$result_file" | head -1 | cut -d: -f2 | cut -d. -f1)
        fi
    fi
    [[ -z "$write_bw" ]] || ! [[ "$write_bw" =~ ^[0-9]+$ ]] && write_bw=0
    
    # 计算写入带宽（MB/s）
    local write_mbps=$((write_bw / 1024))
    # 综合IO评分（模拟GB5存储分数）
    DISK_IOPS=$((read_iops + write_bw / 100))
    
    # 使用人类可读的单位输出
    read_iops_formatted=$(format_number "$read_iops")
    write_mbps_formatted=$(format_number "$write_mbps")
    
    # 使用字符串存储综合评分
    DISK_IOPS_STR=$read_iops
    echo "4K 随机读 IOPS: ${read_iops_formatted}"
    echo "64K 写入带宽: ${write_mbps_formatted} MB/s (${write_bw} KB/s)"
    echo "综合 IO 评分: $(format_number "$DISK_IOPS")"

    # 清理临时文件
    rm -f "$test_file" "$result_file" 2>/dev/null
} 	
# ==================== 2. CPU性能测试 ====================
test_cpu_performance() {
    echo -e "\n\033[1;34m[CPU测试] 单核/多核计算能力（cpubench）\033[0m"

    local cpu_model cpu_mhz physical eff cv go_ver name single multi scale json
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')
    [[ -z "$cpu_model" ]] && cpu_model="未知"
    cores=$(nproc 2>/dev/null || echo 1)
    [[ "$cores" =~ ^[0-9]+$ ]] || cores=1
    [[ "$cores" -lt 1 ]] && cores=1
    cpu_mhz=$(grep -m1 "cpu MHz" /proc/cpuinfo | awk '{print $4}' | cut -d. -f1)
    [[ -z "$cpu_mhz" ]] && cpu_mhz="未知"

    echo "CPU型号: $cpu_model"
    echo "逻辑核心: $cores, 频率: ${cpu_mhz}MHz"
    physical=$(awk '
        /^physical id/ { id = $NF; ids[id] = 1 }
        /^cpu cores/   { if (id == "") id = "x"; cores[id] = $NF }
        END {
            s = 0
            for (i in ids) s += cores[i]
            print s + 0
        }
    ' /proc/cpuinfo)
    if [[ "$physical" =~ ^[0-9]+$ && "$physical" -gt 0 && "$physical" -ne "$cores" ]]; then
        echo "物理核心约: $physical（逻辑核心更多时多半开了超线程，scale 对不齐逻辑核心数是正常的）"
    fi
    echo "pointer_chase 多核大约占用 $((cores * 8))MB 内存"

    CPU_BENCH_OK=0
    if ! build_cpubench; then
        echo "CPU 基准没编出来，跳过"
        return
    fi

    echo "运行 CPU 基准：重复 ${CPU_BENCH_REPS} 次取中位数，每项 ${CPU_BENCH_DURATION}"
    echo "（改时长：CPU_BENCH_DURATION=2s CPU_BENCH_REPS=1 bash benchx.sh）"
    if ! json=$(/tmp/cpubench -d "$CPU_BENCH_DURATION" -reps "$CPU_BENCH_REPS" -json); then
        echo "cpubench 运行失败"
        return
    fi
    printf '%s\n' "$json" > /tmp/cpubench_result.json

    if ! command -v jq >/dev/null 2>&1 || ! jq -e '.single_geomean > 0' >/dev/null <<<"$json"; then
        echo "结果解析失败，原始输出在 /tmp/cpubench_result.json"
        return
    fi

    for name in hash_lookup string_render pointer_chase json_roundtrip branchy_parse; do
        single=$(jq -r --arg n "$name" '.results[$n].single' <<<"$json")
        multi=$(jq -r --arg n "$name" '.results[$n].multi' <<<"$json")
        scale=$(jq -r --arg n "$name" '.results[$n].scale' <<<"$json")
        printf "  %-16s single=%12.0f  multi=%12.0f  scale=%5.2fx\n" "$name" "$single" "$multi" "$scale"
    done

    CPU_SINGLE_SCORE=$(jq -r '.single_geomean | floor' <<<"$json")
    CPU_MULTI_SCORE=$(jq -r '.multi_geomean | floor' <<<"$json")
    CPU_SCALE=$(awk -v s="$(jq -r '.scale_geomean' <<<"$json")" 'BEGIN { printf "%.4f", s }')
    STEAL_PCT=$(awk -v s="$(jq -r '.steal_pct' <<<"$json")" 'BEGIN { printf "%.2f", s }')
    cv=$(awk -v s="$(jq -r '.single_cv_pct' <<<"$json")" 'BEGIN { printf "%.2f", s }')
    go_ver=$(jq -r '.go_version' <<<"$json")
    actual_efficiency="$CPU_SCALE"
    [[ "$CPU_SINGLE_SCORE" =~ ^[0-9]+$ ]] || CPU_SINGLE_SCORE=0
    [[ "$CPU_MULTI_SCORE" =~ ^[0-9]+$ ]] || CPU_MULTI_SCORE=0
    CPU_BENCH_OK=1

    eff=$(awk -v s="$CPU_SCALE" -v c="$cores" 'BEGIN { if (c < 1) c = 1; printf "%.1f", (s / c) * 100 }')
    echo "Go 版本: $go_ver（换机器对比必须相同）"
    echo "单核综合指数: $(format_number "$CPU_SINGLE_SCORE")（五项 single 的几何平均，ops/s，不是 GB5）"
    echo "多核综合指数: $(format_number "$CPU_MULTI_SCORE")（五项 multi 的几何平均，ops/s，不是 GB5）"
    echo "扩展比: ${CPU_SCALE}x / ${cores} 线程，并行效率 ${eff}%"
    echo "测试期间 steal: ${STEAL_PCT}%（持续高于几个百分点就要怀疑宿主机超卖）"
    if [[ "$CPU_BENCH_REPS" -gt 1 ]]; then
        echo "单核综合指数重复 CV: ${cv}%（偏大说明这次短测不稳，别直接拿去比）"
    fi
    echo "GB5 先不估。把 /tmp/cpubench_result.json 和这台机器的 GB5 单核/多核发回来再拟合。"
    echo "原始结果: /tmp/cpubench_result.json"
}

# ==================== 3. 内存带宽测试 ====================
test_memory_bandwidth() {
    echo -e "\n\033[1;34m[内存测试] 内存带宽检测\033[0m"
    
    MEMORY_BANDWIDTH=0
    
    echo "内存读写速度测试..."
    if command -v sysbench &>/dev/null; then
        # 使用sysbench测试内存
        sysbench memory --memory-block-size=1K --memory-total-size=2G \
            --memory-oper=write --threads=4 --time=5 run > /tmp/mem_test.log 2>&1
        
        local mem_result=$(grep "MiB transferred" /tmp/mem_test.log | awk '{print $(NF-2)}' | sed 's/(//')
        if [[ "$mem_result" =~ ^[0-9.]+$ ]]; then
            MEMORY_BANDWIDTH=$(echo "$mem_result * 1024 / 5" | bc | cut -d. -f1)  # 转换为MB/s
        fi
        rm -f /tmp/mem_test.log 2>/dev/null
    fi
    
    # 备用方法：使用dd测试
    if [[ $MEMORY_BANDWIDTH -eq 0 ]]; then
        echo "使用dd测试内存速度..."
        local temp_file="/dev/shm/memtest.tmp"
        if [[ -d "/dev/shm" ]]; then
            sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
            local dd_result=$(dd if=/dev/zero of="$temp_file" bs=1M count=500 conv=fdatasync 2>&1 | \
                grep -o '[0-9.]* [MG]B/s' | head -1)
            
            if [[ "$dd_result" =~ ^[0-9.]+\ GB/s ]]; then
                local gb_speed=$(echo "$dd_result" | awk '{print $1}')
                MEMORY_BANDWIDTH=$(echo "$gb_speed * 1024" | bc | cut -d. -f1)
            elif [[ "$dd_result" =~ ^[0-9.]+\ MB/s ]]; then
                MEMORY_BANDWIDTH=$(echo "$dd_result" | awk '{print $1}' | cut -d. -f1)
            fi
            
            rm -f "$temp_file" 2>/dev/null
        fi
    fi
    
    if [[ $MEMORY_BANDWIDTH -gt 0 ]]; then
        # 转换为GB/s
        local mem_gbs=$(echo "scale=2; $MEMORY_BANDWIDTH / 1024" | bc)
        echo "内存带宽: $(format_number "$MEMORY_BANDWIDTH") MB/s (${mem_gbs} GB/s)"
    else
        echo "内存带宽: 无法检测"
        MEMORY_BANDWIDTH=3000  # 设置默认值
    fi
}

# ==================== 4. 中断风暴检测 ====================
test_interrupt_stability() {
    echo -e "\n\033[1;34m[稳定性测试] 中断和系统负载检测\033[0m"
    
    local before_file="/tmp/interrupts_before"
    local after_file="/tmp/interrupts_after"
    
    cat /proc/interrupts > "$before_file" 2>/dev/null
    local before_total=$(awk 'NR>1 && NF>2 {for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i} END{print sum+0}' "$before_file")
    
    echo "运行系统负载测试（5 秒）..."
    {
        for i in $(seq 1 $(nproc)); do
            timeout 5 bash -c 'x=0; while [ $((x++)) -lt 10000000 ]; do :; done' & 
        done
        timeout 5 dd if=/dev/zero of=/tmp/loadtest bs=1M count=100 conv=fdatasync >/dev/null 2>&1 & 
        wait
    } >/dev/null 2>&1
    
    sleep 1
    cat /proc/interrupts > "$after_file" 2>/dev/null
    local after_total=$(awk 'NR>1 && NF>2 {for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i} END{print sum+0}' "$after_file")
    
    local interrupt_rate=$(( (after_total - before_total) / 5 ))
    echo "中断频率: $(format_number "$interrupt_rate") 次/秒"
    
    # 分析异常中断
    local critical_irqs=0
    if [[ -f "$before_file" && -f "$after_file" ]]; then
        while read -r line; do
            local irq=$(echo "$line" | awk '{print $1}' | tr -d ':')
            [[ ! "$irq" =~ ^[0-9]+$ ]] && continue
            
            local before_count=$(grep "^ *$irq:" "$before_file" 2>/dev/null | \
                awk 'NF>2 {sum=0; for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i; print sum}')
            local after_count=$(grep "^ *$irq:" "$after_file" 2>/dev/null | \
                awk 'NF>2 {sum=0; for(i=2;i<=NF-3;i++) if($i~/^[0-9]+$/) sum+=$i; print sum}')
            
            if [[ -n "$before_count" && -n "$after_count" && "$after_count" -gt "$before_count" ]]; then
                local diff=$((after_count - before_count))
                if [[ $diff -gt 2000 ]]; then
                    echo "⚠️ IRQ $irq 异常活跃: $diff 次中断"
                    critical_irqs=$((critical_irqs + 1))
                fi
            fi
        done < <(tail -n +2 "$after_file")
    fi
    
    rm -f "$before_file" "$after_file" "/tmp/loadtest" 2>/dev/null
    
    # 稳定性评级
    if [[ $critical_irqs -gt 3 ]]; then
        echo "🔴 系统不稳定：检测到 $critical_irqs 个异常中断源"
        return 2
    elif [[ $interrupt_rate -gt 100000 ]]; then
        echo "🟠 系统负载偏高：中断频率 > 10万/秒"
        return 1
    else
        echo "🟢 系统稳定：中断处理正常"
        return 0
    fi
}

# ==================== 5. 修复的网络延迟测试 ====================
test_network_latency() {
    echo -e "\n\033[1;34m[网络测试] CDN和数据库连接延迟\033[0m"
    
    local targets=("8.8.8.8" "1.1.1.1")
    local total_latency="0"
    local successful_pings=0
    
    for target in "${targets[@]}"; do
        echo "测试到 $target 的延迟..."
        local ping_result=$(timeout 3 ping -c 3 -W 1 "$target" 2>/dev/null | \
            grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}' | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')
        
        if [[ "$ping_result" =~ ^[0-9.]+$ ]] && [[ $(echo "$ping_result > 0" | bc 2>/dev/null || echo 0) -eq 1 ]]; then
            total_latency=$(echo "$total_latency + $ping_result" | bc)
            successful_pings=$((successful_pings + 1))
            echo "延迟: ${ping_result}ms"
        else
            echo "延迟: 超时"
        fi
    done
    
    if [[ $successful_pings -gt 0 ]]; then
        NETWORK_LATENCY=$(echo "scale=2; $total_latency / $successful_pings" | bc)
        echo "平均网络延迟: ${NETWORK_LATENCY}ms"
    else
        echo "网络连接异常"
        NETWORK_LATENCY="999"
    fi
}

# ==================== 6. 超售程度评估 ====================
assess_overselling() {
    echo -e "\n\033[1;35m[超售检测] 系统资源分配评估\033[0m"
    
    local cpu_score=0
    local memory_score=0
    local io_score=0
    local total_score=0
    
    # 1. CPU超售检测（cpubench 的 scale / 逻辑核心，外加 steal）
    if [[ "$CPU_BENCH_OK" -eq 1 && "$actual_efficiency" != "0" ]]; then
        local efficiency_percent steal_int
        efficiency_percent=$(awk -v s="$actual_efficiency" -v c="$cores" 'BEGIN { if (c < 1) c = 1; printf "%d", (s / c) * 100 }')
        steal_int=$(awk -v s="${STEAL_PCT:-0}" 'BEGIN { printf "%d", s+0 }')
        [[ "$efficiency_percent" =~ ^[0-9]+$ ]] || efficiency_percent=0

        echo "CPU扩展效率: ${efficiency_percent}%（scale ${actual_efficiency} / ${cores} 线程）"
        echo "CPU steal: ${STEAL_PCT}%"

        if [[ $efficiency_percent -ge 85 ]]; then
            echo "CPU扩展效率: 优秀 - 无超售迹象"
            cpu_score=3
        elif [[ $efficiency_percent -ge 70 ]]; then
            echo "CPU扩展效率: 良好 - 轻度超售，或只是超线程在分执行单元"
            cpu_score=2
        elif [[ $efficiency_percent -ge 50 ]]; then
            echo "CPU扩展效率: 一般 - 中度超售或被限速"
            cpu_score=1
        else
            echo "CPU扩展效率: 差 - 严重超售或被限速"
            cpu_score=0
        fi
        if [[ $steal_int -ge 10 ]]; then
            echo "steal 很高 - 宿主机很可能在超卖 CPU"
            cpu_score=0
        elif [[ $steal_int -ge 4 && $cpu_score -gt 0 ]]; then
            echo "steal 高于几个百分点 - 有超卖迹象，评分下调"
            cpu_score=$((cpu_score - 1))
        fi
    else
        echo "CPU 基准没有跑成，跳过 CPU 超售判断"
        cpu_score=1
    fi
    
    # 2. 内存超售检测
    local mem_used=$(free -m | awk '/Mem:/ {printf "%.1f", $3/$2*100}')
    local swap_used=$(free -m | awk '/Swap:/ {if ($2 == 0) print "0"; else printf "%.1f", $3/$2*100}')
    
    # 内存带宽评估
    local mem_bandwidth_gbs=$(echo "scale=2; $MEMORY_BANDWIDTH / 1024" | bc)
    local mem_bandwidth_score=0
    
    if [ $(echo "$mem_bandwidth_gbs > 15" | bc -l) -eq 1 ]; then
        echo "内存带宽: 优秀 (${mem_bandwidth_gbs} GB/s) - 无超售迹象"
        mem_bandwidth_score=3
    elif [ $(echo "$mem_bandwidth_gbs > 8" | bc -l) -eq 1 ]; then
        echo "内存带宽: 良好 (${mem_bandwidth_gbs} GB/s) - 轻度超售可能"
        mem_bandwidth_score=2 
    elif [ $(echo "$mem_bandwidth_gbs > 3" | bc -l) -eq 1 ]; then
        echo "内存带宽: 普通 (${mem_bandwidth_gbs} GB/s) - 重度超售可能"
        mem_bandwidth_score=1 
    else
        echo "内存带宽: 较差 (${mem_bandwidth_gbs} GB/s) - 可能严重超售"
        mem_bandwidth_score=0
    fi 
    
    memory_score=$(( mem_bandwidth_score + mem_usage_score + swap_score ))
    
    # 3. IO超售检测
    # 数据库查询性能评估 (4K随机读)
    if [[ $DISK_IOPS_STR -gt 10000 ]]; then
        echo "数据库查询性能: 优秀 ($(format_number $read_iops_formatted) IOPS) - 无超售迹象"
        io_score=3
    elif [[ $DISK_IOPS_STR -gt 3000 ]]; then
        echo "数据库查询性能: 良好 ($(format_number $read_iops_formatted) IOPS) - 轻度超售可能"
        io_score=2
    elif [[ $DISK_IOPS_STR -gt 1000 ]]; then
        echo "数据库查询性能: 一般 ($(format_number $read_iops_formatted) IOPS) - 可能超售"
        io_score=1
    else
        echo "数据库查询性能: 差 ($(format_number $read_iops_formatted) IOPS) - 可能严重超售"
        io_score=0
    fi
    
    # 媒体上传性能评估 (64K顺序写)
    if [[ $write_mbps_formatted -gt 500 ]]; then  # >500 MB/s
        echo "媒体上传性能: 优秀 ($(format_number $((write_mbps_formatted))) MB/s) - 无超售迹象"
        io_score=$((io_score + 1))
    elif [[ $write_mbps_formatted -gt 200 ]]; then  # >200 MB/s
        echo "媒体上传性能: 良好 ($(format_number $((write_mbps_formatted))) MB/s) - 轻度超售可能"
        io_score=$((io_score + 1))
    else
        echo "媒体上传性能: 差 ($(format_number $((write_mbps_formatted))) MB/s) - 可能超售"
    fi
    
    # 综合评分
    total_score=$((cpu_score + memory_score + io_score))
    local oversell_level=""
    if [[ $total_score -ge 9 ]]; then
        oversell_level="非常好"
    elif [[ $total_score -ge 8 ]]; then
        oversell_level="无超售迹象"
    elif [[ $total_score -ge 6 ]]; then
        oversell_level="轻度超售可能"
    elif [[ $total_score -ge 3 ]]; then
        oversell_level="中度超售"
    else
        oversell_level="发现远古巨瘦 您已严重超售"
    fi
    
    echo -e "\n\033[1;35m超售综合评估: ${total_score}/10 - ${oversell_level}\033[0m"
}
testc() {
     
    cache_mb=$(echo "$l3_cache" | sed 's/.*\\([0-9]\\+\\) MB.*/\\1/')
    [ -n "$cache_mb" ] || cache_mb=0
    cache_bonus=$(($cache_mb * 20))
    echo "L3 cache $cache_mb"   
    #estimate_gb5_from_benchmarks 118 216 531
    #test_cpu_performance
    #test_cpu_multicore_efficiency
}
# ==================== 主函数 ====================
main() {
    install_tools
    detect_virtualization
    test_disk_performance
    test_cpu_performance
    test_memory_bandwidth
    test_interrupt_stability
    #test_network_latency
    assess_overselling
    
    echo -e "\n\033[1;32m检测完成！\033[0m"
}

# 执行主程序
main "$@"
exit $?

# 下面这段不执行，只给 prepare_cpubench_source 在找不到同目录 cpubench.go 时抽出。
# 和 cpubench.go 保持同一份。同目录有 cpubench.go 时以那个文件为准。
#__CPUBENCH_GO__
// cpubench：五项和建站相关的 CPU 微基准。
// 单核分看 single，并行容量看 multi 和 scale，偷取看 steal_pct。
// 跨机器比较必须用同一个 Go 版本、同一份二进制，重复跑取中位数。
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var sink uint64

type bench struct {
	name string
	mk   func(seed int64) func() uint64 // 返回“一批工作”，结果为完成的操作数
}

func benchHash(seed int64) func() uint64 {
	keys := make([]string, 50000)
	m := make(map[string]int, len(keys))
	for i := range keys {
		keys[i] = "option_" + strconv.Itoa(i*7919)
		m[keys[i]] = i
	}
	r := rand.New(rand.NewSource(seed))
	return func() uint64 {
		s := 0
		for i := 0; i < 1000; i++ {
			s += m[keys[r.Intn(len(keys))]]
		}
		atomic.AddUint64(&sink, uint64(s))
		return 1000
	}
}

func benchString(_ int64) func() uint64 {
	tpl := strings.Repeat(`<div class="{{cls}}"><a href="{{url}}">{{title}}</a></div>`+"\n", 200)
	return func() uint64 {
		s := strings.ReplaceAll(tpl, "{{cls}}", "post")
		s = strings.ReplaceAll(s, "{{url}}", "/2026/10/hello-world/")
		s = strings.ReplaceAll(s, "{{title}}", "Hello World")
		atomic.AddUint64(&sink, uint64(len(s)+strings.Count(s, "<a ")+strings.Index(s, "World")))
		return 1
	}
}

func benchChase(seed int64) func() uint64 {
	n := 1 << 21 // 8MB，超过常见 L2
	next := make([]int32, n)
	perm := rand.New(rand.NewSource(seed)).Perm(n)
	for i := 0; i < n; i++ { // 构造单一大环，避免提前回到起点
		next[perm[i]] = int32(perm[(i+1)%n])
	}
	p := int32(0)
	return func() uint64 {
		for i := 0; i < 100000; i++ {
			p = next[p]
		}
		atomic.AddUint64(&sink, uint64(p))
		return 100000
	}
}

type post struct {
	ID    int               `json:"id"`
	Title string            `json:"title"`
	Tags  []string          `json:"tags"`
	Meta  map[string]string `json:"meta"`
}

func benchJSON(_ int64) func() uint64 {
	p := post{
		ID:    42,
		Title: "Hello World",
		Tags:  []string{"a", "b", "c", "wordpress"},
		Meta:  map[string]string{"_edit_lock": "1700000000:1", "_thumbnail_id": "123", "views": "9999"},
	}
	return func() uint64 {
		b, _ := json.Marshal(p)
		var q post
		_ = json.Unmarshal(b, &q)
		atomic.AddUint64(&sink, uint64(q.ID+len(b)))
		return 1
	}
}

func benchBranchy(seed int64) func() uint64 {
	alpha := []byte("<>/ab =\"\n")
	r := rand.New(rand.NewSource(seed))
	data := make([]byte, 64*1024)
	for i := range data {
		data[i] = alpha[r.Intn(len(alpha))]
	}
	return func() uint64 {
		state, tags, quotes := 0, 0, 0
		for _, c := range data {
			switch state {
			case 0:
				if c == '<' {
					state = 1
				}
			case 1:
				if c == '>' {
					tags++
					state = 0
				} else if c == '"' {
					state = 2
				}
			case 2:
				if c == '"' {
					quotes++
					state = 1
				}
			}
		}
		atomic.AddUint64(&sink, uint64(tags+quotes))
		return 1
	}
}

var benches = []bench{
	{"hash_lookup", benchHash},
	{"string_render", benchString},
	{"pointer_chase", benchChase},
	{"json_roundtrip", benchJSON},
	{"branchy_parse", benchBranchy},
}

// 准备阶段不计入计时。单线程时把 GOMAXPROCS 收到 1，避免 GC 蹭到别的核。
func run(b bench, threads int, dur time.Duration) float64 {
	if threads < 1 {
		threads = 1
	}
	prev := runtime.GOMAXPROCS(threads)
	defer runtime.GOMAXPROCS(prev)

	var total uint64
	var wg sync.WaitGroup
	start := make(chan struct{})
	ready := make(chan struct{})
	var readyN int64

	for t := 0; t < threads; t++ {
		wg.Add(1)
		go func(seed int64) {
			defer wg.Done()
			runtime.LockOSThread()
			work := b.mk(seed)
			if atomic.AddInt64(&readyN, 1) == int64(threads) {
				close(ready)
			}
			<-start
			t0 := time.Now()
			var ops uint64
			for time.Since(t0) < dur {
				ops += work()
			}
			atomic.AddUint64(&total, ops)
		}(int64(t) + 1)
	}
	<-ready
	close(start)
	wg.Wait()
	runtime.GC()
	return float64(total) / dur.Seconds()
}

func readCPU() (steal, total uint64) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return
	}
	f := strings.Fields(strings.SplitN(string(data), "\n", 2)[0])
	for i := 1; i < len(f) && i <= 8; i++ {
		v, _ := strconv.ParseUint(f[i], 10, 64)
		total += v
		if i == 8 {
			steal = v
		}
	}
	return
}

func meanOf(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	var s float64
	for _, x := range xs {
		s += x
	}
	return s / float64(len(xs))
}

func cvRatio(xs []float64) float64 {
	if len(xs) < 2 {
		return 0
	}
	m := meanOf(xs)
	if m == 0 {
		return 0
	}
	var v float64
	for _, x := range xs {
		d := x - m
		v += d * d
	}
	return math.Sqrt(v/float64(len(xs))) / m
}

func stability(secs int) (mean, cv float64) {
	var xs []float64
	for i := 0; i < secs; i++ {
		xs = append(xs, run(benches[1], 1, time.Second))
	}
	return meanOf(xs), cvRatio(xs)
}

func median(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	cp := append([]float64(nil), xs...)
	sort.Float64s(cp)
	n := len(cp)
	if n%2 == 1 {
		return cp[n/2]
	}
	return (cp[n/2-1] + cp[n/2]) / 2
}

func geomean(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	s := 0.0
	for _, x := range xs {
		if x <= 0 {
			return 0
		}
		s += math.Log(x)
	}
	return math.Exp(s / float64(len(xs)))
}

type benchResult struct {
	Single float64 `json:"single"`
	Multi  float64 `json:"multi"`
	Scale  float64 `json:"scale"`
}

func main() {
	d := flag.Duration("d", 2*time.Second, "每项测试时长")
	reps := flag.Int("reps", 1, "重复次数，取中位数")
	stab := flag.Int("stable", 0, "稳定性测试秒数(0 为跳过)")
	asJSON := flag.Bool("json", false, "输出 JSON")
	flag.Parse()
	if *reps < 1 {
		*reps = 1
	}

	n := runtime.NumCPU()
	s0, t0 := readCPU()

	type samples struct {
		single []float64
		multi  []float64
	}
	collected := make(map[string]*samples, len(benches))
	for _, b := range benches {
		collected[b.name] = &samples{}
	}
	repSingleGM := make([]float64, 0, *reps)

	for rep := 0; rep < *reps; rep++ {
		var singles []float64
		for _, b := range benches {
			one := run(b, 1, *d)
			all := run(b, n, *d)
			collected[b.name].single = append(collected[b.name].single, one)
			collected[b.name].multi = append(collected[b.name].multi, all)
			singles = append(singles, one)
		}
		repSingleGM = append(repSingleGM, geomean(singles))
	}

	res := make(map[string]benchResult, len(benches))
	singleMeds := make([]float64, 0, len(benches))
	multiMeds := make([]float64, 0, len(benches))
	for _, b := range benches {
		s := collected[b.name]
		one := median(s.single)
		all := median(s.multi)
		scale := 0.0
		if one > 0 {
			scale = all / one
		}
		res[b.name] = benchResult{Single: one, Multi: all, Scale: scale}
		singleMeds = append(singleMeds, one)
		multiMeds = append(multiMeds, all)
	}

	s1, t1 := readCPU()
	steal := 0.0
	if t1 > t0 {
		steal = float64(s1-s0) / float64(t1-t0) * 100
	}

	singleGM := geomean(singleMeds)
	multiGM := geomean(multiMeds)
	scaleGM := 0.0
	if singleGM > 0 {
		scaleGM = multiGM / singleGM
	}

	out := map[string]interface{}{
		"cpus":           n,
		"go_version":     runtime.Version(),
		"reps":           *reps,
		"duration_sec":   d.Seconds(),
		"steal_pct":      steal,
		"single_geomean": singleGM,
		"multi_geomean":  multiGM,
		"scale_geomean":  scaleGM,
		"single_cv_pct":  cvRatio(repSingleGM) * 100,
		"results":        res,
	}
	if *stab > 0 {
		m, cv := stability(*stab)
		out["stability"] = map[string]float64{"mean_ops": m, "cv_pct": cv * 100}
	}

	if *asJSON {
		buf, _ := json.MarshalIndent(out, "", "  ")
		fmt.Println(string(buf))
		return
	}
	fmt.Printf("CPUs: %d  Go: %s  steal: %.2f%%  reps: %d\n", n, runtime.Version(), steal, *reps)
	for _, b := range benches {
		r := res[b.name]
		fmt.Printf("%-16s single=%12.0f  multi=%12.0f  scale=%.2fx\n", b.name, r.Single, r.Multi, r.Scale)
	}
	fmt.Printf("geomean          single=%12.0f  multi=%12.0f  scale=%.2fx", singleGM, multiGM, scaleGM)
	if *reps > 1 {
		fmt.Printf("  CV=%.2f%%", cvRatio(repSingleGM)*100)
	}
	fmt.Println()
	if s, ok := out["stability"].(map[string]float64); ok {
		fmt.Printf("stability: mean=%.0f ops/s  CV=%.2f%%\n", s["mean_ops"], s["cv_pct"])
	}
}
#__CPUBENCH_END__
