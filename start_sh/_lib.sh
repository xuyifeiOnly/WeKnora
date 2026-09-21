#!/bin/bash
# ============================================================================
# 公共函数库 —— 供 start_sh/ 下各脚本 source 使用，请勿直接执行
# ============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info()    { printf "%b\n" "${BLUE}[INFO]${NC} $1"; }
log_success() { printf "%b\n" "${GREEN}[ OK ]${NC} $1"; }
log_warn()    { printf "%b\n" "${YELLOW}[WARN]${NC} $1"; }
log_error()   { printf "%b\n" "${RED}[FAIL]${NC} $1"; }
log_step()    { printf "\n%b\n" "${GREEN}==> $1${NC}"; }
log_tip()     { printf "%b\n" "     ${BLUE}↳${NC} $1"; }

# 项目根目录（start_sh 的上一级）
_START_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_START_SH_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# 非 root 用户时使用 sudo（root 下为空）
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# 读取 .env 中的变量值
# 需处理：KEY=value / KEY=value # 行内注释 / KEY="value"
# （Compose 支持行内注释，脚本必须同样剥离，否则端口等值会带上注释文本）
# 注意：sed 一律使用 POSIX 字符类 [[:space:]]，因为 BSD sed 不支持 \s
# ---------------------------------------------------------------------------
env_value() {
    local key="$1" val
    [ -f "$ENV_FILE" ] || { printf ''; return 0; }
    val="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    val="$(printf '%s' "$val" | tr -d '\r')"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$val" in
        \"*) val="$(printf '%s' "$val" | sed -E 's/^"//; s/"[[:space:]]*$//')" ;;
        \'*) val="$(printf '%s' "$val" | sed -E "s/^'//; s/'[[:space:]]*\$//")" ;;
        *)   val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//')"
             val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+$//')" ;;
    esac
    printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# 写入/更新 .env 中的变量（行不存在则追加，带写入校验）
# ---------------------------------------------------------------------------
set_env() {
    local key="$1" val="$2"
    if [ -f "$ENV_FILE" ] && grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$ENV_FILE"; then
        sed -i.bak -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${val}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
    if [ "$(env_value "$key")" != "$val" ]; then
        log_error ".env 写入 ${key} 失败"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# docker compose 包装（兼容 docker compose v2 与 docker-compose v1）
# ---------------------------------------------------------------------------
DC_BIN="docker"; DC_SUB="compose"
if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then
        DC_BIN="docker-compose"; DC_SUB=""
    fi
fi
compose() {
    if [ -n "$DC_SUB" ]; then
        "$DC_BIN" "$DC_SUB" "$@"
    else
        "$DC_BIN" "$@"
    fi
}

# ---------------------------------------------------------------------------
# 轮询等待 URL 返回期望状态码
# 用法: wait_http <url> [期望码=200] [重试次数=40] [名称]
# ---------------------------------------------------------------------------
wait_http() {
    local url="$1" expect="${2:-200}" tries="${3:-40}" label="${4:-服务}"
    local i code
    for i in $(seq 1 "$tries"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || echo 000)"
        if [ "$code" = "$expect" ]; then
            log_success "${label} 就绪 (${url})"
            return 0
        fi
        sleep 3
    done
    log_error "${label} 未就绪 (${url})，最后状态码: ${code}"
    return 1
}

# 依赖检查
require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "未安装 Docker，请先安装"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 服务未运行或当前用户无权限"
        log_tip "尝试: systemctl start docker  或  usermod -aG docker \$USER 后重新登录"
        exit 1
    fi
}

require_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        log_error ".env 不存在，请先执行: ./start_sh/03-config-env.sh"
        exit 1
    fi
}

# 当前主机总内存（MB）
total_mem_mb() {
    if [ -r /proc/meminfo ]; then
        awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo
    else
        printf '0'
    fi
}
