#!/bin/sh
# =============================================================================
#  qbt-lib.sh · 身份解析与目录权限的公共函数
#
#  被 /etc/cont-init.d/* 与 tests/identity.sh 共用，因此：
#    * 只用 POSIX sh，不依赖 bash
#    * 不在库内 set -e / set -u，避免影响调用方
#    * 通过 QBT_UID_MAP / QBT_GID_MAP 可注入假 map 文件，便于单元测试
# =============================================================================

: "${QBT_LOG_TAG:=init}"

qbt_log()  { printf '\033[36m[%s]\033[0m %s\n' "${QBT_LOG_TAG}" "$*"; }
qbt_warn() { printf '\033[33m[%s] 警告:\033[0m %s\n' "${QBT_LOG_TAG}" "$*" >&2; }
qbt_err()  { printf '\033[31m[%s] 错误:\033[0m %s\n' "${QBT_LOG_TAG}" "$*" >&2; }
qbt_die()  { qbt_err "$*"; exit 1; }

qbt_uid_map() { printf '%s\n' "${QBT_UID_MAP:-/proc/self/uid_map}"; }
qbt_gid_map() { printf '%s\n' "${QBT_GID_MAP:-/proc/self/gid_map}"; }

# -----------------------------------------------------------------------------
# qbt_load_container_env · 把 docker/podman -e 传入的变量重新导回当前脚本
#
# 这是本项目最容易踩的坑，也是「PUID 配了却没用」的第二个根因：
#   s6-overlay v3 的 stage1 会用**干净的 environ** 重新 exec 成 PID 1（只留 PATH），
#   用户 -e 传进来的变量被落在 /run/s6/container_environment/ 目录里。
#   stage2 的 cont-init.d / services.d 默认**读不到**这些变量，
#   于是 PUID/PGID/WEBUI_PORT/TZ/CHOWN_DOWNLOADS 全部变成默认值 —— 静默失效。
#
#   官方的 with-contenv 做的就是这件事；这里自己实现，少一层 shebang 依赖，
#   也让用户自己写的 cont-init.d 脚本能直接调用。
#
#   规则：已显式赋值的变量不覆盖（脚本内部判断优先）。
# -----------------------------------------------------------------------------
qbt_load_container_env() {
	__envdir="${S6_CONTAINER_ENV_DIR:-/run/s6/container_environment}"
	[ -d "${__envdir}" ] || return 0
	for __f in "${__envdir}"/*; do
		[ -f "${__f}" ] || continue
		__k="${__f##*/}"
		case "${__k}" in ''|*[!A-Za-z0-9_]*) continue ;; esac
		# 用 ${VAR-} 取当前值，兼容调用方的 set -u
		__cur="$(eval "printf '%s' \"\${${__k}-}\"")"
		[ -n "${__cur}" ] && continue
		__v="$(cat "${__f}" 2>/dev/null)"
		export "${__k}=${__v}" 2>/dev/null || true
	done
	unset __envdir __f __k __cur __v
	return 0
}

# -----------------------------------------------------------------------------
# 是否运行在 user namespace 里
#   rootful : "0 0 4294967295"                      → 身份映射，返回 1
#   rootless: "0 1000 1" + "1 100000 65536"          → 返回 0
# -----------------------------------------------------------------------------
in_userns() {
	__f="$(qbt_uid_map)"
	[ -r "${__f}" ] || return 1
	__in=""; __out=""; __len=""
	read -r __in __out __len __rest <<EOF
$(awk 'NR==1 && NF>=3 {print $1, $2, $3}' "${__f}" 2>/dev/null)
EOF
	[ -n "${__len}" ] || return 1
	# 完整 identity 映射 = 内核没给这个容器建 userns
	if [ "${__in}" -eq 0 ] && [ "${__out}" -eq 0 ] && [ "${__len}" -ge 65536 ]; then
		return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# map_forward <mapfile> <容器内ID>   → 宿主ID
# map_reverse <mapfile> <宿主ID>     → 容器内ID
# 未映射时返回 1
# -----------------------------------------------------------------------------
map_forward() {
	awk -v t="$2" '
		NF>=3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
			if (t >= $1 && t < $1 + $3) { print $2 + (t - $1); found=1; exit }
		}
		END { exit(found ? 0 : 1) }' "$1"
}

map_reverse() {
	awk -v t="$2" '
		NF>=3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
			if (t >= $2 && t < $2 + $3) { print $1 + (t - $2); found=1; exit }
		}
		END { exit(found ? 0 : 1) }' "$1"
}

# -----------------------------------------------------------------------------
# 校验 umask 写法（022 / 0022 都接受）
# -----------------------------------------------------------------------------
qbt_normalize_umask() {
	__v="${1:-}"
	[ -n "${__v}" ] || return 1
	case "${__v}" in *[!0-7]*) return 1 ;; esac
	[ "${#__v}" -le 4 ] || return 1
	printf '%s\n' "${__v}"
}

# -----------------------------------------------------------------------------
# 确保存在指定 gid 的组，返回组名
# -----------------------------------------------------------------------------
qbt_ensure_group() {
	__gid="$1"
	__name="$(awk -F: -v g="${__gid}" '$3==g {print $1; exit}' /etc/group)"
	if [ -n "${__name}" ]; then
		printf '%s\n' "${__name}"
		return 0
	fi
	__name="abc"
	if awk -F: -v n="${__name}" '$1==n {f=1} END {exit !f}' /etc/group; then
		__name="qbt-g${__gid}"
	fi
	addgroup -g "${__gid}" "${__name}" >/dev/null 2>&1 || return 1
	printf '%s\n' "${__name}"
}

# -----------------------------------------------------------------------------
# 确保存在指定 uid 的账号，返回账号名
#   复用已有同名 uid 的账号（只校正主组，不递归 chown，避免 /config 很大时卡住）
#   否则新建 qbt / qbt-u<uid>
# -----------------------------------------------------------------------------
qbt_ensure_user() {
	__uid="$1"; __gid="$2"; __grp="$3"; __home="$4"
	__name="$(awk -F: -v u="${__uid}" '$3==u {print $1; exit}' /etc/passwd)"
	if [ -n "${__name}" ]; then
		__cur="$(awk -F: -v n="${__name}" '$1==n {print $3; exit}' /etc/passwd)"
		if [ "${__cur}" != "${__gid}" ]; then
			usermod -g "${__grp}" "${__name}" >/dev/null 2>&1 || return 1
		fi
		printf '%s\n' "${__name}"
		return 0
	fi
	__name="qbt"
	if awk -F: -v n="${__name}" '$1==n {f=1} END {exit !f}' /etc/passwd; then
		__name="qbt-u${__uid}"
	fi
	adduser -u "${__uid}" -G "${__grp}" -h "${__home}" -s /sbin/nologin -D -H "${__name}" >/dev/null 2>&1 || return 1
	printf '%s\n' "${__name}"
}

# -----------------------------------------------------------------------------
# chown_tree <路径> <uid:gid> <用户名> <组名>
#   只修正「确实不一致」的条目；全部一致时只做 stat 遍历，开销可忽略
# -----------------------------------------------------------------------------
qbt_chown_tree() {
	__path="$1"; __owner="$2"; __user="$3"; __group="$4"
	[ -e "${__path}" ] || return 0
	if ! find "${__path}" \( ! -user "${__user}" -o ! -group "${__group}" \) -print -quit 2>/dev/null | grep -q .; then
		return 0
	fi
	if ! find "${__path}" \( ! -user "${__user}" -o ! -group "${__group}" \) \
		-exec chown -h "${__owner}" {} + 2>/dev/null; then
		qbt_warn "chown ${__path} 未完全成功（只读挂载、NFS root_squash 或 SELinux 标签？）"
		return 1
	fi
	qbt_log "已修正 ${__path} 下不一致的属主 → ${__owner}"
	return 0
}
