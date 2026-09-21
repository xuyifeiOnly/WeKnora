#!/bin/bash
# ============================================================================
# 03 生成 / 校正 .env 配置
#
# 作用:
#   1) .env 不存在时从 .env.example 创建
#   2) 生成安全密钥与数据库密码（为空或仍是示例默认值时）
#   3) 按服务器内存自动写入并发调优参数
#   4) 写入 npm 镜像源（加速前端构建）
#
# 幂等: 是。已存在的密钥不会被覆盖，除非显式加 --rotate。
#
# 使用:
#   ./start_sh/03-config-env.sh              # 常规执行
#   ./start_sh/03-config-env.sh --rotate     # 强制重新生成全部密钥（危险）
#
# ⚠️  --rotate 会生成新的 SYSTEM_AES_KEY：数据库中已用旧密钥加密的
#     模型 API Key / 凭证将无法解密，仅限首次部署或确实需要轮换时使用。
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

ROTATE=0
for arg in "$@"; do
    case "$arg" in
        --rotate) ROTATE=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) log_warn "未知参数: $arg" ;;
    esac
done

cd "$PROJECT_ROOT"

# ---------- 1. 确保 .env 存在 ----------
log_step "准备 .env"
if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$PROJECT_ROOT/.env.example" ]; then
        cp "$PROJECT_ROOT/.env.example" "$ENV_FILE"
        log_success "已从 .env.example 创建 .env"
    else
        log_error "缺少 .env.example，无法创建 .env"
        exit 1
    fi
else
    log_success ".env 已存在，将只补齐缺失/非法的项"
fi

[ "$ROTATE" -eq 1 ] && log_warn "已启用 --rotate：将重新生成全部密钥"

# ---------- 2. 密钥与密码 ----------
log_step "生成密钥与数据库密码"

gen_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# 弱默认值判定（.env.example 中的原始值）
is_weak() {
    case "$1" in
        ""|"postgres123!@#"|"redis123!@#"|"password"|"changeme") return 0 ;;
        *) return 1 ;;
    esac
}

ensure_key() {
    local key="$1" len="$2" label="$3" current
    current="$(env_value "$key")"
    if [ "$ROTATE" -eq 1 ] || is_weak "$current"; then
        set_env "$key" "$(gen_hex "$len")" || exit 1
        log_success "${label} (${key}) 已生成"
    else
        log_info "${label} (${key}) 已存在，保持不变"
        log_tip "如需重新生成: ./start_sh/03-config-env.sh --rotate"
    fi
}

ensure_key JWT_SECRET           32 "登录令牌签名密钥"
ensure_key SYSTEM_AES_KEY       16 "敏感字段加密主密钥"
ensure_key SYSTEM_SIGNING_KEY   32 "直链签名密钥"
ensure_key DB_PASSWORD          16 "数据库密码"
ensure_key REDIS_PASSWORD       16 "Redis 密码"

# ---------- 3. 按内存写入并发调优 ----------
log_step "按服务器内存写入调优参数"

MEM_TOTAL_MB="$(total_mem_mb)"
MEM_GB=$((MEM_TOTAL_MB / 1024))
echo "      检测到内存: ${MEM_GB} GB (${MEM_TOTAL_MB} MB)"

if [ "$MEM_TOTAL_MB" -lt 5000 ]; then
    PROFILE="低内存（< 5 GB）"
    set_env DOCREADER_GRPC_MAX_WORKERS 1
    set_env DOCREADER_PDF_RENDER_MAX_WORKERS 1
    set_env DOCREADER_PDF_RENDER_PARALLELISM 1
    set_env DOCREADER_MARKITDOWN_MAX_WORKERS 1
    set_env WEKNORA_ASYNQ_CORE_CONCURRENCY 2
    set_env WEKNORA_ASYNQ_POSTPROCESS_CONCURRENCY 1
    set_env WEKNORA_ASYNQ_ENRICHMENT_CONCURRENCY 4
    set_env WEKNORA_MODEL_MAX_CONCURRENCY 8
    set_env MAX_FILE_SIZE_MB 20
elif [ "$MEM_TOTAL_MB" -lt 8000 ]; then
    PROFILE="中等内存（5~8 GB）"
    set_env DOCREADER_GRPC_MAX_WORKERS 2
    set_env DOCREADER_PDF_RENDER_MAX_WORKERS 1
    set_env DOCREADER_PDF_RENDER_PARALLELISM 2
    set_env WEKNORA_ASYNQ_CORE_CONCURRENCY 4
    set_env WEKNORA_ASYNQ_ENRICHMENT_CONCURRENCY 8
    set_env WEKNORA_MODEL_MAX_CONCURRENCY 16
    set_env MAX_FILE_SIZE_MB 50
else
    PROFILE="充足内存（>= 8 GB），使用默认配置"
fi
log_success "调优档位: ${PROFILE}"

# 前端构建镜像源
if [ -z "$(env_value NPM_REGISTRY)" ]; then
    set_env NPM_REGISTRY "https://registry.npmmirror.com"
    log_success "NPM_REGISTRY 已设置为 npmmirror"
fi

# ---------- 4. 关键项确认 ----------
log_step "关键配置确认"

printf "      %-42s %s\n" "FRONTEND_PORT（访问端口）"   "$(env_value FRONTEND_PORT)"
printf "      %-42s %s\n" "APP_PORT（API 端口）"        "$(env_value APP_PORT)"
printf "      %-42s %s\n" "DISABLE_REGISTRATION"       "$(env_value DISABLE_REGISTRATION)"
printf "      %-42s %s\n" "BOOTSTRAP_SYSTEM_ADMIN_EMAIL" "$(env_value WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL)"
printf "      %-42s %s\n" "WEKNORA_VERSION（镜像版本）"  "$(env_value WEKNORA_VERSION)"
printf "      %-42s %s\n" "TZ"                          "$(env_value TZ)"

echo ""
log_warn "请立即备份以下密钥（尤其 SYSTEM_AES_KEY，丢失后加密数据不可恢复）："
echo ""
grep -E '^(JWT_SECRET|SYSTEM_AES_KEY|SYSTEM_SIGNING_KEY|DB_PASSWORD|REDIS_PASSWORD)=' "$ENV_FILE" | sed 's/^/      /'
echo ""
log_tip "建议另存到密码管理器，不要只留在服务器上"

# ---------- 5. 注册开关提示 ----------
echo ""
if [ "$(env_value DISABLE_REGISTRATION)" = "true" ]; then
    log_warn "当前已关闭注册（DISABLE_REGISTRATION=true）"
    log_tip "初始化首个管理员前需临时改为 false，06-init-admin.sh 会自动处理"
fi

log_step "配置完成"
echo ""
echo "  下一步: ./start_sh/04-build-images.sh"
