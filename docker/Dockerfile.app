# Build extension and daemon from the same pinned source on the runtime architecture.
FROM --platform=$TARGETPLATFORM node:24-bookworm-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS browserskill
WORKDIR /build
# Debian 源镜像：国内网络直连 deb.debian.org 会让 apt-get update 失败（exit 100）
ARG APK_MIRROR_ARG
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi
RUN apt-get update && \
    apt-get install -y --no-install-recommends git python3 ca-certificates curl build-essential cmake pkg-config && \
    rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH

# 浏览器技能（Chrome 扩展 + Rust 守护进程）。
# 该阶段需要 Rust 工具链，国内直连 sh.rustup.rs 会失败，因此提供两条出路：
#   1) ENABLE_BROWSERSKILL=0 完全跳过（默认 1 保持上游行为）——不需要该功能时最省事
#   2) RUSTUP_DIST_SERVER 指向国内镜像，如 https://mirrors.tuna.tsinghua.edu.cn/rustup
ARG ENABLE_BROWSERSKILL=1
ARG RUSTUP_DIST_SERVER=""
ARG TARGETOS
ARG TARGETARCH

RUN --mount=type=bind,source=scripts,target=/build/scripts \
    --mount=type=bind,source=patches,target=/build/patches \
    if [ "$ENABLE_BROWSERSKILL" != "1" ]; then \
        echo "[browserskill] 已跳过（ENABLE_BROWSERSKILL=${ENABLE_BROWSERSKILL}），该功能在镜像内不可用"; \
        mkdir -p /opt/weknora/browserskill; \
    else \
        if [ -n "$RUSTUP_DIST_SERVER" ]; then \
            export RUSTUP_DIST_SERVER; \
            export RUSTUP_UPDATE_ROOT="${RUSTUP_DIST_SERVER}/rustup"; \
            _arch="$(uname -m)"; \
            echo "[browserskill] 使用 Rust 镜像源 ${RUSTUP_DIST_SERVER}"; \
            curl -sSf "${RUSTUP_DIST_SERVER}/rustup/dist/${_arch}-unknown-linux-gnu/rustup-init" -o /tmp/rustup-init && \
            chmod +x /tmp/rustup-init && \
            /tmp/rustup-init -y --profile minimal --default-toolchain stable --no-modify-path; \
        else \
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
                | sh -s -- -y --profile minimal --default-toolchain stable; \
        fi && \
        bash scripts/build_browserskill.sh /opt/weknora/browserskill "${TARGETOS}/${TARGETARCH}"; \
    fi

# Build stage
FROM golang:1.26-bookworm AS builder

WORKDIR /app

# 通过构建参数接收敏感信息
ARG GOPRIVATE_ARG
ARG GOPROXY_ARG
ARG GOSUMDB_ARG=off
ARG APK_MIRROR_ARG

# 设置Go环境变量
ENV GOPRIVATE=${GOPRIVATE_ARG}
ENV GOPROXY=${GOPROXY_ARG}
ENV GOSUMDB=${GOSUMDB_ARG}

# Install dependencies
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y git build-essential libsqlite3-dev curl

# Install migrate tool
RUN go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest

# Copy go mod files. go.mod replace-points anydoc at ./third_party/anydoc-go,
# so that module's go.mod must exist before `go mod download`.
COPY go.mod go.sum ./
COPY third_party/anydoc-go/go.mod third_party/anydoc-go/go.mod
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd/download cmd/download
# 预装 DuckDB 扩展（spatial / excel），供数据分析工具枚举 Excel 工作表使用。
# extensions.duckdb.org 在容器网络下偶发 502/超时，因此加入重试；
# 完全不可达时可设 WITH_DUCKDB_EXT=0 跳过（代价：数据分析工具读 Excel 能力受限）。
ARG WITH_DUCKDB_EXT=1
RUN if [ "$WITH_DUCKDB_EXT" = "1" ]; then \
        go build -o /tmp/dl-duckdb ./cmd/download/duckdb/ && \
        ok=0; \
        for i in 1 2 3 4 5; do \
            if /tmp/dl-duckdb; then ok=1; break; fi; \
            echo "[duckdb] 第 ${i} 次下载失败，10s 后重试..."; \
            sleep 10; \
        done; \
        if [ "$ok" != "1" ]; then \
            echo "[duckdb] 扩展预装失败。可设 WITH_DUCKDB_EXT=0 跳过（数据分析工具将无法枚举 Excel 工作表）"; \
            exit 1; \
        fi; \
        echo "[duckdb] 扩展预装完成"; \
    else \
        echo "[duckdb] 跳过扩展预装（WITH_DUCKDB_EXT=${WITH_DUCKDB_EXT}）"; \
    fi
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod bash ./scripts/copy-licenses.sh /license-bundle

# Get version and commit info for build injection
ARG VERSION_ARG
ARG COMMIT_ID_ARG
ARG BUILD_TIME_ARG
ARG GO_VERSION_ARG

# Set build-time variables
ENV VERSION=${VERSION_ARG}
ENV COMMIT_ID=${COMMIT_ID_ARG}
ENV BUILD_TIME=${BUILD_TIME_ARG}
ENV GO_VERSION=${GO_VERSION_ARG}

# Link the anydoc parser engine (office docs converted in-process, no
# Python docreader). Default on so Hub / compose images ship a working
# engine; pass WITH_ANYDOC=0 to skip the Rust toolchain (~few minutes and
# ~1 GB of build-stage layers).
ARG WITH_ANYDOC=1
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    if [ "$WITH_ANYDOC" = "1" ]; then \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --profile minimal --default-toolchain stable && \
        ./scripts/build-anydoc-lib.sh; \
    fi

# Build the application with version info
RUN --mount=type=cache,target=/go/pkg/mod \
    if [ "$WITH_ANYDOC" = "1" ]; then \
        make build-prod GO_BUILD_TAGS=anydoc; \
    else \
        make build-prod; \
    fi
RUN --mount=type=cache,target=/go/pkg/mod cp -r /go/pkg/mod/github.com/yanyiwu/ /app/yanyiwu/

# Final stage
FROM debian:12.12-slim

WORKDIR /app

ARG APK_MIRROR_ARG

# Pairing derives the gateway URL from the user's page origin by default.
ENV BROWSERSKILL_BINARY=/opt/weknora/browserskill/bsk \
    BROWSERSKILL_EXTENSION_PATH=/opt/weknora/browserskill/browser-skill-weknora-0.3.0.zip
COPY --from=browserskill /opt/weknora/browserskill /opt/weknora/browserskill

# Create a non-root user first
RUN useradd -m -s /bin/bash appuser

# 先装 ca-certificates。这里也先切镜像源：国内直连 deb.debian.org 会失败；
# 镜像源为 HTTP 时不需要证书，为 HTTPS 时基础镜像通常已自带 ca-certificates。
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Then switch to mirror if specified and install other packages
RUN if [ -n "$APK_MIRROR_ARG" ]; then \
        sed -i "s@deb.debian.org@${APK_MIRROR_ARG}@g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential postgresql-client default-mysql-client tzdata sed curl bash vim wget \
        libsqlite3-0 \
        python3 python3-pip python3-dev libffi-dev libssl-dev \
        nodejs npm \
        gosu \
        ffmpeg && \
    python3 -m pip install --break-system-packages --upgrade pip setuptools wheel && \
    mkdir -p /home/appuser/.local/bin && \
    curl -LsSf https://astral.sh/uv/install.sh | CARGO_HOME=/home/appuser/.cargo UV_INSTALL_DIR=/home/appuser/.local/bin sh && \
    chown -R appuser:appuser /home/appuser && \
    ln -sf /home/appuser/.local/bin/uvx /usr/local/bin/uvx && \
    chmod +x /usr/local/bin/uvx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create data directories and set permissions
RUN mkdir -p /data/files && \
    chown -R appuser:appuser /app /data/files

# Copy migrate tool from builder stage
COPY --from=builder /go/bin/migrate /usr/local/bin/
COPY --from=builder /app/yanyiwu/ /go/pkg/mod/github.com/yanyiwu/

# Copy the binary from the builder stage
COPY --from=builder /app/config ./config
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/migrations ./migrations
COPY --from=builder /app/dataset/samples ./dataset/samples
COPY --from=builder /root/.duckdb /home/appuser/.duckdb
COPY --from=builder /app/WeKnora .
COPY --from=builder /license-bundle/ ./

# Copy and make entrypoint script executable
COPY --from=builder /app/scripts/docker-entrypoint.sh ./scripts/docker-entrypoint.sh

# Make scripts executable
RUN chmod +x ./scripts/*.sh

# Expose ports
EXPOSE 8080


ENTRYPOINT ["./scripts/docker-entrypoint.sh"]
CMD ["./WeKnora"]
