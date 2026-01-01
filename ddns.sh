#!/usr/bin/env bash
# Cloudflare DDNS (IPv4+IPv6) for CentOS/Debian/Ubuntu/Alpine
# Config/logs live in: /root/ddns

set -u
set -o pipefail

BASE_DIR="/root/ddns"
CONF_FILE="$BASE_DIR/config.env"
CACHE_FILE="$BASE_DIR/cache.env"
RUN_LOG="$BASE_DIR/run.log"

LOG_PREFIX="chip"          # 变更日志前缀：chip_YYYY-MM-DD.log
CHANGE_KEEP_DAYS=3         # 变更日志最多保留3天（含今天）
LOCK_DIR="$BASE_DIR/.lock"

CF_API_BASE="https://api.cloudflare.com/client/v4"

# -------------------------
# Utils
# -------------------------
ensure_base_dir() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR" 2>/dev/null || true
}

bj_now() { TZ="Asia/Shanghai" date "+%Y-%m-%d %H:%M:%S"; }
bj_day() { TZ="Asia/Shanghai" date "+%Y-%m-%d"; }

log_fail() {
  ensure_base_dir
  local ts msg
  ts="$(bj_now)"
  msg="$*"
  printf "[%s] FAIL %s\n" "$ts" "$msg" >> "$RUN_LOG"
}

change_log_file() { echo "$BASE_DIR/${LOG_PREFIX}_$(bj_day).log"; }

log_change() {
  ensure_base_dir
  local f ts
  f="$(change_log_file)"
  ts="$(bj_now)"
  printf "[%s] %s\n" "$ts" "$*" >> "$f"
}

prune_change_logs() {
  local keep_plus=$((CHANGE_KEEP_DAYS - 1))
  find "$BASE_DIR" -maxdepth 1 -type f -name "${LOG_PREFIX}_*.log" -mtime "+${keep_plus}" -delete 2>/dev/null || true
}

say() { printf "%s\n" "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  if need_cmd apt-get; then echo "apt"
  elif need_cmd dnf; then echo "dnf"
  elif need_cmd yum; then echo "yum"
  elif need_cmd apk; then echo "apk"
  else echo "none"
  fi
}

install_deps() {
  if [ "$(id -u)" -ne 0 ]; then
    say "[ERR] 安装依赖需要 root。请用 root 执行：bash ddns.sh --install-deps"
    return 1
  fi

  local pm
  pm="$(detect_pkg_mgr)"

  case "$pm" in
    apt)
      say "[INFO] 使用 apt 安装依赖：curl jq cron bash"
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq cron bash
      ;;
    dnf)
      say "[INFO] 使用 dnf 安装依赖：curl jq cronie bash"
      dnf install -y curl jq cronie bash
      ;;
    yum)
      say "[INFO] 使用 yum 安装依赖：curl jq cronie bash"
      yum install -y curl jq cronie bash
      ;;
    apk)
      say "[INFO] 使用 apk 安装依赖：bash curl jq dcron"
      apk add --no-cache bash curl jq dcron
      ;;
    *)
      say "[ERR] 未识别的包管理器，无法自动安装。请手动安装：bash curl jq（以及 cron）"
      return 1
      ;;
  esac

  say "[OK] 依赖安装完成。"
  return 0
}

ensure_deps() {
  local missing=0
  for c in curl jq; do
    if ! need_cmd "$c"; then
      say "[WARN] 缺少依赖：$c"
      missing=1
    fi
  done

  if ! need_cmd bash; then
    say "[WARN] 系统可能没有 bash（Alpine 常见）。建议：apk add --no-cache bash"
  fi

  if [ "$missing" -eq 1 ]; then
    say "[HINT] 可执行：bash ddns.sh --install-deps 自动安装依赖（需 root）。"
    return 1
  fi
  return 0
}

acquire_lock() {
  ensure_base_dir
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT
    return 0
  else
    say "[WARN] 检测到已有任务在运行（锁：$LOCK_DIR），本次退出避免并发。"
    return 1
  fi
}

# -------------------------
# Config
# -------------------------
load_config() {
  if [ ! -f "$CONF_FILE" ]; then
    return 1
  fi

  # shellcheck disable=SC1090
  source "$CONF_FILE"

  : "${CFZONE_NAME:?missing CFZONE_NAME}"
  : "${CFRECORD_NAME:?missing CFRECORD_NAME}"

  CF_AUTH_MODE="${CF_AUTH_MODE:-global}"
  ENABLE_IPV4="${ENABLE_IPV4:-1}"
  ENABLE_IPV6="${ENABLE_IPV6:-0}"   # ✅ 更安全：默认不启用 IPv6
  PROXIED="${PROXIED:-false}"
  TTL="${TTL:-1}"

  if [ "$CF_AUTH_MODE" = "token" ]; then
    : "${CF_API_TOKEN:?missing CF_API_TOKEN}"
  else
    : "${CF_EMAIL:?missing CF_EMAIL}"
    : "${CF_API_KEY:?missing CF_API_KEY}"
  fi

  return 0
}

write_config_interactive() {
  ensure_base_dir
  umask 077

  say "========== Cloudflare DDNS 配置 =========="
  say "支持两种认证："
  say "  1) Global API Key（CF_EMAIL + CF_API_KEY）"
  say "  2) API Token（更推荐，更安全）"
  say ""

  read -r -p "选择认证方式 [1=GlobalKey, 2=Token]（默认1）: " mode
  mode="${mode:-1}"

  local CF_AUTH_MODE_in="global"
  local CF_API_KEY_in="" CF_EMAIL_in="" CF_API_TOKEN_in=""
  local CFZONE_NAME_in="" CFRECORD_NAME_in=""
  local ENABLE_IPV4_in="1" ENABLE_IPV6_in="0"
  local PROXIED_in="false" TTL_in="1"

  if [ "$mode" = "2" ]; then
    CF_AUTH_MODE_in="token"
    read -r -p 'CF_API_TOKEN="你的API Token": ' CF_API_TOKEN_in
  else
    CF_AUTH_MODE_in="global"
    read -r -p 'CF_API_KEY="你的GlobalAPIKey": ' CF_API_KEY_in
    read -r -p 'CF_EMAIL="你的Cloudflare邮箱": ' CF_EMAIL_in
  fi

  read -r -p 'CFZONE_NAME="example.com": ' CFZONE_NAME_in
  read -r -p 'CFRECORD_NAME="home.example.com": ' CFRECORD_NAME_in

  say ""
  say "更新模式（防止没 IPv6 也被当错误）："
  say "  1) 只更新 IPv4 (A)"
  say "  2) 只更新 IPv6 (AAAA)"
  say "  3) IPv4 + IPv6 都更新"
  read -r -p "请选择 [1/2/3]（默认1）: " ipmode
  ipmode="${ipmode:-1}"

  case "$ipmode" in
    2) ENABLE_IPV4_in="0"; ENABLE_IPV6_in="1" ;;
    3) ENABLE_IPV4_in="1"; ENABLE_IPV6_in="1" ;;
    *) ENABLE_IPV4_in="1"; ENABLE_IPV6_in="0" ;;  # 默认只启 IPv4
  esac

  read -r -p "Cloudflare 代理（橙云）？[true/false]（默认false）: " PROXIED_in
  PROXIED_in="${PROXIED_in:-false}"

  read -r -p "TTL（1=auto）默认1: " TTL_in
  TTL_in="${TTL_in:-1}"

  cat > "$CONF_FILE" <<EOF
# Cloudflare DDNS config (stored in /root/ddns)
CF_AUTH_MODE="${CF_AUTH_MODE_in}"   # global | token

# Global API Key mode:
CF_API_KEY="${CF_API_KEY_in}"
CF_EMAIL="${CF_EMAIL_in}"

# API Token mode:
CF_API_TOKEN="${CF_API_TOKEN_in}"

CFZONE_NAME="${CFZONE_NAME_in}"
CFRECORD_NAME="${CFRECORD_NAME_in}"

# DDNS mode
ENABLE_IPV4="${ENABLE_IPV4_in}"
ENABLE_IPV6="${ENABLE_IPV6_in}"

PROXIED="${PROXIED_in}"   # true/false
TTL="${TTL_in}"           # 1 = auto
EOF

  chmod 600 "$CONF_FILE" 2>/dev/null || true
  say "[OK] 已保存配置到：$CONF_FILE"
}

# -------------------------
# IP Detect
# -------------------------
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_ipv6() { [[ "$1" =~ : ]]; }

get_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null | trim || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4 -fsS --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | trim || true)"
  fi
  if [ -n "$ip" ] && valid_ipv4 "$ip"; then echo "$ip"; else echo ""; fi
}

get_ipv6() {
  local ip=""
  ip="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null | trim || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -6 -fsS --max-time 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' | trim || true)"
  fi
  if [ -n "$ip" ] && valid_ipv6 "$ip"; then echo "$ip"; else echo ""; fi
}

# -------------------------
# Cloudflare API
# -------------------------
cf_headers() {
  if [ "${CF_AUTH_MODE:-global}" = "token" ]; then
    printf "Authorization: Bearer %s\n" "$CF_API_TOKEN"
  else
    printf "X-Auth-Email: %s\nX-Auth-Key: %s\n" "$CF_EMAIL" "$CF_API_KEY"
  fi
  printf "Content-Type: application/json\n"
}

cf_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${CF_API_BASE}${path}"
  local -a hdr_args=()
  local line

  while IFS= read -r line; do
    [ -n "$line" ] && hdr_args+=(-H "$line")
  done < <(cf_headers)

  if [ -n "$data" ]; then
    curl -fsS -X "$method" "${hdr_args[@]}" --data "$data" "$url"
  else
    curl -fsS -X "$method" "${hdr_args[@]}" "$url"
  fi
}

cache_get() {
  local key="$1"
  if [ -f "$CACHE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CACHE_FILE"
    eval "echo \"\${$key:-}\""
  else
    echo ""
  fi
}

cache_set() {
  ensure_base_dir
  local key="$1" val="$2"
  touch "$CACHE_FILE"
  chmod 600 "$CACHE_FILE" 2>/dev/null || true
  grep -vE "^${key}=" "$CACHE_FILE" > "${CACHE_FILE}.tmp" 2>/dev/null || true
  mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE"
  printf '%s="%s"\n' "$key" "$val" >> "$CACHE_FILE"
}

get_zone_id() {
  local zid
  zid="$(cache_get ZONE_ID)"
  if [ -n "$zid" ]; then echo "$zid"; return 0; fi

  local resp
  resp="$(cf_api GET "/zones?name=${CFZONE_NAME}" 2>/dev/null)" || return 1
  zid="$(echo "$resp" | jq -r '.result[0].id // empty')"
  [ -n "$zid" ] && [ "$zid" != "null" ] || return 1
  cache_set ZONE_ID "$zid"
  echo "$zid"
}

get_record_info() {
  local zid="$1" type="$2" name="$3"
  local resp id content
  resp="$(cf_api GET "/zones/${zid}/dns_records?type=${type}&name=${name}&per_page=1" 2>/dev/null)" || return 1
  id="$(echo "$resp" | jq -r '.result[0].id // empty')"
  content="$(echo "$resp" | jq -r '.result[0].content // empty')"
  printf "%s|%s\n" "$id" "$content"
}

create_record() {
  local zid="$1" type="$2" name="$3" content="$4"
  local data resp id
  data="$(jq -nc \
    --arg type "$type" --arg name "$name" --arg content "$content" \
    --argjson ttl "${TTL}" \
    --argjson proxied "$( [ "$PROXIED" = "true" ] && echo true || echo false )" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"
  resp="$(cf_api POST "/zones/${zid}/dns_records" "$data" 2>/dev/null)" || return 1
  id="$(echo "$resp" | jq -r '.result.id // empty')"
  [ -n "$id" ] && echo "$id"
}

update_record() {
  local zid="$1" rid="$2" type="$3" name="$4" content="$5"
  local data resp ok
  data="$(jq -nc \
    --arg type "$type" --arg name "$name" --arg content "$content" \
    --argjson ttl "${TTL}" \
    --argjson proxied "$( [ "$PROXIED" = "true" ] && echo true || echo false )" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"
  resp="$(cf_api PUT "/zones/${zid}/dns_records/${rid}" "$data" 2>/dev/null)" || return 1
  ok="$(echo "$resp" | jq -r '.success')"
  [ "$ok" = "true" ]
}

ddns_update_one() {
  local type="$1" ip="$2"

  local zid
  zid="$(get_zone_id)" || {
    say "[ERR] 获取 Zone ID 失败（检查 CFZONE_NAME / 认证信息）"
    log_fail "ZoneID 获取失败（zone=${CFZONE_NAME}, type=${type}）"
    return 1
  }

  local info rid old
  info="$(get_record_info "$zid" "$type" "$CFRECORD_NAME")" || {
    say "[ERR] 查询 DNS Record 失败（type=$type name=$CFRECORD_NAME）"
    log_fail "Record 查询失败（type=${type}, name=${CFRECORD_NAME}）"
    return 1
  }

  rid="${info%%|*}"
  old="${info#*|}"

  if [ -z "$rid" ]; then
    say "[INFO] 未找到 $type 记录，将创建：$CFRECORD_NAME -> $ip"
    rid="$(create_record "$zid" "$type" "$CFRECORD_NAME" "$ip")" || {
      say "[ERR] 创建记录失败（type=$type）"
      log_fail "创建记录失败（type=${type}, name=${CFRECORD_NAME}, ip=${ip}）"
      return 1
    }
    say "[OK] 已创建 $type 记录：$CFRECORD_NAME -> $ip"
    log_change "CREATED ${type} ${CFRECORD_NAME} old=<none> new=${ip}"
    return 0
  fi

  if [ "$old" = "$ip" ]; then
    say "[OK] $type 无需更新：$CFRECORD_NAME 当前=$old"
    return 0
  fi

  say "[INFO] 准备更新 $type：$CFRECORD_NAME $old -> $ip"
  if update_record "$zid" "$rid" "$type" "$CFRECORD_NAME" "$ip"; then
    say "[OK] 更新成功 $type：$CFRECORD_NAME $old -> $ip"
    log_change "UPDATED ${type} ${CFRECORD_NAME} old=${old} new=${ip}"
    return 0
  else
    say "[ERR] 更新失败 $type：$CFRECORD_NAME"
    log_fail "更新失败（type=${type}, name=${CFRECORD_NAME}, old=${old}, new=${ip}）"
    return 1
  fi
}

run_once() {
  ensure_base_dir
  prune_change_logs

  ensure_deps || return 1
  load_config || {
    say "[ERR] 找不到配置：$CONF_FILE"
    say "[HINT] 运行：bash ddns.sh 进入交互配置"
    return 1
  }

  acquire_lock || return 0

  say "========== Cloudflare DDNS 执行（北京时间：$(bj_now)） =========="
  say "[INFO] Zone:   $CFZONE_NAME"
  say "[INFO] Record: $CFRECORD_NAME"
  say "[INFO] IPv4:   ENABLE=${ENABLE_IPV4}  | IPv6: ENABLE=${ENABLE_IPV6}"
  say ""

  local rc=0 v4 v6

  if [ "${ENABLE_IPV4}" = "1" ]; then
    v4="$(get_ipv4)"
    if [ -n "$v4" ]; then
      say "[INFO] 读取到公网 IPv4：$v4"
      ddns_update_one "A" "$v4" || rc=1
    else
      say "[WARN] 未能获取公网 IPv4（可能无 IPv4 出口）"
      log_fail "获取IPv4失败（A记录无法更新）"
      rc=1
    fi
    say ""
  fi

  if [ "${ENABLE_IPV6}" = "1" ]; then
    v6="$(get_ipv6)"
    if [ -n "$v6" ]; then
      say "[INFO] 读取到公网 IPv6：$v6"
      ddns_update_one "AAAA" "$v6" || rc=1
    else
      # ✅ 只有当你配置“启用 IPv6”时，这才算失败；如果你不想它报错，就在交互里选“只更新 IPv4”
      say "[WARN] 未能获取公网 IPv6（可能无 IPv6 出口）"
      log_fail "获取IPv6失败（AAAA记录无法更新；如无IPv6请禁用IPv6）"
      rc=1
    fi
    say ""
  fi

  if [ "$rc" -eq 0 ]; then
    say "========== 完成：全部成功 =========="
  else
    say "========== 完成：存在失败（详见 $RUN_LOG） =========="
  fi

  return "$rc"
}

# -------------------------
# Cron install/uninstall
# -------------------------
cron_line() {
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  echo "* * * * * bash \"$script_path\" --run >/dev/null 2>&1 # CF_DDNS"
}

install_cron() {
  ensure_deps || return 1
  local line
  line="$(cron_line)"

  if need_cmd crontab; then
    (crontab -l 2>/dev/null | grep -v ' # CF_DDNS$' ; echo "$line") | crontab -
    say "[OK] 已安装 crontab（每1分钟执行一次）。"
  else
    if [ "$(id -u)" -ne 0 ]; then
      say "[ERR] Alpine 写 /etc/crontabs/root 需要 root。"
      return 1
    fi
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    grep -v ' # CF_DDNS$' /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null || true
    printf "%s\n" "$line" >> /etc/crontabs/root.tmp
    mv -f /etc/crontabs/root.tmp /etc/crontabs/root
    say "[OK] 已写入 /etc/crontabs/root（每1分钟执行一次）。"
  fi

  say ""
  say "[HINT] 如果定时不生效，请确保 cron 服务在运行："
  say "  - Debian/Ubuntu: systemctl enable --now cron"
  say "  - CentOS/RHEL:   systemctl enable --now crond"
  say "  - Alpine(OpenRC): rc-update add crond default && rc-service crond start"
}

uninstall_cron() {
  if need_cmd crontab; then
    (crontab -l 2>/dev/null | grep -v ' # CF_DDNS$') | crontab - 2>/dev/null || true
    say "[OK] 已移除 crontab 里的 CF_DDNS 定时。"
  else
    if [ "$(id -u)" -ne 0 ]; then
      say "[ERR] Alpine 修改 /etc/crontabs/root 需要 root。"
      return 1
    fi
    if [ -f /etc/crontabs/root ]; then
      grep -v ' # CF_DDNS$' /etc/crontabs/root > /etc/crontabs/root.tmp 2>/dev/null || true
      mv -f /etc/crontabs/root.tmp /etc/crontabs/root
      say "[OK] 已移除 /etc/crontabs/root 里的 CF_DDNS 定时。"
    else
      say "[INFO] 未发现 /etc/crontabs/root"
    fi
  fi
}

show_paths() {
  say "配置文件：$CONF_FILE"
  say "失败日志：$RUN_LOG"
  say "变更日志：$BASE_DIR/${LOG_PREFIX}_YYYY-MM-DD.log（北京时间，每天一个，保留${CHANGE_KEEP_DAYS}天）"
}

usage() {
  cat <<EOF
用法：
  bash ddns.sh                 # 交互界面（配置/执行/安装cron）
  bash ddns.sh --run           # 执行一次 DDNS
  bash ddns.sh --install-deps  # 安装依赖（curl/jq/cron/bash）
  bash ddns.sh --install-cron  # 安装每1分钟执行的 cron
  bash ddns.sh --uninstall-cron# 移除 cron
  bash ddns.sh --show-paths    # 显示配置/日志路径

所有配置与日志固定在：/root/ddns/
EOF
}

interactive_menu() {
  ensure_base_dir

  if [ ! -f "$CONF_FILE" ]; then
    write_config_interactive
    say ""
    run_once
    say ""
    show_paths
    return 0
  fi

  say "========== Cloudflare DDNS =========="
  say "1) 立即执行一次（--run）"
  say "2) 重新配置（覆盖 config.env）"
  say "3) 安装 cron（每1分钟）"
  say "4) 移除 cron"
  say "5) 显示配置/日志路径"
  say "0) 退出"
  read -r -p "请选择: " opt
  case "${opt:-}" in
    1) run_once ;;
    2) write_config_interactive ;;
    3) install_cron ;;
    4) uninstall_cron ;;
    5) show_paths ;;
    0) exit 0 ;;
    *) say "[ERR] 无效选择" ;;
  esac
}

# -------------------------
# main
# -------------------------
ensure_base_dir

case "${1:-}" in
  "" ) interactive_menu ;;
  --run ) run_once ;;
  --install-deps ) install_deps ;;
  --install-cron ) install_cron ;;
  --uninstall-cron ) uninstall_cron ;;
  --show-paths ) show_paths ;;
  -h|--help ) usage ;;
  * ) usage; exit 1 ;;
esac
