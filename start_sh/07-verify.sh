#!/bin/bash
# ============================================================================
# 07 部署验证（只读）
#
# 作用:
#   端到端确认部署结果：容器健康、后端接口、前端可达、
#   注册已关闭、品牌是否生效。
#
# 使用:
#   ./start_sh/07-verify.sh
#
# 可选:
#   ./start_sh/07-verify.sh --login admin@rutang.cn --password 'xxx'
#       额外的登录验证，确认账号可正常登录
# ============================================================================

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

cd "$PROJECT_ROOT"
require_env_file

LOGIN_EMAIL=""; LOGIN_PASSWORD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --login)    LOGIN_EMAIL="${2:-}"; shift 2 ;;
        --password) LOGIN_PASSWORD="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
        *) log_warn "未知参数: $1"; shift ;;
    esac
done

FE_PORT="$(env_value FRONTEND_PORT)"; FE_PORT="${FE_PORT:-80}"
API_PORT="$(env_value APP_PORT)";     API_PORT="${API_PORT:-8080}"
DB_NAME="$(env_value DB_NAME)";       DB_NAME="${DB_NAME:-WeKnora}"
DB_USER="$(env_value DB_USER)";       DB_USER="${DB_USER:-postgres}"
API="http://127.0.0.1:${API_PORT}"

PASS=0; FAIL=0
ok()   { log_success "$1"; PASS=$((PASS + 1)); }
bad()  { log_error   "$1"; FAIL=$((FAIL + 1)); }

log_step "部署验证（前端 :${FE_PORT} / 后端 :${API_PORT}）"

# ---------- 0. 等待健康检查稳定 ----------
# 刚重建的容器 healthcheck 处于 starting 阶段（start_period 约 60s），
# 此时直接读状态会误报为异常；先等其收敛为 healthy 再检查。
log_info "等待容器健康检查稳定..."
for svc in app docreader postgres; do
    for _ in $(seq 1 30); do
        st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "WeKnora-${svc}" 2>/dev/null || echo unknown)"
        [ "$st" = "healthy" ] && break
        sleep 3
    done
done

# ---------- 1. 容器状态 ----------
log_info "[1/6] 容器状态"
for svc in app docreader postgres frontend; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "WeKnora-${svc}"; then
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "WeKnora-${svc}" 2>/dev/null)"
        if [ "$health" = "healthy" ] || [ "$health" = "running" ]; then
            ok "WeKnora-${svc} 运行中 (${health})"
        else
            bad "WeKnora-${svc} 状态异常 (${health})"
        fi
    else
        bad "WeKnora-${svc} 未运行"
    fi
done

# ---------- 2. 后端接口 ----------
log_info "[2/6] 后端健康检查"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${API}/health" 2>/dev/null || echo 000)"
[ "$code" = "200" ] && ok "GET /health → 200" || bad "GET /health → ${code}"

# ---------- 3. 注册状态 ----------
log_info "[3/6] 注册开关"
cfg="$(curl -s --max-time 5 "${API}/api/v1/auth/config" 2>/dev/null || true)"
if printf '%s' "$cfg" | grep -q 'invite_only'; then
    ok "registration_mode=invite_only（注册已关闭）"
elif printf '%s' "$cfg" | grep -q 'self_serve'; then
    bad "registration_mode=self_serve（注册仍开启）"
    log_tip "关闭方式: sed -i 's|^#\\?DISABLE_REGISTRATION=.*|DISABLE_REGISTRATION=true|' .env && docker compose up -d app"
else
    bad "无法获取 /auth/config"
fi

# 实际尝试注册（应被拒绝）
reg_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -X POST "${API}/api/v1/auth/register" -H 'Content-Type: application/json' \
    -d '{"username":"verify_probe","email":"verify_probe@example.com","password":"Probe@12345"}' 2>/dev/null || echo 000)"
if [ "$reg_code" = "403" ]; then
    ok "注册请求被拒绝（HTTP 403）"
elif [ "$reg_code" = "200" ] || [ "$reg_code" = "201" ]; then
    bad "注册请求被接受（HTTP ${reg_code}）—— 注册未关闭！"
else
    log_warn "注册探测返回 HTTP ${reg_code}（非预期但未必是问题）"
fi

# ---------- 4. 前端 ----------
log_info "[4/6] 前端可达性"
fe_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${FE_PORT}/" 2>/dev/null || echo 000)"
[ "$fe_code" = "200" ] && ok "GET / → 200" || bad "GET / → ${fe_code}"
log_tip "浏览器访问 http://<服务器IP>:${FE_PORT}"

# 品牌校验（页面标题）
title="$(curl -s --max-time 5 "http://127.0.0.1:${FE_PORT}/" 2>/dev/null | grep -oE '<title>[^<]*</title>' | head -1)"
case "$title" in
    *如棠*|*Rutang*) ok "前端标题已品牌化: ${title}" ;;
    "")              log_warn "未取到页面标题（前端可能仍在加载）" ;;
    *)               bad "前端标题仍为默认品牌: ${title} —— 是否漏执行 build frontend？" ;;
esac

# ---------- 5. 管理员 ----------
log_info "[5/6] 管理员账号"
admin_count="$(compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT count(*) FROM users WHERE is_system_admin = true;" 2>/dev/null | tr -d '[:space:]')"
if [ "${admin_count:-0}" -ge 1 ] 2>/dev/null; then
    ok "系统管理员数量: ${admin_count}"
    compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT '        ' || email FROM users WHERE is_system_admin = true;" 2>/dev/null || true
else
    bad "未找到系统管理员 —— 请执行 ./start_sh/06-init-admin.sh"
fi

# 可选：登录验证
if [ -n "$LOGIN_EMAIL" ] && [ -n "$LOGIN_PASSWORD" ]; then
    resp="$(curl -s --max-time 10 -X POST "${API}/api/v1/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"${LOGIN_EMAIL}\",\"password\":\"${LOGIN_PASSWORD}\"}" 2>/dev/null || true)"
    if printf '%s' "$resp" | grep -q '"success":true'; then
        ok "登录验证通过 (${LOGIN_EMAIL})"
    else
        bad "登录验证失败 (${LOGIN_EMAIL})"
    fi
fi

# ---------- 6. 资源占用 ----------
log_info "[6/6] 资源占用"
docker stats --no-stream --format '      {{.Name}}  内存 {{.MemUsage}}  CPU {{.CPUPerc}}' 2>/dev/null || true
df -h "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print "      磁盘可用: " $4 " / " $2}' || true

# ---------- 汇总 ----------
log_step "验证结果"
echo ""
if [ "$FAIL" -eq 0 ]; then
    log_success "全部通过（${PASS} 项）"
else
    log_error "通过 ${PASS} 项，失败 ${FAIL} 项"
fi
echo ""
echo "  常用运维命令:"
echo "    查看状态: docker compose ps"
echo "    查看日志: docker compose logs -f app"
echo "    停止服务: docker compose stop"
echo "    重启服务: docker compose restart app"
