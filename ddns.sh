#!/usr/bin/env bash
set -euo pipefail

# =========================
# Cloudflare DDNS (Global API Key) - Interactive + --run
# Config & logs in: /root/ddns
# Run interactive:  bash ddns.sh
# Run cron mode:    bash ddns.sh --run
# Works on: CentOS/Debian/Ubuntu/Alpine
# =========================

BASE_DIR="/root/ddns"
CONFIG_FILE="${BASE_DIR}/config.env"
LOG_FILE="${BASE_DIR}/ip_changes.log"
RUN_LOG="${BASE_DIR}/run.log"

TZ_BEIJING="Asia/Shanghai"

die() { echo "[ERR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1（请安装）"; }

mkdir -p "$BASE_DIR" || die "无法创建目录：$BASE_DIR"

need_cmd curl
need_cmd awk
need_cmd sed
need_cmd date

HAS_JQ=0
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; fi

now_beijing() { TZ="$TZ_BEIJING" date "+%Y-%m-%d %H:%M:%S %Z"; }

cleanup_log_30d() {
  [[ -f "$LOG_FILE" ]] || return 0
  local cutoff
  cutoff="$(TZ="$TZ_BEIJING" date -d "30 days ago" "+%Y-%m-%d" 2>/dev/null || true)"
  if [[ -z "$cutoff" ]]; then
    # Alpine busybox date fallback: keep last N lines
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    return 0
  fi
  awk -v c="$cutoff" '
    length($1)==10 && $1>=c { print; next }
    length($1)!=10 { print }
  ' "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

http_get() { curl -fsS --connect-timeout 5 --max-time 15 "$1"; }

detect_ipv4() {
  local ip=""
  ip="$(http_get "https://api.ipify.org" 2>/dev/null || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ip="$(http_get "https://ipv4.icanhazip.com" 2>/dev/null | tr -d ' \n\r' || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ip="$(http_get "https://ifconfig.me/ip" 2>/dev/null | tr -d ' \n\r' || true)"
  echo "$ip"
}

detect_ipv6() {
  local ip=""
  ip="$(http_get "https://api64.ipify.org" 2>/dev/null || true)"
  [[ "$ip" =~ : ]] || ip="$(http_get "https://ipv6.icanhazip.com" 2>/dev/null | tr -d ' \n\r' || true)"
  echo "$ip"
}

# ---- Cloudflare API (Global Key) ----
cf_api() {
  local method="$1"; shift
  local url="https://api.cloudflare.com/client/v4$1"; shift
  local data="${1:-}"

  if [[ -n "$data" ]]; then
    curl -fsS --connect-timeout 5 --max-time 25 \
      -X "$method" "$url" \
      -H "X-Auth-Email: ${CF_EMAIL}" \
      -H "X-Auth-Key: ${CF_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS --connect-timeout 5 --max-time 25 \
      -X "$method" "$url" \
      -H "X-Auth-Email: ${CF_EMAIL}" \
      -H "X-Auth-Key: ${CF_API_KEY}" \
      -H "Content-Type: application/json"
  fi
}

print_banner() {
  echo "==========================================="
  echo " Cloudflare DDNS (Global API Key)"
  echo " 配置/日志目录：${BASE_DIR}"
  echo " 交互模式：bash ddns.sh"
  echo " 定时模式：bash ddns.sh --run"
  echo "==========================================="
}

load_config_if_exists() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    return 0
  fi
  return 1
}

save_config() {
  umask 077
  cat > "$CONFIG_FILE" <<EOF
# Cloudflare DDNS config (saved at $(now_beijing))
CF_API_KEY="${CF_API_KEY}"
CF_EMAIL="${CF_EMAIL}"
CFZONE_NAME="${CFZONE_NAME}"
CFRECORD_NAME="${CFRECORD_NAME}"
CF_RECORD_TYPE="${CF_RECORD_TYPE}"
CF_TTL="${CF_TTL}"
CF_PROXIED="${CF_PROXIED}"
EOF
  info "配置已保存：$CONFIG_FILE"
}

prompt_input() {
  local var="$1"
  local prompt="$2"
  local def="${3:-}"
  local secret="${4:-0}"
  local val=""

  if [[ "$secret" == "1" ]]; then
    if [[ -n "$def" ]]; then
      read -r -s -p "${prompt} (回车保留已设)：" val; echo
      val="${val:-$def}"
    else
      read -r -s -p "${prompt}：" val; echo
    fi
  else
    if [[ -n "$def" ]]; then
      read -r -p "${prompt} [默认: ${def}]：" val
      val="${val:-$def}"
    else
      read -r -p "${prompt}：" val
    fi
  fi

  [[ -n "$val" ]] || die "输入不能为空：$var"
  printf -v "$var" '%s' "$val"
}

interactive_setup() {
  print_banner
  echo "[设置] 请输入 Cloudflare 信息（首次/修改时需要）"
  echo

  local cur_key="${CF_API_KEY:-}"
  local cur_email="${CF_EMAIL:-}"
  local cur_zone="${CFZONE_NAME:-}"
  local cur_record="${CFRECORD_NAME:-}"
  local cur_type="${CF_RECORD_TYPE:-A}"
  local cur_ttl="${CF_TTL:-120}"
  local cur_prox="${CF_PROXIED:-false}"

  prompt_input CF_API_KEY "CF_API_KEY(Global API Key)" "$cur_key" 1
  prompt_input CF_EMAIL "CF_EMAIL(Cloudflare邮箱)" "$cur_email" 0
  prompt_input CFZONE_NAME "CFZONE_NAME(如 example.com)" "$cur_zone" 0
  prompt_input CFRECORD_NAME "CFRECORD_NAME(如 home.example.com，全名)" "$cur_record" 0

  read -r -p "记录类型 A(IPv4) / AAAA(IPv6) [默认: ${cur_type}]：" CF_RECORD_TYPE
  CF_RECORD_TYPE="${CF_RECORD_TYPE:-$cur_type}"
  [[ "$CF_RECORD_TYPE" == "A" || "$CF_RECORD_TYPE" == "AAAA" ]] || die "记录类型只能是 A 或 AAAA"

  read -r -p "TTL(秒，1=Auto) [默认: ${cur_ttl}]：" CF_TTL
  CF_TTL="${CF_TTL:-$cur_ttl}"
  [[ "$CF_TTL" =~ ^[0-9]+$ ]] || die "TTL 必须是数字"

  read -r -p "是否开启代理 proxied true/false [默认: ${cur_prox}]：" CF_PROXIED
  CF_PROXIED="${CF_PROXIED:-$cur_prox}"
  [[ "$CF_PROXIED" == "true" || "$CF_PROXIED" == "false" ]] || die "proxied 只能是 true 或 false"

  save_config
}

show_menu() {
  echo
  echo "1) 直接执行 DDNS 更新"
  echo "2) 修改/重新输入配置"
  echo "3) 查看最近 20 条 IP 变更日志"
  echo "4) 退出"
  echo
}

show_current_config_masked() {
  echo "当前配置："
  echo "  CF_EMAIL       = ${CF_EMAIL:-<未设置>}"
  echo "  CFZONE_NAME    = ${CFZONE_NAME:-<未设置>}"
  echo "  CFRECORD_NAME  = ${CFRECORD_NAME:-<未设置>}"
  echo "  CF_RECORD_TYPE = ${CF_RECORD_TYPE:-<未设置>}"
  echo "  CF_TTL         = ${CF_TTL:-<未设置>}"
  echo "  CF_PROXIED     = ${CF_PROXIED:-<未设置>}"
  if [[ -n "${CF_API_KEY:-}" ]]; then
    echo "  CF_API_KEY     = 已设置（已隐藏）"
  else
    echo "  CF_API_KEY     = <未设置>"
  fi
}

validate_config() {
  [[ -n "${CF_API_KEY:-}" ]] || die "未设置 CF_API_KEY"
  [[ -n "${CF_EMAIL:-}" ]] || die "未设置 CF_EMAIL"
  [[ -n "${CFZONE_NAME:-}" ]] || die "未设置 CFZONE_NAME"
  [[ -n "${CFRECORD_NAME:-}" ]] || die "未设置 CFRECORD_NAME"
  [[ "${CF_RECORD_TYPE:-}" == "A" || "${CF_RECORD_TYPE:-}" == "AAAA" ]] || die "CF_RECORD_TYPE 只能是 A 或 AAAA"
  [[ "${CF_PROXIED:-}" == "true" || "${CF_PROXIED:-}" == "false" ]] || die "CF_PROXIED 只能是 true 或 false"
  [[ "${CF_TTL:-}" =~ ^[0-9]+$ ]] || die "CF_TTL 必须是数字"
}

run_ddns_once() {
  validate_config

  print_banner
  show_current_config_masked
  echo

  # ---- Step 1: public IP ----
  local PUB_IP=""
  if [[ "$CF_RECORD_TYPE" == "A" ]]; then
    PUB_IP="$(detect_ipv4)"
    [[ "$PUB_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "步骤1失败：获取公网 IPv4 失败（检查网络/出口/IPv4）"
  else
    PUB_IP="$(detect_ipv6)"
    [[ "$PUB_IP" =~ : ]] || die "步骤1失败：获取公网 IPv6 失败（检查网络/出口/IPv6）"
  fi
  info "步骤1成功：检测到公网IP($CF_RECORD_TYPE)：$PUB_IP"

  # ---- Step 2: zone id ----
  local ZONE_JSON ZONE_ID
  ZONE_JSON="$(cf_api GET "/zones?name=${CFZONE_NAME}&status=active&page=1&per_page=50" )" \
    || die "步骤2失败：查询 Zone 失败（网络问题或 Key/邮箱错误）"

  if [[ $HAS_JQ -eq 1 ]]; then
    [[ "$(echo "$ZONE_JSON" | jq -r '.success')" == "true" ]] || die "步骤2失败：查询 Zone 返回 success=false：$(echo "$ZONE_JSON" | jq -c '.errors // empty')"
    ZONE_ID="$(echo "$ZONE_JSON" | jq -r '.result[0].id // empty')"
  else
    ZONE_ID="$(echo "$ZONE_JSON" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)"
  fi
  [[ -n "$ZONE_ID" ]] || die "步骤2失败：找不到 Zone：${CFZONE_NAME}（确认域名在该账号下且 active）"
  info "步骤2成功：Zone匹配：$CFZONE_NAME -> $ZONE_ID"

  # ---- Step 3: record id ----
  local REC_JSON REC_ID CUR_IP
  REC_JSON="$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=${CF_RECORD_TYPE}&name=${CFRECORD_NAME}&page=1&per_page=100" )" \
    || die "步骤3失败：查询 DNS Record 失败（检查权限/网络/记录名）"

  if [[ $HAS_JQ -eq 1 ]]; then
    [[ "$(echo "$REC_JSON" | jq -r '.success')" == "true" ]] || die "步骤3失败：查询 Record 返回 success=false：$(echo "$REC_JSON" | jq -c '.errors // empty')"
    REC_ID="$(echo "$REC_JSON" | jq -r '.result[0].id // empty')"
    CUR_IP="$(echo "$REC_JSON" | jq -r '.result[0].content // empty')"
  else
    REC_ID="$(echo "$REC_JSON" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)"
    CUR_IP="$(echo "$REC_JSON" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -n1)"
  fi

  [[ -n "$REC_ID" ]] || die "步骤3失败：找不到记录：type=${CF_RECORD_TYPE}, name=${CFRECORD_NAME}（确认记录已存在且名称为全名）"
  [[ -n "$CUR_IP" ]] || die "步骤3失败：无法读取当前记录 content（建议安装 jq）"

  info "步骤3成功：当前解析：$CFRECORD_NAME -> $CUR_IP"

  # ---- Step 4: compare/update ----
  if [[ "$CUR_IP" == "$PUB_IP" ]]; then
    info "步骤4：无需更新（公网IP与解析一致）"
    return 0
  fi

  info "步骤4：需要更新：$CUR_IP -> $PUB_IP"

  local UPDATE_JSON PUT_JSON
  UPDATE_JSON="$(cat <<EOF
{
  "type": "${CF_RECORD_TYPE}",
  "name": "${CFRECORD_NAME}",
  "content": "${PUB_IP}",
  "ttl": ${CF_TTL},
  "proxied": ${CF_PROXIED}
}
EOF
)"

  PUT_JSON="$(cf_api PUT "/zones/${ZONE_ID}/dns_records/${REC_ID}" "$UPDATE_JSON")" \
    || die "步骤4失败：更新请求失败（网络问题或权限不足）"

  if [[ $HAS_JQ -eq 1 ]]; then
    [[ "$(echo "$PUT_JSON" | jq -r '.success')" == "true" ]] || die "步骤4失败：更新失败：$(echo "$PUT_JSON" | jq -c '.errors // empty')"
  else
    echo "$PUT_JSON" | grep -q '"success":true' || die "步骤4失败：更新失败（建议安装 jq 查看 errors）"
  fi

  info "步骤4成功：更新成功：$CFRECORD_NAME -> $PUB_IP"

  # ---- Log only on change ----
  local TS
  TS="$(now_beijing)"
  echo "${TS} ${CFRECORD_NAME} ${CUR_IP} -> ${PUB_IP}" >> "$LOG_FILE"
  cleanup_log_30d
  info "已记录变更日志：$LOG_FILE（只记录变更，保留30天）"
}

main() {
  # ---------- cron mode ----------
  if [[ "${1:-}" == "--run" ]]; then
    load_config_if_exists || die "未找到配置：$CONFIG_FILE。请先运行：bash ddns.sh 进行交互配置"
    # 把输出也写到 /root/ddns/run.log（不影响你 cron 自己重定向）
    {
      echo "----- $(now_beijing) RUN -----"
      run_ddns_once
    } >> "$RUN_LOG" 2>&1
    exit 0
  fi

  # ---------- interactive mode ----------
  load_config_if_exists || true
  if [[ -z "${CF_API_KEY:-}" || -z "${CF_EMAIL:-}" || -z "${CFZONE_NAME:-}" || -z "${CFRECORD_NAME:-}" ]]; then
    interactive_setup
  fi

  while true; do
    show_menu
    read -r -p "请选择 [1-4]：" choice
    case "${choice:-}" in
      1) run_ddns_once ;;
      2) interactive_setup ;;
      3)
        if [[ -f "$LOG_FILE" ]]; then
          echo "---- 最近 20 条变更 ----"
          tail -n 20 "$LOG_FILE"
          echo "------------------------"
        else
          info "暂无变更日志：$LOG_FILE"
        fi
        ;;
      4) exit 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
  done
}

main "$@"
