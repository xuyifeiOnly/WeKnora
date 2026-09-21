#!/bin/bash
# ============================================================================
# 04 拉取基础镜像 + 构建定制前端
#
# 作用:
#   docker compose pull          —— 拉取 postgres / redis / app / docreader / ui
#   docker compose build frontend —— 用本地源码构建前端镜像（品牌定制在此生效）
#
# ⚠️ 顺序不可颠倒:
#   pull 会拉取官方 weknora-ui 镜像并覆盖同名 tag，
#   因此必须在 pull 之后再 build frontend，否则页面会退回 WeKnora 默认品牌。
#
# 幂等: 是。镜像已存在时会复用缓存，重复执行很快。
#
# 使用:
#   ./start_sh/04-build-images.sh
#   ./start_sh/04-build-images.sh --skip-pull    # 只构建前端
#
# 预计耗时: 首次 5~20 分钟（取决于网络），后续几分钟
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SKIP_PULL=0
for arg in "$@"; do
    case "$arg" in
        --skip-pull) SKIP_PULL=1 ;;
        -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
        *) log_warn "未知参数: $arg" ;;
    esac
done

cd "$PROJECT_ROOT"
require_docker
require_env_file

NPM_REGISTRY="$(env_value NPM_REGISTRY)"
WEKNORA_VERSION="$(env_value WEKNORA_VERSION)"; WEKNORA_VERSION="${WEKNORA_VERSION:-latest}"
MIRRORS_EXIST=0
[ -f /etc/docker/daemon.json ] && grep -q 'registry-mirrors' /etc/docker/daemon.json 2>/dev/null && MIRRORS_EXIST=1

echo "      镜像版本   : ${WEKNORA_VERSION}"
echo "      npm 源     : ${NPM_REGISTRY:-（默认源）}"
echo "      镜像加速器 : $([ "$MIRRORS_EXIST" -eq 1 ] && echo '已配置' || echo '未配置')"

# ---------- 1. 拉取基础镜像 ----------
if [ "$SKIP_PULL" -eq 0 ]; then
    log_step "拉取基础镜像（postgres / redis / app / docreader / ui）"
    log_tip "首次拉取较大（约 7.5 GB），耗时取决于网络；输出持续滚动即表示正常进行"

    # 不能管道到 tail：会缓冲输出导致过程屏幕全黑，容易被误判为卡死
    if ! compose pull; then
        log_error "镜像拉取失败"
        echo ""
        log_tip "排查方向:"
        echo "        1) 确认已执行 02-prepare-host.sh 配置镜像加速"
        echo "        2) 检查 /etc/docker/daemon.json 中的 registry-mirrors 是否可用"
        echo "        3) 手动测试: docker pull redis:7.0-alpine"
        echo "        4) 全部加速站都不可用时，可改为「本地导出镜像 → 上传 → docker load」"
        exit 1
    fi
    log_success "基础镜像拉取完成"
else
    log_info "已跳过 pull（--skip-pull）"
fi

# ---------- 2. 构建定制前端 ----------
log_step "构建定制前端镜像"
log_warn "这一步会覆盖 pull 下来的官方 ui 镜像 —— 品牌定制依赖此步骤"

BUILD_ARGS=()
[ -n "$NPM_REGISTRY" ] && BUILD_ARGS+=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")

if ! compose build "${BUILD_ARGS[@]}" frontend; then
    log_error "前端镜像构建失败"
    echo ""
    log_tip "常见原因:"
    echo "        1) 网络无法访问 npm 源 → 在 .env 中设置 NPM_REGISTRY=https://registry.npmmirror.com"
    echo "        2) 内存不足（Vite 构建需要 2 GB 以上）→ 可提高 NODE_MAX_OLD_SPACE_SIZE 或加 swap"
    echo "        3) 前端源码不完整 → 确认 frontend/ 目录已完整上传"
    exit 1
fi
log_success "前端镜像构建完成"

# ---------- 3. 汇总 ----------
log_step "镜像清单"
docker images --format '      {{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null \
    | grep -E 'weknora|paradedb|redis' || true

echo ""
log_info "磁盘占用: $(docker system df --format '{{.Type}} {{.Size}}' 2>/dev/null | tr '\n' ' ' || echo 'n/a')"
echo ""
echo "  下一步: ./start_sh/05-start.sh"
