# 服务器部署脚本（按顺序执行）

一套用于 **Linux 服务器首次部署** 的脚本，覆盖从环境自检到验证的完整流程。
每个脚本职责单一、可重复执行，出问题时可单独重跑某一步。

---

## 使用顺序与作用

| 顺序 | 脚本 | 作用 | 需要 sudo | 预计耗时 |
|:---:|------|------|:---:|:---:|
| ① | `01-check-env.sh` | **环境自检**：Docker 版本、CPU/内存/磁盘、端口占用、Docker Hub 连通性、历史容器残留（只读，不改任何配置） | 否 | 10 秒 |
| ② | `02-prepare-host.sh` | **宿主机准备**：配置 Docker 镜像加速器（国内必需）、内存不足时创建 4 GB swap | **是** | 1~2 分钟 |
| ③ | `03-config-env.sh` | **生成 .env**：创建配置文件、生成密钥与数据库密码、按内存自动写入并发调优、设置 npm 镜像源 | 否 | 10 秒 |
| ④ | `04-build-images.sh` | **拉镜像 + 构建前端**：`pull` 基础镜像，再用本地源码构建定制前端（品牌定制的关键步骤） | 否 | 5~20 分钟 |
| ⑤ | `05-start.sh` | **启动服务**：按依赖顺序启动 5 个核心容器，并轮询等待健康检查通过 | 否 | 1~3 分钟 |
| ⑥ | `06-init-admin.sh` | **初始化管理员**：临时开启注册 → 创建账号并提权 → 关闭注册 | 否 | 1~2 分钟 |
| ⑦ | `07-verify.sh` | **部署验证**：容器健康、接口可用、注册已关闭、品牌已生效、管理员存在 | 否 | 30 秒 |

> `_lib.sh` 是公共函数库，**不要直接执行**，由其他脚本自动加载。

---

## 快速开始

```bash
cd /opt/weknora

# 一次性赋权
chmod +x start_sh/*.sh scripts/*.sh

# 按顺序执行（建议逐步执行并查看输出）
./start_sh/01-check-env.sh
./start_sh/02-prepare-host.sh
./start_sh/03-config-env.sh
./start_sh/04-build-images.sh
./start_sh/05-start.sh
./start_sh/06-init-admin.sh
./start_sh/07-verify.sh
```

全部完成后，浏览器访问 **`http://<服务器IP>:9008`**（端口取自 `.env` 的 `FRONTEND_PORT`）。

---

## 各脚本可选参数

```bash
# 只做 swap，不动 Docker 配置
./start_sh/02-prepare-host.sh --skip-mirror

# 强制重新生成全部密钥（⚠️ 会破坏已加密数据，仅首次部署可用）
./start_sh/03-config-env.sh --rotate

# 镜像已就绪，只重新构建前端
./start_sh/04-build-images.sh --skip-pull

# 启动时附加组件（低内存服务器慎用）
./start_sh/05-start.sh --profile neo4j

# 非交互方式初始化管理员
./start_sh/06-init-admin.sh --email admin@rutang.cn --username admin --password 'YourPass@123'

# 结束后保留注册开关（不自动关闭）
./start_sh/06-init-admin.sh --keep-registration

# 验证时附带登录测试
./start_sh/07-verify.sh --login admin@rutang.cn --password 'YourPass@123'
```

---

## 三个关键注意点

**1. 顺序不能乱**

`04-build-images.sh` 内部固定为「先 `pull` 再 `build frontend`」。
因为两者都打 `weknora-ui:latest` 标签，顺序反了定制品牌会被官方镜像覆盖。

**2. 密钥必须另行备份**

`03-config-env.sh` 生成的 `SYSTEM_AES_KEY` 用于加密数据库中保存的模型 API Key。
**丢失后这些数据无法恢复**，请另存到密码管理器，不要只留在服务器上。

**3. 内存不足的服务器会自动降配**

`03-config-env.sh` 会读取 `/proc/meminfo` 自动选择并发档位：

| 内存 | 策略 |
|------|------|
| < 5 GB | 最低并发 + 单文件上限 20 MB（必须配合 swap） |
| 5 ~ 8 GB | 中等并发 |
| ≥ 8 GB | 使用默认配置 |

---

## 常见问题

**Q: 提示 `permission denied` 连接 Docker**
```bash
sudo usermod -aG docker $USER   # 之后需重新登录
```

**Q: 04 步骤镜像拉取失败**
```bash
# 检查加速器配置
cat /etc/docker/daemon.json
# 手动测试
docker pull redis:7.0-alpine
# 若全部加速站不可用，改用本地导出镜像再上传：
#   docker save wechatopenai/weknora-app:latest | gzip > app.tar.gz
#   scp app.tar.gz server:/tmp/ && docker load < /tmp/app.tar.gz
```

**Q: 06 步骤提示"注册功能已关闭"**
脚本会自动临时开启注册，正常不会遇到。若手动执行 `scripts/init-admin.sh` 遇到，
说明此时注册为关闭状态，请先执行本目录的 `06-init-admin.sh`。

**Q: 页面仍是 WeKnora 默认品牌**
漏了前端构建。执行：
```bash
./start_sh/04-build-images.sh --skip-pull
docker compose up -d frontend
```

**Q: 服务反复重启 / 被 OOM Kill**
```bash
docker inspect WeKnora-docreader | grep -i oom
# 确认 swap 已启用
free -h
# 降低并发后重启
docker compose restart app
```

**Q: 想重新开始**
```bash
docker compose down        # 停容器（保留数据）
docker compose down -v     # ⚠️ 连数据卷一起删除，数据不可恢复
```

---

## 部署后常用命令

```bash
docker compose ps                      # 状态
docker compose logs -f app             # 后端日志
docker compose restart app             # 重启后端
docker compose stop                    # 停止全部
docker compose up -d                   # 重新启动
```
