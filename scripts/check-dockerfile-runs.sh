#!/usr/bin/env bash
# =============================================================================
#  check-dockerfile-runs.sh · 对 Dockerfile 里每个 RUN 块做 shell 语法检查
#
#  为什么需要它：
#    我们踩过一次 —— `tr -d ' \n")` 少了一个收尾单引号，`sh` 报
#    "unterminated quoted string"。这种错误只有 docker build 才会发现，
#    而 build 要几分钟；放在 lint 阶段只需毫秒。
#
#  做法：把每个 RUN（拼合续行）落成一个临时脚本，用 `sh -n` 检查。
#        不做变量展开、不联网、不需要 docker。
#
#  用法： bash scripts/check-dockerfile-runs.sh [Dockerfile]
# =============================================================================

set -Eeuo pipefail

FILE="${1:-Dockerfile}"
[[ -r "${FILE}" ]] || { printf 'ERROR: 找不到 %s\n' "${FILE}" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/qbt-dockerlint.XXXXXX")"
cleanup() { rm -rf "${TMP}" 2>/dev/null || true; }
trap cleanup EXIT

count=0
bad=0
lineno=0
in_run=0
acc=""
start_line=0

check_block() { # $1 起始行号  $2 脚本内容
	local out
	if ! out="$(printf '%s\n' "$2" > "${TMP}/run-$1.sh" && sh -n "${TMP}/run-$1.sh" 2>&1)"; then
		bad=$((bad + 1))
		printf '  \033[31mFAIL\033[0m RUN @ line %s：%s\n' "$1" "${out}" >&2
		return 1
	fi
	return 0
}

while IFS= read -r line || [[ -n "${line}" ]]; do
	lineno=$((lineno + 1))

	if [[ "${in_run}" -eq 0 ]]; then
		case "${line}" in
			RUN\ *)
				body="${line#RUN }"
				if [[ "${body}" == *\\ ]]; then
					# 多行 RUN：先攒起来
					in_run=1
					acc="${body}"
					start_line="${lineno}"
				else
					# 单行 RUN：立刻检查
					check_block "${lineno}" "${body}" || true
					count=$((count + 1))
				fi
				;;
		esac
		continue
	fi

	# 仍在多行 RUN 中
	if [[ "${line}" == *\\ ]]; then
		acc+=$'\n'"${line}"
		continue
	fi
	acc+=$'\n'"${line}"
	check_block "${start_line}" "${acc}" || true
	count=$((count + 1))
	in_run=0
	acc=""
done < "${FILE}"

if [[ "${in_run}" -eq 1 ]]; then
	printf '  \033[31mFAIL\033[0m RUN @ line %s：文件结束时仍未闭合\n' "${start_line}" >&2
	bad=$((bad + 1))
fi

printf '检查了 %d 个 RUN 块，语法错误 %d 个\n' "${count}" "${bad}"
[[ "${bad}" -eq 0 ]]
