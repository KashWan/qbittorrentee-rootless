#!/usr/bin/env bash
# =============================================================================
#  tests/resolve-upstream.sh · 用桩件离线验证 scripts/resolve-upstream.sh
#
#  不访问网络、不需要 jq/curl：在临时目录里伪造 curl 与 jq，
#  校验「版本归一化 → 资产齐备性 → 标签组装 → 跳过/构建」这条逻辑。
#
#  用法： bash tests/resolve-upstream.sh
# =============================================================================

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/resolve-upstream.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qbt-resolve.XXXXXX")"
FAIL=0

cleanup() { rm -rf "${TMP}" 2>/dev/null || true; }
trap cleanup EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
eq()   { if [[ "$2" == "$3" ]]; then pass "$1 = $2"; else fail "$1：期望 '$3'，实际 '$2'"; fi; }
has()  { if grep -qxF "$3" <<<"$2"; then pass "$1 含 $3"; else fail "$1 缺少 $3"; fi; }

mkdir -p "${TMP}/bin" "${TMP}/out"

# --- 伪造 curl ---------------------------------------------------------------
# FAKE_HTTP_CODE  注册表 manifest 请求返回的状态码（默认 404 = 标签不存在）
# FAKE_TAG_JSON   带 tag 的 release JSON 文件
# FAKE_LIST_JSON  列表形式的 release JSON 文件
cat > "${TMP}/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""; url=""; wantcode=0
args=("$@")
for i in "${!args[@]}"; do
	case "${args[$i]}" in
		-o) out="${args[$((i + 1))]}" ;;
		-w) wantcode=1 ;;
	esac
done
for a in "${args[@]}"; do
	case "$a" in
		http*|*ghcr.io*) url="$a" ;;
	esac
done

if [[ "${wantcode}" -eq 1 ]]; then
	echo "${FAKE_HTTP_CODE:-404}"
	exit 0
fi

emit() { # $1 文件
	if [[ -n "${out}" && "${out}" != "/dev/null" ]]; then
		cat "$1" > "${out}"
	else
		cat "$1"
	fi
}

case "${url}" in
	*api.github.com/repos/*/releases/tags/*) emit "${FAKE_TAG_JSON}" ;;
	*api.github.com/repos/*/releases*)       emit "${FAKE_LIST_JSON}" ;;
	*ghcr.io/token*)                         echo "{\"token\":\"${FAKE_TOKEN:-}\"}" ;;
	*) exit 22 ;;
esac
CURL

# --- 伪造 jq（只认本脚本用到的过滤器；过滤器永远是最后一个参数）---------------
cat > "${TMP}/bin/jq" <<'JQ'
#!/usr/bin/env bash
filter="${!#}"
case "${filter}" in
	*".token"*)                   printf '%s\n' "${FAKE_TOKEN:-}" ;;
	*".published_at // \"\""*)    printf '%s\n' "${FAKE_PUBLISHED:-2026-10-03T18:04:46Z}" ;;
	*".prerelease // false"*)     printf '%s\n' "${FAKE_PRERELEASE:-false}" ;;
	*".assets[].name"*)           printf '%s\n' ${FAKE_ASSETS} ;;
	*"test("*)                    printf '%s\n' "${FAKE_TAG:-release-5.2.4.10}" ;;
	*"select(.tag_name==\$t)"*)   printf '%s\n' "${FAKE_PUBLISHED:-2026-10-03T18:04:46Z}" ;;
	*)                            printf '' ;;
esac
JQ
chmod +x "${TMP}/bin/curl" "${TMP}/bin/jq"

# --- 伪造 release JSON -------------------------------------------------------
cat > "${TMP}/release.json" <<'JSON'
{
  "tag_name": "release-5.2.4.10",
  "published_at": "2026-10-03T18:04:46Z",
  "prerelease": false,
  "assets": [
    {"name": "qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip"},
    {"name": "qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip"}
  ]
}
JSON

cat > "${TMP}/release-missing.json" <<'JSON'
{
  "tag_name": "release-5.2.4.11",
  "published_at": "2026-10-10T00:00:00Z",
  "prerelease": false,
  "assets": [
    {"name": "qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip"}
  ]
}
JSON

export PATH="${TMP}/bin:${PATH}"
export FAKE_TAG_JSON="${TMP}/release.json"
export FAKE_LIST_JSON="${TMP}/release.json"
export FAKE_ASSETS="qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip
qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip"

run_case() { # $1 输出文件
	# 前缀赋值作用于 bash 子进程（对函数调用本身的赋值不会自动 export）
	IMAGE="ghcr.io/Some/Repo" \
	GITHUB_OUTPUT="$1" \
	GITHUB_SHA="${GITHUB_SHA:-}" \
	GH_TOKEN="" \
	FORCE="${FORCE:-false}" \
	INPUT_VERSION="${INPUT_VERSION:-}" \
	EVENT_NAME="${EVENT_NAME:-workflow_dispatch}" \
	FAKE_TOKEN="${FAKE_TOKEN:-}" \
	FAKE_HTTP_CODE="${FAKE_HTTP_CODE:-404}" \
	bash "${SCRIPT}" >"${TMP}/log" 2>&1
}

multiline() { sed -n "/^$2<<__EOF__\$/,/^__EOF__\$/p" "$1" | sed '1d;$d'; }

echo "== 用例 1：自动取最新版本，FORCE=true =="
: > "${TMP}/out/1"
if FORCE=true EVENT_NAME=schedule GITHUB_SHA=abcdef1234567890 run_case "${TMP}/out/1"; then
	pass "脚本执行成功"
	o="$(cat "${TMP}/out/1")"
	eq "build"          "$(sed -n 's/^build=//p' <<<"${o}")" "true"
	eq "version"        "$(sed -n 's/^version=//p' <<<"${o}")" "5.2.4.10"
	eq "published_at"   "$(sed -n 's/^published_at=//p' <<<"${o}")" "2026-10-03T18:04:46Z"
	eq "image 已转小写" "$(sed -n 's/^image=//p' <<<"${o}")" "ghcr.io/some/repo"
	has "tags"    "$(multiline "${TMP}/out/1" tags)"    "ghcr.io/some/repo:5.2.4.10"
	has "tags"    "$(multiline "${TMP}/out/1" tags)"    "ghcr.io/some/repo:sha-abcdef1"
	has "aliases" "$(multiline "${TMP}/out/1" aliases)" "ghcr.io/some/repo:5.2"
	has "aliases" "$(multiline "${TMP}/out/1" aliases)" "ghcr.io/some/repo:5"
	has "aliases" "$(multiline "${TMP}/out/1" aliases)" "ghcr.io/some/repo:latest"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 2：push 事件额外产出 edge 标签 =="
: > "${TMP}/out/2"
if FORCE=false EVENT_NAME=push GITHUB_SHA=abcdef1234567890 run_case "${TMP}/out/2"; then
	has "tags" "$(multiline "${TMP}/out/2" tags)" "ghcr.io/some/repo:edge"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 3：手动指定版本（带 release- 前缀）=="
: > "${TMP}/out/3"
if INPUT_VERSION="release-5.2.4.9" FORCE=true EVENT_NAME=workflow_dispatch run_case "${TMP}/out/3"; then
	eq "version" "$(sed -n 's/^version=//p' "${TMP}/out/3")" "5.2.4.9"
	has "tags"   "$(multiline "${TMP}/out/3" tags)" "ghcr.io/some/repo:5.2.4.9"
	has "aliases" "$(multiline "${TMP}/out/3" aliases)" "ghcr.io/some/repo:5.2"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 4：非法版本号应失败 =="
: > "${TMP}/out/4"
if INPUT_VERSION="oops" FORCE=true run_case "${TMP}/out/4"; then
	fail "非法版本号竟然通过了"
else
	pass "非法版本号被拒绝"
fi

echo "== 用例 5：上游缺 x86_64 静态包应失败 =="
: > "${TMP}/out/5"
if FAKE_TAG_JSON="${TMP}/release-missing.json" \
	FAKE_LIST_JSON="${TMP}/release-missing.json" \
	FAKE_TAG="release-5.2.4.11" \
	FAKE_ASSETS="qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip" \
	FORCE=true EVENT_NAME=schedule run_case "${TMP}/out/5"; then
	fail "缺资产竟然通过了"
elif grep -q "缺少必需资产" "${TMP}/log"; then
	pass "缺资产被拒绝，且提示清晰"
else
	fail "失败但提示不明确：$(cat "${TMP}/log")"
fi

echo "== 用例 6：标签已存在时应 SKIP（零构建开销）=="
: > "${TMP}/out/6"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=200 FORCE=false EVENT_NAME=schedule run_case "${TMP}/out/6"; then
	eq "build"  "$(sed -n 's/^build=//p' "${TMP}/out/6")" "false"
	eq "reason" "$(sed -n 's/^reason=//p' "${TMP}/out/6")" "镜像 ghcr.io/some/repo:5.2.4.10 已存在，上游无新版本"
else
	fail "SKIP 分支执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 7：已存在但 FORCE=true 时必须重建 =="
: > "${TMP}/out/7"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=200 FORCE=true EVENT_NAME=workflow_dispatch run_case "${TMP}/out/7"; then
	eq "build" "$(sed -n 's/^build=//p' "${TMP}/out/7")" "true"
else
	fail "FORCE 分支执行失败：$(cat "${TMP}/log")"
fi

echo
if [[ "${FAIL}" -eq 0 ]]; then
	printf '\033[32m全部通过\033[0m\n'
	exit 0
fi
printf '\033[31m%d 个用例失败\033[0m\n' "${FAIL}"
exit 1
