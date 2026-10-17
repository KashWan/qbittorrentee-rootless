#!/bin/sh
# =============================================================================
#  docker-entrypoint.sh
#
#  只做两件事，然后 exec /init 让 s6-overlay 成为 PID 1：
#    1. 若用户显式指定了别的命令（sh、qbittorrent-nox --version…）就直接执行
#    2. 预检 /run 是否可写，把 s6 的晦涩报错换成可执行建议
#
#  这样做的好处：PUID/PGID 这类需要 root 的活儿交给 stage2 的 cont-init.d，
#  entrypoint 本身不碰身份，避免「entrypoint 里 setuid 之后 s6 起不来」的坑。
# =============================================================================

set -eu

if [ "$#" -gt 0 ] && [ "${1}" != "/init" ] && [ "${1}" != "init" ]; then
	exec "$@"
fi

# --- /run 可写性预检 ---------------------------------------------------------
# s6-overlay v3 的 stage1 会在 /run/s6 下建目录、写 fifo；不可写就整个起不来。
# 这里提前探测，失败时给出可直接复制的修法，而不是让用户对着
# "s6-overlay-suexec: fatal: can only run as pid 1" 之类的话发呆。
probe_run() {
	mkdir -p /run/s6 2>/dev/null || return 1
	( : > /run/s6/.qbt-probe ) 2>/dev/null || return 1
	rm -f /run/s6/.qbt-probe 2>/dev/null || true
	return 0
}

if ! probe_run; then
	uid="$(id -u)"
	if [ "${uid}" -ne 0 ]; then
		cat >&2 <<EOF
[致命] 以非 root（uid=${uid}）启动，但 /run 不可写，s6-overlay 无法初始化。

  可选方案（任选其一）：

  A. 让容器以 root 启动（推荐；rootless podman 下容器 root 就是宿主上的你）：
       podman run \\
         -e PUID=0 -e PGID=0 \\
         -v /srv/qbt/config:/config:Z \\
         -v /srv/qbt/downloads:/downloads:Z \\
         -p 8080:8080 <镜像>

  B. 坚持用 --user / --userns=keep-id，则必须给 /run 挂一个属于该 uid 的 tmpfs：
       podman run --user ${uid}:$(id -g) \\
         --tmpfs /run:rw,exec,mode=0755,uid=${uid},gid=$(id -g) \\
         -v /srv/qbt/config:/config:Z <镜像>
     Kubernetes 的 runAsNonRoot 同理：给 /run 挂一个可写的 emptyDir。

  C. 只是想进容器看看：
       podman run --rm -it --entrypoint sh <镜像>
EOF
	else
		cat >&2 <<EOF
[致命] /run 不可写，s6-overlay 无法初始化（当前 uid=0）。

  可能原因：
    * 用了 --read-only 但没给 /run 挂 tmpfs
        加: --tmpfs /run:rw,exec,mode=0755
    * /run 被绑定挂载成只读目录
        检查: mount | grep ' /run '

  只读根文件系统 + 可写 /run 是受支持的组合：
      podman run --read-only --tmpfs /run:rw,exec,mode=0755 \\
        -v /srv/qbt/config:/config:Z -v /srv/qbt/downloads:/downloads:Z <镜像>
EOF
	fi
	exit 1
fi

exec /init
