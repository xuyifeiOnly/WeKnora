#!/bin/bash
# ============================================================================
# 02 宿主机准备（需要 sudo）
#
# 作用:
#   1) 配置 Docker 镜像加速器 —— 国内服务器无法直连 Docker Hub 时必需
#   2) 创建 swap —— 内存 < 6 GB 时兜底，避免解析文档时被 OOM Kill
#
# 幂等: 是。重复执行不会重复写入配置 / 重复创建 swap。
#
# 使用:
#   ./start_sh/02-prepare-host.sh
#   ./start_sh/02-prepare-host.sh --skip-mirror   # 只做 swap
#   ./start_sh/02-prepare-host.sh --skip-swap     # 只做镜像加速
#
# 注意: 重启 Docker 会短暂中断已有容器（首次部署无影响）
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SKIP_MIRROR=0
SKIP_SWAP=0
for arg in "$@"; do
    case "$arg" in
        --skip-mirror) SKIP_MIRROR=1 ;;
        --skip-swap)   SKIP_SWAP=1 ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) log_warn "未知参数: $arg" ;;
    esac
done

DAEMON_JSON="/etc/docker/daemon.json"
MIRRORS=(
    "https://mirror.ccs.tencentyun.com"
    "https://docker.m.daocloud.io"
    "https://dockerproxy.net"
)

# ---------- 1. Docker 镜像加速 ----------
if [ "$SKIP_MIRROR" -eq 0 ]; then
    log_step "配置 Docker 镜像加速器"

    if [ -f "$DAEMON_JSON" ] && grep -q 'registry-mirrors' "$DAEMON_JSON" 2>/dev/null; then
        log_info "已存在 registry-mirrors 配置，跳过写入"
        log_tip "如需修改请直接编辑: ${DAEMON_JSON}"
    else
        $SUDO mkdir -p /etc/docker
        if [ -f "$DAEMON_JSON" ]; then
            $SUDO cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
            log_info "已备份原配置到 ${DAEMON_JSON}.bak.*"
        fi

        MIRROR_LIST=""
        for m in "${MIRRORS[@]}"; do
            [ -n "$MIRROR_LIST" ] && MIRROR_LIST="${MIRROR_LIST},"
            MIRROR_LIST="${MIRROR_LIST}\"${m}\""
        done

        printf '{\n  "registry-mirrors": [%s]\n}\n' "$MIRROR_LIST" | $SUDO tee "$DAEMON_JSON" >/dev/null
        log_success "已写入 ${DAEMON_JSON}"
        sed 's/^/      /' "$DAEMON_JSON"

        log_info "重启 Docker 服务..."
        $SUDO systemctl daemon-reload 2>/dev/null || true
        if $SUDO systemctl restart docker 2>/dev/null; then
            log_success "Docker 已重启"
            sleep 3
        else
            log_warn "systemctl 不可用，请手动重启 Docker"
        fi
    fi

    # 拉取小镜像验证
    log_info "验证镜像拉取（redis:7.0-alpine）..."
    if docker pull redis:7.0-alpine >/dev/null 2>&1; then
        log_success "镜像拉取正常"
    else
        log_warn "镜像拉取失败，可尝试其他加速地址，或改用离线导入方式"
        log_tip "请在 ${DAEMON_JSON} 中调整 registry-mirrors 后重试"
    fi
fi

# ---------- 2. swap ----------
if [ "$SKIP_SWAP" -eq 0 ]; then
    log_step "检查 swap"

    MEM_TOTAL_MB="$(total_mem_mb)"
    SWAP_TOTAL_MB="$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

    echo "      内存: $((MEM_TOTAL_MB / 1024)) GB    swap: $((SWAP_TOTAL_MB / 1024)) GB"

    if [ "$MEM_TOTAL_MB" -ge 6000 ]; then
        log_success "内存充足（>= 6 GB），无需额外 swap"
    elif [ "$SWAP_TOTAL_MB" -ge 1024 ]; then
        log_success "已有 swap（$((SWAP_TOTAL_MB / 1024)) GB），跳过"
    elif [ -f /swapfile ]; then
        log_warn "/swapfile 已存在但未启用，请检查 /etc/fstab"
    else
        log_info "内存偏低且无 swap，创建 4 GB swap..."
        if $SUDO fallocate -l 4G /swapfile 2>/dev/null \
           && $SUDO chmod 600 /swapfile \
           && $SUDO mkswap /swapfile >/dev/null 2>&1 \
           && $SUDO swapon /swapfile 2>/dev/null; then
            if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
                echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
            fi
            log_success "swap 已启用并写入 /etc/fstab（重启后自动挂载）"
            log_tip "建议同时降低 swappiness: sysctl -w vm.swappiness=10"
        else
            log_error "swap 创建失败（可能是容器内无权限操作 swap）"
            log_tip "若在容器中运行本脚本，请在宿主机上手动创建"
        fi
    fi
fi

log_step "宿主机准备完成"
echo ""
echo "  下一步: ./start_sh/03-config-env.sh"
