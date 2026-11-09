#!/bin/bash
# =============================================================================
# truenas-sources-test.sh — offline test for what configure.sh reads from
# TrueNAS's own published data: the train (release folder) of each version on
# download.truenas.com, the host's train from /data/manifest.json, and the
# TRUENAS_TRAIN line in .env (old TRUENAS_CODENAME files still read).
# Pages come from tests/fixtures/truenas/.
#
# Usage:  tests/truenas-sources-test.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="${REPO}/tests/fixtures/truenas"
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
    echo 'info() { :; }; warn() { :; }; ok() { :; }; err() { :; }'
    sed -n '/^declare -gA TRUENAS_KERNEL_CACHE=/p;/^TRUENAS_KERNEL_UNKNOWN_SHOWN=/p;/^declare -A NVIDIA_BRANCH_MAX_KERNEL=/,/^)/p' "${REPO}/configure.sh"
    sed -n '/^declare -gA TRUENAS_VERSION_\(TRAIN\|TAGS\|PROFILE\)=/p;/^declare -gA TRUENAS_CHOSEN_TRAIN=/p' "${REPO}/configure.sh"
    for fn in valid_train truenas_train_display host_truenas_train resolve_selected_train remember_truenas_train \
              fetch_unreachable \
              truenas_release_label truenas_update_trains truenas_update_releases fetch_truenas_release_labels truenas_menu_default \
              truenas_version_supported fetch_truenas_versions \
              mtree_kernel_of truenas_release_kernel truenas_kernel_mm fetch_url_range \
              kernel_version_gt nvidia_major patching_relevant advise_legacy_driver announce_truenas_kernel \
              read_existing_config; do
        sed -n "/^${fn}() {/,/^}/p" "${REPO}/configure.sh"
    done
} > "${WORK}/code.sh"
# shellcheck disable=SC1091
source "${WORK}/code.sh"

# Stub: download.truenas.com answers from the fixture; anything else fails.
fetch_url() {
    case "$1" in
        https://download.truenas.com/) cat "${FX}/download-root.html" ;;
        https://update.truenas.com/scale/trains_v2.json) cat "${FX}/update-trains_v2.json" ;;
        https://update.truenas.com/scale/*/releases.json)
            local f="${1#https://update.truenas.com/scale/}"
            f="${FX}/update-${f%/releases.json}_releases.json"
            [[ -r "${f}" ]] && cat "${f}" || return 1 ;;
        *) return 1 ;;
    esac
}
listed_version() { local v; for v in "${TRUENAS_VERSIONS[@]}"; do [[ "${v}" == "$1" ]] && return 0; done; return 1; }
# The train read_existing_config takes from a .env holding just these lines.
env_train_from() {
    printf '%s\n' "$@" > "${WORK}/train.env"
    read_existing_config "${WORK}/train.env" >/dev/null 2>&1
    printf '%s' "${EXISTING_TRAIN}"
}

fetch_truenas_versions >/dev/null 2>&1
SAVED_VERSIONS=("${TRUENAS_VERSIONS[@]}")

echo "train per version"
check "25.10.8 → Goldeye"        is "${TRUENAS_VERSION_TRAIN[25.10.8]}" TrueNAS-SCALE-Goldeye
check "25.10-RC.1 → Goldeye-RC"  is "${TRUENAS_VERSION_TRAIN[25.10-RC.1]}" TrueNAS-SCALE-Goldeye-RC
check "27.0.0-RC.1 → 27-RC"      is "${TRUENAS_VERSION_TRAIN[27.0.0-RC.1]}" TrueNAS-27-RC
check "26 BETA → 26-BETA"        is "${TRUENAS_VERSION_TRAIN[26.0.0-BETA.3]}" TrueNAS-26-BETA
check "24.04 still dropped"      is "${TRUENAS_VERSION_TRAIN[24.04.2.5]:-}" ""
check "24.04 not listed"         not listed_version 24.04.2.5
check "nightly ISO not a version" not listed_version 26.0.0-MASTER+20260306-025151
check "eight versions listed"    is "${#TRUENAS_VERSIONS[@]}" 8
check "display name"             is "$(truenas_train_display TrueNAS-SCALE-Goldeye-RC)" Goldeye-RC
check "display name, 26+"        is "$(truenas_train_display TrueNAS-27-RC)" 27-RC
check "good train accepted"      valid_train TrueNAS-SCALE-Goldeye
check "bad train rejected"       not valid_train "TrueNAS-x;rm"
check "train with a slash rejected" not valid_train "TrueNAS-SCALE-Goldeye/25.10.8"
check "empty train rejected"     not valid_train ""
# A version listed under two trains keeps the first one on the page (as the
# build's find_truenas_train does), not the alphabetically first.
page_order_train() {
    (
        fetch_url() {
            [[ "$1" == https://download.truenas.com/ ]] || return 1
            printf '%s\n' '<a href="TrueNAS-SCALE-Goldeye/25.10.8">' '<a href="TrueNAS-SCALE-Fangtooth/25.10.8">'
        }
        fetch_truenas_versions >/dev/null 2>&1
        printf '%s' "${TRUENAS_VERSION_TRAIN[25.10.8]:-}"
    )
}
check "listed twice → first on the page" is "$(page_order_train)" TrueNAS-SCALE-Goldeye

echo "release labels"
check "25.10.8 General"           is "${TRUENAS_VERSION_TAGS[25.10.8]}" "★ General"
check "25.10.7 Mission Critical"  is "${TRUENAS_VERSION_TAGS[25.10.7]}" "★ Mission Critical"
check "25.10-RC.1 Early Adopter"  is "${TRUENAS_VERSION_TAGS[25.10-RC.1]}" "Early Adopter"
check "27 RC Early Adopter"       is "${TRUENAS_VERSION_TAGS[27.0.0-RC.1]}" "Early Adopter"
check "24.10 has no label"        is "${TRUENAS_VERSION_TAGS[24.10.2.4]:-}" ""
# A one-entry releases.json for train TrueNAS-T, labelled by the real code.
one_entry_label() {
    (
        fetch_url() {
            [[ "$1" == https://update.truenas.com/scale/TrueNAS-T/releases.json ]] \
                && printf '{"9.9.9": {"profile": "%s", "lts": %s}}\n' "$PROFILE" "$LTS" || return 1
        }
        declare -gA TRUENAS_VERSION_TRAIN=([9.9.9]=TrueNAS-T)
        PROFILE="$1" LTS="$2"
        fetch_truenas_release_labels 9.9.9 >/dev/null 2>&1
        printf '%s' "${TRUENAS_VERSION_TAGS[9.9.9]:-}"
    )
}
lts_fixture_label()     { one_entry_label GENERAL true; }
unknown_profile_label() { one_entry_label CONSERVATIVE true; }
check "lts appends"               is "$(lts_fixture_label)" "★ General · LTS"
check "unknown profile → no label" is "$(unknown_profile_label)" ""
check "developer label"           is "$(one_entry_label DEVELOPER false)" "Developer"
check "heuristic tags gone"       is "$(grep -cE 'Latest Stable|Latest Pre-release|Previous Stable' "$REPO/configure.sh")" 0

echo "menu default"
check "host version wins"         is "$(DETECTED_TRUENAS_VERSION=25.10.7; truenas_menu_default)" 25.10.7
check "else newest General/MC"    is "$(DETECTED_TRUENAS_VERSION=; truenas_menu_default)" 25.10.8
check "unlisted host version ignored" is "$(DETECTED_TRUENAS_VERSION=25.10.99; truenas_menu_default)" 25.10.8
check "order is newest first"     is "${TRUENAS_VERSIONS[0]}" 27.0.0-RC.1
check "menu default without labels → first non-pre-release" \
    is "$(DETECTED_TRUENAS_VERSION=; declare -gA TRUENAS_VERSION_PROFILE=(); truenas_menu_default)" 25.10.8
echo "kernel from rootfs.mtree"
fetch_url_range() {
    case "$1" in
        https://download.truenas.com/TrueNAS-SCALE-ElectricEel/24.10.0/rootfs.mtree?download=1) cat "${FX}/rootfs-24.10.0.mtree.head" ;;
        https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/rootfs.mtree?download=1) cat "${FX}/rootfs-25.10.8.mtree.head" ;;
        https://download.truenas.com/TrueNAS-27-RC/27.0.0-RC.1/rootfs.mtree?download=1) cat "${FX}/rootfs-27.0.0-RC.1.mtree.head" ;;
        *) return 1 ;;
    esac
}
warn() { printf '%s\n' "$*"; }; info() { printf 'INFO %s\n' "$*"; }; ok() { printf 'OK %s\n' "$*"; }
check "24.10.0 → 6.6.44"      is "$(truenas_release_kernel 24.10.0)" 6.6.44-production+truenas
check "25.10.8 → 6.12.113"    is "$(truenas_release_kernel 25.10.8)" 6.12.113-production+truenas
check "27 RC → 6.18.52"       is "$(truenas_release_kernel 27.0.0-RC.1)" 6.18.52-production+truenas
check "mm for 27 RC"          is "$(truenas_kernel_mm 27.0.0-RC.1)" 6.18
check "debug kernel ignored"  not grep -q debug <<< "$(truenas_release_kernel 25.10.8)"
check "other suffix accepted" is "$(mtree_kernel_of './boot/vmlinuz-7.1.2-generic+truenas')" 7.1.2-generic+truenas
check "unknown train → 1"     not truenas_release_kernel 99.1.1
check "unknown → empty mm"    is "$(truenas_kernel_mm 99.1.1)" ""
check "470 on 27 RC needs patches" patching_relevant 470.256.02 27.0.0-RC.1
check "470 warning names 6.18" grep -q '6.18.52' <<< "$(advise_legacy_driver 470.256.02 27.0.0-RC.1 2>&1)"
check "470 on 24.10.0 quiet"  not grep -q 'FAIL' <<< "$(advise_legacy_driver 470.256.02 24.10.0 2>&1)"
check "table gone"            is "$(grep -c 'TRUENAS_KERNEL_MM' "$REPO/configure.sh")" 0
check "no example kernels in text" is "$(grep -cE '25\.10 / 26 ship|ship kernel 6\.12' "$REPO/configure.sh")" 0
# Kernel unknown: generic warning, no example kernel; announced once per run.
check "unknown kernel → generic warning" grep -q 'end-of-life' <<< "$(advise_legacy_driver 470.256.02 99.1.1 2>&1)"
check "legacy warning text" grep -qF 'ships 6.18.52-production+truenas, so it will FAIL to compile without patches in patches/6.18/.' <<< "$(advise_legacy_driver 470.256.02 27.0.0-RC.1 2>&1)"
check "unknown generic has no kernel number" not grep -qE 'kernel 6\.[0-9]+[^.]' <<< "$(advise_legacy_driver 470.256.02 99.1.1 2>&1 | grep -v 'up to kernel')"
check "ok line"  is "$(announce_truenas_kernel 25.10.8)" "OK TrueNAS 25.10.8 kernel: 6.12.113-production+truenas"
TRUENAS_KERNEL_UNKNOWN_SHOWN=false
announce_truenas_kernel 99.1.1 > "${WORK}/ann"; announce_truenas_kernel 99.2.2 >> "${WORK}/ann"
check "unknown info exactly once" is "$(grep -c 'Kernel of TrueNAS 99.1.1 unknown — kernel-based checks skipped' "${WORK}/ann")$(grep -c unknown "${WORK}/ann")" 11
info() { :; }; warn() { :; }; ok() { :; }
# Real fetch_url_range with a stubbed curl that ignores Range and sends 49152 bytes.
eval "$(sed -n '/^fetch_url_range() {/,/^}/p' "${REPO}/configure.sh")"
curl() { cat "${FX}/rootfs-25.10.8.mtree.head" "${FX}/rootfs-25.10.8.mtree.head" "${FX}/rootfs-25.10.8.mtree.head"; }
FETCH_CMD=curl
check "stub body is 3x head"  is "$(curl | wc -c)" "$(( $(wc -c < "${FX}/rootfs-25.10.8.mtree.head") * 3 ))"
check "range capped at 16384" is "$(fetch_url_range https://x/full 16384 | wc -c)" 16384
unset -f curl

echo "update.truenas.com down"
fetch_url() {
    case "$1" in
        https://download.truenas.com/) cat "${FX}/download-root.html" ;;
        *) return 1 ;;
    esac
}
warn() { printf '%s\n' "$*" >> "${WORK}/out"; }
: > "${WORK}/out"
fetch_truenas_versions >/dev/null 2>&1
check "list still complete"       is "${#TRUENAS_VERSIONS[@]}" 8
check "no labels"                 is "${#TRUENAS_VERSION_TAGS[@]}" 0
check "says so once"              is "$(grep -c 'TrueNAS release labels unavailable' "$WORK/out")" 1
# trains_v2.json cannot be reached (curl 7/28, not an HTTP error): no
# releases.json is tried after it, so a firewalled host costs one timeout.
labels_when_trains_rc() {
    (
        TRAINS_RC="$1"
        fetch_url() {
            case "$1" in
                https://update.truenas.com/scale/trains_v2.json) return "${TRAINS_RC}" ;;
                https://update.truenas.com/scale/*/releases.json)
                    echo "$1" >> "${WORK}/releases-asked"
                    local f="${1#https://update.truenas.com/scale/}"
                    cat "${FX}/update-${f%/releases.json}_releases.json" 2>/dev/null || return 22 ;;
                *) return 22 ;;
            esac
        }
        declare -gA TRUENAS_VERSION_TRAIN=([25.10.8]=TrueNAS-SCALE-Goldeye)
        : > "${WORK}/releases-asked"; : > "${WORK}/out"
        FETCH_CMD=curl fetch_truenas_release_labels 25.10.8 >/dev/null 2>&1
        printf '%s|%s|%s' "$(wc -l < "${WORK}/releases-asked")" "${TRUENAS_VERSION_TAGS[25.10.8]:-}" \
            "$(grep -c 'TrueNAS release labels unavailable — update.truenas.com could not be read' "${WORK}/out")"
    )
}
check "trains_v2 unreachable → no releases.json, one line" is "$(labels_when_trains_rc 7)" "0||1"
check "trains_v2 timeout → no releases.json" is "$(labels_when_trains_rc 28)" "0||1"
check "trains_v2 404 → the version's train still read" is "$(labels_when_trains_rc 22)" "1|★ General|0"

echo "host train"
cat > "${WORK}/manifest.json" <<'JSON'
{"buildtime": 1761000000, "train": "TrueNAS-SCALE-Goldeye", "version": "25.10.9", "size": 1}
JSON
export TRUENAS_MANIFEST_FILE="${WORK}/manifest.json"
check "train from manifest.json" is "$(host_truenas_train)" TrueNAS-SCALE-Goldeye
check "unlisted host version uses manifest train" \
    is "$(DETECTED_TRUENAS_VERSION=25.10.9; resolve_selected_train 25.10.9)" TrueNAS-SCALE-Goldeye
check "listed version uses the list" \
    is "$(DETECTED_TRUENAS_VERSION=25.10.9; resolve_selected_train 27.0.0-RC.1)" TrueNAS-27-RC
check "unlisted, not the host → nothing" \
    is "$(DETECTED_TRUENAS_VERSION=25.10.9; resolve_selected_train 25.10.99)" ""
mkdir -p "${WORK}/jq-only" "${WORK}/no-json"
if command -v jq >/dev/null 2>&1; then
    ln -s "$(command -v jq)" "${WORK}/jq-only/jq"
    check "jq when there is no python3" is "$(PATH="${WORK}/jq-only" host_truenas_train)" TrueNAS-SCALE-Goldeye
else
    echo "  skipped: jq not installed"
fi
check "neither python3 nor jq → nothing" is "$(PATH="${WORK}/no-json" host_truenas_train)" ""
printf '{"train": "TrueNAS-x;rm -rf /"}\n' > "${WORK}/bad-manifest.json"
check "bad manifest train ignored" is "$(TRUENAS_MANIFEST_FILE="${WORK}/bad-manifest.json" host_truenas_train)" ""
check "no manifest → nothing" is "$(TRUENAS_MANIFEST_FILE="${WORK}/missing.json" host_truenas_train)" ""
printf 'not json\n' > "${WORK}/junk.json"
check "unreadable manifest → nothing" is "$(TRUENAS_MANIFEST_FILE="${WORK}/junk.json" host_truenas_train 2>/dev/null)" ""
unset TRUENAS_MANIFEST_FILE

echo ".env reader"
check "legacy codename read"     is "$(env_train_from TRUENAS_CODENAME=Goldeye)" TrueNAS-SCALE-Goldeye
check "legacy codename with a space" is "$(env_train_from 'TRUENAS_CODENAME=Electric Eel')" TrueNAS-SCALE-ElectricEel
check "TRUENAS_TRAIN wins over codename" \
    is "$(env_train_from TRUENAS_TRAIN=TrueNAS-27-RC TRUENAS_CODENAME=Goldeye)" TrueNAS-27-RC
check "neither → empty"          is "$(env_train_from TRUENAS_VERSION=25.10.8)" ""
check "empty codename → empty"   is "$(env_train_from TRUENAS_CODENAME=)" ""
check "bad TRUENAS_TRAIN dropped" is "$(env_train_from 'TRUENAS_TRAIN=TrueNAS-x;rm')" ""

# ── the whole wizard, run on a copy so the real .env is never touched ────────
# curl serves download.truenas.com from the fixture (or fails when $2 is
# "down"); NVIDIA's pages fail, so the driver labels are simply missing.
# "mtree": the list fails but 25.10.8's rootfs.mtree is served; "mtree-nv"
# also serves NVIDIA's driver folder (470.256.02 and 595.112.07). Every URL
# asked for is logged to curl.log.
make_repo() {
    local d="$1" net="${2:-up}"
    mkdir -p "${d}/bin"
    cp "${REPO}/configure.sh" "${REPO}/docker-compose.yaml" "${d}/"
    printf '#!/bin/bash\nexit 0\n' > "${d}/bin/lspci"
    printf '#!/bin/bash\nexit 1\n' > "${d}/bin/midclt"
    printf '#!/bin/bash\nexit 1\n' > "${d}/bin/wget"
    cat > "${d}/bin/curl" <<STUB
#!/bin/bash
url="\${@: -1}"
echo "\${url}" >> "${d}/curl.log"
case "${net}:\${url}" in
    up:https://download.truenas.com/) cat "${FX}/download-root.html" ;;
    mtree*:https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.8/rootfs.mtree?download=1)
        cat "${FX}/rootfs-25.10.8.mtree.head" ;;
    mtree-nv:https://download.nvidia.com/XFree86/Linux-x86_64/)
        printf "<a href='470.256.02/'>470.256.02/</a>\\n<a href='595.112.07/'>595.112.07/</a>\\n" ;;
    *) exit 22 ;;
esac
STUB
    chmod +x "${d}/bin/"*
}
mtree_asked() { grep -c 'rootfs.mtree' "$1/curl.log" 2>/dev/null; }
run_cfg() { local d="$1"; shift; PATH="${d}/bin:${PATH}" TRUENAS_MANIFEST_FILE="${d}/manifest.json" \
    timeout 60 bash "${d}/configure.sh" "$@" > "${d}/out" 2>&1; RC=$?; }

echo ".env"
make_repo "$WORK/repo"
run_cfg "$WORK/repo" --truenas 25.10.8 --nvidia 595.112.07 </dev/null
check "writes TRUENAS_TRAIN"     grep -qx "TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye" "$WORK/repo/.env"
check "no TRUENAS_CODENAME line" not grep -q "^TRUENAS_CODENAME=" "$WORK/repo/.env"
check "comment names the folder" grep -q "Folder of this release on download.truenas.com / update.truenas.com" "$WORK/repo/.env"

echo "host version the list has not indexed"
make_repo "$WORK/repo-h"
printf '#!/bin/bash\necho 25.10.9\n' > "$WORK/repo-h/bin/midclt"
printf '{"train": "TrueNAS-SCALE-Goldeye", "version": "25.10.9"}\n' > "$WORK/repo-h/manifest.json"
run_cfg "$WORK/repo-h" --truenas 25.10.9 --nvidia 595.112.07 </dev/null
check "train comes from manifest.json" grep -qx "TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye" "$WORK/repo-h/.env"
make_repo "$WORK/repo-hw"
printf '#!/bin/bash\necho 25.10.9\n' > "$WORK/repo-hw/bin/midclt"
printf '{"train": "TrueNAS-SCALE-Goldeye", "version": "25.10.9"}\n' > "$WORK/repo-hw/manifest.json"
run_cfg "$WORK/repo-hw" --no-whiptail < <(printf '1\n595.112.07\n\n\n\n\n\n\n\n\n\n')
check "wizard: detected version keeps its train" grep -qx "TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye" "$WORK/repo-hw/.env"
check "wizard: nothing asked" not grep -qF "is not known here" "$WORK/repo-hw/out"

echo "--train"
make_repo "$WORK/repo-t" down
run_cfg "$WORK/repo-t" --truenas 27.0.0-RC.1 --nvidia 595.112.07 --train TrueNAS-27-RC </dev/null
check "--train reaches .env"     grep -qx "TRUENAS_TRAIN=TrueNAS-27-RC" "$WORK/repo-t/.env"
make_repo "$WORK/repo-tb" down
run_cfg "$WORK/repo-tb" --truenas 25.10.8 --nvidia 595.112.07 --train 'TrueNAS-x;rm' </dev/null
check "bad --train refused"      not is "${RC}" 0
check "bad --train writes no .env" not test -e "$WORK/repo-tb/.env"
make_repo "$WORK/repo-tn" down
run_cfg "$WORK/repo-tn" --truenas 25.10.8 --nvidia 595.112.07 </dev/null
check "list down, no --train → empty train" grep -qx "TRUENAS_TRAIN=" "$WORK/repo-tn/.env"
check "list down, no --train → still accepted" is "${RC}" 0

echo "a known train reaches the kernel lookup"
make_repo "$WORK/repo-k" mtree
run_cfg "$WORK/repo-k" --truenas 25.10.8 --nvidia 470.256.02 --train TrueNAS-SCALE-Goldeye </dev/null
check "--train, list down: kernel read" grep -qF "TrueNAS 25.10.8 kernel: 6.12.113-production+truenas" "$WORK/repo-k/out"
check "--train, list down: the 470 warning names it" grep -qF "ships 6.12.113-production+truenas" "$WORK/repo-k/out"
check "--train: rootfs.mtree read once" is "$(mtree_asked "$WORK/repo-k")" 1
make_repo "$WORK/repo-kr" mtree-nv
cat > "$WORK/repo-kr/.env" <<'ENV'
NVIDIA_VERSION=595.112.07
TRUENAS_VERSION=25.10.8
TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye
NVIDIA_KERNEL_MODULE_TYPE=open
EMBED_NVIDIA_RAW_IN_UPDATE=false
ENV
run_cfg "$WORK/repo-kr" --reconfigure --no-whiptail < <(printf '2\n2\n\n\n')
check "reconfigure → nvidia: 470 picked" grep -qx "NVIDIA_VERSION=470.256.02" "$WORK/repo-kr/.env"
check "reconfigure → nvidia: kernel from .env's train" grep -qF "ships 6.12.113-production+truenas" "$WORK/repo-kr/out"
check "reconfigure → nvidia: rootfs.mtree read once" is "$(mtree_asked "$WORK/repo-kr")" 1
make_repo "$WORK/repo-kw" mtree
# Answers: version, train, driver, the module note, embed "No", patches "my own".
run_cfg "$WORK/repo-kw" --no-whiptail < <(printf '25.10.8\nTrueNAS-SCALE-Goldeye\n470.256.02\n\n1\n1\n\n\n\n\n\n')
check "wizard, typed train: kernel read" grep -qF "TrueNAS 25.10.8 kernel: 6.12.113-production+truenas" "$WORK/repo-kw/out"
check "wizard, typed train + 470: patches asked" grep -qF "won't build on kernel 6.12 unaided" "$WORK/repo-kw/out"
check "wizard, typed train + 470: the answer is kept" grep -qx "NVIDIA_PATCH_MODE=custom" "$WORK/repo-kw/.env"
check "wizard, typed train: rootfs.mtree read once" is "$(mtree_asked "$WORK/repo-kw")" 1

echo "non-interactive runs skip the labels"
make_repo "$WORK/repo-nl"
run_cfg "$WORK/repo-nl" --truenas 25.10.8 --nvidia 595.112.07 </dev/null
check "CLI: list read" grep -qx "TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye" "$WORK/repo-nl/.env"
check "CLI: update.truenas.com never asked" is "$(grep -c 'update.truenas.com' "$WORK/repo-nl/curl.log")" 0

echo "wizard, list unreachable"
make_repo "$WORK/repo-w" down
run_cfg "$WORK/repo-w" --no-whiptail < <(printf '25.10.8\nTrueNAS-SCALE-Goldeye\n595.112.07\n\n\n\n\n\n\n\n\n\n')
# read -p shows its prompt only on a terminal, so the wording is checked in the script.
check "the prompt's wording" grep -qF "Enter the release folder on download.truenas.com (e.g. TrueNAS-SCALE-Goldeye), or leave empty to let the build find it:" "$REPO/configure.sh"
check "says the folder is unknown" grep -qF "The release folder of TrueNAS 25.10.8 is not known here." "$WORK/repo-w/out"
check "typed train reaches .env" grep -qx "TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye" "$WORK/repo-w/.env"
make_repo "$WORK/repo-we" down
run_cfg "$WORK/repo-we" --no-whiptail < <(printf '25.10.8\n\n595.112.07\n\n\n\n\n\n\n\n\n\n')
check "empty answer allowed"     grep -qx "TRUENAS_TRAIN=" "$WORK/repo-we/.env"
make_repo "$WORK/repo-wb" down
run_cfg "$WORK/repo-wb" --no-whiptail < <(printf '25.10.8\nTrueNAS-x;rm\nTrueNAS-26-BETA\n595.112.07\n\n\n\n\n\n\n\n\n\n')
check "bad answer asked again"   grep -qx "TRUENAS_TRAIN=TrueNAS-26-BETA" "$WORK/repo-wb/.env"

echo "reconfigure an old .env"
make_repo "$WORK/repo-r" down
cat > "$WORK/repo-r/.env" <<'ENV'
NVIDIA_VERSION=595.112.07
TRUENAS_VERSION=25.10.8
NVIDIA_KERNEL_MODULE_TYPE=open
TRUENAS_CODENAME=Goldeye
EMBED_NVIDIA_RAW_IN_UPDATE=false
ENV
run_cfg "$WORK/repo-r" --reconfigure --no-whiptail < <(printf '4\n1\n\n\n')
check "codename becomes TRUENAS_TRAIN" grep -qx "TRUENAS_TRAIN=TrueNAS-SCALE-Goldeye" "$WORK/repo-r/.env"
check "codename line gone"       not grep -q "^TRUENAS_CODENAME=" "$WORK/repo-r/.env"

echo "tables and prompts"
check "tables gone"              is "$(grep -cE 'CODENAME_MAP|VERSION_TO_CODENAME' "$REPO/configure.sh")" 0
check "per-version codenames gone" is "$(grep -c 'TRUENAS_VERSION_CODENAMES' "$REPO/configure.sh")" 0
check "no 26+ codename prompt"   is "$(grep -c 'leave empty for TrueNAS 26' "$REPO/configure.sh")" 0
check "compose passes TRUENAS_TRAIN" grep -q 'TRUENAS_TRAIN=${TRUENAS_TRAIN:-}' "$REPO/docker-compose.yaml"
check "compose keeps TRUENAS_CODENAME" grep -q 'TRUENAS_CODENAME=${TRUENAS_CODENAME:-}' "$REPO/docker-compose.yaml"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
