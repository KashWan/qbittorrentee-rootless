#!/bin/sh
# =============================================================================
#  healthcheck.sh · 容器健康检查
#
#  分层判断，任何一层通过即视为健康：
#    1. HTTP 探活   (WebUI 返回 200)
#    2. HTTPS 探活  (启用了证书)
#    3. TCP LISTEN  (WebUI 要求认证时 wget 会拿到 401，此时看端口更准)
#  全部失败 → 退出码 2（unhealthy）
# =============================================================================

set -u

PORT="${HEALTHCHECK_PORT:-${WEBUI_PORT:-8080}}"
case "${PORT}" in ''|*[!0-9]*) PORT=8080 ;; esac

probe_http() {
	wget -q -T 3 -O /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null
}

probe_https() {
	wget -q -T 3 --no-check-certificate -O /dev/null "https://127.0.0.1:${PORT}/" 2>/dev/null
}

# /proc/net/tcp 中 state 0A = LISTEN，端口是 4 位大写十六进制
probe_listen() {
	hex="$(printf '%04X' "${PORT}")"
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

if probe_http || probe_https; then
	exit 0
fi

if probe_listen; then
	# WebUI 在监听，只是需要认证（或证书自签），这仍然是健康的
	exit 0
fi

echo "unhealthy: WebUI 端口 ${PORT} 无响应" >&2
exit 2
