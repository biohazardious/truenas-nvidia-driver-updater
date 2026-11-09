#!/bin/bash
# =============================================================================
# gpu-fit-test.sh — offline test for GPU detection by PCI ID and the README
# support lookup in configure.sh. READMEs and lspci output come from
# tests/fixtures/nvidia/.
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
    for fn in parse_nvidia_gpus nvidia_supported_chips gpu_support gpu_name detect_nvidia_gpu; do
        sed -n "/^${fn}() {/,/^}/p" "${REPO}/configure.sh"
    done
} > "${WORK}/code.sh"
# shellcheck disable=SC1091
source "${WORK}/code.sh"

# Stub: only the per-version README exists; anything else fails.
fetch_url() {
    case "$1" in
        */README/supportedchips.html)
            local ver="${1%/README/*}"; ver="${ver##*/}"
            [[ -f "${FX}/supportedchips-${ver}.html" ]] && cat "${FX}/supportedchips-${ver}.html" || return 1 ;;
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
ok() { :; }; warn() { :; }
detect_gpu_architecture() { DETECTED_GPU_ARCH=""; }
LSPCI_FILE=""
lspci() { cat "${LSPCI_FILE}"; }
LSPCI_FILE="${FX}/lspci-truenas-t1000-vfio-rtxpro2000.txt"
detect_nvidia_gpu
check "reserved card kept out of the old logic" is "${#DETECTED_GPUS[@]}|${DETECTED_GPU_MODEL}" "1|Device 2d30"
check "all cards still in GPU_* arrays" is "${#GPU_DEVID[@]}" 2
LSPCI_FILE="${FX}/lspci-gtx1080.txt"
detect_nvidia_gpu
check "plain card feeds DETECTED_GPUS" is "${#DETECTED_GPUS[@]}" 1

echo
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
