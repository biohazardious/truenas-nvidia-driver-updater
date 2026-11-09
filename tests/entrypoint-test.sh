#!/bin/bash
# =============================================================================
# entrypoint-test.sh — offline regression test for entrypoint.sh
#
# Usage:  tests/entrypoint-test.sh
#
# entrypoint.sh runs a whole build when executed, so the helpers are lifted out
# of it and exercised alone. The log wrapper runs for real, in a copy whose
# build stops right after the wrapper.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
is()      { [[ "$1" == "$2" ]]; }
nonzero() { [[ "$1" -ne 0 ]]; }
has()     { grep -qF "$2" "$1"; }
lacks()   { ! grep -qF "$2" "$1"; }
not()     { ! "$@"; }

lift() { sed -n "/^$1() {/,/^}/p" "${REPO}/entrypoint.sh"; }

HELPERS="${WORK}/helpers.sh"
{
    echo 'set -euo pipefail'
    echo 'info() { echo "INFO $*"; }; ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }'
    echo 'die() { echo "FATAL $*" >&2; exit 1; }'
    lift build_truenas_update_filename
    lift build_truenas_update_url
    lift truenas_version_supported
    lift fetch_expected_sha256
    lift verify_sha256
    lift env_is_true
    lift gpu_fit_report
    lift check_target_gpus
} > "${HELPERS}"

url()      { bash -c "source '${HELPERS}'; build_truenas_update_url \"\$@\"" _ "$@" 2>/dev/null; }
filename() { bash -c "source '${HELPERS}'; build_truenas_update_filename \"\$@\"" _ "$@" 2>/dev/null; }

echo "TrueNAS download locations"
check "25.x uses the codename directory" is "$(url 25.10.8 Goldeye)" \
    "https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update?download=1"
check "a codename with a space is normalised" is "$(url 24.10.2 'Electric Eel')" \
    "https://download.truenas.com/TrueNAS-SCALE-ElectricEel/24.10.2/TrueNAS-SCALE-24.10.2.update?download=1"
check "26 beta" is "$(url 26.0.0-BETA.3)" \
    "https://update-public.sys.truenas.net/TrueNAS-26-BETA/TrueNAS-26.0.0-BETA.3.update"
check "27 RC" is "$(url 27.0.0-RC.1)" \
    "https://update-public.sys.truenas.net/TrueNAS-27-RC/TrueNAS-27.0.0-RC.1.update"
check "27 beta" is "$(url 27.1.0-BETA.1)" \
    "https://update-public.sys.truenas.net/TrueNAS-27-BETA/TrueNAS-27.1.0-BETA.1.update"
url 27.0.0 >/dev/null; check "a 27 release has no known location yet" nonzero $?
url 25.10.8 >/dev/null; check "25.x without a codename fails" nonzero $?
check "27 file name" is "$(filename 27.0.0-RC.1)" "TrueNAS-27.0.0-RC.1.update"
check "25.x file name" is "$(filename 25.10.8)" "TrueNAS-SCALE-25.10.8.update"

echo "minimum TrueNAS version"
supported() { bash -c "source '${HELPERS}'; truenas_version_supported \"\$1\"" _ "$1" 2>/dev/null; }
for version in 24.10.2.4 25.04.2.6 25.10.8 26.0.0-BETA.3 27.0.0-RC.1; do
    supported "${version}"; check "${version} is supported" is "$?" 0
done
for version in 24.04.2.5 23.10.2 not-a-version; do
    supported "${version}"; check "${version} is not supported" nonzero $?
done

OLD="${WORK}/old"; mkdir -p "${OLD}/output"
sed -e "s#/output#${OLD}/output#g" "${REPO}/entrypoint.sh" > "${OLD}/entrypoint.sh"
TRUENAS_VERSION=24.04.2.5 NVIDIA_VERSION=595.112.07 timeout 20 bash "${OLD}/entrypoint.sh" > "${OLD}/console" 2>&1
check "a build for 24.04 stops" nonzero $?
check "it names the minimum" has "${OLD}/console" "24.10"
check "it stops before downloading" lacks "${OLD}/console" "Downloading"

echo "published checksums"
BIN="${WORK}/bin"; mkdir -p "${BIN}"
cat > "${BIN}/curl" <<'STUB'
#!/bin/bash
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
[[ "${CURL_STATUS}" == fail ]] && exit 6
printf '%b' "${CURL_BODY:-}" > "${out}"
printf '%s' "${CURL_STATUS}"
STUB
chmod +x "${BIN}/curl"

HEX="$(printf 'a%.0s' {1..64})"
fetch() { PATH="${BIN}:${PATH}" CURL_STATUS="$1" CURL_BODY="${2:-}" bash -c "source '${HELPERS}'; fetch_expected_sha256 http://x/y" 2>/dev/null; }

check "bare digest" is "$(fetch 200 "${HEX}\n")" "${HEX}"
check "digest followed by a file name" is "$(fetch 200 "${HEX}  driver.run\n")" "${HEX}"
check "upper-case digest is normalised" is "$(fetch 200 "${HEX^^}\n")" "${HEX}"
check "404 means none published" is "$(fetch 404)" ""
check "an HTML page is not a checksum" is "$(fetch 200 '<html>not here</html>')" ""
fetch 500 >/dev/null; check "a server error stops the build" nonzero $?
fetch fail >/dev/null; check "a network error stops the build" nonzero $?

FILE="${WORK}/download"
verify() { bash -c "source '${HELPERS}'; verify_sha256 \"\$@\"" _ "${FILE}" "$1" > "${WORK}/verify.out" 2>&1; }

echo payload > "${FILE}"
GOOD="$(sha256sum "${FILE}" | awk '{print $1}')"
verify "${GOOD}"; check "matching file passes" is "$?" 0
verify ""; check "no digest continues" is "$?" 0
check "no digest warns" has "${WORK}/verify.out" "unverified"
verify "${HEX}"; check "mismatch stops the build" nonzero $?
check "mismatch names both digests" has "${WORK}/verify.out" "${GOOD}"
check "mismatch removes the bad file" is "$([[ -e "${FILE}" ]] && echo kept || echo gone)" gone

echo "build log"
SB="${WORK}/log"; mkdir -p "${SB}/output" "${SB}/var"
sed -e "s#/output#${SB}/output#g" \
    -e "s#/var/log/nvidia-installer.log#${SB}/var/installer.log#g" \
    -e '/^# ── Build starts here/a echo -e "\\033[0;36m[INFO]\\033[0m  build ran"; printf "10%%\\r50%%\\r100%%\\n"; echo "to stderr" >&2; [[ -e /proc/self/fd/3 ]] && echo "fd3 open"; exit "${FAKE_RC:-0}"' \
    "${REPO}/entrypoint.sh" > "${SB}/entrypoint.sh"
chmod +x "${SB}/entrypoint.sh"

run_build() { FAKE_RC="$1" bash "${SB}/entrypoint.sh" > "${SB}/console" 2>&1; RC=$?; }
latest()    { ls -1t "${SB}/output/logs/"$1-*.log 2>/dev/null | head -1; }

echo "installer output" > "${SB}/var/installer.log"
run_build 0
check "success keeps exit 0" is "${RC}" 0
log="$(latest build)"
check "log is written" is "$([[ -s "${log}" ]] && echo yes)" yes
check "log has stdout" has "${log}" "build ran"
check "log has stderr" has "${log}" "to stderr"
check "log has no colour codes" lacks "${log}" "[0;36m"
check "log keeps only the final progress state" is "$(grep -c '10%' "${log}")" 0
check "progress line survives" has "${log}" "100%"
check "console still shows the build" has "${SB}/console" "build ran"
check "console says where the log is" has "${SB}/console" "output/logs/build-"
check "terminal descriptor reaches the build" has "${log}" "fd3 open"
check "installer log is lifted out" has "$(latest nvidia-installer)" "installer output"

run_build 7
check "failure keeps its exit code" is "${RC}" 7
check "installer log is lifted out on failure too" has "$(latest nvidia-installer)" "installer output"

for i in 1 2 3 4; do sleep 1.1; run_build 0; done
check "build logs are trimmed to three" is "$(ls -1 "${SB}/output/logs/"build-*.log | wc -l)" 3
check "installer logs are trimmed to three" is "$(ls -1 "${SB}/output/logs/"nvidia-installer-*.log | wc -l)" 3

FX="${REPO}/tests/fixtures/nvidia"
echo "target GPU check (580 list)"
r() { bash -c "source '${HELPERS}'; gpu_fit_report \"\$@\"" _ "$FX/supported-gpus-580.196.07.json" "$1" "$2" 2>/dev/null; }
check "GTX 1080 + proprietary is fine" is "$(r proprietary 1b80:1043:85aa | cut -d'|' -f1)" ok
check "GTX 1080 + open is refused"     is "$(r open 1b80:1043:85aa | cut -d'|' -f1,4)" "module|proprietary"
check "RTX PRO 2000 + proprietary is refused" is "$(r proprietary 2d30:10de:2054 | cut -d'|' -f1,4)" "module|open"
check "T1000 fine either way" is "$(r open 1ff0:17aa:1612; r proprietary 1ff0:17aa:1612)" "$(printf 'ok|1ff0|NVIDIA T1000 8GB\nok|1ff0|NVIDIA T1000 8GB')"
check "GTX 680 points at 470" is "$(r proprietary 1180:: | cut -d'|' -f1,4)" "legacy|470.xx"
check "upper-case id and 0x prefix match" is "$(r open 0x1FF0:: | cut -d'|' -f1)" ok
check "several targets give one line each" is "$(r proprietary 1b80::,1180:: | wc -l)" 2
echo "595's legacy rows"
check "GTX 1080 on 595 is legacy, not 'open ok'" is "$(bash -c "source '${HELPERS}'; gpu_fit_report '$FX/supported-gpus-595.112.07.json' open 1b80::" 2>/dev/null | cut -d'|' -f1,4)" "legacy|580.xx"
check "unknown id is unlisted" is "$(r open dead:: | cut -d'|' -f1)" unlisted
echo "check_target_gpus"
ctg() { ( NVIDIA_TARGET_GPUS="$1"; NVIDIA_KERNEL_MODULE_TYPE="$2"; SKIP_GPU_CHECK="$3"
          NVIDIA_VERSION=580.196.07; NVIDIA_SRC_ROOT="${WORK}/src"
          installer_supports_option() { return 0; }
          source "${HELPERS}"; check_target_gpus ) >/dev/null 2>&1; }
mkdir -p "${WORK}/src/supported-gpus"; cp "$FX/supported-gpus-580.196.07.json" "${WORK}/src/supported-gpus/supported-gpus.json"
check "dies before compiling on a mismatch" not ctg 1b80:: open false
check "SKIP_GPU_CHECK=true only warns"    ctg 1b80:: open true
check "no targets, no check"              ctg "" open false
check "matching target passes"            ctg 1ff0:: open false
check "Dockerfile installs jq"            grep -qw jq "$REPO/Dockerfile"
msg() { ( NVIDIA_TARGET_GPUS="$1"; NVIDIA_KERNEL_MODULE_TYPE="$2"; SKIP_GPU_CHECK=false
          NVIDIA_VERSION=580.196.07; NVIDIA_SRC_ROOT="${WORK}/src"
          installer_supports_option() { return 0; }
          source "${HELPERS}"; check_target_gpus ) 2>&1; }
check "module message names the fix" has <(msg 2d30:10de:2054 proprietary) "Re-run ./configure.sh --module open"
check "legacy message names the branch" has <(msg 1180:: open) "pick 470.xx."
check "unlisted message" has <(msg dead:: open) "10de:dead is not in NVIDIA 580.196.07's supported list."

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
