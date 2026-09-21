#!/bin/bash
# ============================================================================
# 08 代码更新后重建发布（日常迭代用，非首次部署）
#
# 作用:
#   代码同步到服务器后，按改动范围重建对应镜像并滚动重启容器，
#   避免不必要的大镜像全量重建。
#
# 使用:
#   ./start_sh/08-rebuild.sh              # 默认前端（最常见的改动）
#   ./start_sh/08-rebuild.sh frontend     # 前端：Vue/TS/CSS、品牌文案、页面
#   ./start_sh/08-rebuild.sh app          # 后端：cmd/ internal/ 下的 Go 代码
#   ./start_sh/08-rebuild.sh docreader    # 解析器：docreader/ 下的 Python 代码
#   ./start_sh/08-rebuild.sh all          # 三者全部
#   ./start_sh/08-rebuild.sh --no-cache frontend   # 忽略构建缓存
#
# 只需重启、无需重建的场景:
#   改了 .env            → docker compose up -d          （环境变量变更会自动重建容器）
#   改了 config/config.yaml → docker compose restart app （该文件是 bind mount）
#   改了 docker-compose.yml → docker compose up -d
#
# 前置: 代码已同步到服务器（github 不通时用 rsync/scp，见 README）
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

cd "$PROJECT_ROOT"
require_docker
require_env_file

NO_CACHE=0
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --no-cache) NO_CACHE=1 ;;
        -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
        frontend|app|docreader|all) TARGET="$arg" ;;
        *) log_warn "未知参数: $arg" ;;
    esac
done
TARGET="${TARGET:-frontend}"

case "$TARGET" in
    frontend)  SERVICES="frontend" ;;
    app)       SERVICES="app" ;;
    docreader) SERVICES="docreader" ;;
    all)       SERVICES="frontend app docreader" ;;
esac

BUILD_ARGS=()
[ "$NO_CACHE" -eq 1 ] && BUILD_ARGS+=(--no-cache)

# 构建前端时带上 npm 镜像源
if printf '%s' "$SERVICES" | grep -q frontend; then
    NPM_REGISTRY="$(env_value NPM_REGISTRY)"
    [ -n "$NPM_REGISTRY" ] && BUILD_ARGS+=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")
fi

log_step "重建发布（目标: ${TARGET}）"
echo "      待重建服务: ${SERVICES}"
[ "$NO_CACHE" -eq 1 ] && log_warn "已启用 --no-cache（构建较慢）"
echo ""

# ---------- 1. 构建 ----------
START_TS=$(date +%s)
for svc in $SERVICES; do
    log_info "构建 ${svc} 镜像..."
    if ! compose build "${BUILD_ARGS[@]}" "$svc" 2>&1 | tail -12; then
        log_error "${svc} 镜像构建失败，容器未重启（仍运行旧版本）"
        log_tip "排查: docker compose build ${svc}"
        exit 1
    fi
    log_success "${svc} 镜像构建完成"
done
BUILD_SEC=$(( $(date +%s) - START_TS ))

# ---------- 2. 重启容器 ----------
log_step "重启容器"
# --force-recreate：保证容器一定用新镜像重建。
# 否则当 compose 未能识别出变化（例如镜像 ID 未变、或容器被手动改动过）时，
# 会显示 "Running" 直接跳过，导致发布未生效。
if ! compose up -d --force-recreate $SERVICES 2>&1 | tail -10; then
    log_error "容器重启失败"
    log_tip "查看: docker compose logs --tail=50"
    exit 1
fi

# ---------- 3. 等待就绪 ----------
log_step "等待服务就绪"
API_PORT="$(env_value APP_PORT)";     API_PORT="${API_PORT:-8080}"
FE_PORT="$(env_value FRONTEND_PORT)"; FE_PORT="${FE_PORT:-80}"
FAIL=0

for svc in $SERVICES; do
    case "$svc" in
        app)
            wait_http "http://127.0.0.1:${API_PORT}/health" 200 30 "后端 app" || FAIL=1
            ;;
        frontend)
            wait_http "http://127.0.0.1:${FE_PORT}/" 200 20 "前端 frontend" || FAIL=1
            ;;
        docreader)
            ok=0
            for _ in $(seq 1 30); do
                st="$(docker inspect -f '{{.State.Health.Status}}' WeKnora-docreader 2>/dev/null || echo unknown)"
                [ "$st" = "healthy" ] && { ok=1; break; }
                sleep 3
            done
            if [ "$ok" -eq 1 ]; then
                log_success "docreader healthy"
            else
                log_error "docreader 未进入 healthy 状态"
                FAIL=1
            fi
            ;;
    esac
done

# ---------- 4. 结果 ----------
log_step "发布结果"
compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || compose ps
echo ""
log_info "构建耗时: ${BUILD_SEC} 秒"

if [ "$FAIL" -ne 0 ]; then
    log_error "部分服务未就绪，请检查日志："
    for svc in $SERVICES; do echo "      docker compose logs ${svc} --tail=80"; done
    exit 1
fi

log_success "发布完成"
echo ""
case "$TARGET" in
    frontend) log_tip "前端已更新，浏览器请强制刷新（Ctrl/Cmd + Shift + R）以绕过缓存" ;;
    app)      log_tip "后端已更新，API 立即可用" ;;
esac
