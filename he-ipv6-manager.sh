#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM="he-ipv6-manager"
readonly VERSION="1.0.0"
readonly INSTALL_PATH="/usr/local/sbin/${PROGRAM}"
readonly CONFIG_DIR="/etc/${PROGRAM}"
readonly CONFIG_FILE="${CONFIG_DIR}/config.conf"
readonly SERVICE_FILE="/etc/systemd/system/${PROGRAM}.service"

if [[ -t 1 ]]; then
  readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m' BOLD='\033[1m' RESET='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info() { printf '%b[信息]%b %s\n' "$BLUE" "$RESET" "$*"; }
ok() { printf '%b[完成]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$? line_no=$1
  printf '%b[错误]%b 第 %s 行执行失败，退出码：%s\n' "$RED" "$RESET" "$line_no" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "此操作需要 root 权限，请使用 sudo。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

strip_prefix() { printf '%s' "${1%%/*}"; }

valid_ipv4() {
  local ip=$1 part
  local -a parts
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

valid_ipv6() {
  local ip=${1%%/*}
  [[ $ip == *:* && $ip =~ ^[0-9A-Fa-f:]+$ ]]
}

prompt_value() {
  local label=$1 default=${2:-} value
  if [[ -n $default ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    while :; do
      read -r -p "${label}: " value
      [[ -n $value ]] && { printf '%s' "$value"; return; }
      warn "该项不能为空。"
    done
  fi
}

prompt_optional() {
  local label=$1 default=${2:-} value
  if [[ -n $default ]]; then
    read -r -p "${label} [${default}]（输入 - 清空）: " value
    if [[ $value == '-' ]]; then
      printf ''
    else
      printf '%s' "${value:-$default}"
    fi
  else
    read -r -p "${label}（可留空）: " value
    printf '%s' "$value"
  fi
}

prompt_ipv4() {
  local label=$1 default=${2:-} value
  while :; do
    value=$(prompt_value "$label" "$default")
    valid_ipv4 "$value" && { printf '%s' "$value"; return; }
    warn "IPv4 地址格式不正确：$value"
  done
}

prompt_ipv6() {
  local label=$1 default=${2:-} value
  while :; do
    value=$(prompt_value "$label" "$default")
    value=$(strip_prefix "$value")
    valid_ipv6 "$value" && { printf '%s' "$value"; return; }
    warn "IPv6 地址格式不正确：$value"
  done
}

detect_local_ipv4() {
  local remote=${1:-1.1.1.1}
  ip -4 route get "$remote" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

detect_public_ipv4() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null || true
}

load_config() {
  [[ -r $CONFIG_FILE ]] || die "尚未配置。请先运行：${PROGRAM} configure"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  : "${INTERFACE:?配置缺少 INTERFACE}"
  : "${SERVER_IPV4:?配置缺少 SERVER_IPV4}"
  : "${HE_CLIENT_IPV4:?配置缺少 HE_CLIENT_IPV4}"
  : "${LOCAL_IPV4:?配置缺少 LOCAL_IPV4}"
  : "${SERVER_IPV6:?配置缺少 SERVER_IPV6}"
  : "${CLIENT_IPV6:?配置缺少 CLIENT_IPV6}"
  : "${TUNNEL_MTU:?配置缺少 TUNNEL_MTU}"
  ROUTED_64=${ROUTED_64:-}
  ROUTED_48=${ROUTED_48:-}
  CONFIGURED_AT=${CONFIGURED_AT:-未知}
}

write_config() {
  install -d -m 700 "$CONFIG_DIR"
  umask 077
  {
    printf '# Managed by %s %s. Do not add shell commands.\n' "$PROGRAM" "$VERSION"
    printf 'INTERFACE=%q\n' "$INTERFACE"
    printf 'SERVER_IPV4=%q\n' "$SERVER_IPV4"
    printf 'HE_CLIENT_IPV4=%q\n' "$HE_CLIENT_IPV4"
    printf 'LOCAL_IPV4=%q\n' "$LOCAL_IPV4"
    printf 'SERVER_IPV6=%q\n' "$SERVER_IPV6"
    printf 'CLIENT_IPV6=%q\n' "$CLIENT_IPV6"
    printf 'ROUTED_64=%q\n' "$ROUTED_64"
    printf 'ROUTED_48=%q\n' "$ROUTED_48"
    printf 'TUNNEL_MTU=%q\n' "$TUNNEL_MTU"
    printf 'CONFIGURED_AT=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

install_program() {
  local source_path
  source_path=$(readlink -f "${BASH_SOURCE[0]}")
  if [[ $source_path != "$INSTALL_PATH" ]]; then
    install -m 755 "$source_path" "$INSTALL_PATH"
  fi
}

write_systemd_service() {
  command -v systemctl >/dev/null 2>&1 || die "当前系统未使用 systemd，暂时无法配置开机自启。"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hurricane Electric IPv6 6in4 Tunnel
Documentation=https://github.com/xinian5216/he-ipv6-manager
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} internal-up
ExecStop=${INSTALL_PATH} internal-down

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$PROGRAM.service" >/dev/null
}

tunnel_down() {
  local iface=${INTERFACE:-he-ipv6}
  if ip link show "$iface" >/dev/null 2>&1; then
    ip link set "$iface" down 2>/dev/null || true
    ip tunnel del "$iface" 2>/dev/null || true
  fi
}

tunnel_up() {
  load_config
  require_command ip
  modprobe sit 2>/dev/null || true

  tunnel_down
  ip tunnel add "$INTERFACE" mode sit remote "$SERVER_IPV4" local "$LOCAL_IPV4" ttl 255
  ip link set dev "$INTERFACE" mtu "$TUNNEL_MTU"
  ip link set dev "$INTERFACE" up
  ip -6 addr replace "${CLIENT_IPV6}/64" dev "$INTERFACE"
  ip -6 route replace default via "$SERVER_IPV6" dev "$INTERFACE" metric 1024
}

configure() {
  require_root
  require_command ip

  local old_server_ipv4='' old_he_client_ipv4='' old_local_ipv4=''
  local old_server_ipv6='' old_client_ipv6='' old_routed_64=''
  local old_routed_48='' old_interface='he-ipv6' old_mtu='1480'
  if [[ -r $CONFIG_FILE ]]; then
    load_config
    old_server_ipv4=$SERVER_IPV4
    old_he_client_ipv4=$HE_CLIENT_IPV4
    old_local_ipv4=$LOCAL_IPV4
    old_server_ipv6=$SERVER_IPV6
    old_client_ipv6=$CLIENT_IPV6
    old_routed_64=$ROUTED_64
    old_routed_48=$ROUTED_48
    old_interface=$INTERFACE
    old_mtu=$TUNNEL_MTU
  fi

  printf '\n%bHE Tunnel Broker 配置向导%b\n' "$BOLD" "$RESET"
  printf '请从 Tunnel Details 页面复制以下字段；IPv6 可带 /64，脚本会自动去除。\n\n'

  SERVER_IPV4=$(prompt_ipv4 'Server IPv4 Address' "$old_server_ipv4")
  HE_CLIENT_IPV4=$(prompt_ipv4 'Client IPv4 Address（HE 页面）' "$old_he_client_ipv4")

  local detected_local
  detected_local=$(detect_local_ipv4 "$SERVER_IPV4")
  LOCAL_IPV4=$(prompt_ipv4 'VPS 本机用于隧道的 IPv4' "${old_local_ipv4:-$detected_local}")
  SERVER_IPV6=$(prompt_ipv6 'Server IPv6 Address' "$old_server_ipv6")
  CLIENT_IPV6=$(prompt_ipv6 'Client IPv6 Address' "$old_client_ipv6")
  ROUTED_64=$(prompt_optional 'Routed /64' "$old_routed_64")
  ROUTED_48=$(prompt_optional 'Routed /48' "$old_routed_48")
  INTERFACE=$(prompt_value '隧道接口名' "$old_interface")
  TUNNEL_MTU=$(prompt_value '隧道 MTU' "$old_mtu")

  [[ $INTERFACE =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || die "接口名不合法或超过 15 个字符。"
    [[ $TUNNEL_MTU =~ ^[0-9]+$ ]] || die "MTU 必须是数字。"
      ((TUNNEL_MTU >= 1280 && TUNNEL_MTU <= 1480)) || die "MTU 应在 1280–1480 之间。"
  [[ -z $ROUTED_64 || $ROUTED_64 == */64 ]] || warn "Routed /64 通常应以 /64 结尾，仍按输入内容保存。"
  [[ -z $ROUTED_48 || $ROUTED_48 == */48 ]] || warn "Routed /48 通常应以 /48 结尾，仍按输入内容保存。"

  install_program
  write_config
  write_systemd_service
  systemctl restart "$PROGRAM.service"

  ok "HE IPv6 隧道已配置并设置为开机自启。"
  show_info
  printf '\n'
  diagnose || true
}

show_info() {
  load_config
  local current_public service_state='未知' link_state='未创建'
  current_public=$(detect_public_ipv4)
  command -v systemctl >/dev/null 2>&1 && service_state=$(systemctl is-active "$PROGRAM.service" 2>/dev/null || true)
  ip link show "$INTERFACE" >/dev/null 2>&1 && link_state='已创建'

  printf '\n%bHE IPv6 隧道信息%b\n' "$BOLD" "$RESET"
  printf '%-22s %s\n' '脚本版本' "$VERSION"
  printf '%-22s %s\n' '配置时间（UTC）' "$CONFIGURED_AT"
  printf '%-22s %s\n' '接口' "$INTERFACE"
  printf '%-22s %s\n' '接口状态' "$link_state"
  printf '%-22s %s\n' 'systemd 服务' "$service_state"
  printf '%-22s %s\n' 'Server IPv4' "$SERVER_IPV4"
  printf '%-22s %s\n' 'HE Client IPv4' "$HE_CLIENT_IPV4"
  printf '%-22s %s\n' '本机隧道 IPv4' "$LOCAL_IPV4"
  printf '%-22s %s\n' '当前公网 IPv4' "${current_public:-获取失败}"
  printf '%-22s %s/64\n' 'Server IPv6' "$SERVER_IPV6"
  printf '%-22s %s/64\n' 'Client IPv6' "$CLIENT_IPV6"
  printf '%-22s %s\n' 'Routed /64' "${ROUTED_64:-未配置}"
  printf '%-22s %s\n' 'Routed /48' "${ROUTED_48:-未配置}"
  printf '%-22s %s\n' 'MTU' "$TUNNEL_MTU"
  printf '%-22s %s\n' '配置文件' "$CONFIG_FILE"

  if [[ -n $current_public && $current_public != "$HE_CLIENT_IPV4" ]]; then
    warn "当前公网 IPv4 与 HE Client IPv4 不一致，HE 端点可能需要更新。"
  fi
}

status() {
  load_config
  printf '\n%b接口详情%b\n' "$BOLD" "$RESET"
  ip -d link show "$INTERFACE" 2>/dev/null || warn "接口不存在。"
  printf '\n%bIPv6 地址%b\n' "$BOLD" "$RESET"
  ip -6 addr show dev "$INTERFACE" 2>/dev/null || true
  printf '\n%bIPv6 默认路由%b\n' "$BOLD" "$RESET"
  ip -6 route show default
  if command -v systemctl >/dev/null 2>&1; then
    printf '\n%b服务状态%b\n' "$BOLD" "$RESET"
    systemctl --no-pager --full status "$PROGRAM.service" || true
  fi
}

check() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '%b✓%b %s\n' "$GREEN" "$RESET" "$label"
    return 0
  fi
  printf '%b✗%b %s\n' "$RED" "$RESET" "$label"
  return 1
}

has_client_ipv6() {
  ip -6 -o addr show dev "$INTERFACE" scope global 2>/dev/null \
    | awk '{print $4}' | grep -Fqx "${CLIENT_IPV6}/64"
}

has_ipv6_default_route() {
  ip -6 route show default 2>/dev/null | grep -q '^default '
}

diagnose() {
  load_config
  local failures=0 current_public=''
  printf '\n%b连通性诊断%b\n' "$BOLD" "$RESET"

  check '配置文件权限为 600' test "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)" = 600 || ((failures+=1))
  check 'SIT/6in4 接口存在' ip link show "$INTERFACE" || ((failures+=1))
  check 'Client IPv6 已绑定' has_client_ipv6 || ((failures+=1))
  check 'IPv6 默认路由存在' has_ipv6_default_route || ((failures+=1))
  check 'HE Server IPv4 可达' ping -4 -c 1 -W 3 "$SERVER_IPV4" || ((failures+=1))
  check 'HE Server IPv6 可达' ping -6 -c 2 -W 3 "$SERVER_IPV6" || ((failures+=1))
  check 'IPv6 公网可达' ping -6 -c 2 -W 3 2606:4700:4700::1111 || ((failures+=1))

  current_public=$(detect_public_ipv4)
  if [[ -n $current_public && $current_public == "$HE_CLIENT_IPV4" ]]; then
    printf '%b✓%b 当前公网 IPv4 与 HE Client IPv4 一致\n' "$GREEN" "$RESET"
  elif [[ -n $current_public ]]; then
    printf '%b✗%b 公网 IPv4 不一致：当前 %s，HE 配置 %s\n' \
      "$RED" "$RESET" "$current_public" "$HE_CLIENT_IPV4"
    ((failures+=1))
  else
    warn "无法获取当前公网 IPv4，跳过端点一致性检查。"
  fi

  if ((failures == 0)); then
    ok "所有检查均通过。"
    return 0
  fi

  warn "共有 ${failures} 项未通过。若 IPv4 可达但 IPv6 不通，请检查云防火墙/上游是否允许 IP Protocol 41，并确认 HE 端 Client IPv4。"
  return 1
}

reapply() {
  require_root
  load_config
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$PROGRAM.service"
  else
    tunnel_up
  fi
  ok "隧道已重新应用。"
  diagnose || true
}

uninstall_program() {
  require_root
  load_config
  printf '即将移除接口 %s、systemd 服务、配置和已安装脚本。\n' "$INTERFACE"
  read -r -p '确认卸载？输入 yes：' answer
  [[ $answer == yes ]] || { info "已取消。"; return; }

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$PROGRAM.service" >/dev/null 2>&1 || true
  fi
  tunnel_down
  rm -f "$SERVICE_FILE"
  rm -f "$INSTALL_PATH"
  rm -f "$CONFIG_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
  ok "已卸载 ${PROGRAM}；HE 网站中的 Tunnel Broker 隧道未被删除。"
}

usage() {
  cat <<EOF
${PROGRAM} ${VERSION} - 管理 Hurricane Electric Tunnel Broker IPv6

用法：
  ${PROGRAM}                  打开交互菜单
  ${PROGRAM} configure        配置或重新配置隧道
  ${PROGRAM} show             回顾 HE IP 与本机配置
  ${PROGRAM} status           查看接口、路由与服务状态
  ${PROGRAM} diagnose         执行连通性诊断
  ${PROGRAM} reapply          重建并重新应用隧道
  ${PROGRAM} uninstall        卸载（不会删除 HE 网站中的隧道）
  ${PROGRAM} version          显示版本
EOF
}

menu() {
  while :; do
    printf '\n%b%s %s%b\n' "$BOLD" "$PROGRAM" "$VERSION" "$RESET"
    cat <<'EOF'
1) 配置 / 重新配置 HE IPv6
2) 回顾 HE IP 信息
3) 查看详细状态
4) 运行诊断
5) 重新应用隧道
6) 卸载
0) 退出
EOF
    read -r -p '请选择 [0-6]：' choice
    case $choice in
      1) configure ;;
      2) show_info ;;
      3) status ;;
      4) diagnose || true ;;
      5) reapply ;;
      6) uninstall_program; return ;;
      0) return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

main() {
  case ${1:-menu} in
    menu) menu ;;
    configure|install) configure ;;
    show|info) show_info ;;
    status) status ;;
    diagnose|doctor) diagnose ;;
    reapply|restart) reapply ;;
    uninstall|remove) uninstall_program ;;
    internal-up) require_root; tunnel_up ;;
    internal-down) require_root; load_config; tunnel_down ;;
    version|-v|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
