#!/bin/bash
# ============================================================================
# 部署时初始化系统管理员（幂等，可重复执行）
#
# 用法:
#   ./scripts/init-admin.sh <邮箱> <用户名> <密码>
#
# 示例:
#   ./scripts/init-admin.sh admin@rutang.cn admin 'Rutang@2026'
#
# 背景:
#   WeKnora 没有"用环境变量直接预置管理员账号密码"的机制。
#   WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL 只对【已存在】的用户提权，
#   它不建号、不含密码，且仅在启动时、且系统管理员数为 0 时执行一次。
#
#   因此本脚本按官方流程自动完成三步：
#     1) 调用注册接口创建账号（要求注册功能处于开启状态）
#     2) 把邮箱写入 .env 的 WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL
#     3) 重启 app 触发提权，并校验结果
#
#   脚本结束后请按提示把 DISABLE_REGISTRATION 改为 true。
# ============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { printf "%b\n" "${BLUE}[INFO]${NC} $1"; }
log_success() { printf "%b\n" "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { printf "%b\n" "${YELLOW}[WARN]${NC} $1"; }
log_error()   { printf "%b\n" "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ---------- 参数校验 ----------
if [ $# -ne 3 ]; then
    log_error "参数不足"
    echo "用法: $0 <邮箱> <用户名> <密码>"
    echo "示例: $0 admin@rutang.cn admin 'Rutang@2026'"
    exit 1
fi

ADMIN_EMAIL="$1"
ADMIN_USERNAME="$2"
ADMIN_PASSWORD="$3"

# ---------- 环境检查 ----------
if [ ! -f .env ]; then
    log_error ".env 不存在，请先 cp .env.example .env 并完成配置"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    log_error "未安装 curl"
    exit 1
fi

COMPOSE_BIN="docker"
COMPOSE_SUB="compose"
if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_BIN="docker-compose"
        COMPOSE_SUB=""
    else
        log_error "未检测到 Docker Compose"
        exit 1
    fi
fi

compose() {
    if [ -n "$COMPOSE_SUB" ]; then
        "$COMPOSE_BIN" "$COMPOSE_SUB" "$@"
    else
        "$COMPOSE_BIN" "$@"
    fi
}

# 读取 .env 中的单值变量
# 需处理三种写法：KEY=value / KEY=value # 行内注释 / KEY="value"
# （Compose 自身支持行内注释，脚本必须做同样的剥离，否则端口等值会带上注释文本）
env_value() {
    local key="$1"
    local val
    val="$(grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2-)"
    # 去掉行尾 CR
    val="$(printf '%s' "$val" | tr -d '\r')"
    # 去掉首尾空白
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    # 未加引号的值：剥离 " # 注释" 部分
    case "$val" in
        \"*)
            val="$(printf '%s' "$val" | sed -E 's/^"//; s/"[[:space:]]*$//')"
            ;;
        \'*)
            val="$(printf '%s' "$val" | sed -E "s/^'//; s/'[[:space:]]*\$//")"
            ;;
        *)
            val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//')"
            val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+$//')"
            ;;
    esac
    printf '%s' "$val"
}

APP_PORT="$(env_value APP_PORT)"
APP_PORT="${APP_PORT:-8080}"
DB_NAME="$(env_value DB_NAME)"
DB_NAME="${DB_NAME:-WeKnora}"
DB_USER="$(env_value DB_USER)"
DB_USER="${DB_USER:-postgres}"
BASE_URL="http://127.0.0.1:${APP_PORT}"

log_info "项目目录: $PROJECT_ROOT"
log_info "后端地址: $BASE_URL"

# ---------- 等待 app 就绪 ----------
log_info "等待 app 服务就绪..."
ready=0
for _ in $(seq 1 30); do
    if curl -sf --max-time 3 "${BASE_URL}/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 3
done
if [ "$ready" -ne 1 ]; then
    log_error "app 未在 90 秒内就绪，请先确认服务已启动：docker compose ps"
    exit 1
fi
log_success "app 已就绪"

# ---------- 步骤 1: 创建账号 ----------
log_info "步骤 1/3 创建账号 ${ADMIN_EMAIL} ..."

register_resp="$(curl -s -w '\n%{http_code}' --max-time 20 \
    -X POST "${BASE_URL}/api/v1/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USERNAME}\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}" \
    2>/dev/null || printf '\n000')"

register_code="$(printf '%s' "$register_resp" | tail -1)"
register_body="$(printf '%s' "$register_resp" | sed '$d')"

if [ "$register_code" = "200" ] || [ "$register_code" = "201" ]; then
    log_success "账号创建成功"
elif printf '%s' "$register_body" | grep -qi 'exist'; then
    log_warn "账号已存在，跳过创建（密码以既有账号为准）"
elif printf '%s' "$register_body" | grep -qi 'invite-only\|invite only'; then
    log_error "注册功能已关闭，无法创建账号"
    echo ""
    echo "请先把 .env 中的注册开关打开后重试："
    echo "    DISABLE_REGISTRATION=false"
    echo "    docker compose up -d app"
    echo ""
    echo "（脚本执行完毕后再改回 true）"
    exit 1
else
    log_error "创建账号失败 (HTTP ${register_code})"
    printf '%s\n' "$register_body"
    exit 1
fi

# ---------- 步骤 2: 配置 bootstrap 邮箱并重启 ----------
log_info "步骤 2/3 配置管理员提权并重启 app ..."

current_bootstrap="$(env_value WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL)"
if [ "$current_bootstrap" = "$ADMIN_EMAIL" ]; then
    log_info "WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL 已是目标邮箱"
else
    # 注意：BSD sed(macOS) 不支持 \s，必须用 POSIX 字符类 [[:space:]]，
    # 否则替换会静默失败（sed 无匹配也返回 0）。
    if grep -qE '^[[:space:]]*#?[[:space:]]*WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL=' .env; then
        sed -i.bak -E "s|^[[:space:]]*#?[[:space:]]*WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL=.*|WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL=${ADMIN_EMAIL}|" .env
        rm -f .env.bak
    else
        printf '\nWEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL=%s\n' "$ADMIN_EMAIL" >> .env
    fi

    # 校验写入结果，避免 sed 静默失败后继续往下走
    written="$(env_value WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL)"
    if [ "$written" != "$ADMIN_EMAIL" ]; then
        log_error ".env 写入失败（当前读到: '${written}'），请手动添加："
        echo "    WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL=${ADMIN_EMAIL}"
        exit 1
    fi
    log_info ".env 已更新 WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL=${ADMIN_EMAIL}"
fi

# 环境变量变更需要重建容器才能生效
log_info "重建并重启 app 容器以触发提权..."
compose up -d app >/dev/null

log_info "等待 app 重新就绪..."
ready=0
for _ in $(seq 1 30); do
    if curl -sf --max-time 3 "${BASE_URL}/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 3
done
if [ "$ready" -ne 1 ]; then
    log_error "app 重启后未就绪，请检查：docker compose logs app --tail=100"
    exit 1
fi

# ---------- 步骤 3: 校验提权结果 ----------
log_info "步骤 3/3 校验管理员权限 ..."

is_admin=""
for _ in $(seq 1 10); do
    is_admin="$(compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT is_system_admin FROM users WHERE email='${ADMIN_EMAIL}' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
    [ "$is_admin" = "t" ] && break
    sleep 2
done

echo ""
if [ "$is_admin" = "t" ]; then
    FRONTEND_PORT_VAL="$(env_value FRONTEND_PORT)"
    FRONTEND_PORT_VAL="${FRONTEND_PORT_VAL:-80}"
    log_success "管理员初始化完成"
    echo ""
    echo "  登录地址: http://<服务器IP>:${FRONTEND_PORT_VAL}"
    echo "  邮箱    : ${ADMIN_EMAIL}"
    echo "  用户名  : ${ADMIN_USERNAME}"
    echo "  密码    : （脚本入参中填写的密码）"
    echo ""
    log_warn "下一步：关闭公开注册"
    echo "    1) 编辑 .env：DISABLE_REGISTRATION=true"
    echo "    2) 生效：docker compose up -d app"
    echo ""
    log_info "之后可在「设置 → 系统管理 → 创建用户」为其他同事分配账号密码，"
    log_info "或用接口 POST /api/v1/system/admin/users/create 创建。"
else
    log_error "提权未生效（is_system_admin 仍为空/假）"
    echo ""
    echo "可能原因："
    echo "  1) 系统中已存在其他系统管理员（bootstrap 只在管理员数为 0 时执行）"
    echo "     查看：docker compose exec postgres psql -U ${DB_USER} -d ${DB_NAME} -c \"SELECT email FROM users WHERE is_system_admin;\"" 
    echo "  2) bootstrap 邮箱未正确写入 .env，或 app 未成功重建"
    echo "  3) 查看提权日志：docker compose logs app | grep -i bootstrap"
    exit 1
fi
