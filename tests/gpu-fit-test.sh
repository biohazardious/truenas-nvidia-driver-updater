#!/bin/bash
# =============================================================================
# gpu-fit-test.sh — offline test for GPU detection by PCI ID, the README
# support lookup, the fit tags / recommendation / advice built on them, and the
# driver menu default in configure.sh. READMEs, lspci output, NVIDIA's page and
# its lookup answers come from tests/fixtures/nvidia/.
#
# Usage:  tests/gpu-fit-test.sh
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
    echo 'declare -gA NVIDIA_CHIPS_CACHE=()'
    sed -n '/^NVIDIA_MIN_MAJOR=/p;/^NVIDIA_UNIX_PAGE_URL=/p;/^NVIDIA_LOOKUP_URL=/p' "${REPO}/configure.sh"
    sed -n '/^NVIDIA_LOOKUP_FALLBACK=(/,/^)/p' "${REPO}/configure.sh"
    for fn in parse_nvidia_gpus nvidia_supported_chips gpu_support gpu_name gpu_display_name detect_nvidia_gpu \
              nvidia_major nvidia_latest_in_series nvidia_lookup_queries nvidia_lookup_version \
              fetch_nvidia_branch_info apply_gpu_fit_tags advise_gpu_branch_fit driver_menu_default; do
        sed -n "/^${fn}() {/,/^}/p" "${REPO}/configure.sh"
    done
} > "${WORK}/code.sh"
# shellcheck disable=SC1091
source "${WORK}/code.sh"

# Stub: the per-version READMEs, NVIDIA's unix page and the lookup API answer
# from fixtures; anything else fails. README_DOWN=1 makes every README fail.
README_DOWN=0
fetch_url() {
    case "$1" in
        */README/supportedchips.html)
            [[ ${README_DOWN} -eq 1 ]] && return 1
            local ver="${1%/README/*}"; ver="${ver##*/}"
            [[ -f "${FX}/supportedchips-${ver}.html" ]] && cat "${FX}/supportedchips-${ver}.html" || return 1 ;;
        *drivers/unix/*) cat "${FX}/unix-page.html" ;;
        *AjaxDriverService*)
            case "$1" in
                *release=470*) cat "${FX}/api-LEG.json" ;;
                *qnf=1*)       cat "${FX}/api-NFB.json" ;;
                *beta=1*)      cat "${FX}/api-BETA.json" ;;
                *beta=0*)      cat "${FX}/api-PB.json" ;;
                *)             return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

# One fake card with the given device ID, asked about one driver version.
gpu_support_id() {
    GPU_DEVID=("${2,,}"); GPU_RESERVED=(0)
    gpu_support "$1" 0
}

echo "lspci parsing"
parse_nvidia_gpus < "${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt"
check "two display GPUs, audio skipped" is "${#GPU_DEVID[@]}" 2
check "T1000 id and subsystem"  is "${GPU_DEVID[0]}|${GPU_SUBSYS[0]}" "1ff0|17aa:1612"
check "T1000 name from lspci"   is "${GPU_LSPCI_NAME[0]}" "T1000 8GB"
check "T1000 is reserved"       is "${GPU_RESERVED[0]}" 1
check "RTX PRO 2000 is active"  is "${GPU_RESERVED[1]}|${GPU_DEVID[1]}" "0|2d30"
check "unnamed card has empty lspci name" is "${GPU_LSPCI_NAME[1]}" ""
parse_nvidia_gpus < "${FX}/lspci-rtx5080-3d.txt"
check "3D controller without Subsystem" is "${GPU_DEVID[0]}|${GPU_SUBSYS[0]}" "2c02|"
parse_nvidia_gpus < "${FX}/lspci-gtx1080.txt"
check "GTX 1080 detected active" is "${#GPU_DEVID[@]}|${GPU_RESERVED[0]}" "1|0"
parse_nvidia_gpus < "${FX}/lspci-gtx480-fermi.txt"
check "GTX 480 name and id" is "${GPU_LSPCI_NAME[0]}|${GPU_DEVID[0]}" "GeForce GTX 480|06c0"

echo "README sections"
check "T1000 current in 620"     is "$(gpu_support_id 620.70.06 1FF0)" current
check "GTX 1080 legacy 580 in 620" is "$(gpu_support_id 620.70.06 1B80)" 580
check "GTX 480 legacy 390 in 620"  is "$(gpu_support_id 620.70.06 06C0)" 390
check "GTX 1080 current in 580"  is "$(gpu_support_id 580.196.07 1B80)" current
check "RTX 5080 unlisted in 470" is "$(gpu_support_id 470.256.02 2C02)" unlisted
check "three-ID rows match on the device ID" is "$(nvidia_supported_chips 620.70.06 | grep -c '^1FF0|current|')" "$(grep -c '>1FF0' "${FX}/supportedchips-620.70.06.html")"
check "unknown version → returns 1" not gpu_support 999.1.1 0
check "name for Device 2d30 comes from README" is "$(parse_nvidia_gpus < "${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt"; NVIDIA_VERSIONS=(620.70.06); gpu_name 1)" "NVIDIA RTX PRO 2000 Blackwell"
check "lspci name wins over README" is "$(parse_nvidia_gpus < "${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt"; NVIDIA_VERSIONS=(620.70.06); gpu_name 0)" "T1000 8GB"
check "no README → generic name" is "$(parse_nvidia_gpus < "${FX}/lspci-rtx5080-3d.txt"; NVIDIA_VERSIONS=(999.1.1); gpu_name 0)" "NVIDIA device 10de:2c02"

echo "detect_nvidia_gpu"
ok() { :; }; warn() { :; }; info() { :; }
LSPCI_FILE=""
lspci() { cat "${LSPCI_FILE}"; }
LSPCI_FILE="${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt"
detect_nvidia_gpu
check "reserved card skipped for the model name" is "${DETECTED_GPU_MODEL}" "NVIDIA device 10de:2d30"
check "all cards still in GPU_* arrays" is "${#GPU_DEVID[@]}" 2
LSPCI_FILE="${FX}/lspci-gtx1080.txt"
detect_nvidia_gpu
check "plain card names the model" is "${DETECTED_GPU_MODEL}" "GeForce GTX 1080"

# ── fit tags, recommendation, advice, menu default ───────────────────────────
SINK="${WORK}/out"
info() { echo "info: $*" >> "${SINK}"; }
warn() { echo "warn: $*" >> "${SINK}"; }
ok()   { echo "ok: $*" >> "${SINK}"; }
declare -n TAG=NVIDIA_VERSION_TAGS
VERSIONS=(620.70.06 615.78.08 610.57.04 595.112.07 595.45.04 580.196.07 470.256.02)

# What the wizard knows on a host with the given lspci output: the advice for
# driver ADVISE_VERSION goes to $WORK/advice, everything else to $WORK/out.
host() {
    local lspci_text="$1" advise_version="${2:-620.70.06}"
    : > "${WORK}/out"; : > "${WORK}/advice"
    parse_nvidia_gpus < "${lspci_text}"
    NVIDIA_VERSIONS=("${VERSIONS[@]}")
    fetch_nvidia_branch_info "${VERSIONS[@]}"
    apply_gpu_fit_tags
    advise "${advise_version}"
}
advise() { SINK="${WORK}/advice"; advise_gpu_branch_fit "$1"; SINK="${WORK}/out"; }

echo "GTX 1080 host"
host "${FX}/lspci-gtx1080.txt"
check "580 recommended"        is "${TAG[580.196.07]}" "★ Recommended for your GeForce GTX 1080"
check "620 marked unsupported" is "${TAG[620.70.06]}" "★ Production Branch — does NOT support GeForce GTX 1080"
check "menu starts on 580"     is "$(driver_menu_default)" 580.196.07
check "advice on 620 names the 580 branch" grep -q "NVIDIA lists it for the 580.xx legacy driver" "$WORK/advice"
check "no conflict"            is "${GPU_FIT_CONFLICT}" 0
check "470 still drives it"    is "${TAG[470.256.02]}" "★ Legacy GPU (470.xx)"
: > "${WORK}/advice"; advise 580.196.07
check "no advice on the recommended 580" not test -s "${WORK}/advice"

echo "GTX 480 host"
host "${FX}/lspci-gtx480-fermi.txt"
check "no version recommended" is "${GPU_RECOMMENDED_VERSION:-}" ""
check "says it can't build"    grep -q "This tool can't build a driver for that card" "$WORK/advice"
check "advice names the 390 branch" grep -qF "GeForce GTX 480 is not supported by NVIDIA 620.70.06; NVIDIA lists it for the 390.xx legacy driver." "$WORK/advice"
check "listed as unbuildable"  is "${GPU_UNBUILDABLE[*]}" "GeForce GTX 480|390"
check "menu falls back to Production" is "$(driver_menu_default)" 620.70.06

echo "user's TrueNAS (T1000 reserved, RTX PRO 2000 active)"
host "${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt"
check "no fit warnings"        is "${TAG[620.70.06]}" "★ Production Branch"
check "menu starts on Production" is "$(driver_menu_default)" 620.70.06
check "470 marked unsupported for the RTX PRO" is "${TAG[470.256.02]}" "★ Legacy GPU (470.xx) — does NOT support NVIDIA RTX PRO 2000 Blackwell"
check "reserved T1000 named nowhere" not grep -q "T1000" <<< "${TAG[*]}"
check "no advice on 620"       not test -s "${WORK}/advice"
advise 470.256.02
check "RTX PRO is newer than 470" grep -qF "NVIDIA RTX PRO 2000 Blackwell is newer than NVIDIA 470.256.02 — it is not in that driver's supported list." "$WORK/advice"

echo "only reserved GPUs"      # lspci fixture with the RTX PRO 2000 lines removed
sed '/^0000:81:00/,$d' "${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt" > "${WORK}/lspci-reserved-only.txt"
host "${WORK}/lspci-reserved-only.txt"
check "no recommendation, no warnings" is "${GPU_RECOMMENDED_VERSION:-}|${TAG[620.70.06]}" "|★ Production Branch"
check "no advice"              not test -s "${WORK}/advice"

echo "two cards no single driver serves (GTX 680 + RTX 5080)"
{
    echo '0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GK104 [GeForce GTX 680] [10de:1180] (rev a1)'
    cat "${FX}/lspci-rtx5080-3d.txt"
} > "${WORK}/lspci-kepler-blackwell.txt"
host "${WORK}/lspci-kepler-blackwell.txt" 470.256.02
check "470 recommended, marked for the 5080" is "${TAG[470.256.02]}" "★ Recommended for your GeForce GTX 680 · ★ Legacy GPU (470.xx) — does NOT support NVIDIA GeForce RTX 5080"
check "conflict flagged"       is "${GPU_FIT_CONFLICT}" 1
check "advice on 470 names the 5080" grep -q "NVIDIA GeForce RTX 5080 is newer than NVIDIA 470.256.02" "$WORK/advice"

echo "README unreachable"
NVIDIA_CHIPS_CACHE=(); README_DOWN=1
host "${FX}/lspci-gtx1080.txt"
check "labels kept, no fit claims" is "${TAG[620.70.06]}" "★ Production Branch"
check "says it couldn't check" grep -q "Could not check GPU support" "$WORK/out"
check "advice says it couldn't check" grep -q "Could not check GPU support for NVIDIA 620.70.06" "$WORK/advice"
README_DOWN=0

echo "never default to Beta"
check "default skips the Beta" is "$(GPU_RECOMMENDED_VERSION=; NVIDIA_BRANCH_VERSION=([BETA]=620.70.06); driver_menu_default)" 615.78.08
check "whiptail gets --default-item" grep -q -- '--default-item' "$REPO/configure.sh"

echo "bash menu default"
{
    echo 'RED=""; GREEN=""; YELLOW=""; DIM=""; NC=""; UI_MODE=bash'
    sed -n '/^UI_MENU_DEFAULT=/p' "${REPO}/configure.sh"
    for fn in ui_menu _ui_menu_bash; do
        sed -n "/^${fn}() {/,/^}/p" "${REPO}/configure.sh"
    done
    echo 'UI_MENU_DEFAULT=580.196.07'
    echo 'ui_menu pick "T" "P" 620.70.06 "★ Production Branch" 580.196.07 "★ Recommended"'
    echo 'echo "picked=${pick} default_after=${UI_MENU_DEFAULT}"'
    echo 'ui_menu pick "T" "P" 620.70.06 "" 580.196.07 ""'
    echo 'echo "picked=${pick}"'
} > "${WORK}/menu.sh"
# The menu itself goes to stderr; the picks to stdout.
printf '\n2\n' | bash "${WORK}/menu.sh" > "${WORK}/menu-out" 2> "${WORK}/menu-err"
check "Enter takes the default" grep -qx "picked=580.196.07 default_after=" "${WORK}/menu-out"
check "default is marked"       grep -q "580.196.07  ★ Recommended  (default)" "${WORK}/menu-err"
check "a number still picks"    grep -qx "picked=580.196.07" "${WORK}/menu-out"
printf '\n\n1\n' | bash "${WORK}/menu.sh" > "${WORK}/menu-out" 2> "${WORK}/menu-err"
check "default cleared → Enter asks again" grep -qx "picked=620.70.06" "${WORK}/menu-out"
echo "architecture table gone"
check "no NVIDIA_ARCH_ tables" is "$(grep -c 'NVIDIA_ARCH_' "$REPO/configure.sh")" 0

echo
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
