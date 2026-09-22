# 本地打包镜像并部署到服务器

> 适用场景：**服务器网络受限或配置较低**，不适合在服务器上构建镜像。
> 做法是在本地（开发机）构建好镜像，导出成压缩包上传，服务器只负责加载和运行。

涉及服务：**app（后端）+ frontend（前端）**。
`docreader` 未做改动，沿用官方镜像，不需要打包。

---

## ⚠️ 最重要的一条：镜像架构必须是 linux/amd64

服务器是 x86_64（amd64），而开发机是 Apple Silicon（M 系列）时，默认构建出来的是 **arm64** 镜像。
**arm64 镜像传到服务器上无法运行**，容器会起不来并报 `exec format error`。

所以本文档所有构建命令都显式指定 `--platform linux/amd64`，
并且打包前后各验证一次架构（见「一」「二」两节）。

> 若开发机本身是 x86_64 的 Linux/Windows，构建结果天然是 amd64，
> 可省略 `--platform`，但仍建议按本文档验证一次架构再上传。

---

## 流程概览

```
本地（Mac 上需交叉构建）                     服务器 (/opt/www/WeKnora)
────────────────────────────────────────    ────────────────────────────
docker buildx build --platform linux/amd64
        ↓
docker save …:amd64 → tmp/*-amd64.tar.gz
        ↓  scp 上传
                                     →     docker load < tmp/*-amd64.tar.gz
                                     →     docker tag …:amd64 …:latest
                                     →     docker compose up -d --force-recreate
                                     →     验证
```

| 镜像 | 架构 | 大小（未压缩） | 压缩后 | 说明 |
|------|------|----------------|--------|------|
| `wechatopenai/weknora-app` | amd64 | 1.68 GB | ≈ 533 MB | 后端 Go 服务 |
| `wechatopenai/weknora-ui` | amd64 | 80 MB | ≈ 30 MB | 前端 nginx + 静态资源 |

---

## 前置条件

**本地（开发机）**
- Docker 正在运行，且支持 buildx 交叉构建（Docker Desktop 默认支持）
- 构建参数（镜像源、代理等）见文末「构建参数」，
  改用 buildx 后需通过 `--build-arg 键=值` 显式传入，不再自动读 `.env`

**服务器**
- Docker 已安装
- 项目目录代码已就位（本示例为 `/opt/www/WeKnora`）
- `.env` 已配置好（端口、数据库密码、密钥等）

> 项目目录名按实际调整。下文统一用 `/opt/www/WeKnora`。

---

## 一、本地构建 amd64 镜像

> 用 `docker buildx build --platform linux/amd64`，**不要**用 `docker compose build`——
> compose 会按当前机器架构构建，在 Mac 上出来的是 arm64。
> 同时统一用 `:amd64` 作为 tag，避免覆盖本地开发用的 arm64 `:latest` 镜像。

### 前端（有品牌 / 界面改动时必做）

```bash
cd /Users/xuyifei_coco/Documents/fork_demo/WeKnora

docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
  -t wechatopenai/weknora-ui:amd64 \
  --load ./frontend
```

- `--provenance=false`：避免生成多平台 manifest 导致 `--load` 失败
- `NPM_REGISTRY`：国内 npm 源，加速 `npm ci`

### 后端（有 Go 代码改动时才需要本地构建）

```bash
cd /Users/xuyifei_coco/Documents/fork_demo/WeKnora

docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  -f docker/Dockerfile.app \
  -t wechatopenai/weknora-app:amd64 \
  --build-arg APK_MIRROR_ARG=mirrors.aliyun.com \
  --build-arg GOPROXY_ARG=https://goproxy.cn \
  --load .
```

> **后端没改过代码**时不必本地构建，直接拉官方 amd64 镜像：
>
> ```bash
> # 先备份本地 arm64 版本，避免被覆盖后开发环境跑不动
> docker tag wechatopenai/weknora-app:latest wechatopenai/weknora-app:arm64
>
> docker pull --platform linux/amd64 wechatopenai/weknora-app:latest
> docker tag wechatopenai/weknora-app:latest wechatopenai/weknora-app:amd64
> ```

### 确认构建结果

```bash
docker images --format '{{.Repository}}:{{.Tag}}  {{.CreatedSince}}  {{.Size}}' | grep weknora
```

输出中的 `CreatedSince` 应是「刚刚」（minutes ago），**不是** `weeks ago`。
如果还是 weeks，说明构建没有真正更新，检查上一步输出。

**再验证架构（关键，别跳过）**：

```bash
for img in wechatopenai/weknora-ui:amd64 wechatopenai/weknora-app:amd64; do
  echo "$img -> $(docker image inspect $img --format '{{.Architecture}}/{{.Os}}')"
done
```

期望两行都是 `amd64/linux`。
**如果出现 `arm64/linux`，不要继续往下走**，检查 `--platform` 参数是否漏了。

---   

## 二、导出镜像包到 `tmp/`

打包命令就是 `docker save <镜像:tag> | gzip > 文件`：

```bash
cd /Users/xuyifei_coco/Documents/fork_demo/WeKnora
mkdir -p tmp

# 后端（1.68 GB → 约 533 MB，导出需 1~3 分钟）
docker save wechatopenai/weknora-app:amd64 | gzip > ./tmp/weknora-app-amd64.tar.gz

# 前端（80 MB → 约 30 MB）
docker save wechatopenai/weknora-ui:amd64 | gzip > ./tmp/weknora-ui-amd64.tar.gz

ls -lh tmp/
```

> **关键**：`docker save` 保存的是该 tag **当前指向的架构**。
> 写 `:amd64` 打出来就是 amd64；写 `:latest` 在 Mac 上打出来是 arm64（就是之前踩过的坑）。
> 文件名统一带 `-amd64` 后缀，避免和 arm64 包混在一起。

**打包后验证包内架构**（只需几秒，强烈建议）：

```bash
cd /Users/xuyifei_coco/Documents/fork_demo/WeKnora/tmp
for f in weknora-app-amd64 weknora-ui-amd64; do
  cfg=$(tar -xzOf $f.tar.gz manifest.json | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Config'])")
  arch=$(tar -xzOf $f.tar.gz "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['architecture'])")
  echo "$f.tar.gz -> $arch"
done
```

期望输出：

```
weknora-app-amd64.tar.gz -> amd64
weknora-ui-amd64.tar.gz -> amd64
```

> `tmp/` 已在 `.gitignore` 中，不会被提交到 git，可放心放几百 MB 的包。
> 部署完成后建议删除，避免占用磁盘：`rm -f tmp/*.tar.gz`

---

## 三、上传到服务器

```bash
cd /Users/xuyifei_coco/Documents/fork_demo/WeKnora

scp tmp/weknora-app-amd64.tar.gz tmp/weknora-ui-amd64.tar.gz root@<服务器IP>:/tmp/
```

上传完成后可删除本地包：

```bash
rm -f tmp/*.tar.gz
```

---

## 四、服务器加载并重启

> **⚠️ 必须先 `cd` 到项目目录**
> `docker compose` 依赖当前目录下的 `docker-compose.yml`，
> 在 `~`（家目录）执行会报 `no configuration file provided: not found`。

```bash
# 1) 进入项目目录（关键：compose 依赖该目录下的 docker-compose.yml）
cd /opt/www/WeKnora

# 2) 加载镜像（包内 tag 为 :amd64）
docker load < /opt/www/docker_gz/tmp/weknora-app-amd64.tar.gz
docker load < /opt/www/docker_gz/tmp/weknora-ui-amd64.tar.gz

# 2.1) 补上 compose 实际引用的 latest tag（docker-compose.yml 里写的是 :latest）
docker tag wechatopenai/weknora-app:amd64 wechatopenai/weknora-app:latest
docker tag wechatopenai/weknora-ui:amd64 wechatopenai/weknora-ui:latest

# 2.2) 确认架构正确（关键，别跳过）
docker image inspect wechatopenai/weknora-app:amd64 wechatopenai/weknora-ui:amd64 \
  --format '{{.RepoTags}} -> {{.Architecture}}/{{.Os}}'
#    期望：amd64 / linux

# 3) 清理上传的包
rm -f /opt/www/docker_gz/tmp/weknora-app-amd64.tar.gz /opt/www/docker_gz/tmp/weknora-ui-amd64.tar.gz

# 4) 确认镜像时间已更新（应为「刚刚」，不再是 weeks ago）
docker images | grep weknora

# 5) 强制重建容器，使用新镜像
docker image prune -f # 清理无用的镜像
cd /opt/www/WeKnora 
docker compose up -d --force-recreate app frontend

# 6) 查看状态与日志
docker compose ps
docker compose logs app --tail=30
```

> `--force-recreate` 是必须的：不加的话 compose 可能认为容器无变化而跳过重建，
> 新镜像就不会生效（表现为"部署了但页面/接口没变"）。

---

## 五、验证部署

```bash
cd /opt/www/WeKnora

# 1) 容器健康
docker compose ps
#    期望：app / docreader / postgres 为 (healthy)

# 2) 后端接口
curl -s -o /dev/null -w 'backend health: %{http_code}\n' http://localhost:18080/health
#    期望：200

# 3) 前端品牌（验证前端镜像已生效）
curl -s http://localhost:9008/ | grep -oE '<title>[^<]*</title>'
#    期望：<title>如棠智能知识库</title>

# 4) 注册开关（应为 invite_only）
curl -s http://localhost:18080/api/v1/auth/config
```

**验证新接口已存在**（排查版本错配）：

```bash
TOKEN=$(curl -s -X POST http://localhost:18080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@rutang.cn","password":"你的密码"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -s -o /dev/null -w 'artifacts: %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" http://localhost:18080/api/v1/artifacts
#    期望：200（若是 404，说明跑的仍是旧镜像，回到第四步检查 docker images 时间）
```

浏览器访问 **`http://<服务器IP>:9008`**，用 `Ctrl/Cmd + Shift + R` 强制刷新。

---

## 常见问题

**Q1：部署后页面/接口没变化**

三个排查点，按顺序：

```bash
docker images | grep weknora          # 1. 镜像时间是否已更新（不是 weeks ago）
docker inspect WeKnora-app --format '{{.Image}}'   # 2. 容器用的镜像ID是否与最新一致
docker compose logs app --tail=50     # 3. 日志是否有启动报错
```

最常见原因是**漏了 `--force-recreate`**。

**Q2：前端品牌还是 WeKnora 默认样式**

前端镜像没换成新的，或加载错了包：

```bash
docker load < /tmp/weknora-ui-amd64.tar.gz     # 确认已加载
docker tag wechatopenai/weknora-ui:amd64 wechatopenai/weknora-ui:latest
docker compose up -d --force-recreate frontend
curl -s http://localhost:9008/ | grep title
```

**Q3：⚠️ 千万不要执行 `docker compose pull`**

官方镜像和你自建的镜像**共用同一个 tag**（`wechatopenai/weknora-app:latest`），
`pull` 会用 Docker Hub 上的官方版本覆盖你刚加载的镜像，一切白费。

**Q4：上传/加载很慢**

- 传输慢：可在 scp 前先压缩（本文档已经 gzip），或改用 `rsync` 断点续传
- 加载慢：属正常，`docker load` 需要解压 1.6 GB

**Q5：服务器磁盘不够**

```bash
docker system df                 # 查看占用
docker builder prune -f          # 清构建缓存（服务器一般不构建，通常很少）
docker image prune -f            # 清悬空镜像
```

注意 `docker image prune -a` 会删掉未使用的镜像（包括你其他项目的），谨慎使用。

**Q6：容器起不来，日志报 `exec format error`**

镜像架构不对——传上去的是 arm64 包（最常见的坑）。排查：

```bash
docker image inspect wechatopenai/weknora-app:latest --format '{{.Architecture}}/{{.Os}}'
# 期望 amd64/linux；若是 arm64/linux，说明包打错了
```

回到「二、导出镜像包」，用 `docker save wechatopenai/weknora-xxx:amd64 | gzip > ...` 重新打包，
并按「一」确认构建时带了 `--platform linux/amd64`。

**Q7：本地开发环境突然变慢**

构建或拉取 amd64 镜像时如果用了 `:latest` tag，会覆盖 Mac 原生的 arm64 镜像，
之后本地容器走模拟执行，明显变慢。恢复：

```bash
docker tag wechatopenai/weknora-app:arm64 wechatopenai/weknora-app:latest
docker tag wechatopenai/weknora-ui:arm64  wechatopenai/weknora-ui:latest
```

本文档统一使用 `:amd64` tag 正是为了避开这个问题，本地 `:latest` 不受影响。

---

## 后续更新代码的流程

改完代码后重复上述步骤即可，完整命令如下：

```bash
# ===== 本地：改了什么就构建什么 =====
cd /Users/xuyifei_coco/Documents/fork_demo/WeKnora
mkdir -p tmp

# —— 改了后端 ——
docker buildx build --platform linux/amd64 --provenance=false \
  -f docker/Dockerfile.app -t wechatopenai/weknora-app:amd64 --load .
docker save wechatopenai/weknora-app:amd64 | gzip > tmp/weknora-app-amd64.tar.gz
scp tmp/weknora-app-amd64.tar.gz root@<服务器IP>:/tmp/

# —— 改了前端（logo / 文案 / 页面）——
docker buildx build --platform linux/amd64 --provenance=false \
  --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
  -t wechatopenai/weknora-ui:amd64 --load ./frontend
docker save wechatopenai/weknora-ui:amd64 | gzip > tmp/weknora-ui-amd64.tar.gz
scp tmp/weknora-ui-amd64.tar.gz root@<服务器IP>:/tmp/

# ===== 服务器 =====
cd /opt/www/WeKnora
docker load < /tmp/weknora-app-amd64.tar.gz && rm -f /tmp/weknora-app-amd64.tar.gz
docker tag wechatopenai/weknora-app:amd64 wechatopenai/weknora-app:latest
docker compose up -d --force-recreate app     # 前端则换成 frontend
```

---

## 附：构建参数说明

以下参数只影响**构建过程**，不影响运行：

> **注意**：`docker buildx build` **不会**自动读取 `.env`，必须用 `--build-arg 键=值` 显式传入；
> `docker compose build` 才会自动读 `.env`。
> 建议把「一」中命令的 `--build-arg` 值与你 `.env` 保持一致，避免两边不一致。

| 变量 | 示例值 | 作用 |
|------|--------|------|
| `APK_MIRROR_ARG` | `mirrors.aliyun.com` | Debian apt 源（必须支持纯 HTTP，腾讯云源会 302 跳 HTTPS 导致失败） |
| `GOPROXY_ARG` | `https://goproxy.cn` | Go 模块代理 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 源（构建前端用） |
| `WITH_ANYDOC` | `0` | 跳过 Rust anydoc 引擎（Office 进程内解析） |
| `ENABLE_BROWSERSKILL` | `0` | 跳过 Rust 浏览器技能 |
| `WITH_DUCKDB_EXT` | `1` | DuckDB 扩展预装（失败会自动重试 5 次） |
| `BUILD_HTTP_PROXY` | `http://host.docker.internal:7890` | 构建代理（宿主机有 fake-ip 类代理时必需） |
| `BUILD_HTTPS_PROXY` | 同上 | 同上 |

> **关于代理**：若宿主机使用 Clash / Surge 等 fake-ip 模式代理，容器内 DNS 会拿到虚拟 IP
> 导致下载失败或极慢。配置 `BUILD_HTTP_PROXY` 指向 `host.docker.internal:<端口>`
> 可让构建流量走宿主机代理，绕过该问题。

---

## 附：各服务端口

| 服务 | 宿主机端口 | 容器内端口 | 对外 |
|------|-----------|-----------|------|
| frontend | `9008` | 80 | ✅ 浏览器访问 |
| app | `18080` | 8080 | 建议仅内网 |
| docreader | 未映射 | 50051 | 容器网络内 |
| postgres | 未映射 | 5432 | 容器网络内 |
| redis | 未映射 | 6379 | 容器网络内 |

前端容器内的 nginx 会把 `/api` 转发到 `app:8080`（容器网络内），
所以**只需暴露 9008**，浏览器即可正常访问所有功能。

# 删除镜像批量
```bash
docker rm 0a8dcfb783d # 删除容器
docker images | grep weknora # 查看镜像
docker images | grep weknora | awk '{print $3}' | xargs docker rmi
```

