#!/usr/bin/env bash
# =============================================================================
#  check-tracked-files.sh · 确认镜像/CI 需要的文件都在版本控制里
#
#  为什么需要它：
#    .gitignore 里一条 `qbt-*` 把 rootfs/usr/local/bin/qbt-lib.sh 当成了构建产物，
#    于是它从未进过 git —— 本地能构建（文件在工作区），CI 一跑就
#    `chmod: /usr/local/bin/qbt-lib.sh: No such file or directory`。
#    这类问题只有 push 之后才暴露，代价很高。
#
#  用法： bash scripts/check-tracked-files.sh [目录…]
# =============================================================================

set -Eeuo pipefail

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	printf '\033[33mSKIP\033[0m 不在 git 仓库里，跳过追踪检查\n'
	exit 0
fi

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
	TARGETS=(Dockerfile .dockerignore .gitignore .gitattributes
		.shellcheckrc .hadolint.yaml .env.example
		rootfs scripts tests .github docs quadlet
		docker-compose.yml Makefile README.md LICENSE)
fi

# 只保留真实存在的路径，避免 pathspec 报错
EXIST=()
for t in "${TARGETS[@]}"; do
	[[ -e "${t}" ]] && EXIST+=("${t}")
done
[[ ${#EXIST[@]} -gt 0 ]] || { printf '没有可检查的路径\n'; exit 0; }

untracked="$(git ls-files --others --exclude-standard -- "${EXIST[@]}")"
ignored="$(git ls-files --others --ignored --exclude-standard -- "${EXIST[@]}")"

status=0

if [[ -n "${untracked}" ]]; then
	status=1
	printf '\033[31m以下文件存在但未被 git 跟踪（提交前需要 git add）：\033[0m\n' >&2
	printf '%s\n' "${untracked}" | sed 's/^/  /' >&2
fi

if [[ -n "${ignored}" ]]; then
	status=1
	printf '\033[31m以下文件被 .gitignore 忽略（很可能是规则写得太宽）：\033[0m\n' >&2
	printf '%s\n' "${ignored}" | sed 's/^/  /' >&2
	printf '  提示：用 git check-ignore -v <文件> 查出是哪条规则命中的。\n' >&2
fi

if [[ "${status}" -eq 0 ]]; then
	printf '\033[32mOK\033[0m 源文件都已纳入版本控制\n'
fi
exit "${status}"
