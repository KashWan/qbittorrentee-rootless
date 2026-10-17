# syntax=docker/dockerfile:1.7
# =============================================================================
#  qBittorrent Enhanced Edition · s6-overlay v3 · rootless / Quadlet 友好
#
#  只构建 linux/amd64。上游虽然也发布其它架构的静态包，但本项目只服务 x86_64
#  主机，所以镜像里没有任何架构分支：架构不符时构建直接失败，而不是产出一个
#  「能启动但跑错二进制」的镜像。
#
#  设计要点
#    1. 上游 c0re100 直接发布 musl 静态二进制，不需要编译 Qt/libtorrent，
#       构建只是「下载 + 解包 + 拷贝」，1 分钟内完成。
#    2. s6-overlay v3 作为 PID 1：stage1 → cont-init.d（按文件名顺序）→ services.d。
#       S6_BEHAVIOUR_IF_STAGE2_FAILS=2 保证初始化失败就停容器，不带坏状态硬跑。
#    3. 镜像默认 USER 为 root：只有 root 才能 chown 与降权。rootless Podman 下
#       容器内 root 已经映射到宿主当前用户，「以 root 启动」并不越权。
#
#  版本来源（重要）
#    QBITTORRENT_VERSION / S6_OVERLAY_VERSION 的默认值**只在这里定义**。
#    CI 与 Makefile 一律通过 scripts/dockerfile-arg.sh 读取，不要别处再抄一份，
#    否则两处默认值会悄悄分叉。
# =============================================================================

ARG ALPINE_VERSION=3.22
ARG QBITTORRENT_VERSION=5.2.4.10
ARG S6_OVERLAY_VERSION=3.2.3.2

# -----------------------------------------------------------------------------
# stage 1：取上游静态二进制
# -----------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS upstream

# alpine 自带 busybox ash，默认没有 pipefail —— 下面 `od | tr` 这条管道里
# 前一段失败会被后一段的 0 退出码盖掉。显式打开 pipefail，set -e 才真正在
# 管道中途失败时中止构建（hadolint DL4006）。
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG QBITTORRENT_VERSION

RUN apk add --no-cache curl unzip

WORKDIR /pkg

# 注意：busybox 的 find 不认 +1M 这类后缀，体积过滤必须写成字节数 +Nc。
RUN set -eux; \
    url="https://github.com/c0re100/qBittorrent-Enhanced-Edition/releases/download/release-${QBITTORRENT_VERSION}/qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip"; \
    echo "==> downloading ${url}"; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o pkg.zip "${url}"; \
    unzip -q -o pkg.zip -d ext; \
    bin="$(find ext -type f -size +1048576c -print -quit)"; \
    [ -n "${bin}" ] || { echo "ERROR: 压缩包内没有找到二进制文件" >&2; exit 1; }; \
    install -D -m 0755 "${bin}" /out/qbittorrent-nox; \
    size="$(wc -c < /out/qbittorrent-nox)"; \
    [ "${size}" -ge 1048576 ] || { echo "ERROR: 二进制体积异常（${size} 字节），疑似下载到错误页" >&2; exit 1; }; \
    magic="$(head -c 4 /out/qbittorrent-nox | od -An -tx1 | tr -d ' \n')"; \
    [ "${magic}" = "7f454c46" ] || { echo "ERROR: 不是 ELF 文件（magic=${magic}）" >&2; exit 1; }; \
    printf 'qbittorrent-nox %s · linux/amd64 · %s bytes\n' "${QBITTORRENT_VERSION}" "${size}"

# -----------------------------------------------------------------------------
# stage 2：运行镜像
# -----------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS runtime

# 同 stage 1：打开 pipefail，让 RUN 里的管道失败能被 set -e 捕获
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG QBITTORRENT_VERSION
ARG S6_OVERLAY_VERSION
ARG WITH_PYTHON=1
ARG IMAGE_SOURCE=""
ARG VCS_REF=""

LABEL org.opencontainers.image.title="qbittorrentee" \
      org.opencontainers.image.description="qBittorrent Enhanced Edition + s6-overlay v3, PUID/PGID 可用，适配 rootless Podman / Quadlet（linux/amd64）" \
      org.opencontainers.image.version="${QBITTORRENT_VERSION}" \
      org.opencontainers.image.s6-overlay.version="${S6_OVERLAY_VERSION}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

# s6-overlay v3 行为开关
#   S6_BEHAVIOUR_IF_STAGE2_FAILS=2 : cont-init.d 任一脚本失败 → 停容器（默认值 0 会带着坏状态继续跑）
#   S6_KILL_GRACETIME=15000        : 停机时给 qBittorrent 15s 落盘 resume 数据
#   S6_SERVICES_GRACETIME=15000    : 同上，作用于 services.d 的 longrun
#   S6_VERBOSITY=2                 : 调成 5 可看到 stage1/stage2 的完整调试输出
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KILL_GRACETIME=15000 \
    S6_SERVICES_GRACETIME=15000 \
    S6_VERBOSITY=2 \
    HOME=/config

# ca-certificates : HTTPS tracker / RSS
# shadow          : adduser / usermod / groupmod（busybox 没有 usermod）
# tzdata          : TZ 环境变量生效
RUN set -eux; \
    apk add --no-cache ca-certificates shadow tzdata; \
    if [ "${WITH_PYTHON}" = "1" ]; then apk add --no-cache python3; fi

# --- s6-overlay v3：下载 + 校验 + 解包 -------------------------------------
# 架构守卫：非 x86_64 立即失败，避免用 --platform 构建出跑错二进制的镜像。
RUN set -eux; \
    arch="$(uname -m)"; \
    [ "${arch}" = "x86_64" ] || { \
      echo "ERROR: 本镜像仅支持 linux/amd64，当前构建架构为 ${arch}。" >&2; \
      echo "       请使用: docker build --platform linux/amd64 ..." >&2; \
      exit 1; }; \
    apk add --no-cache curl xz; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    mkdir -p /tmp/s6; \
    for f in "s6-overlay-noarch.tar.xz" \
             "s6-overlay-x86_64.tar.xz" \
             "s6-overlay-symlinks-noarch.tar.xz" \
             "s6-overlay-symlinks-arch.tar.xz"; do \
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "/tmp/s6/${f}" "${base}/${f}"; \
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "/tmp/s6/${f}.sha256" "${base}/${f}.sha256"; \
      want="$(cut -d' ' -f1 "/tmp/s6/${f}.sha256")"; \
      got="$(sha256sum "/tmp/s6/${f}" | cut -d' ' -f1)"; \
      [ -n "${want}" ] && [ "${want}" = "${got}" ] || { \
        echo "ERROR: ${f} 校验失败（期望 ${want}，实际 ${got}）" >&2; exit 1; }; \
      echo "sha256 OK: ${f}"; \
      tar -C / -Jxpf "/tmp/s6/${f}"; \
    done; \
    rm -rf /tmp/s6; \
    apk del --no-network curl xz; \
    test -x /init

# --- 运行账号（默认 1000:1000，运行时按 PUID/PGID 复用或新建）--------------
RUN set -eux; \
    if ! awk -F: '$3==1000{f=1} END{exit !f}' /etc/group; then addgroup -g 1000 abc; fi; \
    if ! awk -F: '$3==1000{f=1} END{exit !f}' /etc/passwd; then \
      adduser -u 1000 -G abc -h /config -s /sbin/nologin -D -H abc; \
    fi; \
    mkdir -p \
      /config/qBittorrent/config \
      /config/qBittorrent/data/nova3/engines \
      /config/qBittorrent/data/logs \
      /config/qBittorrent/cache \
      /downloads/incomplete \
      /usr/local/share/qbittorrent/defaults \
      /usr/local/share/qbittorrent/searchengines; \
    chown -R 1000:1000 /config /downloads; \
    rm -rf /var/cache/apk/*

COPY --from=upstream /out/qbittorrent-nox /usr/local/bin/qbittorrent-nox
COPY rootfs/ /

RUN set -eux; \
    chmod 0755 \
      /usr/local/bin/docker-entrypoint.sh \
      /usr/local/bin/healthcheck.sh \
      /usr/local/bin/qbt-lib.sh \
      /usr/local/bin/qbittorrent-nox \
      /etc/cont-init.d/00-identity \
      /etc/cont-init.d/10-config \
      /etc/cont-init.d/20-downloads \
      /etc/services.d/qbittorrent/run \
      /etc/services.d/qbittorrent/finish; \
    chmod 0644 /usr/local/share/qbittorrent/defaults/qBittorrent.conf

# 预置搜索引擎插件（可选，放入该目录即会在首次启动时安装）
# COPY searchengines/ /usr/local/share/qbittorrent/searchengines/

EXPOSE 8080 6881/tcp 6881/udp
VOLUME ["/config", "/downloads"]
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

# ENTRYPOINT 只做「非 root 预检」，随后 exec /init —— s6-overlay 必须成为 PID 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/init"]
