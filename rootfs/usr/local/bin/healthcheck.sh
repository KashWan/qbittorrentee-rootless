#!/bin/sh
# =============================================================================
#  healthcheck.sh · 容器健康检查
#
#  端口候选（按优先级，逐个探测，任一通过即健康）：
#      HEALTHCHECK_PORT  →  WEBUI_PORT  →  qBittorrent.conf 里的 WebUI\Port  →  8080
#
#  为什么不能只看 WEBUI_PORT：用户在 WebUI 里把端口改成 9090、而 compose 里
#  还留着 WEBUI_PORT=8080 时，只读环境变量会让容器被误判 unhealthy。
#
#  每一层判断（任一通过即视为健康）：
#    1. HTTP 探活   (WebUI 返回 200)
#    2. HTTPS 探活  (启用了证书)
#    3. TCP LISTEN  (要求认证时 wget 会拿到 401，此时看端口更准)
# =============================================================================

set -u

CONFIG_DIR="${CONFIG_DIR:-/config}"

# 从配置文件里取 WebUI\Port（qBittorrent 用反斜杠分组）
conf_ports() {
	for f in "${CONFIG_DIR}/qBittorrent/config/qBittorrent.conf" \
	         "${CONFIG_DIR}/qBittorrent/qBittorrent.conf"; do
		[ -r "${f}" ] || continue
		sed -n 's/^[[:space:]]*WebUI\\Port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${f}" | tail -1
	done
}

CANDIDATES=""
add_port() {
	case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
	case " ${CANDIDATES} " in
		*" $1 "*) return 0 ;;
	esac
	CANDIDATES="${CANDIDATES} $1"
}

add_port "${HEALTHCHECK_PORT:-}"
add_port "${WEBUI_PORT:-}"
for p in $(conf_ports); do add_port "${p}"; done
add_port 8080

probe_http() {
	wget -q -T 3 -O /dev/null "http://127.0.0.1:${1}/" 2>/dev/null
}

probe_https() {
	wget -q -T 3 --no-check-certificate -O /dev/null "https://127.0.0.1:${1}/" 2>/dev/null
}

# /proc/net/tcp 中 state 0A = LISTEN，端口是 4 位大写十六进制
probe_listen() {
	hex="$(printf '%04X' "$1")"
	for f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "${f}" ] || continue
		if awk -v want="${hex}" '
			NR > 1 {
				split($2, a, ":")
				if (a[2] == want && $4 == "0A") { found = 1 }
			}
			END { exit(found ? 0 : 1) }' "${f}" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

for port in ${CANDIDATES}; do
	if probe_http "${port}" || probe_https "${port}"; then
		exit 0
	fi
	if probe_listen "${port}"; then
		# WebUI 在监听，只是需要认证（或证书自签），这仍然是健康的
		exit 0
	fi
done

echo "unhealthy: 以下端口均无响应（HTTP/HTTPS/TCP）:${CANDIDATES}" >&2
exit 2
