#!/bin/bash
# ============================================================================
# 01 环境自检（只读，不改动任何配置）
#
# 作用:
#   部署前确认服务器是否具备运行条件：Docker 版本、CPU/内存/磁盘、
#   .env 状态、端口占用、Docker Hub 连通性。
#   全部检查都为只读操作，可以放心反复执行。
#
# 使用:
#   ./start_sh/01-check-env.sh
#
# 是否需要 sudo: 否
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

cd "$PROJECT_ROOT"

log_step "环境自检开始（项目目录: ${PROJECT_ROOT}）"

WARN_COUNT=0
warn() { log_warn "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }

# ---------- 1. 项目文件 ----------
log_info "[1/7] 项目文件"
if [ -f "$PROJECT_ROOT/docker-compose.yml" ]; then
    log_success "docker-compose.yml 存在"
else
    log_error "未找到 docker-compose.yml，请确认代码已完整上传"
    exit 1
fi

if [ -f "$ENV_FILE" ]; then
    log_success ".env 已存在"
else
    warn ".env 不存在，需执行 03-config-env.sh 生成"
fi

# ---------- 2. Docker ----------
log_info "[2/7] Docker 环境"
if ! command -v docker >/dev/null 2>&1; then
    log_error "未安装 Docker"
    exit 1
fi
log_success "Docker: $(docker --version 2>/dev/null | head -1)"

if docker compose version >/dev/null 2>&1; then
    log_success "Compose: $(docker compose version 2>/dev/null | head -1)"
elif command -v docker-compose >/dev/null 2>&1; then
    log_success "Compose: $(docker-compose --version 2>/dev/null | head -1)"
else
    log_error "未检测到 Docker Compose"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    log_error "Docker 服务未运行，或当前用户无权限访问"
    log_tip "启动: systemctl start docker"
    log_tip "授权: usermod -aG docker \$USER && 重新登录"
    exit 1
fi
log_success "Docker 守护进程运行中"

# ---------- 3. 硬件资源 ----------
log_info "[3/7] 硬件资源"
CPU_CORES="$(nproc 2>/dev/null || echo 0)"
MEM_TOTAL_MB="$(total_mem_mb)"
DISK_AVAIL_GB="$(df -BG "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')"
[ -z "$DISK_AVAIL_GB" ] && DISK_AVAIL_GB="0"

echo "      CPU 核心 : ${CPU_CORES}"
echo "      内存总量 : $((MEM_TOTAL_MB / 1024)) GB (${MEM_TOTAL_MB} MB)"
echo "      可用磁盘 : ${DISK_AVAIL_GB} GB"
echo "      架构     : $(uname -m)"

if [ "$MEM_TOTAL_MB" -lt 3800 ]; then
    warn "内存低于 4 GB：解析大文档时可能 OOM，请务必配置 swap（见 02-prepare-host.sh）"
elif [ "$MEM_TOTAL_MB" -lt 7000 ]; then
    warn "内存 4~7 GB：需使用低并发配置（03-config-env.sh 会自动写入）"
else
    log_success "内存充足"
fi

if [ "${DISK_AVAIL_GB:-0}" -lt 20 ]; then
    warn "可用磁盘不足 20 GB：镜像约 7.5 GB + 构建缓存 2~3 GB + 数据增长，建议先清理"
fi

# ---------- 4. 端口 ----------
log_info "[4/7] 端口占用"
FE_PORT="$(env_value FRONTEND_PORT)"; FE_PORT="${FE_PORT:-80}"
API_PORT="$(env_value APP_PORT)";     API_PORT="${API_PORT:-8080}"

check_port() {
    local port="$1" name="$2"
    if command -v ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
            warn "${name} 端口 ${port} 已被占用"
            ss -lntp 2>/dev/null | grep -E "[:.]${port} " | head -3 | sed 's/^/      /'
            return
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
            warn "${name} 端口 ${port} 已被占用"
            return
        fi
    fi
    log_success "${name} 端口 ${port} 可用"
}
echo "      （来自 .env：FRONTEND_PORT=${FE_PORT} / APP_PORT=${API_PORT}）"
check_port "$FE_PORT" "前端"
check_port "$API_PORT" "后端"

# ---------- 5. 网络连通性 ----------
log_info "[5/7] Docker Hub 连通性"
if curl -sI --max-time 8 https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
    log_success "可以访问 Docker Hub"
else
    warn "无法访问 Docker Hub，需要配置镜像加速（见 02-prepare-host.sh）"
fi

if curl -sI --max-time 5 https://registry.npmmirror.com >/dev/null 2>&1; then
    log_success "可以访问 npmmirror（前端构建加速可用）"
else
    warn "无法访问 registry.npmmirror.com，前端构建可能较慢"
fi

# ---------- 6. 已有部署 ----------
log_info "[6/7] 已有部署"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^WeKnora-'; then
    log_warn "检测到已有 WeKnora 容器："
    docker ps -a --filter 'name=WeKnora' --format '      {{.Names}}  {{.Status}}' 2>/dev/null
    log_tip "首次部署通常是历史残留，可执行: docker compose down"
else
    log_success "无历史容器"
fi

# ---------- 7. 汇总 ----------
log_step "自检完成"
if [ "$WARN_COUNT" -eq 0 ]; then
    log_success "所有检查通过，可以继续执行 02-prepare-host.sh"
else
    log_warn "存在 ${WARN_COUNT} 项提醒，请确认后再继续"
fi
echo ""
echo "  下一步: ./start_sh/02-prepare-host.sh"
