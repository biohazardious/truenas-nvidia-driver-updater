#!/bin/bash
# =============================================================================
# driver-labels-test.sh — offline test for the NVIDIA branch labels in
# configure.sh. Pages and API answers come from tests/fixtures/nvidia/.
#
# Usage:  tests/driver-labels-test.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="${REPO}/tests/fixtures/nvidia"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
is()  { [[ "$1" == "$2" ]]; }
not() { ! "$@"; }

# ── lift the code under test out of configure.sh ─────────────────────────────
{
    sed -n '/^NVIDIA_UNIX_PAGE_URL=/p;/^NVIDIA_LOOKUP_URL=/p' "${REPO}/configure.sh"
    sed -n '/^NVIDIA_LOOKUP_FALLBACK=(/,/^)/p' "${REPO}/configure.sh"
    for fn in nvidia_major nvidia_lookup_queries nvidia_lookup_version fetch_nvidia_branch_info; do
        sed -n "/^${fn}() {/,/^}/p" "${REPO}/configure.sh"
    done
} > "${WORK}/code.sh"
# shellcheck disable=SC1091
source "${WORK}/code.sh"

info() { echo "info: $*" >> "${WORK}/out"; }
warn() { echo "warn: $*" >> "${WORK}/out"; }
ok()   { echo "ok: $*" >> "${WORK}/out"; }
declare -n TAG=NVIDIA_VERSION_TAGS

# Stub: what the page and the API answer. Scenarios change these variables.
PAGE_FILE="${FX}/unix-page.html"   # empty → the page fetch fails
API_DOWN=0
PB_FILE="${FX}/api-PB.json"
fetch_url() {
    case "$1" in
        *drivers/unix/*) [[ -n "${PAGE_FILE}" ]] && cat "${PAGE_FILE}" || return 1 ;;
        *AjaxDriverService*)
            [[ ${API_DOWN} -eq 1 ]] && return 1
            case "$1" in
                *release=470*) cat "${FX}/api-LEG.json" ;;
                *qnf=1*)       cat "${FX}/api-NFB.json" ;;
                *beta=1*)      cat "${FX}/api-BETA.json" ;;
                *beta=0*)      cat "${PB_FILE}" ;;
                *)             return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

VERSIONS=(620.70.06 615.78.08 610.57.04 595.112.07 595.45.04 580.196.07 470.256.02)
run() { : > "${WORK}/out"; fetch_nvidia_branch_info "$@"; }

echo "labels from NVIDIA's page queries"
run "${VERSIONS[@]}"
check "620.70.06 is Production"    is "${TAG[620.70.06]}" "★ Production Branch"
check "615.78.08 is New Feature"   is "${TAG[615.78.08]}" "★ New Feature Branch"
check "595.45.04 is Beta"          is "${TAG[595.45.04]}" "Beta — not for production use"
check "470.256.02 is Legacy"       is "${TAG[470.256.02]}" "★ Legacy GPU (470.xx)"
check "595.112.07 has no label"    is "${TAG[595.112.07]:-}" ""
check "four linux64 queries read"  is "$(nvidia_lookup_queries < "${FX}/unix-page.html" | wc -l)" 4
check "info flag set"              is "${NVIDIA_BRANCH_INFO_OK}" 1

echo "page unreadable → built-in queries"
PAGE_FILE=""
run "${VERSIONS[@]}"
check "Production still labelled"  is "${TAG[620.70.06]}" "★ Production Branch"
check "says it used built-in ones" grep -q "built-in NVIDIA lookup queries" "${WORK}/out"

echo "page without the BETA block"
PAGE_FILE="${WORK}/nobeta.html"
sed 's/"drvrType": "BETA"/"drvrType": "GONE"/' "${FX}/unix-page.html" > "${WORK}/nobeta.html"
run "${VERSIONS[@]}"
check "Beta label absent, others kept" is "${TAG[595.45.04]:-}|${TAG[620.70.06]}" "|★ Production Branch"

echo "API unreachable"
PAGE_FILE="${FX}/unix-page.html"; API_DOWN=1
run "${VERSIONS[@]}"
check "no labels at all"           is "${#TAG[@]}" 0
check "says labels are unavailable" grep -q "Branch labels unavailable" "${WORK}/out"
check "info flag cleared"          is "${NVIDIA_BRANCH_INFO_OK}" 0
API_DOWN=0

echo "API names a version not on the server"
run 620.70.06 610.57.04 595.112.07 595.45.04 580.196.07 470.256.02
check "New Feature label dropped"  is "${NVIDIA_BRANCH_VERSION[NFB]:-}" ""
check "Production kept"            is "${NVIDIA_BRANCH_VERSION[PB]:-}" "620.70.06"

echo "hostile page"
sed -e 's/psid=133&pfid=1075/psid=1;rm -rf \/\&x=$(id)/' -e 's/psid=122&pfid=944/a b/' \
    "${FX}/unix-page.html" > "${WORK}/bad.html"
check "rejected params are skipped" is "$(nvidia_lookup_queries < "${WORK}/bad.html" | wc -l)" 0

echo "wrong flag in response"
PB_FILE="${FX}/api-NFB.json"
run "${VERSIONS[@]}"
check "PB not taken from an NFB answer" is "${NVIDIA_BRANCH_VERSION[PB]:-}" ""
PB_FILE="${FX}/api-PB.json"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
