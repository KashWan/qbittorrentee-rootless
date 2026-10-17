#!/bin/sh
# =============================================================================
#  tests/identity.sh · qbt-lib.sh 的纯函数单元测试
#
#  不需要容器、不需要 root，可在任意 Linux/macOS 上运行：
#      sh tests/identity.sh
#  CI 的 validate.yml 会跑它，用于防止 uid_map 解析逻辑被改坏。
# =============================================================================

set -u

LIB="$(cd "$(dirname "$0")/.." && pwd)/rootfs/usr/local/bin/qbt-lib.sh"
# shellcheck disable=SC1090
. "${LIB}"

FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

eq() { # $1 描述  $2 实际  $3 期望
	if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1：期望 '$3'，实际 '$2'"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" 2>/dev/null || true' EXIT

# rootless 默认 userns：容器 0 → 宿主 1000，容器 1..65536 → 宿主 100000..
printf '         0       1000          1\n         1     100000      65536\n' > "${TMP}/rootless.uidmap"
printf '         0       1000          1\n         1     100000      65536\n' > "${TMP}/rootless.gidmap"
# rootful：完整 identity 映射
printf '         0          0 4294967295\n' > "${TMP}/rootful.map"
# --userns=keep-id：宿主 1000 映射到容器 1000
printf '      1000       1000          1\n         0     100000      65536\n' > "${TMP}/keepid.map"

echo "== in_userns =="
QBT_UID_MAP="${TMP}/rootless.uidmap" in_userns && ok "rootless 判定为 userns" || bad "rootless 应判定为 userns"
QBT_UID_MAP="${TMP}/rootful.map"     in_userns && bad "rootful 不应判定为 userns" || ok "rootful 判定为 identity"
QBT_UID_MAP="${TMP}/keepid.map"      in_userns && ok "keep-id 判定为 userns" || bad "keep-id 应判定为 userns"
QBT_UID_MAP="${TMP}/missing.map"     in_userns && bad "缺失 map 不应判定为 userns" || ok "缺失 map 返回非 0"

echo "== map_forward（容器内 → 宿主）=="
eq "rootless 容器 0"    "$(map_forward "${TMP}/rootless.uidmap" 0 || echo ERR)"     "1000"
eq "rootless 容器 1000" "$(map_forward "${TMP}/rootless.uidmap" 1000 || echo ERR)"  "100999"
eq "rootless 容器 65536" "$(map_forward "${TMP}/rootless.uidmap" 65536 || echo ERR)" "165535"
if map_forward "${TMP}/rootless.uidmap" 70000 >/dev/null 2>&1; then
	bad "未映射的 70000 不应返回值"
else
	ok "未映射的 70000 返回非 0"
fi
eq "rootful 容器 1234"  "$(map_forward "${TMP}/rootful.map" 1234 || echo ERR)"      "1234"
eq "keep-id 容器 1000"  "$(map_forward "${TMP}/keepid.map" 1000 || echo ERR)"       "1000"

echo "== map_reverse（宿主 → 容器内）=="
eq "rootless 宿主 1000"   "$(map_reverse "${TMP}/rootless.uidmap" 1000 || echo ERR)"   "0"
eq "rootless 宿主 101000" "$(map_reverse "${TMP}/rootless.uidmap" 101000 || echo ERR)" "1001"
eq "rootful 宿主 1234"    "$(map_reverse "${TMP}/rootful.map" 1234 || echo ERR)"       "1234"
if map_reverse "${TMP}/keepid.map" 5000 >/dev/null 2>&1; then
	bad "keep-id 下宿主 5000 未映射，不应有返回值"
else
	ok "keep-id 下未映射宿主 uid 返回非 0"
fi

echo "== qbt_normalize_umask =="
eq "022"  "$(qbt_normalize_umask 022 || echo ERR)"  "022"
eq "0022" "$(qbt_normalize_umask 0022 || echo ERR)" "0022"
eq "077"  "$(qbt_normalize_umask 077 || echo ERR)"  "077"
if qbt_normalize_umask "abc" >/dev/null 2>&1; then bad "abc 应被拒绝"; else ok "abc 被拒绝"; fi
if qbt_normalize_umask "8" >/dev/null 2>&1;   then bad "8 应被拒绝";   else ok "8 被拒绝"; fi
if qbt_normalize_umask "" >/dev/null 2>&1;    then bad "空值应被拒绝"; else ok "空值被拒绝"; fi

echo
if [ "${FAIL}" -eq 0 ]; then
	printf '\033[32m全部通过\033[0m\n'
	exit 0
fi
printf '\033[31m存在失败用例\033[0m\n'
exit 1
