#!/usr/bin/env bash
# =============================================================================
#  check-image-refs.sh · 守卫「镜像引用」这类只在部署时才炸的错误
#
#  检查两条规则：
#    1. 仓库名必须全小写
#         docker: invalid reference format: repository name (...) must be lowercase
#         podman: Error: repository name must be lowercase
#       这个错误在 `podman pull` / 单元启动时才暴露，很难联想到是大小写问题。
#    2. AutoUpdate=registry 必须配全限定镜像名
#         Error: short name: auto updates require fully-qualified image reference
#
#  tests/ 下的文件不在检查范围内：那边的用例故意传入含大写字母的仓库名，
#  用来验证 resolve-upstream.sh 的自动转小写逻辑。
# =============================================================================

set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

if git rev-parse --git-dir >/dev/null 2>&1; then
	LIST="$(git ls-files)"
else
	LIST="$(find . -path ./.git -prune -o -type f -print | sed 's|^\./||')"
fi

status=0
bad_upper=0
bad_short=0

while IFS= read -r f; do
	[[ -n "${f}" && -f "${f}" ]] || continue
	case "${f}" in
		tests/*) continue ;;
	esac

	# --- 规则 1：小写 -------------------------------------------------------
	while IFS= read -r hit; do
		[[ -n "${hit}" ]] || continue
		printf '\033[31m✗ 大写镜像名\033[0m %s\n' "${hit}"
		printf '    OCI 要求仓库名小写，建议改为：%s\n' \
			"$(printf '%s' "${hit}" | tr '[:upper:]' '[:lower:]')"
		bad_upper=$((bad_upper + 1))
		status=1
	done < <(grep -InHEo 'ghcr\.io/[A-Za-z0-9._/-]*[A-Z][A-Za-z0-9._/-]*' "${f}" 2>/dev/null || true)

	# --- 规则 2：全限定引用 -------------------------------------------------
	if grep -qE '^[[:space:]]*AutoUpdate=registry' "${f}" 2>/dev/null; then
		img="$(sed -n 's/^[[:space:]]*Image=//p' "${f}" | head -1)"
		if [[ -n "${img}" && "${img}" != */* ]]; then
			printf '\033[31m✗ 短名配 AutoUpdate\033[0m %s: Image=%s\n' "${f}" "${img}"
			printf '    AutoUpdate=registry 需要 registry/repo:tag 形式\n'
			bad_short=$((bad_short + 1))
			status=1
		fi
	fi
done <<<"${LIST}"

if [[ "${status}" -eq 0 ]]; then
	printf '\033[32mOK\033[0m 镜像引用全部合法（小写 + 全限定）\n'
	exit 0
fi

printf '\n共发现 %d 处大写、%d 处短名问题\n' "${bad_upper}" "${bad_short}" >&2
exit 1
