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
    lift truenas_version_supported
    lift fetch_expected_sha256
    lift verify_sha256
    lift env_is_true
    lift gpu_fit_report
    lift check_target_gpus
} > "${HELPERS}"

# The TrueNAS download helpers run in this shell, so a test can read the
# variables they set. Every URL is answered from the fixtures by ${SERVE}, as
# TrueNAS publishes it; UPDATE_DOWN=1 makes every update.truenas.com URL fail.
TFX="${WORK}/truenas-fixtures"
cp -r "${REPO}/tests/fixtures/truenas" "${TFX}"
# A release folder that doesn't exist is still a 200: a listing with no files.
grep -v '<a ' "${TFX}/folder-27.0.0-RC.1.html" > "${TFX}/folder-empty.html"
# releases.json entries that must never become a URL.
cat > "${TFX}/update-TrueNAS-Evil_releases.json" <<'JSON'
{"25.10.1": {"filename": "../TrueNAS-25.10.1.update", "checksum": "cf5ea77830950b9d7157572c673c9ed6805d20d3496613fa097a0ab791a6c08e"},
 "25.10.2": {"filename": "TrueNAS-25.10.2.update", "checksum": "not-a-digest"}}
JSON
FIXTURE_SIDECAR_DIGEST="$(printf 'sidecar' | sha256sum | awk '{print $1}')"
export TFX FIXTURE_SIDECAR_DIGEST

SERVE="${WORK}/serve"
cat > "${SERVE}" <<'STUB'
#!/bin/bash
# serve URL — print what TrueNAS publishes at URL, or fail like curl -f.
url="$1" f=""
[[ "${url}" == https://update.truenas.com/* && -n "${UPDATE_DOWN:-}" ]] && exit 7
case "${url}" in
    "https://download.truenas.com/") f=download-root.html ;;
    "https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/") f=folder-25.10.8.html ;;
    "https://download.truenas.com/TrueNAS-27-RC/27.0.0-RC.1/") f=folder-27.0.0-RC.1.html ;;
    "https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update.sha256?download=1")
        printf '%s  TrueNAS-SCALE-25.10.8.update\n' "${FIXTURE_SIDECAR_DIGEST}"; exit 0 ;;
    https://download.truenas.com/*/*/) f=folder-empty.html ;;
    "https://update.truenas.com/scale/trains_v2.json") f=update-trains_v2.json ;;
    https://update.truenas.com/scale/*/releases.json)
        f="${url#https://update.truenas.com/scale/}"; f="update-${f%/releases.json}_releases.json" ;;
    *) exit 22 ;;
esac
[[ -f "${TFX}/${f}" ]] || exit 22
cat "${TFX}/${f}"
STUB
TBIN="${WORK}/truenas-bin"; mkdir -p "${TBIN}"
cat > "${TBIN}/curl" <<STUB
#!/bin/bash
# curl -o FILE … URL (a checksum) gets a status code; curl URL gets the body.
out="" url=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        -m|-w|-r|--retry|--connect-timeout|--max-time) shift ;;
        -*) ;;
        *) url="\$1" ;;
    esac
    shift
done
if [[ -n "\${out}" ]]; then
    if "${SERVE}" "\${url}" > "\${out}"; then printf 200; else : > "\${out}"; printf 404; fi
else
    "${SERVE}" "\${url}"
fi
STUB
printf '#!/bin/bash\nexit 8\n' > "${TBIN}/wget"
chmod +x "${SERVE}" "${TBIN}/curl" "${TBIN}/wget"

TN_HELPERS="${WORK}/truenas-helpers.sh"
{
    echo 'info() { echo "INFO $*"; }; ok() { echo "OK $*"; }; warn() { echo "WARN $*"; }'
    echo 'die() { echo "FATAL $*" >&2; exit 1; }'
    for fn in valid_truenas_train valid_truenas_version fetch_url find_truenas_train \
              resolve_truenas_train list_release_files truenas_release_entry \
              truenas_train_redirect resolve_truenas_update fetch_expected_sha256; do
        lift "${fn}"
    done
    echo "fetch_url() { UPDATE_DOWN=\"\${UPDATE_DOWN:-}\" '${SERVE}' \"\$1\"; }"
    echo "curl() { '${TBIN}/curl' \"\$@\"; }"
} > "${TN_HELPERS}"
# shellcheck disable=SC1090
source "${TN_HELPERS}"
TRUENAS_UPDATE_URL="" TRUENAS_UPDATE_SHA256=""

echo "TrueNAS download locations"
check "25.10.8 lists its .update" is "$(list_release_files TrueNAS-SCALE-Goldeye 25.10.8 | grep -c '\.update$')" 1
check "only the bare download links count" is "$(list_release_files TrueNAS-SCALE-Goldeye 25.10.8 | grep -cE '/|\?|^\.|^$')" 0
check "the 27 RC folder has no .update" is "$(list_release_files TrueNAS-27-RC 27.0.0-RC.1 | grep -c '\.update$')" 0
resolve_truenas_update TrueNAS-SCALE-Goldeye 25.10.8
check "25.10.8 from download.truenas.com" is "$TRUENAS_UPDATE_URL" "https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update?download=1"
check "25.10.8 sidecar checksum"   is "$TRUENAS_UPDATE_SHA256" "$FIXTURE_SIDECAR_DIGEST"
resolve_truenas_update TrueNAS-27-RC 27.0.0-RC.1
check "27 RC from update.truenas.com" is "$TRUENAS_UPDATE_URL" "https://update.truenas.com/scale/TrueNAS-27-RC/TrueNAS-27.0.0-RC.1.update"
check "27 RC checksum"             is "$TRUENAS_UPDATE_SHA256" 25bd11522fec26dce1c41d8b81c6f1e2fa2396dfae37cc340ea5d41fc75afe3d
check "empty folder + unlisted → 1" not resolve_truenas_update TrueNAS-27-RC 27.0.0-RC.9
resolve_truenas_update TrueNAS-SCALE-Goldeye-RC 25.10.0
check "a redirected train's releases.json" is "$TRUENAS_UPDATE_URL" "https://update.truenas.com/scale/TrueNAS-SCALE-Goldeye/TrueNAS-SCALE-25.10.0.update"
check "redirected checksum"        is "$TRUENAS_UPDATE_SHA256" cf5ea77830950b9d7157572c673c9ed6805d20d3496613fa097a0ab791a6c08e
check "a filename with a path is refused" not resolve_truenas_update TrueNAS-Evil 25.10.1
check "a checksum that isn't a digest is refused" not resolve_truenas_update TrueNAS-Evil 25.10.2
check "an invalid train is refused" not resolve_truenas_update 'TrueNAS-../x' 25.10.8
check "an invalid version is refused" not resolve_truenas_update TrueNAS-SCALE-Goldeye '25.10.8/..'
check "legacy codename .env"       is "$(resolve_truenas_train 24.10.2 '' 'Electric Eel')" TrueNAS-SCALE-ElectricEel
check "the .env train wins"        is "$(resolve_truenas_train 25.10.8 TrueNAS-SCALE-Goldeye Fangtooth)" TrueNAS-SCALE-Goldeye
check "train found on the page"    is "$(resolve_truenas_train 27.0.0-RC.1 '' '')" TrueNAS-27-RC
check "the page match is exact"    is "$(resolve_truenas_train 25.10 '' '')" ""
check "unknown version → 1"        not resolve_truenas_train 26.0.0 '' ''
check "update.truenas.com down, folder has .update" is "$(UPDATE_DOWN=1; resolve_truenas_update TrueNAS-SCALE-Goldeye 25.10.8 && echo "$TRUENAS_UPDATE_URL")" "https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update?download=1"
check "update.truenas.com down, no .update → 1" not bash -c "source '${TN_HELPERS}'; UPDATE_DOWN=1; resolve_truenas_update TrueNAS-27-RC 27.0.0-RC.1"
check "nothing calls the old URL builders" is "$(grep -c 'build_truenas_update_' "$REPO/entrypoint.sh")" 0
check "no version cutoff left"     is "$(grep -cE '>= *26|-ge +26' "$REPO/entrypoint.sh" "$REPO/configure.sh" | awk -F: '{s+=$2} END {print s}')" 0
check "no update-public/auto-public anywhere" is "$(grep -rcE 'update-public|auto-public' "$REPO"/*.sh "$REPO/README.md" "$REPO/docker-compose.yaml" "$REPO/.env.example" | awk -F: '{s+=$2} END {print s}')" 0

echo "the build's download step"
DL="${WORK}/dl"; mkdir -p "${DL}/output"
sed -e "s#/output#${DL}/output#g" "${REPO}/entrypoint.sh" > "${DL}/entrypoint.sh"
build_dl() { env PATH="${TBIN}:${PATH}" TRUENAS_VERSION="$1" TRUENAS_TRAIN="$2" TRUENAS_CODENAME="$3" \
                 NVIDIA_VERSION=595.112.07 timeout 20 bash "${DL}/entrypoint.sh" > "${DL}/console" 2>&1; RC=$?; }
build_dl 25.10.8 "" ""
check "the train is looked up and named" has "${DL}/console" "Downloading TrueNAS 25.10.8 (TrueNAS-SCALE-Goldeye) update file from download.truenas.com"
check "it downloads the listed file" has "${DL}/console" "https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/TrueNAS-SCALE-25.10.8.update?download=1"
check "a failed download stops" nonzero "${RC}"
build_dl 27.0.0-RC.1 TrueNAS-27-RC ""
check "27 RC comes from update.truenas.com" has "${DL}/console" "Downloading TrueNAS 27.0.0-RC.1 (TrueNAS-27-RC) update file from update.truenas.com"
build_dl 26.0.0 "" ""
check "an unknown release names the fix" has "${DL}/console" "Unable to find the release folder of TrueNAS 26.0.0 on download.truenas.com. Set TRUENAS_TRAIN in .env (e.g. TrueNAS-SCALE-Goldeye) or place truenas.update in the repo."
build_dl 27.0.0-RC.9 TrueNAS-27-RC ""
check "a release without an .update names both places" has "${DL}/console" "TrueNAS 27.0.0-RC.9 has no .update file in download.truenas.com/TrueNAS-27-RC/27.0.0-RC.9/ or update.truenas.com/scale/TrueNAS-27-RC/releases.json. Place truenas.update in the repo to build from a local file."
build_dl '25.10.8/../x' "" ""
check "an invalid TRUENAS_VERSION stops" nonzero "${RC}"
check "it says the version is invalid" has "${DL}/console" "is not a valid TrueNAS version"
check "it stops before downloading" lacks "${DL}/console" "Downloading"

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
check "module message names the fix" has <(msg 2d30:10de:2054 proprietary) "Run ./configure.sh --reconfigure (Module Type → open) or set NVIDIA_KERNEL_MODULE_TYPE=open in .env"
check "module message keeps the escape" has <(msg 2d30:10de:2054 proprietary) "SKIP_GPU_CHECK=true"
check "no ignored --module hint" not grep -q -- "configure.sh --module" <(msg 2d30:10de:2054 proprietary)
check "legacy message names the branch" has <(msg 1180:: open) "pick 470.xx"
check "legacy message has the escape" has <(msg 1180:: open) "SKIP_GPU_CHECK=true"
check "unlisted message" has <(msg dead:: open) "10de:dead is not in NVIDIA 580.196.07's supported list."
check "unlisted message has the escape" has <(msg dead:: open) "SKIP_GPU_CHECK=true"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
