#!/usr/bin/env bash
# =============================================================================
#  dockerfile-arg.sh · 读取 Dockerfile 里某个 ARG 的默认值
#
#  为什么需要它：
#    上游版本、s6-overlay 版本、Alpine 版本都写在 Dockerfile 的 ARG 里。
#    CI 与 Makefile 以前各自抄了一份默认值，两处会悄悄分叉 ——
#    改了一处、忘了另一处，就会出现「构建用的是旧版本但没人发现」。
#    现在把它们统一从这个脚本读，Dockerfile 是唯一来源。
#
#  用法：
#      bash scripts/dockerfile-arg.sh Dockerfile QBITTORRENT_VERSION
#      bash scripts/dockerfile-arg.sh Dockerfile S6_OVERLAY_VERSION
#
#  找不到（或没有默认值）时退出码 1 —— 调用方应当直接失败，而不是用空值继续。
# =============================================================================

set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
	printf '用法: %s <Dockerfile> <ARG名>\n' "${0##*/}" >&2
	exit 2
fi

file="$1"
key="$2"

if [[ ! -r "${file}" ]]; then
	printf '\033[31m错误:\033[0m 读不到 %s\n' "${file}" >&2
	exit 1
fi

value="$(
	awk -v k="${key}" '
		$1 == "ARG" {
			for (i = 2; i <= NF; i++) {
				kv = $i
				eq = index(kv, "=")
				if (eq == 0) { continue }
				if (substr(kv, 1, eq - 1) != k) { continue }
				v = substr(kv, eq + 1)
				gsub(/^[\047"]/, "", v)
				gsub(/[\047"]$/, "", v)
				print v
				exit
			}
		}' "${file}"
)"

if [[ -z "${value}" ]]; then
	printf '\033[31m错误:\033[0m %s 里没有带默认值的 ARG %s\n' "${file}" "${key}" >&2
	exit 1
fi

printf '%s\n' "${value}"
