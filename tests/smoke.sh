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
#    D 自定义 WEBUI_PORT=8090        → 配置里写入新端口，healthcheck 跟随，宿主端口 200
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

# 清理绝不能把测试判成失败。
#   容器会以 1000、1234、65534 等身份往挂载目录里写文件，而跑测试的账号
#   （CI 里是 runner，uid 1001）对这些文件没有写权限，裸 rm -rf 会报一堆
#   Permission denied 并返回非 0 —— 断言全过、步骤却红。所以这里分四道：
#   1) sudo（GitHub Actions 的 runner 有免密 sudo）
#   2) podman unshare（rootless 下 subuid 属主的文件）
#   3) 借一个 root 容器来删（不依赖宿主机权限）
#   4) 兜底忽略错误
#   每一道都是 `|| true`，函数最终返回进入时的状态码，清理成败与测试结论无关。
cleanup() {
	local rc=$?
	for c in qbt-smoke-a qbt-smoke-b qbt-smoke-c qbt-smoke-d; do
		"${RUNTIME}" rm -f "$c" >/dev/null 2>&1 || true
	done

	if [[ -d "${WORK}" ]]; then
		sudo -n rm -rf "${WORK}" >/dev/null 2>&1 || true
	fi
	if [[ -d "${WORK}" && "${RUNTIME}" == "podman" ]]; then
		podman unshare rm -rf "${WORK}" >/dev/null 2>&1 || true
	fi
	if [[ -d "${WORK}" ]]; then
		"${RUNTIME}" run --rm --entrypoint sh \
			-v "${WORK%/*}:/w" "${IMAGE}" \
			-c "rm -rf '/w/${WORK##*/}'" >/dev/null 2>&1 || true
	fi
	if [[ -d "${WORK}" ]]; then
		rm -rf "${WORK}" >/dev/null 2>&1 || true
	fi

	return "${rc}"
}
trap cleanup EXIT

# 取容器内 qbittorrent-nox 进程的真实 uid（exec 本身是 root，不能用 id -u）
proc_uid() {
	# 这段是写给容器里的 sh 执行的，$p / $(cat ...) 必须原样传过去
	# shellcheck disable=SC2016
	"${RUNTIME}" exec "$1" sh -c '
		for p in /proc/[0-9]*; do
			if [ "$(cat "$p/comm" 2>/dev/null)" = "qbittorrent-nox" ]; then
				awk "/^Uid:/{print \$2}" "$p/status"; exit 0
			fi
		done
		echo none' | tr -d '\r\n'
}

proc_gid() {
	# 同上
	# shellcheck disable=SC2016
	"${RUNTIME}" exec "$1" sh -c '
		for p in /proc/[0-9]*; do
			if [ "$(cat "$p/comm" 2>/dev/null)" = "qbittorrent-nox" ]; then
				awk "/^Gid:/{print \$2}" "$p/status"; exit 0
			fi
		done
		echo none' | tr -d '\r\n'
}

# 检查容器日志里是否出现某个字符串
#   不能写成 `docker logs | grep -q`：脚本开了 pipefail，grep -q 提前退出会让
#   logs 收到 SIGPIPE（141），整条管道被判为失败 —— 明明有日志却「匹配不到」。
logs_contain() {
	local out
	out="$("${RUNTIME}" logs "$1" 2>&1 || true)"
	[ -n "${out}" ] || return 1
	grep -qF -- "$2" <<<"${out}"
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

	if logs_contain qbt-smoke-a "场景：rootful"; then
		pass "日志标识 rootful 场景"
	else
		fail "日志中缺少「场景：rootful」"
	fi

	if logs_contain qbt-smoke-a "运行身份：abc"; then
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
# 用例 C：非 root 启动（--user 指定一个真正的非 root uid）
#
#  注意：不能用 $(id -u) —— 在 root 下跑测试时那就是 --user 0:0，
#  等价于 rootful，测不到「非 root 降级」这条路径。
# -----------------------------------------------------------------------------
TEST_UID=65534
TEST_GID=65534
log "用例 C：--user ${TEST_UID}:${TEST_GID} + 可写 /run tmpfs（预期 PUID 被忽略并告警）"
PORT_C=$((BASE_PORT + 2))
mkdir -p "${WORK}/c/config" "${WORK}/c/downloads"
chmod -R 0777 "${WORK}/c"

if "${RUNTIME}" run -d --name qbt-smoke-c \
	--user "${TEST_UID}:${TEST_GID}" \
	--tmpfs "/run:rw,exec,mode=0755,uid=${TEST_UID},gid=${TEST_GID}" \
	-p "127.0.0.1:${PORT_C}:8080" \
	-v "${WORK}/c/config:/config" \
	-v "${WORK}/c/downloads:/downloads" \
	-e PUID=9999 -e PGID=9999 \
	"${IMAGE}" >/dev/null 2>&1; then
	if wait_healthy qbt-smoke-c; then
		pass "非 root 启动可用"
		chk "运行进程 uid" "$(proc_uid qbt-smoke-c)" "${TEST_UID}"
		if logs_contain qbt-smoke-c "已被忽略"; then
			pass "PUID 被忽略时已明确告警"
		else
			fail "缺少「PUID 已被忽略」告警（用户会以为配置没生效）"
		fi
	else
		warn "非 root 启动未通过健康检查（该模式为尽力支持，详见 docs/puid-pgid.md）"
	fi
else
	warn "非 root 启动失败（该模式为尽力支持，详见 docs/puid-pgid.md）"
fi

"${RUNTIME}" rm -f qbt-smoke-c >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 用例 D：自定义 WEBUI_PORT
#
#  验证两件事：
#    1. WEBUI_PORT 会同时写进 qBittorrent.conf 和命令行（两侧端口一致）
#    2. healthcheck 不会死盯 8080 —— 它在 8090 上也能判定为健康
#       （用户改了端口却没改 compose 时，这是最容易踩的坑）
# -----------------------------------------------------------------------------
WEBUI_PORT_D=8090
log "用例 D：WEBUI_PORT=${WEBUI_PORT_D}（端口自适应 + healthcheck 跟随）"
PORT_D=$((BASE_PORT + 3))
mkdir -p "${WORK}/d/config" "${WORK}/d/downloads"

"${RUNTIME}" run -d --name qbt-smoke-d \
	-p "127.0.0.1:${PORT_D}:${WEBUI_PORT_D}" \
	-v "${WORK}/d/config:/config" \
	-v "${WORK}/d/downloads:/downloads" \
	-e WEBUI_PORT="${WEBUI_PORT_D}" \
	"${IMAGE}" >/dev/null

if wait_healthy qbt-smoke-d; then
	pass "容器在非默认端口上进入 healthy"

	# 直接在宿主的挂载目录里读配置，避免在 sh -c 里嵌套转义
	conf_port="$(sed -n 's/^WebUI\\Port=//p' \
		"${WORK}/d/config/qBittorrent/config/qBittorrent.conf" 2>/dev/null \
		| head -1 | tr -d '\r\n')"
	chk "配置文件里的 WebUI 端口" "${conf_port}" "${WEBUI_PORT_D}"
	chk "WebUI HTTP 状态（宿主映射端口）" "$(http_code "${PORT_D}")" "200"

	# 清掉环境变量后 healthcheck 只能靠配置文件 —— 它必须仍能判定健康
	if "${RUNTIME}" exec -e WEBUI_PORT= qbt-smoke-d /usr/local/bin/healthcheck.sh >/dev/null 2>&1; then
		pass "healthcheck 能从配置读到真实端口（不只认环境变量）"
	else
		fail "无 WEBUI_PORT 环境下 healthcheck 误判 unhealthy"
	fi
else
	fail "自定义端口场景未进入 healthy（healthcheck 可能仍盯着 8080）"
fi

"${RUNTIME}" rm -f qbt-smoke-d >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
echo
echo "结果：FAIL=${FAIL}  WARN=${WARN}"
if [[ "${FAIL}" -gt 0 ]]; then
	printf '\033[31m冒烟测试失败\033[0m\n'
	exit 1
fi
printf '\033[32m冒烟测试通过\033[0m\n'
