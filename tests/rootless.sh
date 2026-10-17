#!/usr/bin/env bash
# =============================================================================
#  tests/rootless.sh · rootless Podman 下的 PUID/PGID 行为验证
#
#  必须以普通用户身份运行（不要 sudo）。环境不满足时退出码 77（skip 约定）。
#
#  断言：
#    1. 默认（不设 PUID/PGID）→ 容器以 root 运行，但宿主上文件属主就是你本人
#    2. 显式 PUID=1000        → 日志明确警告「会映射到 subuid」，不静默失败
#    3. 两个用例的日志都应显示「场景：rootless」
# =============================================================================

set -Eeuo pipefail

IMAGE="${IMAGE:-qbittorrentee:test}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qbt-rootless.XXXXXX")"
BASE_PORT=$(( 22000 + RANDOM % 8000 ))
FAIL=0

skip() { printf '\033[33mSKIP:\033[0m %s\n' "$*"; exit 77; }
log()  { printf '\n\033[36m▶ %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

cleanup() {
	podman rm -f qbt-rootless-1 qbt-rootless-2 >/dev/null 2>&1 || true
	# 数据目录里可能有 subuid 属主（PUID 场景），普通用户删不掉 → 借 userns 删
	podman unshare rm -rf "${WORK}" >/dev/null 2>&1 || rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# --- 前置条件 ---------------------------------------------------------------
[[ "$(id -u)" -ne 0 ]] || skip "当前是 root，rootless 测试无意义"
command -v podman >/dev/null 2>&1 || skip "未安装 podman"
grep -q "^$(id -un):" /etc/subuid 2>/dev/null || skip "/etc/subuid 未配置当前用户"
grep -q "^$(id -un):" /etc/subgid 2>/dev/null || skip "/etc/subgid 未配置当前用户"
podman info >/dev/null 2>&1 || skip "rootless podman 不可用（podman info 失败）"
podman image exists "${IMAGE}" 2>/dev/null || skip "本地没有镜像 ${IMAGE}"

echo "镜像：${IMAGE}"
echo "当前用户：$(id -un) uid=$(id -u) gid=$(id -g)"

# 检查容器日志里是否出现某个字符串
#   不能写成 `podman logs | grep -q`：脚本开了 pipefail，grep -q 提前退出会让
#   podman logs 收到 SIGPIPE（141），整条管道被判为失败 —— 明明有日志却「匹配不到」。
logs_contain() {
	local out
	out="$(podman logs "$1" 2>&1 || true)"
	[ -n "${out}" ] || return 1
	grep -qF -- "$2" <<<"${out}"
}

wait_up() {
	for _ in $(seq 1 45); do
		if podman container exists "$1" 2>/dev/null; then
			state="$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)"
			if [[ "${state}" == "true" ]]; then
				return 0
			fi
			if [[ "$(podman inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)" == "exited" ]]; then
				podman logs "$1" 2>&1 | tail -20
				return 1
			fi
		fi
		sleep 2
	done
	return 1
}

# -----------------------------------------------------------------------------
# 用例 1：默认（不设 PUID/PGID）
# -----------------------------------------------------------------------------
log "用例 1：rootless 默认（不设 PUID/PGID）"
mkdir -p "${WORK}/1/config" "${WORK}/1/downloads"

podman run -d --name qbt-rootless-1 \
	-p "127.0.0.1:$((BASE_PORT)):8080" \
	-v "${WORK}/1/config:/config:Z" \
	-v "${WORK}/1/downloads:/downloads:Z" \
	"${IMAGE}" >/dev/null

if wait_up qbt-rootless-1 && sleep 8; then
	pass "容器已启动"

	if logs_contain qbt-rootless-1 "场景：rootless"; then
		pass "识别为 rootless userns"
	else
		fail "未识别为 rootless userns（日志缺少「场景：rootless」）"
	fi

	# rootless 下容器 root 就是宿主用户，属主天然正确 —— 必须一个 chown 都不做
	if logs_contain qbt-rootless-1 "属主修正：跳过"; then
		pass "未执行任何 chown（属主天然正确）"
	else
		fail "日志未声明跳过 chown（可能在 rootless 下仍去改属主）"
	fi

	if logs_contain qbt-rootless-1 "运行身份：root（uid=0 gid=0）"; then
		pass "运行身份 = 容器 root（即宿主 $(id -u)）"
	else
		fail "运行身份不是容器 root（PUID=0 时应以 root 运行、不降权）"
	fi

	host_uid="$(stat -c '%u' "${WORK}/1/config/qBittorrent/config/qBittorrent.conf" 2>/dev/null || echo none)"
	if [[ "${host_uid}" == "$(id -u)" ]]; then
		pass "宿主上配置文件属主 = 我本人（${host_uid}）"
	else
		fail "宿主上配置文件属主为 ${host_uid}，期望 $(id -u)"
	fi

	if curl -s -o /dev/null -m 5 "http://127.0.0.1:$((BASE_PORT))/"; then
		pass "WebUI 可访问"
	else
		fail "WebUI 无响应"
	fi
else
	fail "容器未能启动"
fi

podman rm -f qbt-rootless-1 >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 用例 2：显式 PUID=1000（应被明确告警，而不是静默"不生效"）
# -----------------------------------------------------------------------------
log "用例 2：显式 PUID=1000 PGID=1000（预期告警）"
mkdir -p "${WORK}/2/config" "${WORK}/2/downloads"

podman run -d --name qbt-rootless-2 \
	-p "127.0.0.1:$((BASE_PORT + 1)):8080" \
	-v "${WORK}/2/config:/config:Z" \
	-v "${WORK}/2/downloads:/downloads:Z" \
	-e PUID=1000 -e PGID=1000 \
	"${IMAGE}" >/dev/null

if wait_up qbt-rootless-2 && sleep 8; then
	if logs_contain qbt-rootless-2 "rootless userns 下 PUID=1000"; then
		pass "已给出「PUID 会映射到 subuid」的警告"
	else
		fail "缺少 PUID 映射警告（用户会以为配置又没生效）"
	fi

	host_uid="$(stat -c '%u' "${WORK}/2/config/qBittorrent/config/qBittorrent.conf" 2>/dev/null || echo none)"
	if [[ "${host_uid}" != "$(id -u)" ]]; then
		pass "印证了告警：宿主属主变成 ${host_uid}（subuid），不是 $(id -u)"
	else
		printf '  \033[33mINFO\033[0m 该环境下 uid 1000 恰好 1:1 映射，属主仍是本人\n'
	fi
else
	fail "容器未能启动"
fi

podman rm -f qbt-rootless-2 >/dev/null 2>&1 || true

echo
echo "结果：FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
printf '\033[32mrootless 测试通过\033[0m\n'
