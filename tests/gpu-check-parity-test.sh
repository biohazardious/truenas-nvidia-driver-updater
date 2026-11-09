#!/bin/bash
# =============================================================================
# gpu-check-parity-test.sh — the build's GPU check (entrypoint.sh, jq) and the
# deploy's (deploy-nvidia.sh, python3) must classify every GPU the same way.
# Both are run on the same supported-gpus.json fixtures and targets, and their
# answers compared line for line.
#
# Usage:  tests/gpu-check-parity-test.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="${REPO}/tests/fixtures/nvidia"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "skipped: jq or python3 missing"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }

# ── lift the two implementations out of their scripts ────────────────────────
sed -n '/^gpu_fit_report() {/,/^}/p' "${REPO}/entrypoint.sh" > "${WORK}/build.sh"
sed -n '/^gpu_fit_eval() {/,/^}/p' "${REPO}/deploy-nvidia.sh" > "${WORK}/deploy.sh"
# shellcheck disable=SC1091
source "${WORK}/build.sh"
# shellcheck disable=SC1091
source "${WORK}/deploy.sh"

# A list where one device ID has a subsystem-specific row that differs from the
# generic one (no kernelopen: proprietary only), listed after the generic rows.
python3 -I - "${FX}/supported-gpus-580.196.07.json" "${WORK}/subsys.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
data["chips"].append({"devid": "0x1FF0", "subvendorid": "0xBEEF", "subdevid": "0x0001",
                      "name": "Subsystem Variant", "features": ["runtimepm"]})
with open(sys.argv[2], "w") as f:
    json.dump(data, f)
PY

declare -A JSON=(
    [580]="${FX}/supported-gpus-580.196.07.json"
    [595]="${FX}/supported-gpus-595.112.07.json"
    [sub]="${WORK}/subsys.json"
)

# The build's answer for one target (devid:subvendor:subdevice).
build_answer() { gpu_fit_report "$1" "$2" "$3"; }
# The deploy's answer, with its slot field dropped so the lines compare.
deploy_answer() {
    local t="$3"
    gpu_fit_eval "$1" "$2" "0000:01:00.0|${t%%:*}|${t#*:}" | cut -d'|' -f1,3-
}

# list module target expected-kind
CASES=(
    "580 open        1b80:1043:85aa       module"
    "580 proprietary 1b80:1043:85aa       ok"
    "580 open        2d30:10de:2054       ok"
    "580 proprietary 2d30:10de:2054       module"
    "580 open        1ff0:17aa:1612       ok"
    "580 proprietary 1ff0:17aa:1612       ok"
    "580 open        2c02::               ok"
    "580 proprietary 2c02::               module"
    "580 open        1180::               legacy"
    "580 proprietary 1180::               legacy"
    "580 open        dead::               unlisted"
    "580 proprietary 06c0::               unlisted"
    "595 open        1b80:1043:85aa       legacy"
    "595 proprietary 1b80::               legacy"
    "595 open        2d30:10de:2054       ok"
    "595 proprietary 1ff0:17aa:1612       ok"
    "595 open        1180::               legacy"
    "595 open        dead::               unlisted"
    "sub open        1ff0:beef:0001       module"
    "sub proprietary 1ff0:beef:0001       ok"
    "sub open        0x1FF0:0xBEEF:0x0001 module"
    "sub open        1ff0::               ok"
    "sub open        1ff0:beef:0002       ok"
)

echo "same classification from the build and the deploy check"
for c in "${CASES[@]}"; do
    read -r list module target want <<< "${c}"
    b="$(build_answer "${JSON[${list}]}" "${module}" "${target}")"
    d="$(deploy_answer "${JSON[${list}]}" "${module}" "${target}")"
    name="${list} ${module} ${target} → ${want}"
    if [[ -n "${b}" && "${b}" == "${d}" && "${b%%|*}" == "${want}" ]]; then
        pass "${name}  (${b})"
    else
        fail "${name}  build='${b}' deploy='${d}'"
    fi
done

echo "named rows"
b="$(build_answer "${JSON[sub]}" open 1ff0:beef:0001)"
[[ "${b}" == "module|1ff0|Subsystem Variant|proprietary" ]] \
    && pass "subsystem row wins over the generic one" || fail "subsystem row wins over the generic one: '${b}'"
b="$(build_answer "${JSON[595]}" open 1b80::)"
[[ "${b}" == "legacy|1b80|NVIDIA GeForce GTX 1080|580.xx" ]] \
    && pass "595's legacy row names 580.xx" || fail "595's legacy row names 580.xx: '${b}'"

echo "several targets at once"
b="$(gpu_fit_report "${JSON[580]}" open "1b80:1043:85aa,1180::,dead::,2d30:10de:2054")"
d="$(gpu_fit_eval "${JSON[580]}" open "a|1b80|1043:85aa" "b|1180|:" "c|dead|:" "d|2d30|10de:2054" | cut -d'|' -f1,3-)"
[[ -n "${b}" && "${b}" == "${d}" ]] && pass "four targets, same four lines" || fail "four targets differ: build='${b}' deploy='${d}'"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
