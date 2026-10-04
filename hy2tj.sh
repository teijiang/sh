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

need_pkgs() {
  case "$OS_TYPE" in
    debian|ubuntu)
      apt-get update
      apt-get install -y wget curl openssl ca-certificates python3 qrencode iptables iproute2
      ;;
    centos|rhel|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y wget curl openssl ca-certificates python3 qrencode iptables iproute
      else
        yum install -y epel-release || true
        yum install -y wget curl openssl ca-certificates python3 qrencode iptables iproute
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
}

save_meta() {
  mkdir -p "$BASE"
  cat > "$META" <<EOF
PORT=${PORT}
AUTH=${AUTH}
OBFS=${OBFS}
UP=${UP}
DOWN=${DOWN}
IP=${IP}
SNI=${SNI}
CERT_MODE=${CERT_MODE}
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
HOP=${HOP:-0}
HOP_START=${HOP_START:-}
HOP_END=${HOP_END:-}
HOP_IFACE=${HOP_IFACE:-}
EOF
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
  local tls_block
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
  cat > "$CFG" <<EOF
listen: :${PORT}

${tls_block}

auth:
  type: password
  password: ${AUTH}

obfs:
  type: gecko
  gecko:
    password: ${OBFS}

ignoreClientBandwidth: false
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
EOF
}

write_clients() {
  local enc_auth enc_obfs extra link bare
  enc_auth="$(urlencode "$AUTH")"
  enc_obfs="$(urlencode "$OBFS")"
  extra=""
  [ "$CERT_MODE" = "self" ] && extra="&insecure=1"
  if [ "${HOP:-0}" = "1" ]; then
    extra="${extra}&mport=${PORT},${HOP_START}-${HOP_END}"
  fi
  link="hysteria2://${enc_auth}@${IP}:${PORT}/?obfs=gecko&obfs-password=${enc_obfs}&sni=${SNI}${extra}#HY2-Gecko"
  echo "$link" > "$BASE/neko.txt"
  qrencode -o "$BASE/hy2.png" "$link"
  bare="${IP//[\[\]]/}"
  cat > "$BASE/clash-mate.yaml" <<EOF
proxies:
  - name: HY2-Gecko
    type: hysteria2
    server: ${bare}
    port: ${PORT}
    password: ${AUTH}
    sni: ${SNI}
    skip-cert-verify: $([ "$CERT_MODE" = "self" ] && echo true || echo false)
    obfs: gecko
    obfs-password: ${OBFS}
EOF
}

restart_svc() {
  write_unit
  systemctl enable hysteria.service
  systemctl restart hysteria.service
}

show_info() {
  load_meta
  echo "地址: $IP"
  echo "端口: $PORT"
  echo "认证密码: $AUTH"
  echo "Gecko 密码: $OBFS"
  echo "证书: $CERT_MODE  SNI: $SNI"
  echo
  echo "节点链接:"
  cat "$BASE/neko.txt"
  echo
  qrencode -t ANSIUTF8 < "$BASE/neko.txt" || true
  echo
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

  local in_port in_auth in_obfs in_up in_down in_sni in_ip in_cert in_hop

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

  read -r -p "Gecko 混淆密码 [回车随机]: " in_obfs
  OBFS="${in_obfs:-$(randpw)}"

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
  OBFS="$(randpw)"
  save_meta
  write_config
  write_clients
  restart_svc
  show_info
}

refresh_ip() {
  load_meta
  detect_ip
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
  echo "11 重置认证密码和 Gecko 密码"
  echo "12 重新检测公网 IP"
  echo "13 切换自签 / ACME 证书"
  read -r -p "选择: " choice

  case "$choice" in
    1)  ( install_hysteria ) ;;
    2)  ( uninstall_hysteria ) ;;
    3)  ( show_info ) ;;
    4|0|q|Q) exit 0 ;;
    5)  ( update_bin ) ;;
    6)  ( service_op ) ;;
    7)  ( show_status ) ;;
    8)  ( change_port ) ;;
    9)  ( change_bw ) ;;
    10) ( change_hop ) ;;
    11) ( reset_pass ) ;;
    12) ( refresh_ip ) ;;
    13) ( switch_cert ) ;;
    *)  echo "无效选项" ;;
  esac

  echo
  read -r -p "按回车返回菜单..." _
done
