# 构建后端
docker compose build app
#  用新镜像重启后端
docker compose up -d --force-recreate app

# 构建前端
docker compose build frontend
# 启动前端
docker compose up -d --force-recreate frontend
# 开发模式
make dev-frontend


# 构建所有
docker compose build
# 启动
docker compose up -d

# 本地打包
docker save wechatopenai/weknora-app:latest | gzip > ./tmp/weknora-app.tar.gz