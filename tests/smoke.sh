#!/usr/bin/env bash
# =============================================================================
#  tests/smoke.sh · 对已构建镜像做真实容器验证
#
#  用法：
#      IMAGE=ghcr.io/you/qbittorrentee-rootless:5.2.4.10 bash tests/smoke.sh
#      IMAGE=qbittorrentee:test RUNTIME=podman bash tests/smoke.sh
#
#  用例：
#    A 默认启动（rootful）           → s6 是 PID 1，服务降权到 1000:1000，WebUI 200
#    B PUID/PGID 自定义              → 进程 uid=1234 gid=2345，配置文件属主同步
#    C 非 root 启动（--user + tmpfs）→ 不崩溃、明确告警（尽力而为，失败只记 WARN）
# =============================================================================

set -Eeuo pipefail

IMAGE="${IMAGE:-qbittorrentee:test}"
RUNTIME="${RUNTIME:-docker}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qbt-smoke.XXXXXX")"
BASE_PORT=$(( 20000 + RANDOM % 10000 ))
FAIL=0
WARN=0

log()  { printf '\n\033[36m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARN=$((WARN + 1)); }

chk() { # 描述 实际 期望
	if [[ "$2" == "$3" ]]; then pass "$1（$2）"; else fail "$1：期望 '$3'，实际 '$2'"; fi
}

cleanup() {
	for c in qbt-smoke-a qbt-smoke-b qbt-smoke-c; do
		"${RUNTIME}" rm -f "$c" >/dev/null 2>&1 || true
	done
	rm -rf "${WORK}"
}
trap cleanup EXIT

# 取容器内 qbittorrent-nox 进程的真实 uid（exec 本身是 root，不能用 id -u）
proc_uid() {
	"${RUNTIME}" exec "$1" sh -c '
		for p in /proc/[0-9]*; do
			if [ "$(cat "$p/comm" 2>/dev/null)" = "qbittorrent-nox" ]; then
				awk "/^Uid:/{print \$2}" "$p/status"; exit 0
			fi
		done
		echo none' | tr -d '\r\n'
}

proc_gid() {
	"${RUNTIME}" exec "$1" sh -c '
		for p in /proc/[0-9]*; do
			if [ "$(cat "$p/comm" 2>/dev/null)" = "qbittorrent-nox" ]; then
				awk "/^Gid:/{print \$2}" "$p/status"; exit 0
			fi
		done
		echo none' | tr -d '\r\n'
}

wait_healthy() { # 容器名
	local st
	for _ in $(seq 1 60); do
		st="$("${RUNTIME}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo none)"
		case "${st}" in
			healthy) return 0 ;;
			unhealthy)
				echo "--- 容器日志（末尾 30 行）---"
				"${RUNTIME}" logs "$1" 2>&1 | tail -30
				return 1 ;;
		esac
		sleep 2
	done
	echo "--- 等待健康检查超时，容器日志（末尾 30 行）---"
	"${RUNTIME}" logs "$1" 2>&1 | tail -30
	return 1
}

http_code() {
	curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$1/" || echo 000
}

echo "镜像：${IMAGE}"
echo "运行时：${RUNTIME}"
"${RUNTIME}" image inspect "${IMAGE}" >/dev/null

# -----------------------------------------------------------------------------
# 用例 A：默认启动
# -----------------------------------------------------------------------------
log "用例 A：默认启动（rootful，不设 PUID/PGID）"
PORT_A="${BASE_PORT}"
mkdir -p "${WORK}/a/config" "${WORK}/a/downloads"

"${RUNTIME}" run -d --name qbt-smoke-a \
	-p "127.0.0.1:${PORT_A}:8080" \
	-v "${WORK}/a/config:/config" \
	-v "${WORK}/a/downloads:/downloads" \
	-e TZ=Asia/Shanghai \
	"${IMAGE}" >/dev/null

if wait_healthy qbt-smoke-a; then
	pass "容器进入 healthy"

	chk "PID 1 是 s6-svscan" \
		"$("${RUNTIME}" exec qbt-smoke-a cat /proc/1/comm | tr -d '\r\n')" "s6-svscan"

	chk "运行进程 uid" "$(proc_uid qbt-smoke-a)" "1000"
	chk "运行进程 gid" "$(proc_gid qbt-smoke-a)" "1000"

	chk "配置文件属主" \
		"$("${RUNTIME}" exec qbt-smoke-a stat -c '%u:%g' /config/qBittorrent/config/qBittorrent.conf)" "1000:1000"

	chk "配置文件已落盘" \
		"$("${RUNTIME}" exec qbt-smoke-a test -f /config/qBittorrent/config/qBittorrent.conf && echo yes || echo no)" "yes"

	chk "search 插件目录存在" \
		"$("${RUNTIME}" exec qbt-smoke-a test -d /config/qBittorrent/data/nova3/engines && echo yes || echo no)" "yes"

	chk "WebUI HTTP 状态" "$(http_code "${PORT_A}")" "200"

	if "${RUNTIME}" logs qbt-smoke-a 2>&1 | grep -q "场景：rootful"; then
		pass "日志标识 rootful 场景"
	else
		fail "日志中缺少「场景：rootful」"
	fi

	if "${RUNTIME}" logs qbt-smoke-a 2>&1 | grep -q "运行身份：abc"; then
		pass "日志显示降权到 abc"
	else
		warn "日志未出现「运行身份：abc」（默认账号名可能不同）"
	fi
else
	fail "容器未进入 healthy"
fi

"${RUNTIME}" rm -f qbt-smoke-a >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 用例 B：自定义 PUID/PGID
# -----------------------------------------------------------------------------
log "用例 B：PUID=1234 PGID=2345"
PORT_B=$((BASE_PORT + 1))
mkdir -p "${WORK}/b/config" "${WORK}/b/downloads"

"${RUNTIME}" run -d --name qbt-smoke-b \
	-p "127.0.0.1:${PORT_B}:8080" \
	-v "${WORK}/b/config:/config" \
	-v "${WORK}/b/downloads:/downloads" \
	-e PUID=1234 -e PGID=2345 -e UMASK=027 \
	"${IMAGE}" >/dev/null

if wait_healthy qbt-smoke-b; then
	pass "容器进入 healthy"
	chk "运行进程 uid" "$(proc_uid qbt-smoke-b)" "1234"
	chk "运行进程 gid" "$(proc_gid qbt-smoke-b)" "2345"
	chk "配置文件属主" \
		"$("${RUNTIME}" exec qbt-smoke-b stat -c '%u:%g' /config/qBittorrent/data/nova3/engines)" "1234:2345"
	chk "WebUI HTTP 状态" "$(http_code "${PORT_B}")" "200"
else
	fail "PUID/PGID 场景未进入 healthy"
fi

"${RUNTIME}" rm -f qbt-smoke-b >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 用例 C：非 root 启动（尽力而为）
# -----------------------------------------------------------------------------
log "用例 C：--user $(id -u):$(id -g) + 可写 /run tmpfs"
PORT_C=$((BASE_PORT + 2))
mkdir -p "${WORK}/c/config" "${WORK}/c/downloads"
chmod -R 0777 "${WORK}/c"

if "${RUNTIME}" run -d --name qbt-smoke-c \
	--user "$(id -u):$(id -g)" \
	--tmpfs "/run:rw,exec,mode=0755,uid=$(id -u),gid=$(id -g)" \
	-p "127.0.0.1:${PORT_C}:8080" \
	-v "${WORK}/c/config:/config" \
	-v "${WORK}/c/downloads:/downloads" \
	"${IMAGE}" >/dev/null 2>&1; then
	if wait_healthy qbt-smoke-c; then
		pass "非 root 启动可用"
		chk "运行进程 uid" "$(proc_uid qbt-smoke-c)" "$(id -u)"
		if "${RUNTIME}" logs qbt-smoke-c 2>&1 | grep -q "已忽略"; then
			pass "PUID 被忽略时已明确告警"
		else
			warn "未看到 PUID 忽略告警"
		fi
	else
		warn "非 root 启动未通过健康检查（该模式为尽力支持，详见 docs/puid-pgid.md）"
	fi
else
	warn "非 root 启动失败（该模式为尽力支持，详见 docs/puid-pgid.md）"
fi

"${RUNTIME}" rm -f qbt-smoke-c >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
echo
echo "结果：FAIL=${FAIL}  WARN=${WARN}"
if [[ "${FAIL}" -gt 0 ]]; then
	printf '\033[31m冒烟测试失败\033[0m\n'
	exit 1
fi
printf '\033[32m冒烟测试通过\033[0m\n'
