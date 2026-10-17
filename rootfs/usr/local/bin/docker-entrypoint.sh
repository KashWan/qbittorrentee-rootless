#!/bin/sh
# =============================================================================
#  docker-entrypoint.sh
#
#  只做两件事，然后 exec /init 让 s6-overlay 成为 PID 1：
#    1. 若用户显式指定了别的命令（sh、qbittorrent-nox --version…）就直接执行
#    2. 非 root 启动时提前校验 /run 可写，把 s6 的晦涩报错换成可执行建议
#
#  这样做的好处：PUID/PGID 这类需要 root 的活儿交给 stage2 的 cont-init.d，
#  entrypoint 本身不碰身份，避免"entrypoint 里 setuid 之后 s6 起不来"的经典坑。
# =============================================================================

set -eu

if [ "$#" -gt 0 ] && [ "${1}" != "/init" ] && [ "${1}" != "init" ]; then
	exec "$@"
fi

# --- 非 root 预检 -------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	if ! mkdir -p /run/s6 2>/dev/null; then
		cat >&2 <<EOF
[致命] 当前以非 root（uid=$(id -u)）启动，但 /run 不可写，s6-overlay 无法初始化。

  可选方案（任选其一）：

  A. 让容器以 root 启动（推荐，rootless podman 下容器 root 就是宿主上的你）：
       podman run \\
         -e PUID=0 -e PGID=0 \\
         -v /srv/qbt/config:/config:Z \\
         -v /srv/qbt/downloads:/downloads:Z \\
         -p 8080:8080 <镜像>

  B. 坚持用 --user 运行，则给 /run 挂一个属于该 uid 的 tmpfs：
       podman run --user $(id -u):$(id -g) \\
         --tmpfs /run:rw,exec,mode=0755,uid=$(id -u),gid=$(id -g) \\
         -v /srv/qbt/config:/config:Z <镜像>
     （Kubernetes 的 runAsNonRoot 同理，需要可写的 emptyDir 挂到 /run）

  C. 只是想进容器看看：
       podman run --rm -it --entrypoint sh <镜像>
EOF
		exit 1
	fi
fi

exec /init
