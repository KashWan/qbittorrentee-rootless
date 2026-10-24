#!/usr/bin/env bash
# =============================================================================
#  publish-release.sh · 为「本次构建的上游版本」创建一个 GitHub Release
#
#  为什么要有它：
#    仓库原先只有镜像标签，没有 Release 页面 —— 想确认「上游有没有发新版」
#    只能去 GHCR 翻标签列表。Release 以版本号命名（5.2.4.10），与镜像的
#    不可变标签一一对应，GitHub 的 Releases 页面就成了一条按版本排好的时间线。
#
#  为什么 tag 不带 v 前缀：
#    build.yml 的 on.push.tags 里有 "v*"。若 Release tag 叫 v5.2.4.10，
#    任何一次手动 git push tag 都会额外触发一整轮完整构建。纯版本号不匹配
#    "v*"，没有这个耦合；同时它与镜像标签 5.2.4.10 完全同名，对照最直观。
#    （CI 用 GITHUB_TOKEN 创建 tag 本就不会触发 workflow，这里是不依赖该
#      隐式行为的额外一层保险。）
#
#  幂等：同名 release 已存在则退出 0。push 到 main 会重建镜像，但只有上游
#       出现新版本时才需要新 release，重复调用不应报错。
#
#  输入（环境变量）
#    VERSION        必填，上游版本号，如 5.2.4.10
#    UPSTREAM_TAG   上游 tag，缺省 release-<VERSION>
#    PUBLISHED_AT   上游发布时间（可空）
#    IMAGE          镜像名，缺省 ghcr.io/<REPO>
#    DIGEST         镜像 digest（可空）
#    REFS           本次推送的镜像标签，每行一个（可空）
#    REPO           owner/repo，缺省 $GITHUB_REPOSITORY
#    TARGET_SHA     tag 不存在时，release tag 要指向的 commit
#    GH_TOKEN       gh 认证（CI 里是 GITHUB_TOKEN）
#    DRY_RUN=true   只生成并打印说明，不创建
#
#  输出：写 GITHUB_OUTPUT 的 created=true|false
# =============================================================================

# 本脚本生成的是 Markdown 正文，其中的反引号是字面量而非命令替换。
# SC2016（"Expressions don't expand in single quotes"）在这个文件里恒为误报。
# 文件级指令必须出现在第一条命令之前，所以放在 set 之上。
# shellcheck disable=SC2016

set -Eeuo pipefail

die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

VERSION="${VERSION:-}"
[[ -n "${VERSION}" ]] || die "VERSION 未设置"
# 只接受上游的四段版本号。v0.1.0 这类是本仓库的 CI 触发 tag，不是发版依据。
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| die "VERSION '${VERSION}' 非法：只接受上游 release 版本（形如 5.2.4.10）"

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
[[ -n "${REPO}" ]] || die "REPO 未设置（owner/repo）"

IMAGE="${IMAGE:-ghcr.io/${REPO}}"
UPSTREAM_REPO="c0re100/qBittorrent-Enhanced-Edition"
UPSTREAM_TAG="${UPSTREAM_TAG:-release-${VERSION}}"
TARGET_SHA="${TARGET_SHA:-}"
PUBLISHED_AT="${PUBLISHED_AT:-}"
DIGEST="${DIGEST:-}"
REFS="${REFS:-}"
DRY_RUN="${DRY_RUN:-false}"
OUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

command -v gh >/dev/null 2>&1 || die "找不到 gh（GitHub CLI）"

# -----------------------------------------------------------------------------
# 1. 幂等：已有同名 release 就结束
# -----------------------------------------------------------------------------
if gh release view "${VERSION}" --repo "${REPO}" >/dev/null 2>&1; then
	note "Release ${VERSION} 已存在，跳过"
	printf 'created=false\n' >>"${OUT_FILE}"
	exit 0
fi

# -----------------------------------------------------------------------------
# 2. 判断是不是当前最新版本 —— 决定要不要打 --latest
#    只和「纯版本号」形态的 release 比较，v0.1.0 之类不参与排序
# -----------------------------------------------------------------------------
existing=""
existing="$(gh release list --repo "${REPO}" --exclude-drafts \
	--exclude-pre-releases --limit 100 --json tagName \
	-q '.[].tagName' 2>/dev/null \
	| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"

newest="$(printf '%s\n%s\n' "${existing}" "${VERSION}" \
	| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

is_latest=false
if [[ "${newest}" == "${VERSION}" ]]; then
	is_latest=true
fi

# -----------------------------------------------------------------------------
# 3. tag 是否已存在 —— 存在就不能传 --target，否则 gh 直接报错退出
# -----------------------------------------------------------------------------
tag_exists=false
if gh api "repos/${REPO}/git/ref/tags/${VERSION}" >/dev/null 2>&1; then
	tag_exists=true
fi

# -----------------------------------------------------------------------------
# 4. Release 说明
#    用 printf 逐段拼，不用 heredoc：说明里含 ``` 代码块，heredoc 会把
#    反引号当命令替换，引号包裹的 heredoc 又无法展开变量。
# -----------------------------------------------------------------------------
notes="$(mktemp)"
# EXIT trap 的最后一个命令决定脚本退出码，所以 rm 失败不能传导出去
trap 'if [[ -n "${notes:-}" ]]; then rm -f "${notes}" 2>/dev/null || true; fi' EXIT

{
	printf '## 与上游 release 同步的镜像 `%s`\n\n' "${VERSION}"
	printf '本 Release 由 CI 自动创建，版本号与上游 release 完全一致，'
	printf '仅用于观察上游版本更新。\n\n'
	printf '| 项 | 值 |\n'
	printf '|---|---|\n'
	printf '| 镜像版本 | `%s` |\n' "${VERSION}"
	printf '| 上游版本 | [`%s`](https://github.com/%s/releases/tag/%s) |\n' \
		"${UPSTREAM_TAG}" "${UPSTREAM_REPO}" "${UPSTREAM_TAG}"
	if [[ -n "${PUBLISHED_AT}" ]]; then
		printf '| 上游发布 | %s |\n' "${PUBLISHED_AT}"
	fi
	printf '| 平台 | linux/amd64 |\n'
	if [[ -n "${DIGEST}" ]]; then
		printf '| Digest | `%s` |\n' "${DIGEST}"
	fi
	printf '\n### 拉取\n\n'
	printf '```bash\ndocker pull %s:%s\npodman pull %s:%s\n```\n\n' \
		"${IMAGE}" "${VERSION}" "${IMAGE}" "${VERSION}"
	if [[ -n "${REFS}" ]]; then
		printf '### 本次推送的镜像标签\n\n```\n'
		printf '%s\n' "${REFS}" | grep -v '^[[:space:]]*$' | sed 's|.*:||' || true
		printf '```\n\n'
	fi
	printf '### 说明\n\n'
	printf '%s\n' \
		'- 二进制直接取自上游 musl 静态包，未做任何源码修改；本镜像只负责容器与 rootless 适配。' \
		'- 只构建 `linux/amd64`，不使用 QEMU。' \
		"- 上游发布说明：https://github.com/${UPSTREAM_REPO}/releases/tag/${UPSTREAM_TAG}"
} >"${notes}"

if [[ "${DRY_RUN}" == "true" ]]; then
	note "DRY_RUN=true：不创建 Release，仅输出说明"
	cat "${notes}"
	printf 'created=false\n' >>"${OUT_FILE}"
	exit 0
fi

# -----------------------------------------------------------------------------
# 5. 创建
# -----------------------------------------------------------------------------
args=(release create "${VERSION}" --title "${VERSION}" --notes-file "${notes}")
if [[ "${tag_exists}" == "false" && -n "${TARGET_SHA}" ]]; then
	args+=(--target "${TARGET_SHA}")
fi
if [[ "${is_latest}" == "true" ]]; then
	args+=(--latest)
fi

note "创建 Release ${VERSION}（latest=${is_latest} tag_exists=${tag_exists}）"
gh "${args[@]}" --repo "${REPO}"

printf 'created=true\n' >>"${OUT_FILE}"
note "Release ${VERSION} 创建完成"
