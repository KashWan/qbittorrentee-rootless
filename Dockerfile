# syntax=docker/dockerfile:1.7
# =============================================================================
#  qBittorrent Enhanced Edition · s6-overlay v3 · rootless / Quadlet 友好
#
#  设计要点
#    1. 上游 c0re100 直接发布 musl 静态二进制，因此不需要编译 Qt/libtorrent，
#       多架构构建只是「下载 + 解包 + 拷贝」，2 分钟内完成。
#    2. s6-overlay v3 作为 PID 1，PUID/PGID 解析放在 stage2 的 cont-init.d 里，
#       由 00-identity → 10-config → 20-downloads 顺序执行，任何一步失败都
#       可以通过 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 直接终止容器。
#    3. 镜像默认 USER 为 root：只有 root 才能 chown/降权。rootless Podman 下
#       容器内 root 已经映射到宿主当前用户，所以「以 root 启动」并不越权。
# =============================================================================

ARG ALPINE_VERSION=3.22
ARG QBITTORRENT_VERSION=5.2.4.10
ARG S6_OVERLAY_VERSION=3.2.3.2

# -----------------------------------------------------------------------------
# stage 1：取上游静态二进制
# -----------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS upstream

ARG QBITTORRENT_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk add --no-cache curl unzip

WORKDIR /pkg

RUN set -eux; \
    case "${TARGETARCH}/${TARGETVARIANT#v}" in \
      "amd64/") pkg="x86_64-linux-musl_static"          ; s6arch="x86_64"  ;; \
      "arm64/") pkg="aarch64-linux-musl_static"         ; s6arch="aarch64" ;; \
      "arm/v7") pkg="armv7-linux-musleabihf_static"     ; s6arch="arm"     ;; \
      "arm/v6") pkg="armv6-linux-musleabihf_static"     ; s6arch="armhf"   ;; \
      "386/")   pkg="i686-linux-musl_static"            ; s6arch="i686"    ;; \
      *) echo "ERROR: 上游未提供 ${TARGETARCH}/${TARGETVARIANT} 的静态包" >&2; exit 1 ;; \
    esac; \
    echo "${s6arch}" > /pkg/s6arch; \
    url="https://github.com/c0re100/qBittorrent-Enhanced-Edition/releases/download/release-${QBITTORRENT_VERSION}/qbittorrent-enhanced-nox_${pkg}.zip"; \
    echo "==> downloading ${url}"; \
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o pkg.zip "${url}"; \
    unzip -q -o pkg.zip -d ext; \
    bin="$(find ext -type f -size +1M -print -quit)"; \
    [ -n "${bin}" ] || { echo "ERROR: 压缩包内没有找到二进制文件" >&2; exit 1; }; \
    install -D -m 0755 "${bin}" /out/qbittorrent-nox; \
    size="$(wc -c < /out/qbittorrent-nox)"; \
    [ "${size}" -ge 1048576 ] || { echo "ERROR: 二进制体积异常（${size} 字节），疑似下载到错误页" >&2; exit 1; }; \
    magic="$(head -c 4 /out/qbittorrent-nox | od -An -tx1 | tr -d ' \n')"; \
    [ "${magic}" = "7f454c46" ] || { echo "ERROR: 不是 ELF 文件（magic=${magic}）" >&2; exit 1; }; \
    printf 'qbittorrent-nox %s · %s · %s bytes\n' "${QBITTORRENT_VERSION}" "${TARGETARCH}/${TARGETVARIANT}" "${size}"

# -----------------------------------------------------------------------------
# stage 2：运行镜像
# -----------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS runtime

ARG QBITTORRENT_VERSION
ARG S6_OVERLAY_VERSION
ARG TARGETARCH
ARG TARGETVARIANT
ARG WITH_PYTHON=1
ARG IMAGE_SOURCE=""
ARG VCS_REF=""

LABEL org.opencontainers.image.title="qbittorrentee" \
      org.opencontainers.image.description="qBittorrent Enhanced Edition + s6-overlay v3, PUID/PGID 可用，适配 rootless Podman / Quadlet" \
      org.opencontainers.image.version="${QBITTORRENT_VERSION}" \
      org.opencontainers.image.s6-overlay.version="${S6_OVERLAY_VERSION}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

# s6 行为开关
#   S6_BEHAVIOUR_IF_STAGE2_FAILS=2 : cont-init.d 失败 → 直接停容器，不带着坏状态硬跑
#   S6_KILL_GRACETIME=15000        : 停止时给 qBittorrent 15s 落盘 resume 数据
#   S6_SERVICES_GRACETIME=15000    : 同上，作用于 services.d 的 longrun
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
RUN set -eux; \
    case "${TARGETARCH}/${TARGETVARIANT#v}" in \
      "amd64/") s6arch="x86_64"  ;; \
      "arm64/") s6arch="aarch64" ;; \
      "arm/v7") s6arch="arm"     ;; \
      "arm/v6") s6arch="armhf"   ;; \
      "386/")   s6arch="i686"    ;; \
      *) echo "ERROR: s6-overlay 不支持 ${TARGETARCH}/${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    apk add --no-cache curl xz; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    mkdir -p /tmp/s6; cd /tmp/s6; \
    for f in "s6-overlay-noarch.tar.xz" \
             "s6-overlay-${s6arch}.tar.xz" \
             "s6-overlay-symlinks-noarch.tar.xz" \
             "s6-overlay-symlinks-arch.tar.xz"; do \
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -O "${base}/${f}"; \
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -O "${base}/${f}.sha256"; \
      sha256sum -c "${f}.sha256"; \
      tar -C / -Jxpf "${f}"; \
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
