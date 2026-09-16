#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Cloudflare DDNS 通用模板
# 依赖：bash 4+、curl、jq；安装定时任务时还需要 crontab。

readonly SCRIPT_NAME="$(basename "$0")"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"

INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/cloudflare-ddns}"
CONFIG_PATH="${CONFIG_PATH:-/etc/cloudflare-ddns/config}"
LOG_PATH="${LOG_PATH:-/var/log/cloudflare-ddns.log}"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_AUTH_EMAIL="${CF_AUTH_EMAIL:-}"
CF_GLOBAL_API_KEY="${CF_GLOBAL_API_KEY:-}"
CF_ZONE_NAME="${CF_ZONE_NAME:-}"
CF_RECORD_NAME="${CF_RECORD_NAME:-}"
CF_RECORD_IP="${CF_RECORD_IP:-}"
CF_PROXIED="${CF_PROXIED:-false}"
CF_TTL="${CF_TTL:-1}"
IP_LOOKUP_URL="${IP_LOOKUP_URL:-https://api.ipify.org}"

INSTALL_CRON=0
CONFIG_FILE=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Cloudflare DDNS 通用模板

用法：
  ${SCRIPT_NAME} --token TOKEN --zone example.com --record home.example.com [--ip IPv4]
  ${SCRIPT_NAME} --config /etc/cloudflare-ddns/config
  sudo ${SCRIPT_NAME} --install-cron --token TOKEN --zone example.com --record home.example.com

选项：
  --token TOKEN          Cloudflare API Token（推荐）
  --email EMAIL          Cloudflare 账户邮箱（仅兼容 Global API Key）
  --api-key KEY          Cloudflare Global API Key（不推荐）
  --zone NAME            Cloudflare Zone，例如 example.com
  --record NAME          要维护的完整 A 记录，例如 home.example.com
  --ip IPv4              指定 IPv4；省略时自动查询当前公网 IPv4
  --proxied BOOL         是否开启 Cloudflare 代理：true/false，默认 false
  --ttl SECONDS          DNS TTL；1 表示自动，默认 1
  --config FILE          从仅受信任的本地配置文件读取参数
  --install-cron         安装脚本、配置文件及每 5 分钟运行的定时任务
  -h, --help             显示帮助

Token 最小权限：Zone:Zone:Read、Zone:DNS:Edit；资源范围限制到目标 Zone。
也可使用同名环境变量：CF_API_TOKEN、CF_ZONE_NAME、CF_RECORD_NAME 等。
EOF
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

validate_ipv4() {
    local value="$1" part
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a parts <<< "$value"
    for part in "${parts[@]}"; do
        (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
    done
}

validate_inputs() {
    [[ -n "$CF_ZONE_NAME" ]] || die "缺少 --zone 或 CF_ZONE_NAME"
    [[ -n "$CF_RECORD_NAME" ]] || die "缺少 --record 或 CF_RECORD_NAME"
    [[ "$CF_RECORD_NAME" == "$CF_ZONE_NAME" || "$CF_RECORD_NAME" == *."$CF_ZONE_NAME" ]] || \
        die "记录名称必须属于指定 Zone"
    [[ "$CF_PROXIED" == "true" || "$CF_PROXIED" == "false" ]] || die "--proxied 只能是 true 或 false"
    [[ "$CF_TTL" =~ ^[0-9]+$ ]] || die "--ttl 必须是整数"

    if [[ -n "$CF_API_TOKEN" ]]; then
        return
    fi
    [[ -n "$CF_AUTH_EMAIL" && -n "$CF_GLOBAL_API_KEY" ]] || \
        die "请提供 API Token；或同时提供邮箱和 Global API Key"
}

load_config() {
    local file="$1"
    [[ -f "$file" ]] || die "配置文件不存在: $file"
    # 配置文件会作为 Bash 变量文件读取，因此必须来自可信来源。
    # shellcheck disable=SC1090
    source "$file"
}

setup_headers() {
    CF_HEADERS=(-H 'Content-Type: application/json')
    if [[ -n "$CF_API_TOKEN" ]]; then
        CF_HEADERS+=(-H "Authorization: Bearer ${CF_API_TOKEN}")
    else
        CF_HEADERS+=(-H "X-Auth-Email: ${CF_AUTH_EMAIL}")
        CF_HEADERS+=(-H "X-Auth-Key: ${CF_GLOBAL_API_KEY}")
    fi
}

cf_request() {
    local method="$1" url="$2" data="${3:-}" body_file http_code body message
    body_file="$(mktemp)"

    if [[ -n "$data" ]]; then
        http_code="$(curl -sS -o "$body_file" -w '%{http_code}' --request "$method" \
            "$url" "${CF_HEADERS[@]}" --data "$data")" || {
                rm -f "$body_file"
                die "无法连接 Cloudflare API"
            }
    else
        http_code="$(curl -sS -o "$body_file" -w '%{http_code}' --request "$method" \
            "$url" "${CF_HEADERS[@]}")" || {
                rm -f "$body_file"
                die "无法连接 Cloudflare API"
            }
    fi

    body="$(<"$body_file")"
    rm -f "$body_file"
    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        message="$(jq -r '.errors[0].message // "未知错误"' <<< "$body" 2>/dev/null || true)"
        die "Cloudflare API 请求失败（HTTP ${http_code}）：${message}"
    fi
    jq -e '.success == true' >/dev/null <<< "$body" || die "Cloudflare API 返回失败结果"
    printf '%s' "$body"
}

resolve_public_ip() {
    local value
    if [[ -n "$CF_RECORD_IP" ]]; then
        value="$CF_RECORD_IP"
    else
        value="$(curl -fsS --max-time 15 "$IP_LOOKUP_URL" | tr -d '[:space:]')" || \
            die "无法获取当前公网 IPv4"
    fi
    validate_ipv4 "$value" || die "无效的 IPv4: $value"
    printf '%s' "$value"
}

run_once() {
    local current_ip zone_response zone_id query_url record_response count
    local record_id old_ip old_proxied payload response

    require_cmd curl
    require_cmd jq
    validate_inputs
    setup_headers
    current_ip="$(resolve_public_ip)"

    query_url="${CF_API_BASE}/zones?$(jq -rn --arg v "$CF_ZONE_NAME" '$v|@uri' | sed 's/^/name=/')"
    zone_response="$(cf_request GET "$query_url")"
    zone_id="$(jq -r '.result[0].id // empty' <<< "$zone_response")"
    [[ -n "$zone_id" ]] || die "未找到 Zone: $CF_ZONE_NAME"

    query_url="${CF_API_BASE}/zones/${zone_id}/dns_records?type=A&name=$(jq -rn --arg v "$CF_RECORD_NAME" '$v|@uri')"
    record_response="$(cf_request GET "$query_url")"
    count="$(jq '.result | length' <<< "$record_response")"

    if (( count > 1 )); then
        die "发现 ${count} 条同名 A 记录。为防止误删，请先在 Cloudflare 后台处理重复记录"
    fi

    if (( count == 0 )); then
        payload="$(jq -nc --arg name "$CF_RECORD_NAME" --arg ip "$current_ip" \
            --argjson ttl "$CF_TTL" --argjson proxied "$CF_PROXIED" \
            '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:$proxied}')"
        cf_request POST "${CF_API_BASE}/zones/${zone_id}/dns_records" "$payload" >/dev/null
        log "已创建: ${CF_RECORD_NAME} -> ${current_ip}"
        return
    fi

    record_id="$(jq -r '.result[0].id' <<< "$record_response")"
    old_ip="$(jq -r '.result[0].content' <<< "$record_response")"
    old_proxied="$(jq -r '.result[0].proxied' <<< "$record_response")"

    if [[ "$old_ip" == "$current_ip" && "$old_proxied" == "$CF_PROXIED" ]]; then
        log "无需更新: ${CF_RECORD_NAME} -> ${current_ip}"
        return
    fi

    payload="$(jq -nc --arg name "$CF_RECORD_NAME" --arg ip "$current_ip" \
        --argjson ttl "$CF_TTL" --argjson proxied "$CF_PROXIED" \
        '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:$proxied}')"
    response="$(cf_request PUT "${CF_API_BASE}/zones/${zone_id}/dns_records/${record_id}" "$payload")"
    jq -e '.success == true' >/dev/null <<< "$response"
    log "已更新: ${CF_RECORD_NAME} ${old_ip} -> ${current_ip}"
}

write_config() {
    local target="$1"
    install -d -m 700 "$(dirname "$target")"
    {
        printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
        printf 'CF_AUTH_EMAIL=%q\n' "$CF_AUTH_EMAIL"
        printf 'CF_GLOBAL_API_KEY=%q\n' "$CF_GLOBAL_API_KEY"
        printf 'CF_ZONE_NAME=%q\n' "$CF_ZONE_NAME"
        printf 'CF_RECORD_NAME=%q\n' "$CF_RECORD_NAME"
        printf 'CF_RECORD_IP=%q\n' "$CF_RECORD_IP"
        printf 'CF_PROXIED=%q\n' "$CF_PROXIED"
        printf 'CF_TTL=%q\n' "$CF_TTL"
        printf 'IP_LOOKUP_URL=%q\n' "$IP_LOOKUP_URL"
    } > "$target"
    chmod 600 "$target"
}

install_cron() {
    (( EUID == 0 )) || die "安装定时任务需要 root 权限，请使用 sudo"
    require_cmd install
    require_cmd crontab
    validate_inputs

    local source_path existing cron_line
    source_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    [[ -f "$source_path" ]] || die "请先把脚本保存为本地文件后再安装"

    install -D -m 700 "$source_path" "$INSTALL_PATH"
    write_config "$CONFIG_PATH"
    touch "$LOG_PATH"
    chmod 600 "$LOG_PATH"

    cron_line="*/5 * * * * /bin/bash ${INSTALL_PATH} --config ${CONFIG_PATH} >> ${LOG_PATH} 2>&1"
    existing="$(crontab -l 2>/dev/null | grep -Fv "$INSTALL_PATH" || true)"
    { printf '%s\n' "$existing"; printf '%s\n' "$cron_line"; } | sed '/^[[:space:]]*$/d' | crontab -

    log "脚本已安装到: $INSTALL_PATH"
    log "配置已保存到: $CONFIG_PATH（权限 600）"
    log "已设置每 5 分钟更新一次，日志: $LOG_PATH"
    /bin/bash "$INSTALL_PATH" --config "$CONFIG_PATH"
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --token) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_API_TOKEN="$2"; shift 2 ;;
            --email) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_AUTH_EMAIL="$2"; shift 2 ;;
            --api-key) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_GLOBAL_API_KEY="$2"; shift 2 ;;
            --zone) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_ZONE_NAME="$2"; shift 2 ;;
            --record) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_RECORD_NAME="$2"; shift 2 ;;
            --ip) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_RECORD_IP="$2"; shift 2 ;;
            --proxied) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_PROXIED="$2"; shift 2 ;;
            --ttl) [[ $# -ge 2 ]] || die "$1 缺少参数"; CF_TTL="$2"; shift 2 ;;
            --config) [[ $# -ge 2 ]] || die "$1 缺少参数"; CONFIG_FILE="$2"; shift 2 ;;
            --install-cron) INSTALL_CRON=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数: $1（使用 --help 查看帮助）" ;;
        esac
    done
}

main() {
    parse_args "$@"
    [[ -z "$CONFIG_FILE" ]] || load_config "$CONFIG_FILE"
    if (( INSTALL_CRON )); then
        install_cron
    else
        run_once
    fi
}

main "$@"

