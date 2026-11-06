#!/bin/bash
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_TYPE="${ID:-unknown}"
else
  echo "无法识别系统"
  exit 1
fi

case "$(uname -m)" in
  amd64|x86_64) arch=amd64 ;;
  armv8|aarch64) arch=arm64 ;;
  *) echo "只支持 amd64 和 arm64"; exit 1 ;;
esac

BASE="/root/hy3"
BIN="$BASE/hysteria-linux-$arch"
CFG="$BASE/config.yaml"
META="$BASE/meta.env"
SNI_DEFAULT="www.bing.com"
MIERU_BASE="/root/mieru"

need_pkgs() {
  case "$OS_TYPE" in
    debian|ubuntu)
      apt-get update || return 1
      apt-get install -y wget curl openssl ca-certificates python3 qrencode iptables iproute2 || return 1
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y wget curl openssl ca-certificates python3 qrencode iptables iproute || return 1
      else
        yum install -y epel-release || true
        yum install -y wget curl openssl ca-certificates python3 qrencode iptables iproute || return 1
      fi
      ;;
    *)
      echo "不支持的系统: $OS_TYPE"
      exit 1
      ;;
  esac
  command -v systemctl >/dev/null 2>&1 || { echo "需要 systemd"; exit 1; }
}

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

randpw() {
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20
}

detect_ip() {
  local v4 v6
  v4="$(curl -4 -fsSL --max-time 8 https://api.ipify.org || true)"
  v6="$(curl -6 -fsSL --max-time 8 https://api64.ipify.org || true)"
  if [ -n "$v4" ]; then
    IP="$v4"
  elif [ -n "$v6" ]; then
    IP="[$v6]"
  else
    echo "没有取到公网 IP"
    exit 1
  fi
}

load_meta() {
  [ -f "$META" ] || { echo "还没有安装"; exit 1; }
  # shellcheck disable=SC1090
  . "$META"
  # 兼容旧版本：以前只要有 OBFS 密码就表示开启 Gecko 混淆。
  case "${OBFS_ENABLED:-}" in
    0|1) ;;
    *) [ -n "${OBFS:-}" ] && OBFS_ENABLED=1 || OBFS_ENABLED=0 ;;
  esac
}

save_meta() {
  mkdir -p "$BASE"
  local key
  : > "$META"
  for key in PORT AUTH OBFS_ENABLED OBFS UP DOWN IP SNI CERT_MODE DOMAIN EMAIL HOP HOP_START HOP_END HOP_IFACE; do
    printf '%s=%q\n' "$key" "${!key-}" >> "$META"
  done
  chmod 600 "$META"
}

download_bin() {
  mkdir -p "$BASE" /etc/hysteria
  wget -O "$BIN" "https://download.hysteria.network/app/latest/hysteria-linux-$arch" || {
    rm -f "$BIN"
    echo "内核下载失败"
    exit 1
  }
  chmod +x "$BIN"
}

write_unit() {
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Gecko
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BIN server -c $CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_config() {
  local tls_block obfs_block quoted_auth quoted_obfs
  quoted_auth="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$AUTH")" || return 1
  quoted_obfs="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${OBFS:-}")" || return 1
  if [ "$CERT_MODE" = "acme" ]; then
    tls_block="acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}"
  else
    tls_block="tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/private.key"
  fi
  if [ "${OBFS_ENABLED:-0}" = "1" ]; then
    obfs_block="obfs:
  type: gecko
  gecko:
    password: ${quoted_obfs}"
  else
    obfs_block=""
  fi
  cat > "$CFG" <<EOF
listen: :${PORT}

${tls_block}

${obfs_block}

auth:
  type: password
  password: ${quoted_auth}

ignoreClientBandwidth: false
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
EOF
}

write_clients() {
  local enc_auth enc_obfs extra link bare query node_name
  umask 077
  enc_auth="$(urlencode "$AUTH")"
  extra=""
  query="sni=$(urlencode "$SNI")"
  node_name="HY2"
  if [ "${OBFS_ENABLED:-0}" = "1" ]; then
    enc_obfs="$(urlencode "$OBFS")"
    query="obfs=gecko&obfs-password=${enc_obfs}&${query}"
    node_name="HY2-Gecko"
  fi
  [ "$CERT_MODE" = "self" ] && extra="&insecure=1"
  if [ "${HOP:-0}" = "1" ]; then
    extra="${extra}&mport=${PORT},${HOP_START}-${HOP_END}"
  fi
  link="hysteria2://${enc_auth}@${IP}:${PORT}/?${query}${extra}#${node_name}"
  echo "$link" > "$BASE/neko.txt"
  qrencode -o "$BASE/hy2.png" "$link"
  bare="${IP//[\[\]]/}"
  # JSON flow mappings are also valid YAML; quoting protects custom passwords and IPv6.
  python3 - "$bare" "$PORT" "$AUTH" "$SNI" "$CERT_MODE" "${OBFS_ENABLED:-0}" "${OBFS:-}" "${HOP:-0}" "${HOP_START:-}" "${HOP_END:-}" > "$BASE/clash-mate.yaml" <<'PY'
import json, sys
ip, port, password, sni, cert, obfs_on, obfs, hop, start, end = sys.argv[1:]
node = {'name': 'h-delux', 'type': 'hysteria2', 'server': ip, 'port': int(port),
        'password': password, 'alpn': ['h3'], 'sni': sni,
        'skip-cert-verify': cert == 'self'}
if obfs_on == '1':
    node.update({'obfs': 'gecko', 'obfs-password': obfs})
node['fast-open'] = True
if hop == '1':
    # mihomo uses ports; mport is included for clients using that spelling.
    node['ports'] = node['mport'] = f'{port},{start}-{end}'
print('proxies:\n  - ' + json.dumps(node, ensure_ascii=False))
PY
  [ $? -eq 0 ] || return 1
  chmod 600 "$BASE/neko.txt" "$BASE/clash-mate.yaml" "$BASE/hy2.png"
}

restart_svc() {
  write_unit
  systemctl enable hysteria.service
  systemctl restart hysteria.service
}

show_info() {
  load_meta
  write_clients || return 1
  echo "地址: $IP"
  echo "端口: $PORT"
  echo "认证密码: $AUTH"
  if [ "${OBFS_ENABLED:-0}" = "1" ]; then
    echo "Gecko 混淆: 开启，密码: $OBFS"
  else
    echo "Gecko 混淆: 关闭"
  fi
  echo "证书: $CERT_MODE  SNI: $SNI"
  echo
  echo "节点链接:"
  cat "$BASE/neko.txt"
  echo
  qrencode -t ANSIUTF8 < "$BASE/neko.txt" || true
  echo
  echo "Clash 配置:"
  cat "$BASE/clash-mate.yaml"
  echo "二维码图片: $BASE/hy2.png"
  echo "Clash Party: $BASE/clash-mate.yaml"
  echo "配置: $CFG"
}

make_self_cert() {
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/private.key \
    -out /etc/hysteria/cert.crt \
    -subj "/CN=${SNI}" -days 3650
  chmod 600 /etc/hysteria/private.key
}

apply_hop() {
  local iface
  if [ "${HOP:-0}" != "1" ]; then
    systemctl disable --now ipppp.service 2>/dev/null || true
    rm -f /etc/systemd/system/ipppp.service "$BASE/ipppp.sh"
    systemctl daemon-reload
    return
  fi
  iface="$HOP_IFACE"
  cat > "$BASE/ipppp.sh" <<EOF
#!/bin/bash
iptables -t nat -C PREROUTING -i ${iface} -p udp --dport ${HOP_START}:${HOP_END} -j DNAT --to-destination :${PORT} 2>/dev/null \
  || iptables -t nat -A PREROUTING -i ${iface} -p udp --dport ${HOP_START}:${HOP_END} -j DNAT --to-destination :${PORT}
EOF
  chmod +x "$BASE/ipppp.sh"
  cat > /etc/systemd/system/ipppp.service <<EOF
[Unit]
Description=Hysteria UDP port hop
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BASE/ipppp.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ipppp.service
}
install_hysteria() {
  if [ -f "$META" ]; then
    echo "已经安装。要重装请先选 2。"
    exit 1
  fi
  need_pkgs
  detect_ip
  download_bin

  local in_port in_auth in_obfs in_obfs_enabled in_up in_down in_sni in_ip in_cert in_hop

    while :; do
    rand_port=$((RANDOM % 55536 + 10000))
    if ! ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${rand_port}$"; then
      break
    fi
  done
  read -r -p "端口 [回车随机: ${rand_port}]: " in_port
  PORT="${in_port:-$rand_port}"
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "端口必须是 1-65535 的数字"; exit 1; }

  read -r -p "认证密码 [回车随机]: " in_auth
  AUTH="${in_auth:-$(randpw)}"

  read -r -p "开启 Gecko 混淆? 1=开启 0=关闭 [1]: " in_obfs_enabled
  in_obfs_enabled="${in_obfs_enabled:-1}"
  case "$in_obfs_enabled" in
    1)
      OBFS_ENABLED=1
      read -r -p "Gecko 混淆密码 [回车随机]: " in_obfs
      OBFS="${in_obfs:-$(randpw)}"
      ;;
    0)
      OBFS_ENABLED=0
      OBFS=""
      ;;
    *)
      echo "请选择 1 或 0"
      exit 1
      ;;
  esac

  read -r -p "上行 Mbps [100]: " in_up
  UP="${in_up:-100}"
  read -r -p "下行 Mbps [200]: " in_down
  DOWN="${in_down:-200}"

  read -r -p "服务器地址 [自动检测: $IP]: " in_ip
  [ -n "$in_ip" ] && IP="$in_ip"

  read -r -p "证书类型 1=自签 2=ACME域名 [1]: " in_cert
  in_cert="${in_cert:-1}"
  DOMAIN=""
  EMAIL=""

  if [ "$in_cert" = "2" ]; then
    CERT_MODE="acme"
    read -r -p "已解析到本机的域名: " DOMAIN
    [ -n "$DOMAIN" ] || { echo "域名不能为空"; exit 1; }
    read -r -p "ACME 邮箱 [admin@${DOMAIN}]: " EMAIL
    EMAIL="${EMAIL:-admin@${DOMAIN}}"
    SNI="$DOMAIN"
    IP="$DOMAIN"
  else
    CERT_MODE="self"
    read -r -p "自签证书 SNI [${SNI_DEFAULT}]: " in_sni
    SNI="${in_sni:-$SNI_DEFAULT}"
    make_self_cert
  fi

  HOP=0
  HOP_START=""
  HOP_END=""
  HOP_IFACE=""
  read -r -p "开启端口跳跃? 1=开启 [回车不开启]: " in_hop
  if [ "$in_hop" = "1" ]; then
    read -r -p "起始端口 [20000]: " HOP_START
    HOP_START="${HOP_START:-20000}"
    read -r -p "结束端口 [30000]: " HOP_END
    HOP_END="${HOP_END:-30000}"
    [[ "$HOP_START" =~ ^[0-9]+$ ]] && [[ "$HOP_END" =~ ^[0-9]+$ ]] || { echo "端口必须是数字"; exit 1; }
    [ "$HOP_START" -lt "$HOP_END" ] || { echo "结束端口必须大于起始端口"; exit 1; }
    HOP_IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    HOP_IFACE="${HOP_IFACE:-eth0}"
    HOP=1
  fi

  save_meta
  write_config
  write_clients
  apply_hop
  restart_svc
  sleep 1
  systemctl --no-pager --full status hysteria.service || true
  echo
  show_info
}

uninstall_hysteria() {
  systemctl disable --now hysteria.service 2>/dev/null || true
  systemctl disable --now ipppp.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria.service /etc/systemd/system/ipppp.service
  systemctl daemon-reload
  rm -rf "$BASE" /etc/hysteria/cert.crt /etc/hysteria/private.key
  echo "已卸载服务、配置、链接和二维码。软件包和当前 iptables 规则还在。"
}

get_local_ver() {
  if [ -x "$BIN" ]; then
    "$BIN" version 2>/dev/null | grep -i '^Version' | grep -o 'v[0-9][0-9.]*' | head -1
  fi
}

get_latest_ver() {
  local v
  v="$(curl -fsSL --max-time 10 "https://api.hy2.io/v1/update?cver=installscript&plat=linux&arch=${arch}&chan=release&side=server" 2>/dev/null \
      | grep -oE '"lver":[[:space:]]*"v[0-9][0-9.]*"' | grep -oE 'v[0-9][0-9.]*' | head -1 || true)"
  if [ -z "$v" ]; then
    v="$(curl -fsSL --max-time 10 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null \
        | grep -oE '"tag_name":[[:space:]]*"app/v[0-9][0-9.]*"' | grep -oE 'v[0-9][0-9.]*' | head -1 || true)"
  fi
  echo "$v"
}

update_bin() {
  load_meta
  local cur latest ans
  cur="$(get_local_ver)"
  latest="$(get_latest_ver)"
  echo "当前版本: ${cur:-未知}"
  echo "最新版本: ${latest:-获取失败}"

  if [ -z "$latest" ]; then
    read -r -p "没有取到最新版本，仍然下载最新内核? [y/N]: " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; return; }
  elif [ "$cur" = "$latest" ]; then
    read -r -p "已经是最新版本，是否重新下载覆盖? [y/N]: " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; return; }
  else
    read -r -p "发现新版本 ${cur:-未知} -> ${latest}，是否更新? [Y/n]: " ans
    if [ "$ans" = "n" ] || [ "$ans" = "N" ]; then
      echo "已取消"
      return
    fi
  fi

  local tmp="${BIN}.new"
  wget -O "$tmp" "https://download.hysteria.network/app/latest/hysteria-linux-$arch" || {
    rm -f "$tmp"
    echo "下载失败，保持原版本"
    return 1
  }
  chmod +x "$tmp"
  if ! "$tmp" version >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "新内核无法运行，保持原版本"
    return 1
  fi

  cp -f "$BIN" "${BIN}.bak" 2>/dev/null || true
  systemctl stop hysteria.service || true
  mv -f "$tmp" "$BIN"
  restart_svc
  sleep 1

  if systemctl is-active --quiet hysteria.service; then
    echo "更新完成，当前版本: $(get_local_ver)"
  else
    echo "新内核启动失败，正在回滚"
    mv -f "${BIN}.bak" "$BIN"
    restart_svc
    return 1
  fi
}

service_op() {
  load_meta
  echo "1 启动  2 关闭  3 重启"
  read -r -p "选择: " op
  case "$op" in
    1) systemctl start hysteria.service ;;
    2) systemctl stop hysteria.service ;;
    3) systemctl restart hysteria.service ;;
    *) echo "无效选项"; exit 1 ;;
  esac
  systemctl --no-pager --full status hysteria.service || true
}

show_status() {
  systemctl --no-pager --full status hysteria.service || true
  echo
  journalctl -u hysteria.service -n 40 --no-pager || true
}

change_port() {
  load_meta
  read -r -p "新端口: " PORT
  [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "端口必须是数字"; exit 1; }
  save_meta
  write_config
  write_clients
  apply_hop
  restart_svc
  show_info
}

change_bw() {
  load_meta
  read -r -p "上行 Mbps [$UP]: " up
  read -r -p "下行 Mbps [$DOWN]: " down
  UP="${up:-$UP}"
  DOWN="${down:-$DOWN}"
  save_meta
  write_config
  restart_svc
  echo "带宽已改为 上 ${UP} / 下 ${DOWN} Mbps"
}
change_hop() {
  load_meta
  local old_hop="${HOP:-0}" old_start="${HOP_START:-}" old_end="${HOP_END:-}" old_iface="${HOP_IFACE:-}" old_port="$PORT"
  if [ "$old_hop" = "1" ]; then
    echo "当前端口跳跃: 已开启 ${old_start}-${old_end}"
  else
    echo "当前端口跳跃: 未开启"
  fi
  echo "1 开启或修改"
  echo "2 关闭"
  read -r -p "选择 [回车取消]: " op

  case "$op" in
    1)
      read -r -p "起始端口 [20000]: " HOP_START
      HOP_START="${HOP_START:-20000}"
      read -r -p "结束端口 [30000]: " HOP_END
      HOP_END="${HOP_END:-30000}"
      [[ "$HOP_START" =~ ^[0-9]+$ ]] && [[ "$HOP_END" =~ ^[0-9]+$ ]] || { echo "端口必须是数字"; exit 1; }
      [ "$HOP_START" -lt "$HOP_END" ] || { echo "结束端口必须大于起始端口"; exit 1; }
      HOP_IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
      HOP_IFACE="${HOP_IFACE:-eth0}"
      HOP=1
      ;;
    2)
      HOP=0
      HOP_START=""
      HOP_END=""
      HOP_IFACE=""
      ;;
    *)
      echo "已取消"
      exit 0
      ;;
  esac

  if [ "$old_hop" = "1" ]; then
    iptables -t nat -D PREROUTING -i "$old_iface" -p udp --dport "${old_start}:${old_end}" -j DNAT --to-destination ":${old_port}" 2>/dev/null || true
  fi

  save_meta
  write_clients
  apply_hop
  restart_svc
  sleep 1
  systemctl is-active --quiet hysteria.service && echo "服务已重启" || echo "服务启动失败，请看菜单 7 的日志"
  show_info
}

reset_pass() {
  load_meta
  AUTH="$(randpw)"
  if [ "${OBFS_ENABLED:-0}" = "1" ]; then
    OBFS="$(randpw)"
  fi
  save_meta
  write_config
  write_clients
  restart_svc
  show_info
}

switch_obfs() {
  load_meta
  if [ "${OBFS_ENABLED:-0}" = "1" ]; then
    echo "当前 Gecko 混淆: 已开启"
  else
    echo "当前 Gecko 混淆: 已关闭"
  fi
  echo "1 开启或修改 Gecko 混淆"
  echo "2 关闭 Gecko 混淆"
  read -r -p "选择 [回车取消]: " op

  case "$op" in
    1)
      OBFS_ENABLED=1
      read -r -p "Gecko 混淆密码 [回车保留当前/随机]: " in_obfs
      if [ -n "$in_obfs" ]; then
        OBFS="$in_obfs"
      elif [ -z "${OBFS:-}" ]; then
        OBFS="$(randpw)"
      fi
      ;;
    2)
      OBFS_ENABLED=0
      ;;
    *)
      echo "已取消"
      return 0
      ;;
  esac

  save_meta
  write_config
  write_clients
  restart_svc
  sleep 1
  systemctl is-active --quiet hysteria.service && {
    if [ "$OBFS_ENABLED" = "1" ]; then
      echo "混淆已开启"
    else
      echo "混淆已关闭"
    fi
  } || echo "服务启动失败，请看菜单 7 的日志"
  show_info
}
refresh_ip() {
  load_meta
  detect_ip
  save_meta
  write_clients
  show_info
}

refresh_ipv6() {
  load_meta
  local v6
  v6="$(curl -6 -fsSL --max-time 8 https://api64.ipify.org || true)"
  if [ -z "$v6" ]; then
    echo "没有取到 IPv6 地址"
    return 1
  fi
  IP="[$v6]"
  save_meta
  write_clients
  show_info
}

switch_cert() {
  load_meta
  echo "1 自签 www.bing.com"
  echo "2 ACME 域名证书"
  read -r -p "选择: " op
  if [ "$op" = "1" ]; then
    CERT_MODE="self"
    SNI="$SNI_DEFAULT"
    DOMAIN=""
    EMAIL=""
    make_self_cert
  elif [ "$op" = "2" ]; then
    read -r -p "已解析到本机的域名: " DOMAIN
    read -r -p "邮箱: " EMAIL
    [ -n "$DOMAIN" ] && [ -n "$EMAIL" ] || { echo "域名和邮箱不能空"; exit 1; }
    CERT_MODE="acme"
    SNI="$DOMAIN"
    IP="$DOMAIN"
  else
    echo "无效选项"
    exit 1
  fi
  save_meta
  write_config
  write_clients
  restart_svc
  show_info
}
hy2_menu() {
while true; do
  echo
  echo "========== Hysteria2 Gecko =========="
  echo "系统: $OS_TYPE  架构: $arch"
  echo "内核版本: $(get_local_ver 2>/dev/null || true)"
  echo "1  安装"
  echo "2  卸载"
  echo "3  查看链接和二维码"
  echo "4  退出"
  echo "5  更新 Hysteria 内核"
  echo "6  启动 / 关闭 / 重启"
  echo "7  查看状态和日志"
  echo "8  修改端口"
  echo "9  修改带宽"
  echo "10 端口跳跃"
  echo "11 重置认证密码和混淆密码"
  echo "12 重新检测公网 IP"
  echo "13 切换自签 / ACME 证书"
  echo "14 IPV6"
  echo "15 开关 Gecko 混淆"
  read -r -p "选择: " choice || return

  case "$choice" in
    1)  ( install_hysteria ) ;;
    2)  ( uninstall_hysteria ) ;;
    3)  ( show_info ) ;;
    4|0|q|Q) return ;;
    5)  ( update_bin ) ;;
    6)  ( service_op ) ;;
    7)  ( show_status ) ;;
    8)  ( change_port ) ;;
    9)  ( change_bw ) ;;
    10) ( change_hop ) ;;
    11) ( reset_pass ) ;;
    12) ( refresh_ip ) ;;
    13) ( switch_cert ) ;;
    14) ( refresh_ipv6 ) ;;
    15) ( switch_obfs ) ;;
    *)  echo "无效选项" ;;
  esac

  echo
  read -r -p "按回车返回菜单..." _ || return
done
}

# mieru 使用官方 mita 软件包和独立配置，不覆盖已有的 mita 安装。
mieru_normalize_address() {
  python3 - "$1" <<'PY'
import ipaddress, re, sys
value = sys.argv[1].strip()
try:
    if not value or '%' in value:
        raise ValueError('地址为空或包含 IPv6 区域标识')
    if value.startswith('[') or value.endswith(']'):
        if not (value.startswith('[') and value.endswith(']')):
            raise ValueError('IPv6 方括号不匹配')
        address = ipaddress.IPv6Address(value[1:-1])
    else:
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            if ':' in value or re.fullmatch(r'[0-9.]+', value):
                raise ValueError('无效的 IP 地址')
            name = value.encode('idna').decode('ascii').rstrip('.')
            labels = name.split('.')
            if len(name) > 253 or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in labels):
                raise ValueError('无效的域名')
            address = name
    print(address)
except (ValueError, UnicodeError) as e:
    print('服务器地址无效：%s' % e, file=sys.stderr)
    sys.exit(1)
PY
}

mieru_detect_address() {
  local version="$1" address normalized
  if [ "$version" = 6 ]; then
    address="$(curl -6 -fsSL --max-time 8 https://api64.ipify.org)" || { echo "无法检测公网 IPv6" >&2; return 1; }
  else
    address="$(curl -4 -fsSL --max-time 8 https://api.ipify.org)" || { echo "无法检测公网 IPv4" >&2; return 1; }
  fi
  normalized="$(mieru_normalize_address "$address")" || return 1
  if ! python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == int(sys.argv[2]) else 1)' "$normalized" "$version"; then
    echo "检测结果不是有效的 IPv${version} 地址" >&2
    return 1
  fi
  echo "$normalized"
}

mieru_package() {
  local tmp url asset sha_url pkg sum
  tmp="$(mktemp -d)" || return 1
  if ! curl -fsSL --max-time 30 https://api.github.com/repos/enfein/mieru/releases/latest -o "$tmp/release.json"; then
    echo "无法获取 mieru 最新版本"
    rm -rf "$tmp"; return 1
  fi
  asset="$(python3 - "$tmp/release.json" "$OS_TYPE" "$arch" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    release = json.load(f)
tag = release.get('tag_name', '')
if not re.fullmatch(r'v[0-9]+(?:\.[0-9]+)+', tag):
    sys.exit(1)
v = tag[1:]
if sys.argv[2] in ('debian', 'ubuntu'):
    name = f'mita_{v}_{sys.argv[3]}.deb'
else:
    arch = {'amd64': 'x86_64', 'arm64': 'aarch64'}[sys.argv[3]]
    name = f'mita-{v}-1.{arch}.rpm'
assets = {a['name']: a['browser_download_url'] for a in release['assets']}
if name not in assets or name + '.sha256.txt' not in assets:
    sys.exit(1)
print(name)
PY
  )" || { echo "没有适合本系统的软件包"; rm -rf "$tmp"; return 1; }
  url="$(python3 -c 'import json,sys; print(next(a["browser_download_url"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"]==sys.argv[2]))' "$tmp/release.json" "$asset")"
  sha_url="${url}.sha256.txt"
  pkg="$tmp/$asset"
  if ! curl -fL --retry 2 "$url" -o "$pkg" || ! curl -fsSL "$sha_url" -o "$tmp/checksum"; then
    echo "下载 mita 或校验文件失败"; rm -rf "$tmp"; return 1
  fi
  sum="$(awk '{print $1}' "$tmp/checksum" | head -1)"
  if ! [[ "$sum" =~ ^[a-fA-F0-9]{64}$ ]] || ! (cd "$tmp" && echo "$sum  $asset" | sha256sum -c -); then
    echo "mita 校验失败"; rm -rf "$tmp"; return 1
  fi
  case "$OS_TYPE" in
    debian|ubuntu) dpkg -i "$pkg" ;;
    *) rpm -Uvh "$pkg" ;;
  esac
  local result=$?
  rm -rf "$tmp"
  return "$result"
}

mieru_random_range() {
  local protocol="$1" start range i
  for ((i=0; i<100; i++)); do
    start=$((RANDOM % 50000 + 10000))
    range="${start}-$((start + 9))"
    if mieru_check_port "$range" "" "$protocol" >/dev/null; then
      echo "$range"; return
    fi
  done
  echo "无法找到空闲的 $protocol 端口范围" >&2
  return 1
}

mieru_write_clients() {
  python3 - "$MIERU_BASE" "$IP" "$TCP_PORT" "$UDP_PORT" "$TCP_USER" "$TCP_PASS" "$UDP_USER" "$UDP_PASS" <<'PY'
import json, os, sys, urllib.parse
base, address, tcp_port, udp_port, tcp_user, tcp_pass, udp_user, udp_pass = sys.argv[1:]
server = address.strip('[]')
authority = '[' + server + ']' if ':' in server else server
nodes = []
for name, protocol, port, user, password in (
        ('mt-hc', 'TCP', tcp_port, tcp_user, tcp_pass),
        ('mu-hc', 'UDP', udp_port, udp_user, udp_pass)):
    if not port:
        continue
    node = {'name': name, 'type': 'mieru', 'transport': protocol,
            'server': server, 'username': user, 'password': password}
    node['port-range' if '-' in port else 'port'] = port if '-' in port else int(port)
    nodes.append(node)
    query = urllib.parse.urlencode({'profile': name, 'port': port, 'protocol': protocol})
    link = 'mierus://{}:{}@{}?{}'.format(urllib.parse.quote(user, safe=''),
        urllib.parse.quote(password, safe=''), authority, query)
    with open(os.path.join(base, protocol.lower() + '.txt'), 'w', encoding='utf-8') as f:
        f.write(link + '\n')
with open(os.path.join(base, 'clash-mate.yaml'), 'w', encoding='utf-8') as f:
    f.write('proxies:\n' + ''.join('  - ' + json.dumps(node, ensure_ascii=False) + '\n' for node in nodes))
PY
  [ $? -eq 0 ] || return 1
  if [ -n "$TCP_PORT" ]; then qrencode -o "$MIERU_BASE/tcp.png" < "$MIERU_BASE/tcp.txt" || return 1; fi
  if [ -n "$UDP_PORT" ]; then qrencode -o "$MIERU_BASE/udp.png" < "$MIERU_BASE/udp.txt" || return 1; fi
}

show_mieru() {
  [ -f "$MIERU_BASE/clash-mate.yaml" ] || { echo "还没有安装 mieru"; return 1; }
  echo "Clash 配置:"
  cat "$MIERU_BASE/clash-mate.yaml"
  local protocol
  for protocol in tcp udp; do
    [ -f "$MIERU_BASE/$protocol.txt" ] || continue
    echo
    echo "${protocol^^} 分享链接 (mierus):"
    cat "$MIERU_BASE/$protocol.txt"
    qrencode -t ANSIUTF8 < "$MIERU_BASE/$protocol.txt" || true
    echo "二维码图片: $MIERU_BASE/$protocol.png"
  done
  echo "配置文件: $MIERU_BASE/clash-mate.yaml"
  if [ -f "$MIERU_BASE/tcp.txt" ] && [ -f "$MIERU_BASE/udp.txt" ]; then
    echo "提示: mita 账户不按传输方式隔离，两个账户均可使用 TCP 和 UDP 监听端口。"
  fi
  echo "提示: mierus 链接为官方简单分享格式，客户端需支持该格式。"
}

install_mieru() {
  if [ -e "$MIERU_BASE" ] || [ -e /etc/mita ] || [ -e /var/lib/mita ] || command -v mita >/dev/null 2>&1 || systemctl cat mita.service >/dev/null 2>&1; then
    echo "检测到已有 mita 或脚本配置，为避免覆盖请先自行备份并处理。"
    return 1
  fi
  need_pkgs || return 1
  detect_ip
  local in_ip mode port TCP_PORT="" UDP_PORT="" TCP_USER="" UDP_USER="" TCP_PASS="" UDP_PASS=""
  read -r -p "服务器地址 [自动检测: $IP；输入 6 自动检测 IPv6]: " in_ip || return 1
  if [ "$in_ip" = 6 ]; then
    IP="$(mieru_detect_address 6)" || return 1
  elif [ -n "$in_ip" ]; then
    IP="$in_ip"
  fi
  IP="$(mieru_normalize_address "$IP")" || return 1
  echo "传输方式: 1 仅 TCP  2 仅 UDP  3 TCP + UDP"
  read -r -p "选择 [3]: " mode || return 1
  mode="${mode:-3}"
  [[ "$mode" = 1 || "$mode" = 2 || "$mode" = 3 ]] || { echo "无效选项"; return 1; }
  echo "默认使用随机的 10 个连续端口；也可输入单个端口或范围，如 30001-31200。"
  if [[ "$mode" = 1 || "$mode" = 3 ]]; then
    TCP_PORT="$(mieru_random_range TCP)" || return 1
    read -r -p "TCP 端口或范围 [$TCP_PORT]: " port || return 1
    TCP_PORT="$(mieru_normalize_port "${port:-$TCP_PORT}")" || return 1
    mieru_check_port "$TCP_PORT" "" TCP || return 1
    TCP_USER="tcp_$(openssl rand -hex 4)"; TCP_PASS="$(randpw)"
    [ -n "$TCP_USER" ] && [ -n "$TCP_PASS" ] || return 1
  fi
  if [[ "$mode" = 2 || "$mode" = 3 ]]; then
    UDP_PORT="$(mieru_random_range UDP)" || return 1
    read -r -p "UDP 端口或范围 [$UDP_PORT]: " port || return 1
    UDP_PORT="$(mieru_normalize_port "${port:-$UDP_PORT}")" || return 1
    mieru_check_port "$UDP_PORT" "" UDP || return 1
    UDP_USER="udp_$(openssl rand -hex 4)"; UDP_PASS="$(randpw)"
    [ -n "$UDP_USER" ] && [ -n "$UDP_PASS" ] || return 1
  fi
  umask 077
  mkdir -p "$MIERU_BASE" || return 1
  python3 - "$MIERU_BASE/server.json" "$TCP_PORT" "$UDP_PORT" "$TCP_USER" "$TCP_PASS" "$UDP_USER" "$UDP_PASS" <<'PY'
import json, sys
path, tcp_port, udp_port, tcp_user, tcp_pass, udp_user, udp_pass = sys.argv[1:]
config = {'portBindings': [], 'users': [], 'loggingLevel': 'INFO'}
for protocol, port, user, password in (('TCP', tcp_port, tcp_user, tcp_pass), ('UDP', udp_port, udp_user, udp_pass)):
    if port:
        binding = {'protocol': protocol}
        binding['portRange' if '-' in port else 'port'] = port if '-' in port else int(port)
        config['portBindings'].append(binding)
        config['users'].append({'name': user, 'password': password})
with open(path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2)
PY
  [ $? -eq 0 ] || { echo "生成服务端配置失败"; return 1; }
  mieru_write_clients || { echo "生成客户端配置失败"; return 1; }
  if ! mieru_package; then
    echo "安装失败，配置保留在 $MIERU_BASE，请检查后通过菜单卸载清理。"
    return 1
  fi
  if ! systemctl enable --now mita.service || ! mita replace config "$MIERU_BASE/server.json" || ! mita start; then
    echo "mita 配置或启动失败，请查看状态日志；配置保留在 $MIERU_BASE。"
    return 1
  fi
  if ! mita status | grep -q 'RUNNING'; then
    echo "mita 未处于 RUNNING 状态，请查看状态日志。"
    return 1
  fi
  show_mieru
  [ -z "$TCP_PORT" ] || echo "请放行 TCP $TCP_PORT。"
  [ -z "$UDP_PORT" ] || echo "请放行 UDP $UDP_PORT。"
  echo "请在防火墙及云安全组放行整个范围，并确保客户端和服务器时间同步。"
  echo "使用 IPv6 时还需确认服务器公网 IPv6 可达且服务支持 IPv6 监听。"
  echo "Mieru 在新建连接时选择端口，不会在连接中周期性跳端口。"
}

uninstall_mieru() {
  [ -f "$MIERU_BASE/server.json" ] || { echo "未发现本脚本安装的 mieru，不会卸载系统中的 mita。"; return 1; }
  local answer
  read -r -p "确认卸载本脚本安装的 mita 并删除其全部配置? [y/N]: " answer || return
  [[ "$answer" = [yY] ]] || { echo "已取消"; return; }
  systemctl disable --now mita.service 2>/dev/null || true
  if command -v mita >/dev/null 2>&1; then
    case "$OS_TYPE" in
      debian|ubuntu) dpkg -P mita || return 1 ;;
      *) rpm -e mita || return 1 ;;
    esac
  fi
  rm -rf "$MIERU_BASE" /etc/mita /var/lib/mita
  echo "mieru 已卸载；防火墙规则未更改。"
}

# 以客户端节点里的用户名对应服务端用户，不依赖用户数组的排列顺序。
mieru_load_edit_data() {
  local data_file="$1"
  python3 - "$MIERU_BASE/server.json" "$MIERU_BASE/clash-mate.yaml" > "$data_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        config = json.load(f)
    with open(sys.argv[2], encoding='utf-8') as f:
        lines = f.read().splitlines()
    nodes = [json.loads(line.strip()[2:]) for line in lines if line.strip().startswith('- ')]
    selected = {}
    for node in nodes:
        if node.get('type') != 'mieru' or node.get('transport') not in ('TCP', 'UDP') or node['transport'] in selected:
            raise ValueError('节点类型或传输方式不正确')
        selected[node['transport']] = node
    if not selected:
        raise ValueError('没有 mieru 节点')
    if len({node['server'] for node in selected.values()}) != 1 or len({node['username'] for node in selected.values()}) != len(selected):
        raise ValueError('节点地址或用户名不匹配')
    for node in selected.values():
        key = 'portRange' if 'port-range' in node else 'port'
        port = node.get('port-range', node.get('port'))
        bindings = [b for b in config['portBindings'] if b.get('protocol') == node['transport'] and b.get(key) == port]
        users = [u for u in config['users'] if u.get('name') == node['username'] and u.get('password') == node['password']]
        if port is None or len(bindings) != 1 or len(users) != 1:
            raise ValueError('服务端配置与客户端节点不一致')
    tcp, udp = selected.get('TCP', {}), selected.get('UDP', {})
    port = lambda n: n.get('port-range', n.get('port', ''))
    values = [next(iter(selected.values()))['server'], port(tcp), port(udp), tcp.get('username', ''), tcp.get('password', ''), udp.get('username', ''), udp.get('password', '')]
    for value in values:
        text = str(value)
        if '\x00' in text:
            raise ValueError('配置包含非法字符')
        sys.stdout.buffer.write(text.encode('utf-8') + b'\0')
except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
    print('读取 mieru 配置失败：%s' % e, file=sys.stderr)
    sys.exit(1)
PY
}

mieru_normalize_port() {
  local value="$1" start end
  if [[ "$value" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]]; then
    start=$((10#${BASH_REMATCH[1]}))
    end=$((10#${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}))
    if (( start >= 1025 && end <= 65535 && start <= end )); then
      if (( start == end )); then echo "$start"; else echo "$start-$end"; fi
      return 0
    fi
  fi
  echo "端口或范围必须在 1025-65535 之间，如 20000-20009" >&2
  return 1
}

mieru_check_port() {
  local port="$1" old="$2" protocol="$3" sockets start end old_start=0 old_end=0 conflict
  port="$(mieru_normalize_port "$port")" || return 1
  start="${port%-*}"; end="${port#*-}"
  if [ -n "$old" ]; then
    old="$(mieru_normalize_port "$old")" || return 1
    old_start="${old%-*}"; old_end="${old#*-}"
  fi
  [ "$port" = "$old" ] && return 0
  if [ "$protocol" = TCP ]; then
    sockets="$(ss -lnt)" || { echo "无法检查 TCP 端口"; return 1; }
  else
    sockets="$(ss -lnu)" || { echo "无法检查 UDP 端口"; return 1; }
  fi
  conflict="$(printf '%s\n' "$sockets" | awk -v a="$start" -v b="$end" -v x="$old_start" -v y="$old_end" 'NR>1 {n=split($4,p,":"); v=p[n]; if (v ~ /^[0-9]+$/ && v>=a && v<=b && (v<x || v>y)) {print v; exit}}')"
  if [ -n "$conflict" ]; then
    echo "$protocol 端口 $conflict 已被占用"
    return 1
  fi
}

# 失败时尽量恢复旧配置；备份留在临时目录供人工恢复。
mieru_rollback() {
  local backup="$1" was_running="$2"
  local ok=1 file
  mita stop >/dev/null 2>&1 || true
  mita replace config "$backup/server.json" || ok=0
  if [ "$was_running" = 1 ]; then
    mita start && mita status | grep -q RUNNING || ok=0
  fi
  for file in server.json clash-mate.yaml tcp.txt udp.txt tcp.png udp.png; do
    if [ -f "$backup/$file" ]; then
      cp -p "$backup/$file" "$MIERU_BASE/$file" || ok=0
    else
      rm -f "$MIERU_BASE/$file" || ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "已恢复旧配置和原服务状态。"
    return 0
  fi
  echo "自动回滚未完全成功，旧配置备份保留在 $backup，请检查 mita 状态和日志。"
  return 1
}

change_mieru() {
  local kind="$1" temp backup stage status was_running=0 file answer in_tcp in_udp mode
  local IP TCP_PORT UDP_PORT TCP_USER TCP_PASS UDP_USER UDP_PASS
  local old_tcp old_udp old_tcp_user old_tcp_pass old_udp_user old_udp_pass
  local -a data
  [ -f "$MIERU_BASE/server.json" ] && [ -f "$MIERU_BASE/clash-mate.yaml" ] || { echo "还没有安装 mieru"; return 1; }
  umask 077
  temp="$(mktemp -d "$MIERU_BASE/.edit.XXXXXXXX")" || return 1
  backup="$temp/backup"; stage="$temp/stage"
  mkdir "$backup" "$stage" || { rm -rf "$temp"; return 1; }
  if ! mieru_load_edit_data "$temp/data"; then rm -rf "$temp"; return 1; fi
  mapfile -d '' -t data < "$temp/data"
  if [ "${#data[@]}" -ne 7 ]; then echo "配置数据不完整"; rm -rf "$temp"; return 1; fi
  IP="${data[0]}"; TCP_PORT="${data[1]}"; UDP_PORT="${data[2]}"
  TCP_USER="${data[3]}"; TCP_PASS="${data[4]}"; UDP_USER="${data[5]}"; UDP_PASS="${data[6]}"
  old_tcp="$TCP_PORT"; old_udp="$UDP_PORT"
  old_tcp_user="$TCP_USER"; old_tcp_pass="$TCP_PASS"; old_udp_user="$UDP_USER"; old_udp_pass="$UDP_PASS"

  if [ "$kind" = mode ]; then
    echo "1 仅 TCP  2 仅 UDP  3 TCP + UDP"
    read -r -p "选择传输方式 [回车取消]: " mode || { rm -rf "$temp"; return 1; }
    case "$mode" in
      1) UDP_PORT=""; UDP_USER=""; UDP_PASS="" ;;
      2) TCP_PORT=""; TCP_USER=""; TCP_PASS="" ;;
      3) ;;
      *) echo "已取消"; rm -rf "$temp"; return 0 ;;
    esac
    if [[ "$mode" = 1 || "$mode" = 3 ]] && [ -z "$TCP_PORT" ]; then
      TCP_PORT="$(mieru_random_range TCP)" || { rm -rf "$temp"; return 1; }
      read -r -p "TCP 端口或范围 [$TCP_PORT]: " in_tcp || { rm -rf "$temp"; return 1; }
      TCP_PORT="$(mieru_normalize_port "${in_tcp:-$TCP_PORT}")" || { rm -rf "$temp"; return 1; }
      mieru_check_port "$TCP_PORT" "" TCP || { rm -rf "$temp"; return 1; }
      TCP_USER="tcp_$(openssl rand -hex 4)"; TCP_PASS="$(randpw)"
      [ -n "$TCP_PASS" ] || { rm -rf "$temp"; return 1; }
    fi
    if [[ "$mode" = 2 || "$mode" = 3 ]] && [ -z "$UDP_PORT" ]; then
      UDP_PORT="$(mieru_random_range UDP)" || { rm -rf "$temp"; return 1; }
      read -r -p "UDP 端口或范围 [$UDP_PORT]: " in_udp || { rm -rf "$temp"; return 1; }
      UDP_PORT="$(mieru_normalize_port "${in_udp:-$UDP_PORT}")" || { rm -rf "$temp"; return 1; }
      mieru_check_port "$UDP_PORT" "" UDP || { rm -rf "$temp"; return 1; }
      UDP_USER="udp_$(openssl rand -hex 4)"; UDP_PASS="$(randpw)"
      [ -n "$UDP_PASS" ] || { rm -rf "$temp"; return 1; }
    fi
  elif [ "$kind" = port ]; then
    if [ -n "$TCP_PORT" ]; then
      read -r -p "TCP 端口或范围 [$TCP_PORT，回车不变]: " in_tcp || { rm -rf "$temp"; return 1; }
      TCP_PORT="$(mieru_normalize_port "${in_tcp:-$TCP_PORT}")" || { rm -rf "$temp"; return 1; }
      mieru_check_port "$TCP_PORT" "$old_tcp" TCP || { rm -rf "$temp"; return 1; }
    fi
    if [ -n "$UDP_PORT" ]; then
      read -r -p "UDP 端口或范围 [$UDP_PORT，回车不变]: " in_udp || { rm -rf "$temp"; return 1; }
      UDP_PORT="$(mieru_normalize_port "${in_udp:-$UDP_PORT}")" || { rm -rf "$temp"; return 1; }
      mieru_check_port "$UDP_PORT" "$old_udp" UDP || { rm -rf "$temp"; return 1; }
    fi
  else
    if [ -n "$TCP_PORT" ]; then
      read -r -p "TCP 用户名 [$TCP_USER，回车不变]: " in_tcp || { rm -rf "$temp"; return 1; }
      TCP_USER="${in_tcp:-$TCP_USER}"
      read -r -p "TCP 密码 [回车不变]: " in_tcp || { rm -rf "$temp"; return 1; }
      TCP_PASS="${in_tcp:-$TCP_PASS}"
    fi
    if [ -n "$UDP_PORT" ]; then
      read -r -p "UDP 用户名 [$UDP_USER，回车不变]: " in_udp || { rm -rf "$temp"; return 1; }
      UDP_USER="${in_udp:-$UDP_USER}"
      read -r -p "UDP 密码 [回车不变]: " in_udp || { rm -rf "$temp"; return 1; }
      UDP_PASS="${in_udp:-$UDP_PASS}"
    fi
    if [ -n "$TCP_USER" ] && [ "$TCP_USER" = "$UDP_USER" ]; then
      echo "TCP 和 UDP 用户名不能相同"; rm -rf "$temp"; return 1
    fi
  fi
  if [ "$TCP_PORT" = "$old_tcp" ] && [ "$UDP_PORT" = "$old_udp" ] && [ "$TCP_USER" = "$old_tcp_user" ] && [ "$UDP_USER" = "$old_udp_user" ] && [ "$TCP_PASS" = "$old_tcp_pass" ] && [ "$UDP_PASS" = "$old_udp_pass" ]; then
    echo "没有修改"; rm -rf "$temp"; return 0
  fi
  echo "将以 $MIERU_BASE/server.json 为准替换 mita 配置；如果曾手动修改 mita，请先备份。"
  read -r -p "确认应用并短暂中断连接? [y/N]: " answer || { rm -rf "$temp"; return 1; }
  if [[ ! "$answer" = [yY] ]]; then echo "已取消"; rm -rf "$temp"; return 0; fi

  for file in server.json clash-mate.yaml; do
    cp -p "$MIERU_BASE/$file" "$backup/$file" || { echo "备份失败"; rm -rf "$temp"; return 1; }
  done
  for file in tcp.txt tcp.png udp.txt udp.png; do
    if [ -f "$MIERU_BASE/$file" ]; then
      cp -p "$MIERU_BASE/$file" "$backup/$file" || { echo "备份失败"; rm -rf "$temp"; return 1; }
    fi
  done
  if ! python3 - "$backup/server.json" "$stage/server.json" "$old_tcp_user" "$old_udp_user" "$TCP_PORT" "$UDP_PORT" "$TCP_USER" "$TCP_PASS" "$UDP_USER" "$UDP_PASS" <<'PY'
import json, sys
src, dst, old_tcp, old_udp, tcp_port, udp_port, tcp_user, tcp_pass, udp_user, udp_pass = sys.argv[1:]
with open(src, encoding='utf-8') as f:
    config = json.load(f)
# The old ports are taken from the saved client nodes rather than inferred by protocol.
with open(src.replace('server.json', 'clash-mate.yaml'), encoding='utf-8') as f:
    nodes = [json.loads(line.strip()[2:]) for line in f if line.strip().startswith('- ')]
for protocol, new_port, old_user, new_user, new_pass in (
        ('TCP', tcp_port, old_tcp, tcp_user, tcp_pass), ('UDP', udp_port, old_udp, udp_user, udp_pass)):
    matches = [n for n in nodes if n.get('type') == 'mieru' and n.get('transport') == protocol]
    if matches:
        node, = matches
        old_key = 'portRange' if 'port-range' in node else 'port'
        old_port = node.get('port-range', node.get('port'))
        binding, = [b for b in config['portBindings'] if b.get('protocol') == protocol and b.get(old_key) == old_port]
        user, = [u for u in config['users'] if u.get('name') == old_user]
        if not new_port:
            config['portBindings'].remove(binding)
            config['users'].remove(user)
            continue
        binding.pop('port', None)
        binding.pop('portRange', None)
        user['name'], user['password'] = new_user, new_pass
    elif new_port:
        binding = {'protocol': protocol}
        config['portBindings'].append(binding)
        config['users'].append({'name': new_user, 'password': new_pass})
    else:
        continue
    binding['portRange' if '-' in new_port else 'port'] = new_port if '-' in new_port else int(new_port)
names = [user.get('name') for user in config['users']]
if len(names) != len(set(names)):
    raise ValueError('用户名与已有用户重复')
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
PY
  then echo "生成服务端配置失败"; rm -rf "$temp"; return 1; fi
  if ! ( MIERU_BASE="$stage"; mieru_write_clients ); then
    echo "生成客户端配置或二维码失败"; rm -rf "$temp"; return 1
  fi
  status="$(mita status)" || { echo "无法读取 mita 状态"; rm -rf "$temp"; return 1; }
  if [[ "$status" == *RUNNING* ]]; then
    was_running=1
  elif [[ "$status" != *IDLE* ]]; then
    echo "无法识别 mita 状态，未修改配置: $status"; rm -rf "$temp"; return 1
  fi
  if { [ "$was_running" = 0 ] || mita stop; } && mita replace config "$stage/server.json" &&
     { [ "$was_running" = 0 ] || { mita start && mita status | grep -q RUNNING; }; }; then
    for file in server.json clash-mate.yaml tcp.txt udp.txt tcp.png udp.png; do
      if [ ! -f "$stage/$file" ]; then
        if rm -f "$MIERU_BASE/$file"; then continue; fi
      elif cp -p "$stage/$file" "$MIERU_BASE/$file"; then
        continue
      fi
      {

        echo "保存新配置失败，正在回滚。"
        mieru_rollback "$backup" "$was_running" && rm -rf "$temp"
        return 1
      }
    done
  else
    echo "应用新配置失败，正在回滚。"
    mieru_rollback "$backup" "$was_running" && rm -rf "$temp"
    return 1
  fi
  rm -rf "$temp"
  show_mieru
  if [ "$kind" = port ] || [ "$kind" = mode ]; then
    [ -z "$TCP_PORT" ] || echo "请放行 TCP $TCP_PORT。"
    [ -z "$UDP_PORT" ] || echo "请放行 UDP $UDP_PORT。"
    echo "请在防火墙和云安全组放行整个范围。"
  fi
  echo "旧客户端需更新配置；Mieru 在新建连接时选择端口。"
}

change_mieru_address() {
  local IP TCP_PORT UDP_PORT TCP_USER TCP_PASS UDP_USER UDP_PASS
  local temp stage backup choice address old_ip file restore_ok
  local -a data files
  [ -f "$MIERU_BASE/server.json" ] && [ -f "$MIERU_BASE/clash-mate.yaml" ] || { echo "还没有安装 mieru"; return 1; }
  umask 077
  temp="$(mktemp -d "$MIERU_BASE/.address.XXXXXXXX")" || return 1
  stage="$temp/stage"; backup="$temp/backup"
  mkdir "$stage" "$backup" || { rm -rf "$temp"; return 1; }
  if ! mieru_load_edit_data "$temp/data"; then rm -rf "$temp"; return 1; fi
  mapfile -d '' -t data < "$temp/data"
  if [ "${#data[@]}" -ne 7 ]; then echo "配置数据不完整"; rm -rf "$temp"; return 1; fi
  old_ip="${data[0]}"; TCP_PORT="${data[1]}"; UDP_PORT="${data[2]}"
  TCP_USER="${data[3]}"; TCP_PASS="${data[4]}"; UDP_USER="${data[5]}"; UDP_PASS="${data[6]}"
  echo "当前节点地址: $old_ip"
  echo "1 自动检测公网 IPv6  2 自动检测公网 IPv4  3 手动输入地址或域名"
  read -r -p "选择 [回车取消]: " choice || { rm -rf "$temp"; return 1; }
  case "$choice" in
    1) address="$(mieru_detect_address 6)" || { rm -rf "$temp"; return 1; } ;;
    2) address="$(mieru_detect_address 4)" || { rm -rf "$temp"; return 1; } ;;
    3) read -r -p "服务器 IPv4 / IPv6 地址或域名: " address || { rm -rf "$temp"; return 1; } ;;
    *) echo "已取消"; rm -rf "$temp"; return 0 ;;
  esac
  IP="$(mieru_normalize_address "$address")" || { rm -rf "$temp"; return 1; }
  if [ "$IP" = "$old_ip" ]; then echo "地址没有变化"; rm -rf "$temp"; return 0; fi
  echo "新节点地址: $IP"
  read -r -p "确认更新客户端配置、链接和二维码? [y/N]: " choice || { rm -rf "$temp"; return 1; }
  if [[ ! "$choice" = [yY] ]]; then echo "已取消"; rm -rf "$temp"; return 0; fi
  files=(clash-mate.yaml)
  [ -z "$TCP_PORT" ] || files+=(tcp.txt tcp.png)
  [ -z "$UDP_PORT" ] || files+=(udp.txt udp.png)
  for file in "${files[@]}"; do
    cp -p "$MIERU_BASE/$file" "$backup/$file" || { echo "备份客户端配置失败"; rm -rf "$temp"; return 1; }
  done
  if ! ( MIERU_BASE="$stage"; mieru_write_clients ); then
    echo "生成客户端配置或二维码失败"; rm -rf "$temp"; return 1
  fi
  for file in "${files[@]}"; do
    if ! cp -p "$stage/$file" "$MIERU_BASE/$file"; then
      echo "保存失败，正在恢复旧客户端配置。"
      restore_ok=1
      for file in "${files[@]}"; do cp -p "$backup/$file" "$MIERU_BASE/$file" || restore_ok=0; done
      if [ "$restore_ok" = 1 ]; then
        rm -rf "$temp"
      else
        echo "恢复未完全成功，备份保留在 $backup。"
      fi
      return 1
    fi
  done
  rm -rf "$temp"
  show_mieru
  echo "仅更新了节点地址，服务端监听配置未改变。IPv6 需确认公网可达、服务监听及防火墙规则。"
}

mieru_menu() {
  local choice op
  while :; do
    echo
    echo "========== Mieru =========="
    echo "1 安装 Mieru  2 卸载  3 查看配置和二维码  4 返回"
    echo "5 更新 mita  6 启动 / 关闭 / 重启  7 状态和日志"
    echo "8 修改 TCP / UDP 端口或范围  9 修改账号 / 密码  10 切换传输方式"
    echo "11 切换节点地址 IPv4 / IPv6 / 域名"
    read -r -p "选择: " choice || return
    case "$choice" in
      1) ( install_mieru ) ;;
      2) ( uninstall_mieru ) ;;
      3) ( show_mieru ) ;;
      4|0|q|Q) return ;;
      5) ( [ -f "$MIERU_BASE/server.json" ] || { echo "还没有安装"; exit 1; }; mieru_package && systemctl restart mita.service && mita status ) ;;
      6) ( [ -f "$MIERU_BASE/server.json" ] || { echo "还没有安装"; exit 1; }
           echo "1 启动  2 关闭  3 重启"
           read -r -p "选择: " op
           case "$op" in
             1) systemctl start mita.service && mita start ;;
             2) mita stop ;;
             3) mita stop && mita start ;;
             *) echo "无效选项" ;;
           esac ) ;;
      7) ( systemctl --no-pager --full status mita.service || true; mita status || true; journalctl -u mita.service -n 40 --no-pager || true ) ;;
      8) ( change_mieru port ) ;;
      9) ( change_mieru account ) ;;
      10) ( change_mieru mode ) ;;
      11) ( change_mieru_address ) ;;
      *) echo "无效选项" ;;
    esac
    read -r -p "按回车返回菜单..." _ || return
  done
}

while :; do
  echo
  echo "========== 协议菜单 =========="
  echo "1 Hysteria2"
  echo "2 Mieru"
  echo "0 退出"
  read -r -p "选择: " choice || exit 0
  case "$choice" in
    1) hy2_menu ;;
    2) mieru_menu ;;
    0|q|Q) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done

