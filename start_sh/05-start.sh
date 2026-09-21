#!/bin/bash
# ============================================================================
# 05 启动服务并等待就绪
#
# 作用:
#   按依赖顺序启动 5 个核心容器（postgres / redis / docreader / app / frontend），
#   并轮询等待 app 健康检查通过，确认服务真正可用。
#
# 幂等: 是。已运行的容器不会重建，仅补齐缺失的。
#
# 使用:
#   ./start_sh/05-start.sh
#
# 需要附加组件时（内存充足情况下）:
#   ./start_sh/05-start.sh --profile neo4j   # 知识图谱
#   ./start_sh/05-start.sh --profile minio   # 对象存储
#   ./start_sh/05-start.sh --full            # 全部（低内存服务器请勿使用）
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --profile) ;;                     # 由下一个参数消费
        --full)    EXTRA_ARGS+=(--profile full) ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *)         EXTRA_ARGS+=("$arg") ;;
    esac
done

cd "$PROJECT_ROOT"
require_docker
require_env_file

FE_PORT="$(env_value FRONTEND_PORT)"; FE_PORT="${FE_PORT:-80}"
API_PORT="$(env_value APP_PORT)";     API_PORT="${API_PORT:-8080}"
MEM_TOTAL_MB="$(total_mem_mb)"

if [ "$MEM_TOTAL_MB" -lt 5000 ] && printf '%s' "${EXTRA_ARGS[*]:-}" | grep -qE 'full|neo4j|milvus|doris'; then
    log_warn "当前内存仅 $((MEM_TOTAL_MB / 1024)) GB，启动附加组件很可能 OOM"
    log_tip "建议仅使用默认核心服务"
fi

# ---------- 1. 启动 ----------
log_step "启动容器"
if ! compose "${EXTRA_ARGS[@]}" up -d; then
    log_error "启动失败"
    log_tip "查看详情: docker compose logs --tail=50"
    exit 1
fi
log_success "容器已启动"

# ---------- 2. 等待就绪 ----------
log_step "等待服务就绪"
log_tip "首次启动需要初始化数据库并执行迁移，约 1~3 分钟"

WAIT_FAIL=0

# 内网服务
for svc in postgres docreader; do
    ok=0
    for _ in $(seq 1 40); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "WeKnora-${svc}" 2>/dev/null || echo unknown)"
        [ "$status" = "healthy" ] && { ok=1; break; }
        sleep 3
    done
    if [ "$ok" -eq 1 ]; then
        log_success "${svc} healthy"
    else
        log_error "${svc} 未进入 healthy 状态"
        WAIT_FAIL=1
    fi
done

# 后端 API
if wait_http "http://127.0.0.1:${API_PORT}/health" 200 40 "后端 app"; then
    :
else
    WAIT_FAIL=1
fi

# 前端
if wait_http "http://127.0.0.1:${FE_PORT}/" 200 20 "前端 frontend"; then
    :
else
    WAIT_FAIL=1
fi

# ---------- 3. 状态汇总 ----------
log_step "容器状态"
compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || compose ps

echo ""
if [ "$WAIT_FAIL" -ne 0 ]; then
    log_error "部分服务未就绪，请检查日志："
    echo "      docker compose logs app --tail=80"
    echo "      docker compose logs docreader --tail=80"
    echo "      docker compose logs postgres --tail=50"
    exit 1
fi

log_success "全部核心服务已就绪"
echo ""
echo "      访问地址:  http://<服务器IP>:${FE_PORT}"
echo "      后端 API:  http://127.0.0.1:${API_PORT}"
echo ""
log_tip "请确认防火墙已放行 ${FE_PORT} 端口"
echo "  下一步: ./start_sh/06-init-admin.sh"
