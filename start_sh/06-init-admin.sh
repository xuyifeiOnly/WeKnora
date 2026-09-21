#!/bin/bash
# ============================================================================
# 06 初始化系统管理员（并自动关闭公开注册）
#
# 作用:
#   项目没有"用环境变量直接预置管理员密码"的机制，
#   WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL 只对【已存在】用户提权，不建号、不含密码。
#   因此本脚本按官方三步流程自动完成：
#     1) 临时开启注册（DISABLE_REGISTRATION=false）并重启 app
#     2) 调用 scripts/init-admin.sh 建号并重启提权
#     3) 关闭注册（DISABLE_REGISTRATION=true）并重启 app
#
# 幂等: 是。账号已存在时不会重复创建。
#
# 使用:
#   ./start_sh/06-init-admin.sh
#   ./start_sh/06-init-admin.sh --email admin@rutang.cn --username admin --password 'YourPass@123'
#   ./start_sh/06-init-admin.sh --keep-registration    # 结束后不关闭注册
#
# 前置: 必须先执行 05-start.sh，且服务健康
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

cd "$PROJECT_ROOT"
require_docker
require_env_file

EMAIL="$(env_value WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL)"
USERNAME="admin"
PASSWORD=""
KEEP_REG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --email)             EMAIL="${2:-}"; shift 2 ;;
        --username)          USERNAME="${2:-}"; shift 2 ;;
        --password)          PASSWORD="${2:-}"; shift 2 ;;
        --keep-registration) KEEP_REG=1; shift ;;
        -h|--help)           sed -n '2,22p' "$0"; exit 0 ;;
        *) log_warn "未知参数: $1"; shift ;;
    esac
done

if [ ! -x "$PROJECT_ROOT/scripts/init-admin.sh" ]; then
    log_error "缺少 scripts/init-admin.sh"
    log_tip "请确认代码完整：ls scripts/init-admin.sh && chmod +x scripts/*.sh"
    exit 1
fi

# ---------- 采集信息 ----------
[ -z "$EMAIL" ] && { read -r -p "管理员邮箱: " EMAIL; }
if [ -z "$PASSWORD" ]; then
    read -rs -p "管理员密码: " PASSWORD; echo ""
    read -rs -p "确认密码  : " PASSWORD2; echo ""
    if [ "$PASSWORD" != "$PASSWORD2" ]; then
        log_error "两次输入的密码不一致"
        exit 1
    fi
fi
if [ -z "$PASSWORD" ]; then
    log_error "密码不能为空"
    exit 1
fi

echo ""
echo "      邮箱  : ${EMAIL}"
echo "      用户名: ${USERNAME}"
echo "      密码  : （已隐藏，长度 ${#PASSWORD}）"
echo ""

# ---------- 步骤 1: 临时开启注册 ----------
log_step "步骤 1/3 临时开启注册"
CURRENT_REG="$(env_value DISABLE_REGISTRATION)"
if [ "$CURRENT_REG" = "true" ]; then
    set_env DISABLE_REGISTRATION false || exit 1
    log_info "DISABLE_REGISTRATION 已临时设为 false"
    compose up -d app >/dev/null 2>&1 || true
    log_info "等待 app 重启..."
    API_PORT="$(env_value APP_PORT)"; API_PORT="${API_PORT:-8080}"
    wait_http "http://127.0.0.1:${API_PORT}/health" 200 30 "后端 app" || exit 1
else
    log_info "注册已处于开启状态，无需调整"
fi

# ---------- 步骤 2: 建号并提权 ----------
log_step "步骤 2/3 创建账号并提权"
if ! "$PROJECT_ROOT/scripts/init-admin.sh" "$EMAIL" "$USERNAME" "$PASSWORD"; then
    log_error "管理员初始化失败"
    log_tip "注册开关已保持开启，修复后可重跑本脚本"
    exit 1
fi

# ---------- 步骤 3: 关闭注册 ----------
if [ "$KEEP_REG" -eq 1 ]; then
    log_step "步骤 3/3 保留注册开关（--keep-registration）"
    log_warn "注册功能仍处于开启状态"
    echo "        如需关闭: sed -i 's|^#\\?DISABLE_REGISTRATION=.*|DISABLE_REGISTRATION=true|' .env && docker compose up -d app"
else
    log_step "步骤 3/3 关闭公开注册"
    set_env DISABLE_REGISTRATION true || exit 1
    compose up -d app >/dev/null 2>&1 || true

    API_PORT="$(env_value APP_PORT)"; API_PORT="${API_PORT:-8080}"
    if wait_http "http://127.0.0.1:${API_PORT}/health" 200 30 "后端 app"; then
        mode="$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/api/v1/auth/config" 2>/dev/null || true)"
        if printf '%s' "$mode" | grep -q 'invite_only'; then
            log_success "注册已关闭（registration_mode=invite_only）"
        else
            log_warn "未能确认注册状态，请手动检查："
            echo "        curl http://127.0.0.1:${API_PORT}/api/v1/auth/config"
        fi
    fi
fi

# ---------- 完成 ----------
FE_PORT="$(env_value FRONTEND_PORT)"; FE_PORT="${FE_PORT:-80}"
log_step "管理员初始化完成"
echo ""
echo "      登录地址: http://<服务器IP>:${FE_PORT}"
echo "      邮箱    : ${EMAIL}"
echo "      用户名  : ${USERNAME}"
echo ""
log_info "后续为其他同事开通账号："
log_tip "登录 →「设置 → 系统管理 → 创建用户」填写用户名/邮箱/密码"
echo ""
echo "  下一步: ./start_sh/07-verify.sh"
