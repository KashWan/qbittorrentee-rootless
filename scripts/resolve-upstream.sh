#!/usr/bin/env bash
# =============================================================================
#  resolve-upstream.sh · 决定「要不要构建、构建哪个版本、推哪些标签」
#
#  输入（环境变量）
#    IMAGE            镜像名，默认 ghcr.io/${GITHUB_REPOSITORY}
#    INPUT_VERSION    可选，手动指定上游版本（5.2.4.10 或 release-5.2.4.10）
#    FORCE            true 时忽略「标签已存在」，强制重建
#    GH_TOKEN         GitHub token（读取 private 包 / 避免 API 限流）
#    EVENT_NAME       push / schedule / workflow_dispatch
#    GITHUB_OUTPUT    由 Actions 提供
#
#  输出（写 GITHUB_OUTPUT）
#    build=true|false   reason   version   tag   image   primary_ref
#    tags（多行，version/sha/edge）  aliases（多行，major.minor/major/latest）
#    push_tags（多行，tags + aliases 的合集，CI 在冒烟通过后一次性推送）
#
#  版本来源（唯一）：
#    只认上游 c0re100/qBittorrent-Enhanced-Edition 的 release tag
#    （形如 release-5.2.4.10）。本仓库自己的 tag —— v0.1.0 之类 ——
#    只用于触发 CI，**永远不会**成为镜像版本号；传入此类值会直接失败。
# =============================================================================

set -Eeuo pipefail

die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m==>\033[0m %s\n' "$*"; }

out() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未设置}"; }
out_multi() { printf '%s<<__EOF__\n%s\n__EOF__\n' "$1" "$2" >> "${GITHUB_OUTPUT:?}"; }

IMAGE="${IMAGE:-ghcr.io/${GITHUB_REPOSITORY:-local/qbittorrentee}}"
IMAGE="${IMAGE,,}"
FORCE="${FORCE:-false}"
INPUT_VERSION="${INPUT_VERSION:-}"
EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
UPSTREAM_REPO="c0re100/qBittorrent-Enhanced-Edition"

api_headers=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
if [[ -n "${GH_TOKEN:-}" ]]; then
	api_headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

# -----------------------------------------------------------------------------
# 1. 归一化版本号
# -----------------------------------------------------------------------------
normalize_version() {
	local v="$1"
	v="${v#release-}"; v="${v#v}"
	printf '%s' "$v"
}

# -----------------------------------------------------------------------------
# 2. 取上游版本
# -----------------------------------------------------------------------------
TAG=""
PUBLISHED=""
PRERELEASE="false"
ASSETS=""

if [[ -n "${INPUT_VERSION}" ]]; then
	VER="$(normalize_version "${INPUT_VERSION}")"
	# 只接受上游的 x.y.z.w 四段版本号。像 v0.1.0（本仓库的 CI 触发 tag）
	# 这种三段号在这里必须失败，否则镜像标签会跟上游脱钩。
	[[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "版本 '${INPUT_VERSION}' 非法：只接受上游 release 版本（形如 5.2.4.10 或 release-5.2.4.10）。本仓库的 v0.1.0 之类 tag 仅用于触发 CI，不是镜像版本来源。"
	TAG="release-${VER}"
	note "使用手动指定版本：${TAG}"

	rel_json="$(curl -fsSL --max-time 30 "${api_headers[@]}" \
		"https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/${TAG}")" \
		|| die "上游不存在该版本：${TAG}"
	PUBLISHED="$(jq -r '.published_at // ""' <<<"${rel_json}")"
	PRERELEASE="$(jq -r '.prerelease // false' <<<"${rel_json}")"
	ASSETS="$(jq -r '.assets[].name' <<<"${rel_json}")"
else
	note "查询上游最新 release…"
	rel_json="$(curl -fsSL --max-time 30 "${api_headers[@]}" \
		"https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=10")" \
		|| die "无法访问 GitHub API（网络或限流）"

	# 取最新的非 prerelease、且 tag 形如 release-x.y.z.w 的发布
	TAG="$(jq -r '[.[] | select(.prerelease == false) | select(.tag_name | test("^release-[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))][0].tag_name // empty' <<<"${rel_json}")"
	[[ -n "${TAG}" ]] || die "未找到符合格式的上游 release"
	VER="$(normalize_version "${TAG}")"
	PUBLISHED="$(jq -r --arg t "${TAG}" '.[] | select(.tag_name==$t) | .published_at' <<<"${rel_json}")"
	PRERELEASE="false"
	ASSETS="$(jq -r --arg t "${TAG}" '.[] | select(.tag_name==$t) | .assets[].name' <<<"${rel_json}")"
	note "上游最新版本：${TAG}（${PUBLISHED}）"
fi

[[ "${VER}" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+\.[0-9]+$ ]] || die "版本号解析失败：${VER}"
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"

# -----------------------------------------------------------------------------
# 3. 校验静态包是否齐备（只看 x86_64：本镜像只构建 linux/amd64）
# -----------------------------------------------------------------------------
need_assets=(
	"qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip"
)
missing=()
for a in "${need_assets[@]}"; do
	grep -qxF "${a}" <<<"${ASSETS}" || missing+=("${a}")
done
if (( ${#missing[@]} > 0 )); then
	die "上游 ${TAG} 缺少必需资产：${missing[*]}"
fi
note "静态包校验通过（x86_64）"

# -----------------------------------------------------------------------------
# 4. 组装标签
#    不可变标签 : <version>  sha-<commit>（push 事件再加 edge）
#    晋升标签   : <major>.<minor>  <major>  latest
#    push_tags  : 上面两者的合集 —— CI 在冒烟通过后一次性推送
# -----------------------------------------------------------------------------
SHORT_SHA="${GITHUB_SHA:-}"
SHORT_SHA="${SHORT_SHA:0:7}"
tags="${IMAGE}:${VER}"
if [[ -n "${SHORT_SHA}" ]]; then
	tags+=$'\n'"${IMAGE}:sha-${SHORT_SHA}"
fi
# edge 的语义是「main 分支最新一次构建」，所以只认 refs/heads/*。
# 推 v0.1.0 这类 tag 同样会走 push 事件，但那是发版触发，不是 main 前进，
# 不能把 edge 挪到 tag 指向的 commit 上。
if [[ "${EVENT_NAME}" == "push" && "${GITHUB_REF:-}" == refs/heads/* ]]; then
	tags+=$'\n'"${IMAGE}:edge"
fi

aliases="${IMAGE}:${MAJOR}.${MINOR}"$'\n'"${IMAGE}:${MAJOR}"
if [[ "${PRERELEASE}" != "true" ]]; then
	aliases+=$'\n'"${IMAGE}:latest"
fi

push_tags="${tags}"$'\n'"${aliases}"

PRIMARY_REF="${IMAGE}:${VER}"

# -----------------------------------------------------------------------------
# 5. 检测目标标签是否已存在
# -----------------------------------------------------------------------------
ghcr_token() {
	local repo="$1" tok=""
	tok="$(curl -fsSL --max-time 20 \
		"https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null \
		| jq -r '.token // empty')" || true
	if [[ -z "${tok}" && -n "${GH_TOKEN:-}" ]]; then
		tok="$(curl -fsSL --max-time 20 -u "${GITHUB_ACTOR:-ci}:${GH_TOKEN}" \
			"https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null \
			| jq -r '.token // empty')" || true
	fi
	printf '%s' "${tok}"
}

tag_exists() {
	local ref="$1" repo token code
	repo="${ref#"${IMAGE}:"}"
	[[ "${IMAGE}" == ghcr.io/* ]] || return 1
	token="$(ghcr_token "${IMAGE#ghcr.io/}")"
	[[ -n "${token}" ]] || return 1
	code="$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
		-X HEAD \
		-H "Authorization: Bearer ${token}" \
		-H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
		"https://ghcr.io/v2/${IMAGE#ghcr.io/}/manifests/${repo}" || echo 000)"
	[[ "${code}" == "200" ]]
}

finish_skip() {
	out build "false"
	out reason "$1"
	out image "${IMAGE}"
	out version "${VER}"
	out tag "${TAG}"
	note "SKIP: $1"
	exit 0
}

if [[ "${FORCE}" == "true" ]]; then
	note "FORCE=true，忽略已存在的 ${PRIMARY_REF}"
elif [[ "${EVENT_NAME}" == "push" ]]; then
	note "push 触发强制重建：${GITHUB_REF:-<未设置>}（edge 仅在 main 分支产出）"
elif tag_exists "${PRIMARY_REF}"; then
	finish_skip "镜像 ${PRIMARY_REF} 已存在，上游无新版本"
fi

# -----------------------------------------------------------------------------
# 6. 输出
# -----------------------------------------------------------------------------
out build "true"
out reason "ready"
out image "${IMAGE}"
out version "${VER}"
out tag "${TAG}"
out prerelease "${PRERELEASE}"
out published_at "${PUBLISHED:-}"
out primary_ref "${PRIMARY_REF}"
out_multi tags "${tags}"
out_multi aliases "${aliases}"
out_multi push_tags "${push_tags}"

note "待构建：${PRIMARY_REF}"
note "构建标签："$'\n'"${tags}"
note "晋升标签："$'\n'"${aliases}"
note "冒烟通过后一次性推送以上全部标签"
