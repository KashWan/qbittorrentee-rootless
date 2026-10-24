#!/usr/bin/env bash
# =============================================================================
#  tests/publish-release.sh · publish-release.sh 的离线单元测试
#
#  用桩件顶替 gh，不联网、不需要 token，验证三件容易出错的事：
#    - 幂等：同名 Release 已存在时不重复创建
#    - --latest 的判定：只有比现有最大版本更新才打这个标记
#    - tag 已存在时不能传 --target（否则 gh 直接报错）
#
#  用法： bash tests/publish-release.sh
# =============================================================================

# 断言里比对的是 Markdown 正文，含字面反引号；SC2016 在此为误报。
# 文件级指令必须出现在第一条命令之前，所以放在 set 之上。
# shellcheck disable=SC2016

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/publish-release.sh"
[[ -f "${SCRIPT}" ]] || { echo "找不到 ${SCRIPT}" >&2; exit 1; }

TMP="$(mktemp -d)"
# 清理失败不能影响脚本退出码（EXIT trap 的最后一条命令决定它）
trap 'rm -rf "${TMP}" 2>/dev/null || true' EXIT
mkdir -p "${TMP}/bin"

# --- gh 桩件 ---------------------------------------------------------------
# STUB_RELEASE_EXISTS=1  -> gh release view 成功
# STUB_TAGS="a b"        -> gh release list 输出的 tag
# STUB_TAG_REF=1         -> gh api .../git/ref/tags/... 成功
# 调用 gh release create 时把参数写入 $STUB_LOG
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "release" ]]; then
	case "${2:-}" in
	view)
		[[ "${STUB_RELEASE_EXISTS:-0}" == "1" ]] && exit 0
		exit 1
		;;
	list)
		printf '%s\n' ${STUB_TAGS:-}
		exit 0
		;;
	create)
		shift 2
		printf '%s\n' "$*" >>"${STUB_LOG:?}"
		exit 0
		;;
	esac
fi
if [[ "${1:-}" == "api" ]]; then
	[[ "${STUB_TAG_REF:-0}" == "1" ]] && exit 0
	exit 1
fi
exit 0
STUB
chmod +x "${TMP}/bin/gh"

export PATH="${TMP}/bin:${PATH}"
export STUB_LOG="${TMP}/calls.log"
: >"${STUB_LOG}"

pass=0
fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no() {
	printf '  \033[31mFAIL\033[0m %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '%s\n' "${2}" | sed 's/^/       /'
	fail=$((fail + 1))
}

run() { # run <输出文件> [环境变量…]
	local out="$1"
	shift
	local rc=0
	( env REPO="owner/repo" GITHUB_OUTPUT="${TMP}/out.env" "$@" \
		bash "${SCRIPT}" ) >"${out}" 2>&1 || rc=$?
	return "${rc}"
}

echo "== 用例 1：同名 Release 已存在 → 幂等跳过 =="
: >"${STUB_LOG}"
: >"${TMP}/out.env"
rc=0
run "${TMP}/o1" STUB_RELEASE_EXISTS=1 VERSION=5.2.4.10 || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "已存在" "${TMP}/o1" \
	&& [[ "$(cat "${TMP}/out.env")" == "created=false" ]] \
	&& [[ ! -s "${STUB_LOG}" ]]; then
	ok "已存在的版本不重复创建"
else
	no "幂等跳过" "rc=${rc} out=$(cat "${TMP}/o1") calls=$(cat "${STUB_LOG}")"
fi

echo "== 用例 2：DRY_RUN 生成说明，不调用 create =="
: >"${STUB_LOG}"
: >"${TMP}/out.env"
rc=0
run "${TMP}/o2" \
	DRY_RUN=true VERSION=5.2.4.10 UPSTREAM_TAG=release-5.2.4.10 \
	IMAGE=ghcr.io/owner/repo DIGEST=sha256:deadbeef0000 \
	REFS=$'ghcr.io/owner/repo:5.2.4.10\nghcr.io/owner/repo:latest\nghcr.io/owner/repo:edge' \
	STUB_RELEASE_EXISTS=0 STUB_TAG_REF=0 STUB_TAGS="" || rc=$?
o2="$(cat "${TMP}/o2")"
if [[ "${rc}" -eq 0 ]] \
	&& grep -q '## 与上游 release 同步的镜像 `5.2.4.10`' <<<"${o2}" \
	&& grep -q 'release-5.2.4.10' <<<"${o2}" \
	&& grep -q 'docker pull ghcr.io/owner/repo:5.2.4.10' <<<"${o2}" \
	&& grep -q 'sha256:deadbeef0000' <<<"${o2}" \
	&& grep -qx 'edge' <<<"${o2}" \
	&& [[ ! -s "${STUB_LOG}" ]]; then
	ok "说明内容完整，且未创建 Release"
else
	no "DRY_RUN 说明" "rc=${rc} out=${o2} calls=$(cat "${STUB_LOG}")"
fi

echo "== 用例 3：本仓库 tag（v0.1.0）不得作为发版版本 =="
rc=0
run "${TMP}/o3" VERSION=v0.1.0 || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q "只接受上游 release 版本" "${TMP}/o3"; then
	ok "v0.1.0 被拒绝"
else
	no "v0.1.0 应被拒绝" "rc=${rc} out=$(cat "${TMP}/o3")"
fi

echo "== 用例 4：比现有最大版本新 → 打 --latest =="
: >"${STUB_LOG}"
rc=0
run "${TMP}/o4" VERSION=5.2.4.10 STUB_RELEASE_EXISTS=0 STUB_TAG_REF=0 \
	STUB_TAGS="5.2.4.9 5.1.0.1" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q -- "--latest" "${STUB_LOG}"; then
	ok "新版本带 --latest"
else
	no "--latest" "rc=${rc} calls=$(cat "${STUB_LOG}")"
fi

echo "== 用例 5：比现有最大版本旧 → 不带 --latest =="
: >"${STUB_LOG}"
rc=0
run "${TMP}/o5" VERSION=5.2.4.9 STUB_RELEASE_EXISTS=0 STUB_TAG_REF=0 \
	STUB_TAGS="5.2.4.10" || rc=$?
if [[ "${rc}" -eq 0 ]] && ! grep -q -- "--latest" "${STUB_LOG}"; then
	ok "旧版本不带 --latest"
else
	no "旧版本无 --latest" "rc=${rc} calls=$(cat "${STUB_LOG}")"
fi

echo "== 用例 6：tag 已存在 → 不传 --target =="
: >"${STUB_LOG}"
rc=0
run "${TMP}/o6" VERSION=5.2.4.10 TARGET_SHA=abc1234 STUB_RELEASE_EXISTS=0 \
	STUB_TAG_REF=1 STUB_TAGS="" || rc=$?
if [[ "${rc}" -eq 0 ]] && ! grep -q -- "--target" "${STUB_LOG}"; then
	ok "tag 已存在时省略 --target"
else
	no "省略 --target" "rc=${rc} calls=$(cat "${STUB_LOG}")"
fi

echo "== 用例 7：tag 不存在且有 TARGET_SHA → 带 --target =="
: >"${STUB_LOG}"
rc=0
run "${TMP}/o7" VERSION=5.2.4.10 TARGET_SHA=abc1234 STUB_RELEASE_EXISTS=0 \
	STUB_TAG_REF=0 STUB_TAGS="" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q -- "--target abc1234" "${STUB_LOG}"; then
	ok "tag 不存在时用 commit 定位"
else
	no "--target" "rc=${rc} calls=$(cat "${STUB_LOG}")"
fi

printf '\n通过 %d 项，失败 %d 项\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
