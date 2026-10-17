#!/usr/bin/env bash
# =============================================================================
#  install-quadlet.sh · 一键安装 rootless Quadlet 单元
#
#  用法：
#      ./scripts/install-quadlet.sh                      # 交互式默认值
#      ./scripts/install-quadlet.sh --image ghcr.io/me/qbittorrentee-rootless:5.2.4.10
#      ./scripts/install-quadlet.sh --dry-run
#
#  做的事：
#      1. 建好 ~/qbt/{config,downloads}
#      2. 渲染 quadlet 单元到 ~/.config/containers/systemd/
#      3. systemctl --user daemon-reload && 启动
# =============================================================================

set -Eeuo pipefail

IMAGE="${IMAGE:-}"
CONFIG_DIR="${CONFIG_DIR:-${HOME}/qbt/config}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-${HOME}/qbt/downloads}"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
UNIT_NAME="qbittorrentee.container"
WEBUI_PORT="${WEBUI_PORT:-8080}"
BT_PORT="${BT_PORT:-6881}"
TZ_VALUE="${TZ:-$(cat /etc/timezone 2>/dev/null || echo Asia/Shanghai)}"
DRY_RUN=0

die() { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--image)   IMAGE="${2:?}"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '3,14p' "$0"; exit 0 ;;
		*) die "未知参数：$1" ;;
	esac
done

[[ -n "${IMAGE}" ]] || die "请用 --image 指定镜像，例如 --image ghcr.io/you/qbittorrentee-rootless:latest"
[[ "$(id -u)" -ne 0 ]] || die "请以普通用户运行（rootless），不要用 sudo"

# 镜像仓库名必须全小写，否则 docker/podman 直接报
#   invalid reference format / repository name must be lowercase
# 这个错误在单元启动时才暴露，很难联想到是大小写问题，所以这里先拦住。
case "${IMAGE%%:*}" in
	*[A-Z]*) die "镜像名不能含大写字母：${IMAGE}
  OCI 规范要求仓库名为小写。请改成 $(printf '%s' "${IMAGE}" | tr '[:upper:]' '[:lower:]')" ;;
esac

TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/quadlet/${UNIT_NAME}"
[[ -r "${TEMPLATE}" ]] || die "找不到模板：${TEMPLATE}"

# podman 的 AutoUpdate=registry 要求镜像是「全限定引用」（含 registry/repo）。
# 本地构建的短名（qbittorrentee:dev）会让单元直接启动失败：
#   Error: short name: auto updates require fully-qualified image reference
# 所以短名时自动去掉 AutoUpdate，并明确告知。
DROP_AUTOUPDATE=0
case "${IMAGE}" in
	*/*) : ;;
	*)   DROP_AUTOUPDATE=1 ;;
esac

info "镜像：${IMAGE}"
info "配置：${CONFIG_DIR}"
info "下载：${DOWNLOADS_DIR}"
info "端口：WebUI ${WEBUI_PORT} / BT ${BT_PORT}"
if [[ "${DROP_AUTOUPDATE}" -eq 1 ]]; then
	info "注意：${IMAGE} 不是全限定镜像名，已去掉 AutoUpdate=registry"
fi

mkdir -p "${CONFIG_DIR}" "${DOWNLOADS_DIR}" "${UNIT_DIR}"

rendered="$(
	sed \
		-e "s|ghcr.io/kashwan/qbittorrentee-rootless:latest|${IMAGE}|" \
		-e "s|^Environment=WEBUI_PORT=.*|Environment=WEBUI_PORT=${WEBUI_PORT}|" \
		-e "s|^Environment=BT_PORT=.*|Environment=BT_PORT=${BT_PORT}|" \
		-e "s|^Environment=TZ=.*|Environment=TZ=${TZ_VALUE}|" \
		-e "s|^PublishPort=8080:8080$|PublishPort=${WEBUI_PORT}:${WEBUI_PORT}|" \
		-e "s|^PublishPort=6881:6881$|PublishPort=${BT_PORT}:${BT_PORT}|" \
		-e "s|^PublishPort=6881:6881/udp$|PublishPort=${BT_PORT}:${BT_PORT}/udp|" \
		-e "s|^Volume=%h/qbt/config:/config:Z|Volume=${CONFIG_DIR}:/config:Z|" \
		-e "s|^Volume=%h/qbt/downloads:/downloads:Z|Volume=${DOWNLOADS_DIR}:/downloads:Z|" \
		"${TEMPLATE}"
)"

if [[ "${DROP_AUTOUPDATE}" -eq 1 ]]; then
	rendered="$(printf '%s\n' "${rendered}" | sed '/^AutoUpdate=registry$/d')"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
	echo "--- 将要写入 ${UNIT_DIR}/${UNIT_NAME} ---"
	printf '%s\n' "${rendered}"
	exit 0
fi

printf '%s\n' "${rendered}" > "${UNIT_DIR}/${UNIT_NAME}"
info "已写入 ${UNIT_DIR}/${UNIT_NAME}"

systemctl --user daemon-reload
info "已重新加载 systemd 用户单元"

if systemctl --user start qbittorrentee 2>/dev/null; then
	info "已启动 qbittorrentee"
else
	info "启动失败，查看原因：journalctl --user -u qbittorrentee -n 50 --no-pager"
fi

cat <<EOF

后续步骤：
  开机自启     systemctl --user enable qbittorrentee
  未登录也运行  loginctl enable-linger "$USER"
  查看日志     journalctl --user -u qbittorrentee -f
  WebUI        http://127.0.0.1:${WEBUI_PORT}
  首启密码     journalctl --user -u qbittorrentee | grep -i "temporary password"

更新镜像：
  podman auto-update          # 依赖 AutoUpdate=registry
  或 systemctl --user restart qbittorrentee
EOF
