#!/bin/bash
# =============================================================================
# configure.sh — Interactive configuration wizard for TrueNAS NVIDIA Driver Updater
#
# Fetches available NVIDIA driver and TrueNAS versions from public download
# pages, presents them as interactive menus, and generates docker-compose.yaml.
#
# UI modes (auto-detected):
#   - whiptail: full TUI dialogs with scrolling (preferred, available on TrueNAS)
#   - bash:     numbered menus via bash select (fallback, works everywhere)
#
# Usage:
#   ./configure.sh                  Interactive mode (default)
#   ./configure.sh --help           Show help
#   ./configure.sh --no-whiptail    Force bash menu mode
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ── UI mode detection ────────────────────────────────────────────────────────
UI_MODE="bash"
FORCE_BASH=false

# ── detect download tool ─────────────────────────────────────────────────────
FETCH_CMD=""
detect_fetch_cmd() {
    if command -v curl &>/dev/null; then
        FETCH_CMD="curl"
    elif command -v wget &>/dev/null; then
        FETCH_CMD="wget"
    else
        err "Neither curl nor wget found. Please install one of them."
        exit 1
    fi
}

# Fetch a URL to stdout
fetch_url() {
    local url="$1"
    if [[ "${FETCH_CMD}" == "curl" ]]; then
        curl -fsSL --connect-timeout 15 --max-time 60 "${url}" 2>/dev/null
    else
        wget -qO- --timeout=15 "${url}" 2>/dev/null
    fi
}

# Fetch at most $2 bytes of the body of $1 (a Range request; the output is
# capped even when the server ignores Range and sends the whole file).
fetch_url_range() {
    local url="$1" bytes="$2" rc=0
    if [[ "${FETCH_CMD}" == "curl" ]]; then
        curl -fsSL --connect-timeout 15 --max-time 60 -r "0-$((bytes - 1))" "${url}" 2>/dev/null | head -c "${bytes}"
        rc="${PIPESTATUS[0]}"
        [[ "${rc}" == 23 ]] && rc=0   # head closed the pipe: the server sent more than asked
    else
        wget -qO- --timeout=15 --header="Range: bytes=0-$((bytes - 1))" "${url}" 2>/dev/null | head -c "${bytes}"
        rc="${PIPESTATUS[0]}"
        [[ "${rc}" == 141 || "${rc}" == 3 ]] && rc=0
    fi
    return "${rc}"
}

# ── help ─────────────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
TrueNAS NVIDIA Driver Updater — Interactive Configuration Wizard

Usage:
  ./configure.sh              Launch the interactive wizard
  ./configure.sh --no-whiptail  Force plain bash menus (skip whiptail)
  ./configure.sh --reconfigure  Quick-change a single setting in existing config
  ./configure.sh --help       Show this help message

Non-interactive mode (for automation / CI):
  ./configure.sh --truenas 25.10.8 --nvidia 595.112.07
  ./configure.sh --truenas 25.10.8 --nvidia 595.112.07 --module open --embed false

  All flags:
    --truenas VERSION     TrueNAS version (e.g. 25.10.8)
    --nvidia VERSION      NVIDIA driver version (e.g. 595.112.07)
    --train TRAIN         Release folder on download.truenas.com, e.g.
                          TrueNAS-SCALE-Goldeye (default: looked up for --truenas)
    --module TYPE         Kernel module type: open (default) or proprietary
    --embed true|false    Embed nvidia.raw in truenas.update (default: false)
    --patch MODE          Source patches: none, custom, predefined, or auto
    --run-url URL         Download the installer from this URL instead
    --custom-run FILE     Use this .run installer as-is (must be inside
                          the project directory so the build can see it)
                          (default: auto). 'predefined' downloads the curated
                          set for the driver branch (for EOL drivers on new kernels).

The wizard will:
  1. Detect your system (auto-detect TrueNAS version and GPU if running locally)
  2. Fetch available TrueNAS versions from download.truenas.com
  3. Fetch available NVIDIA driver versions from download.nvidia.com
  4. Let you select options from interactive menus
  5. Generate docker-compose.yaml with your choices

UI modes (auto-detected):
  - If whiptail is available: full TUI dialog boxes with scrolling
  - Otherwise: numbered bash menus (works on any terminal)

Requirements:
  - bash (built-in on TrueNAS and most Linux systems)
  - curl or wget (for fetching version lists)
  - whiptail (optional — for enhanced TUI; available on TrueNAS)

After running the wizard, build with:
  docker compose build
  docker compose run --rm nvidia-builder
EOF
    exit 0
}

# ── CLI variables for non-interactive mode ───────────────────────────────────
CLI_TRUENAS=""
CLI_NVIDIA=""
CLI_TRAIN=""
CLI_MODULE=""
CLI_EMBED=""
CLI_PATCH=""
# Installer overrides — a URL to fetch, or a local .run to use as-is.
CLI_RUN_URL=""
CLI_RUN_FILE=""
CLI_RECONFIGURE=false

# ── parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)        show_help ;;
        --no-whiptail)    FORCE_BASH=true ;;
        --reconfigure)    CLI_RECONFIGURE=true ;;
        --truenas)        CLI_TRUENAS="$2"; shift ;;
        --nvidia)         CLI_NVIDIA="$2"; shift ;;
        --train)          CLI_TRAIN="$2"; shift ;;
        --module)         CLI_MODULE="$2"; shift ;;
        --embed)          CLI_EMBED="$2"; shift ;;
        --patch)          CLI_PATCH="$2"; shift ;;
        --run-url)        CLI_RUN_URL="$2"; shift ;;
        --custom-run)     CLI_RUN_FILE="$2"; shift ;;
        --truenas=*)      CLI_TRUENAS="${1#*=}" ;;
        --nvidia=*)       CLI_NVIDIA="${1#*=}" ;;
        --train=*)        CLI_TRAIN="${1#*=}" ;;
        --module=*)       CLI_MODULE="${1#*=}" ;;
        --embed=*)        CLI_EMBED="${1#*=}" ;;
        --patch=*)        CLI_PATCH="${1#*=}" ;;
        --run-url=*)      CLI_RUN_URL="${1#*=}" ;;
        --custom-run=*)   CLI_RUN_FILE="${1#*=}" ;;
        *) warn "Unknown argument: $1" ;;
    esac
    shift
done

# ── detect UI mode ───────────────────────────────────────────────────────────
detect_ui_mode() {
    if [[ "${FORCE_BASH}" == true ]]; then
        UI_MODE="bash"
        info "UI mode: bash (forced via --no-whiptail)"
        return
    fi

    if command -v whiptail &>/dev/null; then
        UI_MODE="whiptail"
        info "UI mode: whiptail (TUI dialogs)"
    else
        UI_MODE="bash"
        info "UI mode: bash (plain numbered menus)"
    fi
}

# Calculate whiptail dialog dimensions from terminal size
wt_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)

    WT_HEIGHT=$((rows - 4))
    WT_WIDTH=$((cols - 8))
    [[ ${WT_HEIGHT} -gt 30 ]] && WT_HEIGHT=30
    [[ ${WT_WIDTH} -gt 90 ]] && WT_WIDTH=90
    [[ ${WT_WIDTH} -lt 60 ]] && WT_WIDTH=60
    WT_MENU_HEIGHT=$((WT_HEIGHT - 8))
}

# =============================================================================
# TrueNAS Version Fetching
# =============================================================================

# Train of each listed version: the folder it sits in on download.truenas.com
# (e.g. 25.10.8 → TrueNAS-SCALE-Goldeye, 27.0.0-RC.1 → TrueNAS-27-RC). The same
# name is the train on update.truenas.com. Filled by fetch_truenas_versions.
declare -gA TRUENAS_VERSION_TRAIN=()
declare -gA TRUENAS_VERSION_TAGS=()
declare -gA TRUENAS_VERSION_PROFILE=()
TRUENAS_LIST_TRIED=false

# The host's own release record (written by TrueNAS; holds "train").
TRUENAS_MANIFEST_FILE="${TRUENAS_MANIFEST_FILE:-/data/manifest.json}"

# 0 when $1 looks like a train name (a single folder, nothing to escape).
valid_train() {
    [[ "${1:-}" =~ ^TrueNAS-[A-Za-z0-9-]+$ ]]
}

# Human name of a train: TrueNAS-SCALE-Goldeye-RC → Goldeye-RC, TrueNAS-27-RC → 27-RC.
truenas_train_display() {
    local name="${1#TrueNAS-SCALE-}"
    [[ "${name}" == "$1" ]] && name="${1#TrueNAS-}"
    printf '%s\n' "${name}"
}

# Menu description of a listed version: its train's name and its tag.
truenas_menu_desc() {
    local ver="$1" name="" tag="${TRUENAS_VERSION_TAGS[$1]:-}"
    [[ -n "${TRUENAS_VERSION_TRAIN[${ver}]:-}" ]] \
        && name="$(truenas_train_display "${TRUENAS_VERSION_TRAIN[${ver}]}")"
    printf '%s\n' "${name}${tag:+${name:+  }${tag}}"
}

# Train of the TrueNAS this runs on, from its manifest.json; prints nothing when
# the file is missing, unreadable, or there is no python3/jq to read it.
host_truenas_train() {
    local file="${TRUENAS_MANIFEST_FILE:-/data/manifest.json}" train=""
    [[ -r "${file}" ]] || return 0
    if command -v python3 >/dev/null 2>&1; then
        train="$(python3 -I -c 'import json, sys
t = json.load(open(sys.argv[1])).get("train")
print(t if isinstance(t, str) else "")' "${file}" 2>/dev/null)" || train=""
    elif command -v jq >/dev/null 2>&1; then
        train="$(jq -r 'if (.train | type) == "string" then .train else "" end' "${file}" 2>/dev/null)" || train=""
    fi
    valid_train "${train}" && printf '%s\n' "${train}"
    return 0
}

# Train of the selected version: from the download.truenas.com list, else —
# for the version this host runs (which the list may not have indexed yet) —
# from the host's manifest.json. Prints nothing when neither knows it.
resolve_selected_train() {
    local version="$1"
    if [[ -n "${TRUENAS_VERSION_TRAIN[${version}]:-}" ]]; then
        printf '%s\n' "${TRUENAS_VERSION_TRAIN[${version}]}"
    elif [[ -n "${version}" ]] && [[ "${version}" == "${DETECTED_TRUENAS_VERSION:-}" ]]; then
        host_truenas_train
    fi
    return 0
}

# Ask for the train once (an invalid answer is asked again). Empty is allowed:
# the build then finds the folder itself. Sets the variable named by $1.
prompt_truenas_train() {
    local -n _train_answer=$1
    local answer=""
    while true; do
        answer=""
        ui_inputbox answer "Release folder" \
            "Enter the release folder on download.truenas.com (e.g. TrueNAS-SCALE-Goldeye), or leave empty to let the build find it:" \
            || answer=""
        answer="${answer//[[:space:]]/}"
        if [[ -z "${answer}" ]] || valid_train "${answer}"; then
            _train_answer="${answer}"
            return 0
        fi
        warn "'${answer}' is not a release folder name (expected e.g. TrueNAS-SCALE-Goldeye)."
    done
}

# Train for the version the wizard selected: the list, the host, then — when
# the list has not been fetched yet — the list after all; asks only when none
# of them knows it. Sets the variable named by $1.
wizard_truenas_train() {
    local -n _wizard_train=$1
    local version="$2" train=""
    train="$(resolve_selected_train "${version}")"
    if [[ -z "${train}" ]] && [[ "${TRUENAS_LIST_TRIED}" != true ]] \
        && fetch_truenas_versions; then
        train="$(resolve_selected_train "${version}")"
    fi
    if [[ -z "${train}" ]]; then
        warn "The release folder of TrueNAS ${version} is not known here."
        prompt_truenas_train train
    fi
    _wizard_train="${train}"
}

# Label of a release from its update profile (TrueNAS's own: MISSION_CRITICAL,
# GENERAL, EARLY_ADOPTER, DEVELOPER) and "lts" flag. An unknown profile → no label.
truenas_release_label() {
    local profile="${1:-}" lts="${2:-}" label=""
    case "${profile}" in
        MISSION_CRITICAL) label="★ Mission Critical" ;;
        GENERAL)          label="★ General" ;;
        EARLY_ADOPTER)    label="Early Adopter" ;;
        DEVELOPER)        label="Developer" ;;
        *) return 0 ;;
    esac
    [[ "${lts}" == "true" || "${lts}" == "True" ]] && label="${label} · LTS"
    printf '%s\n' "${label}"
}

# Prints "<train>" lines of update.truenas.com's trains_v2.json (every train and
# every redirection target); nothing when unreadable or no python3/jq.
truenas_update_trains() {
    local json="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -I -c 'import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict): sys.exit(0)
t = d.get("trains"); r = d.get("trains_redirection")
for k in (t if isinstance(t, dict) else {}): print(k)
for v in (r.values() if isinstance(r, dict) else []):
    if isinstance(v, str): print(v)' <<< "${json}" 2>/dev/null
    elif command -v jq >/dev/null 2>&1; then
        jq -r '((.trains // {}) | if type == "object" then keys[] else empty end),
               ((.trains_redirection // {}) | if type == "object" then .[] | strings else empty end)' \
            <<< "${json}" 2>/dev/null
    fi
    return 0
}

# Prints "<version> <profile> <lts>" lines of one train's releases.json.
truenas_update_releases() {
    local json="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -I -c 'import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict): sys.exit(0)
for k, v in d.items():
    if not isinstance(v, dict): continue
    p = v.get("profile"); l = v.get("lts")
    print(k, p if isinstance(p, str) else "-", "true" if l is True else "false")' <<< "${json}" 2>/dev/null
    elif command -v jq >/dev/null 2>&1; then
        jq -r 'if type == "object" then to_entries[] | select(.value | type == "object")
               | "\(.key) \(if (.value.profile | type) == "string" then .value.profile else "-" end) \(if .value.lts == true then "true" else "false" end)"
               else empty end' <<< "${json}" 2>/dev/null
    fi
    return 0
}

TRUENAS_LABELS_OK=0

# Label the given versions with TrueNAS's own profile from update.truenas.com
# (fills TRUENAS_VERSION_TAGS and TRUENAS_VERSION_PROFILE). Reads the trains the
# trains_v2.json names (nightlies excluded) plus the train of every given
# version; a train without a releases.json is skipped. Never guesses: a version
# nobody labels, or with an unknown profile, simply has no label.
fetch_truenas_release_labels() {
    declare -gA TRUENAS_VERSION_TAGS=()
    declare -gA TRUENAS_VERSION_PROFILE=()
    TRUENAS_LABELS_OK=0
    local -A wanted=() seen=()
    local v
    for v in "$@"; do wanted["${v}"]=1; done

    local -a trains=()
    local t trains_json="" releases_json="" line ver profile lts label
    trains_json="$(fetch_url "https://update.truenas.com/scale/trains_v2.json" 2>/dev/null)" || trains_json=""
    while IFS= read -r t; do
        [[ -n "${t}" && "${t}" != *Nightlies* ]] || continue
        valid_train "${t}" || continue
        [[ -n "${seen[${t}]:-}" ]] && continue
        seen["${t}"]=1; trains+=("${t}")
    done < <(
        [[ -n "${trains_json}" ]] && truenas_update_trains "${trains_json}"
        for v in "$@"; do printf '%s\n' "${TRUENAS_VERSION_TRAIN[${v}]:-}"; done
    )

    for t in "${trains[@]}"; do
        releases_json="$(fetch_url "https://update.truenas.com/scale/${t}/releases.json" 2>/dev/null)" || continue
        [[ -n "${releases_json}" ]] || continue
        while read -r ver profile lts; do
            [[ -n "${wanted[${ver}]:-}" && -n "${profile}" ]] || continue
            TRUENAS_LABELS_OK=1
            # The same release can be listed by several trains; the first wins.
            [[ -n "${TRUENAS_VERSION_PROFILE[${ver}]:-}" ]] && continue
            [[ "${profile}" == "-" ]] && continue
            TRUENAS_VERSION_PROFILE["${ver}"]="${profile}"
            label="$(truenas_release_label "${profile}" "${lts}")"
            [[ -n "${label}" ]] && TRUENAS_VERSION_TAGS["${ver}"]="${label}"
        done < <(truenas_update_releases "${releases_json}")
    done

    if (( TRUENAS_LABELS_OK == 0 )); then
        warn "TrueNAS release labels unavailable — update.truenas.com could not be read"
        return 1
    fi
    return 0
}

# Where the TrueNAS menu starts: the version this host runs if listed, else the
# newest version TrueNAS itself rates GENERAL or MISSION_CRITICAL, else the
# newest that is not a BETA/RC. Prints nothing when the list is empty.
truenas_menu_default() {
    local v
    if [[ -n "${DETECTED_TRUENAS_VERSION:-}" ]]; then
        for v in "${TRUENAS_VERSIONS[@]}"; do
            [[ "${v}" == "${DETECTED_TRUENAS_VERSION}" ]] && { printf '%s\n' "${v}"; return 0; }
        done
    fi
    for v in "${TRUENAS_VERSIONS[@]}"; do
        case "${TRUENAS_VERSION_PROFILE[${v}]:-}" in
            GENERAL|MISSION_CRITICAL) printf '%s\n' "${v}"; return 0 ;;
        esac
    done
    for v in "${TRUENAS_VERSIONS[@]}"; do
        [[ "${v}" == *-BETA* || "${v}" == *-RC* ]] || { printf '%s\n' "${v}"; return 0; }
    done
    return 0
}

# TrueNAS only ships the driver as a sysext from 24.10 on; before that it is
# ordinary packages, with no nvidia.raw for this project to replace.
truenas_version_supported() {
    local major="${1%%.*}" rest="${1#*.}"
    # The minor is the digits after the first dot: 25.10-RC.1 is 25.10.
    local minor="${rest%%[!0-9]*}"
    [[ "$1" == *.* ]] && [[ "${major}" =~ ^[0-9]+$ ]] && [[ "${minor}" =~ ^[0-9]+$ ]] || return 1
    (( 10#${major} * 100 + 10#${minor} >= 2410 ))
}

require_supported_truenas() {
    truenas_version_supported "$1" && return 0
    err "TrueNAS $1 is not supported. The minimum is 24.10: older releases ship the"
    err "driver as ordinary packages, so there is no nvidia.raw to replace."
    exit 1
}

fetch_truenas_versions() {
    local html=""
    TRUENAS_LIST_TRIED=true

    info "Fetching TrueNAS versions from download.truenas.com …"

    html="$(fetch_url "https://download.truenas.com/" 2>/dev/null)" || {
        warn "Could not fetch TrueNAS version list from download.truenas.com"
        return 1
    }

    # Each release is a folder inside its train's folder, linked as
    #   href="TrueNAS-SCALE-Goldeye/25.10.8"
    #   href="TrueNAS-27-RC/27.0.0-RC.1"
    # so the parent folder of every version is its train. Files (ISOs, nightly
    # builds) and deeper paths are not releases.
    local raw_versions=""
    raw_versions="$(grep -oE 'href="TrueNAS-[^"/]+/[0-9][^"]*"' <<< "${html}" \
        | sed 's/^href="//;s/"$//;s:/$::' \
        | grep -vE '\.(iso|gpg|sha256|mtree|update|deb|gz|xz|bz2)$' \
        | grep -vE 'Nightlies|MASTER|packages' \
        | sort -u)" || true

    if [[ -z "${raw_versions}" ]]; then
        warn "Could not parse TrueNAS versions from download page"
        return 1
    fi

    # Version → train, and the version list
    declare -gA TRUENAS_VERSION_TRAIN=()
    declare -ga TRUENAS_VERSIONS=()

    local entry train version
    while IFS= read -r entry; do
        train="${entry%%/*}"
        version="${entry#*/}"

        valid_train "${train}" || continue
        [[ "${version}" =~ ^[0-9]+\.[0-9]+[0-9A-Za-z.-]*$ ]] || continue
        truenas_version_supported "${version}" || continue
        # A version listed under two trains keeps the first one.
        [[ -n "${TRUENAS_VERSION_TRAIN[${version}]:-}" ]] && continue

        TRUENAS_VERSION_TRAIN["${version}"]="${train}"
        TRUENAS_VERSIONS+=("${version}")
    done <<< "${raw_versions}"

    # Sort versions: newest first (reverse version sort)
    local sorted_versions=""
    sorted_versions="$(printf '%s\n' "${TRUENAS_VERSIONS[@]}" | sort -rV)"
    local -a sorted_arr=()
    while IFS= read -r v; do
        [[ -n "${v}" ]] && sorted_arr+=("${v}")
    done <<< "${sorted_versions}"

    if [[ ${#sorted_arr[@]} -eq 0 ]]; then
        warn "No TrueNAS versions found"
        return 1
    fi

    TRUENAS_VERSIONS=("${sorted_arr[@]}")

    # TrueNAS's own labels; the list is complete without them.
    fetch_truenas_release_labels "${TRUENAS_VERSIONS[@]}" || true

    ok "Found ${#TRUENAS_VERSIONS[@]} TrueNAS versions"
    return 0
}

# =============================================================================
# NVIDIA Driver Version Fetching
# =============================================================================

# Minimum driver version to show (older ones don't support modern TrueNAS kernels)
NVIDIA_MIN_MAJOR=470

# Where NVIDIA's own page says which query yields each branch label, and the
# lookup service those queries go to.
NVIDIA_UNIX_PAGE_URL="https://www.nvidia.com/en-us/drivers/unix/"
NVIDIA_LOOKUP_URL="https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup"

# Used when the page can't be read or yields no usable query (TYPE|PARAMS,
# copied from the linux64 blocks of that page).
NVIDIA_LOOKUP_FALLBACK=(
    "PB|psid=133&pfid=1075&osID=12&languageCode=1033&beta=0&isWHQL=0&dltype=-1&dch=0&upCRD=null&qnf=0&ctk=null&sort1=&numberOfResults=1"
    "NFB|psid=133&pfid=1075&osID=12&languageCode=1033&beta=null&isWHQL=0&dltype=-1&dch=0&upCRD=null&qnf=1&ctk=null&sort1=1&numberOfResults=1"
    "BETA|psid=133&pfid=1075&osID=12&languageCode=1033&beta=1&isWHQL=0&dltype=-1&dch=0&upCRD=null&qnf=0&ctk=null&sort1=1&numberOfResults=1"
    "Legacy|psid=122&pfid=944&osID=12&languageCode=1033&isWHQL=0&beta=0&dltype=-1&dch=0&upCRD=null&qnf=0&ctk=null&sort1=1&release=470&numberOfResults=1"
)

# Extract major version prefix from a version string (e.g. "595.80" → "595")
nvidia_major() {
    [[ "$1" =~ ^([0-9]+)\. ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Minimum driver major whose nvidia-installer understands --kernel-module-type
# (the flag that selects the open vs proprietary flavor). It first appears in the
# R555 feature branch; older branches — including the 535/550 LTS lines — lack it,
# so the flavor can't be chosen and the installer builds proprietary by default.
# This is only a wizard heuristic; the build itself probes the real installer
# (see installer_supports_option() in entrypoint.sh) and is authoritative.
NVIDIA_MODULE_TYPE_MIN_MAJOR=555

# Returns 0 (true) when the given driver version can select the kernel module
# flavor (open vs proprietary), i.e. major >= NVIDIA_MODULE_TYPE_MIN_MAJOR.
nvidia_supports_module_type() {
    local major=""
    major="$(nvidia_major "$1")"
    [[ "${major}" =~ ^[0-9]+$ ]] || return 1
    (( major >= NVIDIA_MODULE_TYPE_MIN_MAJOR ))
}

# End-of-life driver branches and the highest Linux kernel (MAJOR.MINOR) they
# can still build against. Only end-of-life branches are listed, because NVIDIA
# publishes no maximum kernel per branch; current branches have no entry.
# Kept in sync with NVIDIA_BRANCH_MAX_KERNEL in entrypoint.sh.
declare -A NVIDIA_BRANCH_MAX_KERNEL=(
    [390]="5.15"
    [470]="6.9"
)

# The kernel of a TrueNAS release, read from the first bytes of its
# rootfs.mtree on download.truenas.com (the same data the build image has).
# Cached per version; an unknown kernel is cached too (as empty).
declare -gA TRUENAS_KERNEL_CACHE=()

# Returns 0 when version $1 is strictly greater than $2 (both "MAJOR.MINOR").
kernel_version_gt() {
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# Kernel name in one mtree line ("./boot/vmlinuz-<kernel> mode=..."): prints it
# when it starts with a digit and is not a debug kernel.
mtree_kernel_of() {
    local line="$1" k=""
    [[ "${line}" == ./boot/vmlinuz-* ]] || return 1
    k="${line#./boot/vmlinuz-}"
    k="${k%%[[:space:]]*}"
    [[ "${k}" =~ ^[0-9] ]] || return 1
    [[ "${k}" != *debug* ]] || return 1
    printf '%s\n' "${k}"
}

truenas_release_kernel() {
    local version="$1" train="" head="" line="" k=""
    if [[ -n "${TRUENAS_KERNEL_CACHE[${version}]+x}" ]]; then
        [[ -n "${TRUENAS_KERNEL_CACHE[${version}]}" ]] || return 1
        printf '%s\n' "${TRUENAS_KERNEL_CACHE[${version}]}"
        return 0
    fi
    TRUENAS_KERNEL_CACHE[${version}]=""
    train="$(resolve_selected_train "${version}")"
    [[ -n "${train}" ]] || return 1
    head="$(fetch_url_range "https://download.truenas.com/${train}/${version}/rootfs.mtree?download=1" 16384)" || return 1
    while IFS= read -r line; do
        if k="$(mtree_kernel_of "${line}")"; then
            TRUENAS_KERNEL_CACHE[${version}]="${k}"
            printf '%s\n' "${k}"
            return 0
        fi
    done <<< "${head}"
    return 1
}

# MAJOR.MINOR of a TrueNAS release's kernel; empty when unknown. The build
# reads the REAL kernel from the image and is authoritative.
truenas_kernel_mm() {
    local k=""
    k="$(truenas_release_kernel "$1" 2>/dev/null)" || return 0
    [[ "${k}" =~ ^([0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}

# Step 1 confirmation: the release's kernel, or — once per run — that it is
# unknown. Runs in the current shell so the cache survives for later lookups.
TRUENAS_KERNEL_UNKNOWN_SHOWN=false
announce_truenas_kernel() {
    local version="$1" k=""
    truenas_release_kernel "${version}" >/dev/null 2>&1 || true
    k="${TRUENAS_KERNEL_CACHE[${version}]:-}"
    if [[ -n "${k}" ]]; then
        ok "TrueNAS ${version} kernel: ${k}"
    elif [[ "${TRUENAS_KERNEL_UNKNOWN_SHOWN}" != true ]]; then
        TRUENAS_KERNEL_UNKNOWN_SHOWN=true
        info "Kernel of TrueNAS ${version} unknown — kernel-based checks skipped"
    fi
    return 0
}

# Early heads-up when an end-of-life driver branch is selected: those branches
# fail to compile on recent kernels. Advisory only — the build does the
# authoritative check against the real image kernel (see
# check_driver_kernel_compatibility() in entrypoint.sh).
advise_legacy_driver() {
    local version="$1" truenas_version="${2:-}"
    local major="" max="" kernel="" kmm=""
    major="$(nvidia_major "${version}")"
    max="${NVIDIA_BRANCH_MAX_KERNEL[${major}]:-}"
    [[ -z "${max}" ]] && return 0

    if [[ -n "${truenas_version}" ]]; then
        kernel="$(truenas_release_kernel "${truenas_version}" 2>/dev/null)" || kernel=""
        kmm="$(truenas_kernel_mm "${truenas_version}")"
    fi
    if [[ -n "${kmm}" ]]; then
        kernel_version_gt "${kmm}" "${max}" || return 0
        warn "NVIDIA ${version} is an end-of-life branch that builds only up to kernel ${max};"
        warn "TrueNAS ${truenas_version} ships ${kernel}, so it will FAIL to compile without patches in patches/${kmm}/."
        warn "Pick a current driver branch (★ Production / ★ New Feature) or add patches — see the README."
        return 0
    fi
    warn "NVIDIA ${version} is an end-of-life branch that builds only up to kernel ${max};"
    warn "a TrueNAS release with a newer kernel will FAIL to compile it without patches in patches/<kernel>/."
    warn "Use it only for older GPUs on an older TrueNAS release, pick a current"
    warn "branch (★ Production / ★ New Feature), or add patches — see the README."
}

# Warn at config time when the build WILL patch the driver — i.e. the repo's
# patches/<kernel>/ for the selected TrueNAS version's kernel contains patches.
advise_patches() {
    local truenas_version="$1"
    local kmm=""
    kmm="$(truenas_kernel_mm "${truenas_version}")"
    [[ -n "${kmm}" ]] || return 0

    local self_dir=""
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local pdir="${self_dir}/patches/${kmm}"
    [[ -d "${pdir}" ]] || return 0

    local -a found=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] && found+=("${f}")
    done < <(find "${pdir}" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | sort)
    [[ ${#found[@]} -gt 0 ]] || return 0

    warn "Source patches found for kernel ${kmm} (patches/${kmm}/): ${#found[@]} file(s)."
    warn "The build will PATCH the NVIDIA driver with them — a community-patched,"
    warn "non-standard build that NVIDIA does not support. Remove them to build stock."
}

# Repo directory (where configure.sh lives).
config_repo_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

# Translate a host path to the path the build container will see. The repo is
# bind-mounted at /workspace, so a custom .run has to live inside it — anything
# else simply isn't visible to the build.
host_path_to_container() {
    local host_path="$1"
    local repo_dir="" abs=""
    repo_dir="$(config_repo_dir)"

    abs="$(readlink -f "${host_path}" 2>/dev/null || printf '%s' "${host_path}")"

    if [[ ! -f "${abs}" ]]; then
        err "Installer not found: ${host_path}"
        return 1
    fi
    if [[ "${abs}" != "${repo_dir}/"* ]]; then
        err "The installer must live inside the project directory so the build"
        err "container can see it (the repo is mounted at /workspace)."
        err "  given: ${abs}"
        err "  fix:   cp '${abs}' '${repo_dir}/' and pass the copy instead"
        return 1
    fi

    printf '/workspace/%s' "${abs#"${repo_dir}"/}"
}

# True when the selected driver can't build on the selected TrueNAS kernel unaided
# (legacy branch + kernel newer than its ceiling) — i.e. patches are needed.
patching_relevant() {
    local driver_major=""
    driver_major="$(nvidia_major "$1")"
    local max="${NVIDIA_BRANCH_MAX_KERNEL[${driver_major}]:-}"
    [[ -n "${max}" ]] || return 1
    local kmm=""
    kmm="$(truenas_kernel_mm "$2")"
    [[ -n "${kmm}" ]] || return 1
    [[ "${kmm}" != "${max}" \
       && "$(printf '%s\n%s\n' "${kmm}" "${max}" | sort -V | tail -n1)" == "${kmm}" ]]
}

# Download the curated predefined patch set for a driver branch (per its
# predefined-patches/<driver>/PATCHES.list) into predefined-patches/<driver>/,
# numbered to preserve apply order. Returns non-zero on any failure.
fetch_predefined_patches() {
    local driver_major="$1"
    local pdir="$(config_repo_dir)/predefined-patches/${driver_major}"
    local manifest="${pdir}/PATCHES.list"
    [[ -f "${manifest}" ]] || { err "No predefined patch set for NVIDIA ${driver_major}."; return 1; }

    local base="" line
    local -a names=()
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        if [[ "${line}" =~ ^@base[[:space:]]+(.+)$ ]]; then
            base="$(echo "${BASH_REMATCH[1]}" | tr -d '[:space:]')"
            continue
        fi
        names+=("$(echo "${line}" | tr -d '[:space:]')")
    done < "${manifest}"

    [[ -n "${base}" ]] || { err "Predefined manifest missing an @base URL."; return 1; }
    [[ ${#names[@]} -gt 0 ]] || { err "Predefined manifest lists no patches."; return 1; }

    # Clear any stale downloads so a re-run is clean
    find "${pdir}" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) -delete 2>/dev/null || true

    info "Downloading ${#names[@]} predefined patch(es) for NVIDIA ${driver_major} …"
    local n=0 name out
    for name in "${names[@]}"; do
        n=$((n + 1))
        out="$(printf '%s/%02d-%s' "${pdir}" "${n}" "${name}")"
        if ! fetch_url "${base}/${name}" > "${out}" 2>/dev/null || [[ ! -s "${out}" ]]; then
            rm -f "${out}"
            err "Failed to download ${name} from ${base}/"
            return 1
        fi
        echo -e "  ${GREEN}✓${NC} ${name}"
    done
    ok "Saved ${n} patch(es) to predefined-patches/${driver_major}/"
    warn "These are COMMUNITY patches, not tested/endorsed here — verify your build."
    return 0
}

# Ask how to handle source patches, but only when the driver/kernel combo needs
# them. Sets SELECTED_PATCH_MODE to none|custom|predefined (default none).
SELECTED_PATCH_MODE="none"
choose_patch_mode() {
    local nvidia_version="$1" truenas_version="$2"
    SELECTED_PATCH_MODE="none"

    patching_relevant "${nvidia_version}" "${truenas_version}" || return 0

    local driver_major="" kmm=""
    driver_major="$(nvidia_major "${nvidia_version}")"
    kmm="$(truenas_kernel_mm "${truenas_version}")"
    local have_predefined="no"
    [[ -f "$(config_repo_dir)/predefined-patches/${driver_major}/PATCHES.list" ]] && have_predefined="yes"

    banner "Kernel Patches"
    echo -e "  ${YELLOW}NVIDIA ${nvidia_version} (legacy) won't build on kernel ${kmm} unaided.${NC}"
    echo -e "  ${DIM}You can patch the driver source so it compiles, or skip and use a newer driver.${NC}"
    echo ""

    local choice=""
    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        local -a opts=()
        [[ "${have_predefined}" == "yes" ]] && opts+=("predefined" "Download curated community patches for ${driver_major} (recommended)")
        opts+=("custom" "Use my own patches in patches/${kmm}/")
        opts+=("none" "No patches (build will likely fail)")
        choice=$(whiptail --title "Kernel Patches" \
            --menu "NVIDIA ${nvidia_version} needs source patches for kernel ${kmm}:" \
            ${WT_HEIGHT} ${WT_WIDTH} 3 "${opts[@]}" 3>&1 1>&2 2>&3) || choice="none"
    else
        local -a labels=() tags=()
        if [[ "${have_predefined}" == "yes" ]]; then
            labels+=("Download curated community patches (recommended)"); tags+=("predefined")
        fi
        labels+=("Use my own patches in patches/${kmm}/"); tags+=("custom")
        labels+=("No patches (build will likely fail)"); tags+=("none")
        PS3="  #? "
        local sel
        select sel in "${labels[@]}"; do
            if [[ -n "${sel}" ]]; then choice="${tags[$((REPLY-1))]}"; break; fi
            echo -e "  ${RED}Invalid selection.${NC}"
        done
    fi
    [[ -n "${choice}" ]] || choice="none"

    case "${choice}" in
        predefined)
            if fetch_predefined_patches "${driver_major}"; then
                SELECTED_PATCH_MODE="predefined"
            else
                warn "Falling back to 'custom' — add patches to patches/${kmm}/ before building."
                SELECTED_PATCH_MODE="custom"
            fi
            ;;
        custom)
            SELECTED_PATCH_MODE="custom"
            info "Place your patches in patches/${kmm}/ before building (see README)."
            ;;
        *)
            SELECTED_PATCH_MODE="none"
            ;;
    esac
    ok "Patch mode: ${SELECTED_PATCH_MODE}"
}

# Find the latest version in the sorted list matching a given major prefix
nvidia_latest_in_series() {
    local target_major="$1"; shift
    local -a versions=("$@")
    for ver in "${versions[@]}"; do
        if [[ "$(nvidia_major "${ver}")" == "${target_major}" ]]; then
            printf '%s' "${ver}"
            return 0
        fi
    done
    return 1
}

# Read NVIDIA's unix-drivers page (stdin) and print "TYPE|PARAMS" for every
# linux64 lookup block. Blocks whose params look unsafe are dropped: the string
# is later put into a URL, so only a plain query-string alphabet is accepted.
nvidia_lookup_queries() {
    local type params
    while IFS='|' read -r type params; do
        [[ "${type}" =~ ^(PB|NFB|BETA|Legacy)$ ]] || continue
        [[ "${params}" =~ ^[A-Za-z0-9=\&_.-]+$ ]] || continue
        printf '%s|%s\n' "${type}" "${params}"
    done < <(awk '
        /"drvrLkupInfo"/ { p = ""; t = ""; o = "" }
        /"urlParams"/ {
            line = $0
            gsub(/"\+countryID\+"/, "1033", line)
            if (match(line, /"urlParams"[ \t]*:[ \t]*"[^"]*"/)) {
                p = substr(line, RSTART, RLENGTH)
                sub(/^"urlParams"[ \t]*:[ \t]*"/, "", p); sub(/"$/, "", p)
            }
        }
        /"drvrType"/ { if (match($0, /:[ \t]*"[^"]*"/)) { t = substr($0, RSTART, RLENGTH); gsub(/^:[ \t]*"|"$/, "", t) } }
        /"osCode"/   { if (match($0, /:[ \t]*"[^"]*"/)) { o = substr($0, RSTART, RLENGTH); gsub(/^:[ \t]*"|"$/, "", o) } }
        /^[ \t]*}/   { if (o == "linux64" && t != "" && p != "") print t "|" p; p = ""; t = ""; o = "" }
    ')
}

# Ask NVIDIA's lookup service one query and print the version it answers with.
# Returns 1 when the answer is not what the label needs, 2 when the service
# could not be reached.
nvidia_lookup_version() {
    local type="$1" params="$2" body="" flag="" version=""
    body="$(fetch_url "${NVIDIA_LOOKUP_URL}&${params}" 2>/dev/null)" || return 2
    case "${type}" in
        PB)     flag='"IsRecommended" : "1"' ;;
        NFB)    flag='"IsFeaturePreview" : "1"' ;;
        BETA)   flag='"IsBeta" : "1"' ;;
        Legacy) flag="" ;;
        *)      return 1 ;;
    esac
    [[ -z "${flag}" ]] || [[ "${body}" == *"${flag}"* ]] || return 1
    version="$(grep -oP 'NVIDIA-Linux-x86_64-\K[0-9]+\.[0-9]+(\.[0-9]+)?(?=\.run)' <<< "${body}" | head -1)" || true
    [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    if [[ "${type}" == "Legacy" ]]; then
        local release=""
        release="$(grep -oP '(^|&)release=\K[0-9]+' <<< "${params}" | head -1)" || true
        [[ -n "${release}" && "$(nvidia_major "${version}")" == "${release}" ]] || return 1
    fi
    printf '%s' "${version}"
}

fetch_nvidia_branch_info() {
    # Label driver versions using the queries NVIDIA's own page defines:
    #   1. read the lookup queries from the unix-drivers page (built-in copy if
    #      the page is unreadable)
    #   2. ask each one; keep the answer only when its flag confirms the label
    #      and the version is actually in our list
    # A label that cannot be confirmed is simply not shown.
    #
    # Args: version list from download.nvidia.com
    # Sets: NVIDIA_VERSION_TAGS[version], NVIDIA_BRANCH_VERSION[TYPE],
    #       NVIDIA_BRANCH_INFO_OK (1 when at least one label was confirmed)

    declare -gA NVIDIA_VERSION_TAGS=()
    declare -gA NVIDIA_BRANCH_VERSION=()
    NVIDIA_BRANCH_INFO_OK=0
    local -a sorted=("$@")

    [[ ${#sorted[@]} -eq 0 ]] && return 1

    local page="" queries=""
    page="$(fetch_url "${NVIDIA_UNIX_PAGE_URL}" 2>/dev/null)" || page=""
    queries="$(nvidia_lookup_queries <<< "${page}")"
    if [[ -z "${queries}" ]]; then
        info "Using built-in NVIDIA lookup queries"
        queries="$(printf '%s\n' "${NVIDIA_LOOKUP_FALLBACK[@]}")"
    fi

    local -A label=(
        [PB]="★ Production Branch"
        [NFB]="★ New Feature Branch"
        [BETA]="Beta — not for production use"
    )
    local type params version rc listed v text release
    while IFS='|' read -r type params; do
        [[ -n "${type}" ]] || continue
        version="$(nvidia_lookup_version "${type}" "${params}")" && rc=0 || rc=$?
        [[ ${rc} -eq 2 ]] && break   # service unreachable: the rest would fail too
        [[ ${rc} -eq 0 ]] || continue
        listed=0
        for v in "${sorted[@]}"; do [[ "${v}" == "${version}" ]] && listed=1; done
        [[ ${listed} -eq 1 ]] || continue
        if [[ "${type}" == "Legacy" ]]; then
            # The series comes from the query's own release= value, which
            # nvidia_lookup_version has confirmed equals the version's major.
            # NVIDIA may define more than one Legacy block: each confirmed
            # version gets its own label, and NVIDIA_BRANCH_VERSION[Legacy]
            # holds the first 470 one when present, otherwise the first one.
            release="$(grep -oP '(^|&)release=\K[0-9]+' <<< "${params}" | head -1)" || true
            text="★ Legacy GPU (${release}.xx)"
            v="${NVIDIA_BRANCH_VERSION[Legacy]:-}"
            if [[ -z "${v}" ]] || [[ "${release}" == "470" && "$(nvidia_major "${v}")" != "470" ]]; then
                NVIDIA_BRANCH_VERSION[Legacy]="${version}"
            fi
        else
            text="${label[${type}]}"
            NVIDIA_BRANCH_VERSION["${type}"]="${version}"
        fi
        # The same label twice on one version (a repeated block) is shown once.
        if [[ " · ${NVIDIA_VERSION_TAGS[${version}]:-} · " != *" · ${text} · "* ]]; then
            NVIDIA_VERSION_TAGS["${version}"]="${NVIDIA_VERSION_TAGS[${version}]:+${NVIDIA_VERSION_TAGS[${version}]} · }${text}"
        fi
        NVIDIA_BRANCH_INFO_OK=1
    done <<< "${queries}"

    if [[ ${NVIDIA_BRANCH_INFO_OK} -eq 0 ]]; then
        warn "Branch labels unavailable — see ${NVIDIA_UNIX_PAGE_URL}"
    fi
}

# Print the labels (with any GPU fit tags) one per line, newest version first.
# Args: version list, newest first.
report_nvidia_version_tags() {
    local tag_count=${#NVIDIA_VERSION_TAGS[@]} ver
    [[ ${tag_count} -gt 0 ]] || return 0
    ok "Identified ${tag_count} driver branch(es)"
    for ver in "$@"; do
        [[ -n "${NVIDIA_VERSION_TAGS[${ver}]:-}" ]] || continue
        info "  ${ver} → ${NVIDIA_VERSION_TAGS[${ver}]}"
    done
}

fetch_nvidia_versions() {
    local html=""

    info "Fetching NVIDIA driver versions from download.nvidia.com …"

    html="$(fetch_url "https://download.nvidia.com/XFree86/Linux-x86_64/" 2>/dev/null)" || {
        warn "Could not fetch NVIDIA driver list from download.nvidia.com"
        return 1
    }

    declare -ga NVIDIA_VERSIONS=()

    # Parse directory listing: extract version strings from href='VERSION/'
    local raw_versions=""
    raw_versions="$(echo "${html}" | grep -oP "href='([0-9][^']*)/'" \
        | sed "s/href='//;s|/'||" \
        | sort -u)" || true

    if [[ -z "${raw_versions}" ]]; then
        warn "Could not parse NVIDIA versions from download page"
        return 1
    fi

    # Filter to relevant versions (>= NVIDIA_MIN_MAJOR) and sort newest first
    local -a filtered=()
    while IFS= read -r ver; do
        [[ -z "${ver}" ]] && continue
        local major=""
        major="$(nvidia_major "${ver}")"
        [[ -z "${major}" ]] && continue
        if [[ "${major}" -ge "${NVIDIA_MIN_MAJOR}" ]] 2>/dev/null; then
            filtered+=("${ver}")
        fi
    done <<< "${raw_versions}"

    # Sort newest first
    local sorted_versions=""
    sorted_versions="$(printf '%s\n' "${filtered[@]}" | sort -rV)"
    local -a sorted_arr=()
    while IFS= read -r v; do
        [[ -n "${v}" ]] && sorted_arr+=("${v}")
    done <<< "${sorted_versions}"

    # Now that we have the sorted list, fetch branch tags and check them against
    # the detected GPUs. NVIDIA_VERSIONS is newest-first while that runs: the
    # fit check reads the newest version's supported-chip list.
    NVIDIA_VERSIONS=("${sorted_arr[@]}")
    fetch_nvidia_branch_info "${sorted_arr[@]}"
    apply_gpu_fit_tags
    report_nvidia_version_tags "${sorted_arr[@]}"

    # Place tagged versions at the top, then the rest
    local -a tagged_order=()
    local -A tagged_seen=()

    # Insert in priority order: the GPU-specific recommendation first (when the
    # card needs an older branch), then Production, New Feature, Legacy.
    for priority in "Recommended" "Production" "New Feature" "Legacy"; do
        for ver in "${sorted_arr[@]}"; do
            local tag="${NVIDIA_VERSION_TAGS[${ver}]:-}"
            if [[ -n "${tag}" ]] && [[ "${tag}" == *"${priority}"* ]] && [[ -z "${tagged_seen[${ver}]:-}" ]]; then
                tagged_order+=("${ver}")
                tagged_seen["${ver}"]=1
            fi
        done
    done

    # Build final list: tagged first, then all others
    NVIDIA_VERSIONS=("${tagged_order[@]}")
    for ver in "${sorted_arr[@]}"; do
        [[ -n "${tagged_seen[${ver}]:-}" ]] && continue
        NVIDIA_VERSIONS+=("${ver}")
    done

    if [[ ${#NVIDIA_VERSIONS[@]} -eq 0 ]]; then
        warn "No NVIDIA driver versions found"
        return 1
    fi

    ok "Found ${#NVIDIA_VERSIONS[@]} NVIDIA driver versions (≥ ${NVIDIA_MIN_MAJOR}.x)"
    return 0
}

# =============================================================================
# UI Wrappers (whiptail or bash select)
# =============================================================================

# ui_menu RESULT_VAR "title" "prompt" tag1 desc1 tag2 desc2 ...
#
# Shows a scrollable menu. Each item is a tag/description pair.
# The selected TAG is stored in RESULT_VAR.
# Special tag "MANUAL" triggers a text input prompt.
#
# In whiptail mode: native scrollable dialog.
# In bash mode:     paginated numbered list.
#
# UI_MENU_DEFAULT, when set to one of the tags, is where the menu starts:
# whiptail puts the cursor on it, the bash menu marks it "(default)" and takes
# it on an empty answer. It applies to one call only and is cleared afterwards.
UI_MENU_DEFAULT=""
ui_menu() {
    local -n _ui_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift
    # Remaining args: tag1 desc1 tag2 desc2 ...

    local rc=0
    if [[ "${UI_MODE}" == "whiptail" ]]; then
        _ui_menu_whiptail _ui_result "${title}" "${prompt}" "$@" || rc=$?
    else
        _ui_menu_bash _ui_result "${title}" "${prompt}" "$@" || rc=$?
    fi
    UI_MENU_DEFAULT=""
    return ${rc}
}

_ui_menu_whiptail() {
    local -n _wt_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift

    # Store all items for potential filtering
    local -a all_args=("$@")

    wt_size

    local -a default_item=()
    [[ -n "${UI_MENU_DEFAULT:-}" ]] && default_item=(--default-item "${UI_MENU_DEFAULT}")

    while true; do
        local choice=""
        choice=$(whiptail --title "${title}" "${default_item[@]}" --menu "${prompt}" \
            ${WT_HEIGHT} ${WT_WIDTH} ${WT_MENU_HEIGHT} \
            "${all_args[@]}" \
            "FILTER" "🔍 Filter / search versions" \
            "MANUAL" "✎ Enter version manually" \
            3>&1 1>&2 2>&3) || { _wt_result=""; return 1; }

        if [[ "${choice}" == "FILTER" ]]; then
            local filter=""
            filter=$(whiptail --title "Filter" --inputbox \
                "Type a version number, codename, or keyword to filter.\nLeave empty to reset." \
                10 ${WT_WIDTH} "" \
                3>&1 1>&2 2>&3) || continue

            if [[ -n "${filter}" ]]; then
                # Rebuild args with only matching items
                local -a filtered_args=()
                local idx=0
                while [[ ${idx} -lt ${#all_args[@]} ]]; do
                    local tag="${all_args[$idx]}"
                    local desc="${all_args[$((idx+1))]}"
                    if [[ "${tag}" == *"${filter}"* ]] || [[ "${desc,,}" == *"${filter,,}"* ]]; then
                        filtered_args+=("${tag}" "${desc}")
                    fi
                    (( idx += 2 ))
                done
                if [[ ${#filtered_args[@]} -gt 0 ]]; then
                    all_args=("${filtered_args[@]}")
                    prompt="Filtered (${#filtered_args[@]}/$(($# / 2)) matches for '${filter}'):"
                else
                    whiptail --title "No matches" --msgbox \
                        "No versions matched '${filter}'. Showing full list." \
                        8 ${WT_WIDTH} 3>&1 1>&2 2>&3
                    all_args=("$@")
                fi
            else
                # Reset filter
                all_args=("$@")
                prompt="$3"
            fi
            continue
        fi

        if [[ "${choice}" == "MANUAL" ]]; then
            choice=$(whiptail --title "${title}" --inputbox \
                "Enter version manually:" 8 ${WT_WIDTH} "" \
                3>&1 1>&2 2>&3) || { _wt_result=""; return 1; }
        fi

        _wt_result="${choice}"
        return 0
    done
}

_ui_menu_bash() {
    local -n _bash_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift

    # Build display items from tag/desc pairs
    local -a all_tags=() all_descs=() all_display=()
    while [[ $# -gt 0 ]]; do
        all_tags+=("$1")
        all_descs+=("${2:-}")
        local d="$1"
        [[ -n "${2:-}" ]] && d="${d}  ${2}"
        [[ -n "${UI_MENU_DEFAULT:-}" && "$1" == "${UI_MENU_DEFAULT}" ]] && d="${d}  (default)"
        all_display+=("${d}")
        shift 2 || shift
    done

    # Active filter state (working copies that can be filtered)
    local -a tags=("${all_tags[@]}")
    local -a display=("${all_display[@]}")
    local active_filter=""

    local page_size=20
    local page=0

    while true; do
        local total=${#display[@]}
        local max_page=$(( total > 0 ? (total - 1) / page_size : 0 ))
        [[ ${page} -gt ${max_page} ]] && page=0

        local start=$(( page * page_size ))
        local end=$(( start + page_size ))
        [[ ${end} -gt ${total} ]] && end=${total}

        # Build the page items
        local -a page_items=()
        local -a page_tags=()
        local i
        for (( i = start; i < end; i++ )); do
            page_items+=("${display[$i]}")
            page_tags+=("${tags[$i]}")
        done

        # Navigation and utility options
        if [[ ${page} -gt 0 ]]; then
            page_items+=("◀ Previous page")
            page_tags+=("__PREV__")
        fi
        if [[ ${page} -lt ${max_page} ]]; then
            page_items+=("▶ Next page  (showing $((start+1))–${end} of ${total})")
            page_tags+=("__NEXT__")
        fi
        page_items+=("🔍 Filter versions")
        page_tags+=("__FILTER__")
        page_items+=("✎ Enter manually")
        page_tags+=("__MANUAL__")

        if [[ -n "${active_filter}" ]]; then
            echo -e "${DIM}  Filter: '${active_filter}' — ${total} matches (showing $((start+1))–${end})${NC}"
        else
            echo -e "${DIM}  Page $((page+1)) of $((max_page+1)) — showing $((start+1))–${end} of ${total}${NC}"
        fi

        # A numbered list like `select`, but an empty answer takes the default.
        local ask="  #? "
        [[ -n "${UI_MENU_DEFAULT:-}" ]] && ask="  #? [Enter = ${UI_MENU_DEFAULT}] "
        for (( i = 0; i < ${#page_items[@]}; i++ )); do
            printf '%3d) %s\n' "$((i + 1))" "${page_items[$i]}" >&2
        done
        while true; do
            local reply=""
            printf '%s' "${ask}" >&2
            if ! read -r reply; then
                _bash_result=""
                return 1
            fi
            if [[ -z "${reply}" ]]; then
                [[ -n "${UI_MENU_DEFAULT:-}" ]] || continue
                _bash_result="${UI_MENU_DEFAULT}"
                return 0
            fi
            if ! [[ "${reply}" =~ ^[0-9]{1,4}$ ]] || (( 10#${reply} < 1 || 10#${reply} > ${#page_items[@]} )); then
                echo -e "  ${RED}Invalid selection. Try again.${NC}"
                continue
            fi

            local sel_tag="${page_tags[$((10#${reply} - 1))]}"

            case "${sel_tag}" in
                __PREV__)   page=$((page - 1)); break ;;
                __NEXT__)   page=$((page + 1)); break ;;
                __FILTER__)
                    echo ""
                    read -rp "  Filter (empty to reset): " filter_input
                    if [[ -n "${filter_input}" ]]; then
                        active_filter="${filter_input}"
                        tags=() display=()
                        for (( i = 0; i < ${#all_tags[@]}; i++ )); do
                            if [[ "${all_tags[$i],,}" == *"${filter_input,,}"* ]] \
                               || [[ "${all_display[$i],,}" == *"${filter_input,,}"* ]]; then
                                tags+=("${all_tags[$i]}")
                                display+=("${all_display[$i]}")
                            fi
                        done
                        if [[ ${#tags[@]} -eq 0 ]]; then
                            echo -e "  ${YELLOW}No matches for '${filter_input}'. Showing all.${NC}"
                            tags=("${all_tags[@]}")
                            display=("${all_display[@]}")
                            active_filter=""
                        else
                            echo -e "  ${GREEN}Found ${#tags[@]} matches.${NC}"
                        fi
                        page=0
                    else
                        tags=("${all_tags[@]}")
                        display=("${all_display[@]}")
                        active_filter=""
                        page=0
                    fi
                    break
                    ;;
                __MANUAL__)
                    echo ""
                    read -rp "  Enter version: " manual_input
                    if [[ -n "${manual_input}" ]]; then
                        _bash_result="${manual_input}"
                        return 0
                    else
                        echo -e "  ${RED}Empty input. Try again.${NC}"
                        continue
                    fi
                    ;;
                *)
                    _bash_result="${sel_tag}"
                    return 0
                    ;;
            esac
        done
    done
}

# ui_yesno "title" "prompt" [default_yes]
#
# Returns 0 for yes, 1 for no.
# default_yes: if "true", default is yes (whiptail: --defaultno is NOT set).
ui_yesno() {
    local title="$1"
    local prompt="$2"
    local default_yes="${3:-false}"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        local -a extra_args=()
        [[ "${default_yes}" != "true" ]] && extra_args+=(--defaultno)
        whiptail --title "${title}" --yesno "${prompt}" \
            $((WT_HEIGHT / 2)) ${WT_WIDTH} "${extra_args[@]}" \
            3>&1 1>&2 2>&3
        return $?
    else
        local -a options=()
        if [[ "${default_yes}" == "true" ]]; then
            options=("Yes" "No")
        else
            options=("No" "Yes")
        fi
        PS3="  #? "
        select choice in "${options[@]}"; do
            case "${choice}" in
                "Yes") return 0 ;;
                "No")  return 1 ;;
                *) echo -e "  ${RED}Invalid selection. Try again.${NC}" ;;
            esac
        done
    fi
}

# ui_inputbox RESULT_VAR "title" "prompt" [default_value]
#
# Shows a text input box. Result stored in RESULT_VAR.
ui_inputbox() {
    local -n _input_result=$1; shift
    local title="$1"
    local prompt="$2"
    local default="${3:-}"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        _input_result=$(whiptail --title "${title}" --inputbox \
            "${prompt}" $((WT_HEIGHT / 2)) ${WT_WIDTH} "${default}" \
            3>&1 1>&2 2>&3) || { _input_result=""; return 1; }
    else
        read -rp "  ${prompt} " _input_result
    fi
}

# ui_msgbox "title" "message"
#
# Shows an info message and waits for OK.
ui_msgbox() {
    local title="$1"
    local message="$2"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        whiptail --title "${title}" --msgbox "${message}" \
            ${WT_HEIGHT} ${WT_WIDTH} 3>&1 1>&2 2>&3
    else
        echo ""
        echo -e "${message}"
        echo ""
    fi
}

# =============================================================================
# .env File Generator
# =============================================================================

generate_env_file() {
    local nvidia_version="$1"
    local truenas_version="$2"
    local train="$3"
    local module_type="$4"
    local embed_update="$5"
    local build_cc="$6"
    local output_file="$7"
    local patch_mode="${8:-auto}"
    # Cards for the build to check the driver against; an opt-out already in
    # .env (read by --reconfigure) is kept, anything else turns the check on.
    # Only this machine's own cards are known here, so they are the target only
    # when the wizard runs on the TrueNAS host itself (detect_truenas_version
    # found a version). Anywhere else the list stays empty and the deploy step
    # checks the real host's GPUs.
    local target_gpus="" skip_gpu_check="false"
    if [[ -n "${DETECTED_TRUENAS_VERSION:-}" ]]; then
        target_gpus="$(nvidia_target_gpus)"
    else
        info "Not running on TrueNAS — the GPUs will be checked by deploy-nvidia.sh on the target"
    fi
    [[ "${EXISTING_SKIP_GPU_CHECK:-}" == "true" ]] && skip_gpu_check="true"

    cat > "${output_file}" <<EOF
# Generated by configure.sh — $(date '+%Y-%m-%d %H:%M:%S')
# Re-run ./configure.sh to reconfigure, or edit this file directly.
# Docker Compose reads this file automatically.

# ── Required ─────────────────────────────────────────────────────────────────
NVIDIA_VERSION=${nvidia_version}
TRUENAS_VERSION=${truenas_version}

# ── Optional ─────────────────────────────────────────────────────────────────
# open         -> Open GPU kernel modules (recommended for Turing/Ampere/Ada+)
# proprietary  -> Legacy closed-source kernel modules
NVIDIA_KERNEL_MODULE_TYPE=${module_type}

# GPUs the build checks the driver against (devid:subvendor:subdevice, comma
# separated; cards reserved for a VM are left out). Filled in by configure.sh
# when it runs on the TrueNAS host; empty elsewhere (deploy-nvidia.sh then
# checks the host's GPUs). Set SKIP_GPU_CHECK=true to build a driver that does
# not list these cards.
NVIDIA_TARGET_GPUS=${target_gpus}
SKIP_GPU_CHECK=${skip_gpu_check}

# Folder of this release on download.truenas.com / update.truenas.com
# (e.g. TrueNAS-SCALE-Goldeye). Leave empty to let the build find it.
TRUENAS_TRAIN=${train}

# Compiler override for the NVIDIA kernel module build (e.g. gcc-14).
# Leave empty to auto-detect.
NVIDIA_BUILD_CC=${build_cc}

# When true, also produces a rebuilt truenas.update with nvidia.raw embedded.
EMBED_NVIDIA_RAW_IN_UPDATE=${embed_update}

# Source-patch mode for building EOL drivers on newer kernels:
#   none        -> never patch
#   custom      -> your own patches in patches/<kernel>/ (or flat patches/)
#   predefined  -> curated set in predefined-patches/<driver>/ (see configure.sh)
#   auto        -> apply patches/<kernel>/ if present (default; backward compatible)
NVIDIA_PATCH_MODE=${patch_mode}

# ── Installer overrides (optional) ────────────────────────────────────────────
# Leave both empty to download the official installer for NVIDIA_VERSION.
#   NVIDIA_RUN_URL  -> fetch the installer from this URL instead
#   NVIDIA_RUN_FILE -> use this .run as-is (path INSIDE the container)
NVIDIA_RUN_URL=${CLI_RUN_URL}
NVIDIA_RUN_FILE=${CLI_RUN_FILE}
EOF
}

# =============================================================================
# System Auto-Detection
# =============================================================================

# Detect TrueNAS version if running on a TrueNAS system
detect_truenas_version() {
    declare -g DETECTED_TRUENAS_VERSION=""

    # Method 1: /etc/version (present on TrueNAS SCALE)
    if [[ -f /etc/version ]]; then
        DETECTED_TRUENAS_VERSION="$(cat /etc/version 2>/dev/null | tr -d '[:space:]')" || true
    fi

    # Method 2: midclt (TrueNAS middleware CLI)
    if [[ -z "${DETECTED_TRUENAS_VERSION}" ]] && command -v midclt &>/dev/null; then
        DETECTED_TRUENAS_VERSION="$(midclt call system.version 2>/dev/null | tr -d '"[:space:]')" || true
    fi

    # Middleware can answer with a product prefix, e.g. TrueNAS-SCALE-25.10.8.
    DETECTED_TRUENAS_VERSION="${DETECTED_TRUENAS_VERSION#"${DETECTED_TRUENAS_VERSION%%[0-9]*}"}"

    if [[ -n "${DETECTED_TRUENAS_VERSION}" ]]; then
        ok "Detected TrueNAS version: ${DETECTED_TRUENAS_VERSION}"
    fi
}

# ── GPU identification by PCI ID ─────────────────────────────────────────────
declare -ga GPU_SLOT=() GPU_DEVID=() GPU_SUBSYS=() GPU_LSPCI_NAME=() GPU_RESERVED=() GPU_NAME=()
declare -gA NVIDIA_CHIPS_CACHE=()

# Read `lspci -Dnnk -d 10de:` text on stdin; fill the GPU_* arrays (one index
# per display controller: classes 0300/0302/0380). GPU_RESERVED=1 when the card
# is bound to vfio-pci (handed to a VM). GPU_LSPCI_NAME is empty when lspci only
# knows the card as "Device xxxx". GPU_NAME is filled later, by
# apply_gpu_fit_tags.
parse_nvidia_gpus() {
    GPU_SLOT=(); GPU_DEVID=(); GPU_SUBSYS=(); GPU_LSPCI_NAME=(); GPU_RESERVED=(); GPU_NAME=()
    local hdr='^([0-9a-fA-F:.]+) .*\[(0300|0302|0380)\]: (.*) \[10de:([0-9a-fA-F]{4})\]'
    local line cur=-1 prefix devid
    while IFS= read -r line; do
        if [[ "${line}" =~ ${hdr} ]]; then
            prefix="${BASH_REMATCH[3]}"
            devid="${BASH_REMATCH[4],,}"
            cur=${#GPU_DEVID[@]}
            GPU_SLOT[cur]="${BASH_REMATCH[1]}"
            GPU_DEVID[cur]="${devid}"
            GPU_SUBSYS[cur]=""
            GPU_RESERVED[cur]=0
            if [[ "${prefix}" =~ \[([^][]*)\]$ ]]; then
                GPU_LSPCI_NAME[cur]="${BASH_REMATCH[1]}"
            else
                GPU_LSPCI_NAME[cur]=""
            fi
        elif [[ "${line}" =~ ^[[:space:]] ]]; then
            [[ ${cur} -ge 0 ]] || continue
            if [[ "${line}" =~ Subsystem:.*\[([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\]$ ]]; then
                GPU_SUBSYS[cur]="${BASH_REMATCH[1],,}"
            elif [[ "${line}" =~ Kernel\ driver\ in\ use:\ vfio-pci ]]; then
                GPU_RESERVED[cur]=1
            fi
        else
            cur=-1   # another device (e.g. the GPU's audio function)
        fi
    done
    return 0
}

# Print `DEVID|SECTION|NAME` for every row of NVIDIA's supported-chips README for
# VERSION. SECTION is `current` or the legacy branch (580, 173.14, ...). Rows
# list "<name> | <devid> [subvendor subdevice]"; only the device ID is kept.
# Returns 1 when the README cannot be fetched or has no rows.
nvidia_supported_chips() {
    local ver="$1" html rows
    if [[ -n "${NVIDIA_CHIPS_CACHE[${ver}]+x}" ]]; then
        printf '%s\n' "${NVIDIA_CHIPS_CACHE[${ver}]}"
        return 0
    fi
    html="$(fetch_url "https://download.nvidia.com/XFree86/Linux-x86_64/${ver}/README/supportedchips.html")" || return 1
    rows="$(awk '
        BEGIN { RS = "<tr"; sec = "current" }
        NR > 1 {
            end = index($0, "</tr>")
            body = end ? substr($0, 1, end - 1) : $0
            rest = end ? substr($0, end) : ""
            n = split(body, t, "<td")
            if (n >= 3) {
                name = t[2]; id = t[3]
                sub(/^[^>]*>/, "", name); gsub(/<[^>]*>/, "", name)
                sub(/^[^>]*>/, "", id);   gsub(/<[^>]*>/, "", id)
                gsub(/&nbsp;/, " ", name); gsub(/&amp;/, "\\&", name)
                gsub(/&[A-Za-z0-9#]+;/, "", name)
                gsub(/[ \t\r\n]+/, " ", name); sub(/^ /, "", name); sub(/ $/, "", name)
                gsub(/^[ \t\r\n]+/, "", id); split(id, p, /[ \t\r\n]+/)
                if (p[1] ~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/)
                    print toupper(p[1]) "|" sec "|" name
            }
            if (match(rest, /name="legacy_[^"]*"/)) {
                s = substr(rest, RSTART + 13, RLENGTH - 14)
                sub(/\.xx$/, "", s)
                sec = s
            }
        }' <<< "${html}")"
    [[ -n "${rows}" ]] || return 1
    NVIDIA_CHIPS_CACHE[${ver}]="${rows}"
    printf '%s\n' "${rows}"
}

# Does driver VERSION support GPU index IDX? Prints `current`, the legacy branch
# that carries the card (e.g. 580), or `unlisted`. Returns 1 when the README is
# unavailable — never guess.
gpu_support() {
    local ver="$1" idx="$2" id rows hit
    id="${GPU_DEVID[idx]^^}"
    nvidia_supported_chips "${ver}" >/dev/null || return 1
    rows="${NVIDIA_CHIPS_CACHE[${ver}]}"
    hit="$(awk -F'|' -v id="${id}" '
        $1 == id { if ($2 == "current") { print "current"; exit } if (first == "") first = $2 }
        END { if (first != "") print first }' <<< "${rows}" | head -n1)"
    printf '%s\n' "${hit:-unlisted}"
}

# Display name for GPU index IDX: what lspci knows, else the newest README's
# name for that device ID, else a generic one.
gpu_name() {
    local idx="$1" name="" rows
    if [[ -n "${GPU_LSPCI_NAME[idx]}" ]]; then
        printf '%s\n' "${GPU_LSPCI_NAME[idx]}"
        return 0
    fi
    if [[ -n "${NVIDIA_VERSIONS[0]:-}" ]] && nvidia_supported_chips "${NVIDIA_VERSIONS[0]}" >/dev/null; then
        rows="${NVIDIA_CHIPS_CACHE[${NVIDIA_VERSIONS[0]}]}"
        name="$(awk -F'|' -v id="${GPU_DEVID[idx]^^}" '$1 == id { print $3; exit }' <<< "${rows}")"
    fi
    printf '%s\n' "${name:-NVIDIA device 10de:${GPU_DEVID[idx]}}"
}

# Name to show for GPU index IDX: the one apply_gpu_fit_tags settled on (read
# from the newest README while the version list was still newest-first), else
# gpu_name.
gpu_display_name() {
    if [[ -n "${GPU_NAME[$1]:-}" ]]; then
        printf '%s\n' "${GPU_NAME[$1]}"
    else
        gpu_name "$1"
    fi
}

# Detect every NVIDIA GPU via lspci (fills the GPU_* arrays) and list them.
# Cards bound to vfio-pci are handed to a VM: listed, never checked.
# DETECTED_GPU_MODEL is the first active card, for the driver prompt.
detect_nvidia_gpu() {
    declare -g DETECTED_GPU_MODEL=""
    GPU_SLOT=(); GPU_DEVID=(); GPU_SUBSYS=(); GPU_LSPCI_NAME=(); GPU_RESERVED=(); GPU_NAME=()

    if ! command -v lspci &>/dev/null; then
        return 0
    fi

    # Every NVIDIA display controller, identified by PCI ID.
    local lspci_out
    lspci_out="$(lspci -Dnnk -d 10de: 2>/dev/null || true)"
    parse_nvidia_gpus <<< "${lspci_out}"

    local i name
    for i in "${!GPU_DEVID[@]}"; do
        name="$(gpu_name "${i}")"
        [[ "${name}" == *"10de:${GPU_DEVID[i]}"* ]] || name="${name} (10de:${GPU_DEVID[i]})"
        if [[ "${GPU_RESERVED[i]}" == "1" ]]; then
            ok "Detected GPU: ${name} — reserved for a VM (vfio-pci) — not checked"
        else
            ok "Detected GPU: ${name}"
            [[ -n "${DETECTED_GPU_MODEL}" ]] || DETECTED_GPU_MODEL="$(gpu_name "${i}")"
        fi
    done
    return 0
}

# Active (non-vfio-pci) cards as devid:subvendor:subdevice, comma separated,
# lowercase; "2c02::" when lspci gave no subsystem. Empty when there are none.
nvidia_target_gpus() {
    local i out=""
    for i in "${!GPU_DEVID[@]}"; do
        [[ "${GPU_RESERVED[i]:-0}" == "1" ]] && continue
        out+="${out:+,}${GPU_DEVID[i]}:${GPU_SUBSYS[i]:-:}"
    done
    printf '%s\n' "${out}"
}

# ── GPU ↔ driver version fit ─────────────────────────────────────────────────
# A driver can build, package and merge perfectly and still not drive the card:
# nvidia-smi just reports "No devices were found" after a 15-minute build.
# NVIDIA's supported-chip list for each version says which cards it drives and,
# for a card it dropped, which legacy branch still does — so the wizard checks
# the fit up front, from that list only. Reserved (vfio-pci) cards are skipped.
declare -g GPU_RECOMMENDED_VERSION="" GPU_FIT_CONFLICT=0
declare -ga GPU_UNBUILDABLE=() GPU_UNLISTED=()

# Run right after fetch_nvidia_branch_info, with NVIDIA_VERSIONS newest-first.
# Sets: GPU_NAME[idx] for every card, GPU_RECOMMENDED_VERSION (newest version
#       in the oldest legacy branch an active card needs), GPU_UNBUILDABLE
#       ("name|branch" for cards whose branch is below NVIDIA_MIN_MAJOR),
#       GPU_UNLISTED ("name|newest version" for cards the newest README does
#       not list at all), GPU_FIT_CONFLICT=1 when the recommended version
#       leaves a card out.
# Tags: "★ Recommended for your <name>" on the recommendation; every labelled
#       version gets " — does NOT support <name>" per active card it does not
#       drive. A version whose list can't be read gets no fit tag (never guess).
apply_gpu_fit_tags() {
    declare -g GPU_RECOMMENDED_VERSION="" GPU_FIT_CONFLICT=0
    declare -ga GPU_UNBUILDABLE=() GPU_UNLISTED=()
    declare -gA NVIDIA_VERSION_TAGS
    GPU_NAME=()

    local newest="${NVIDIA_VERSIONS[0]:-}" i
    local -a active=()
    for i in "${!GPU_DEVID[@]}"; do
        [[ "${GPU_RESERVED[i]:-0}" == "1" ]] || active+=("${i}")
    done
    [[ -n "${newest}" && ${#GPU_DEVID[@]} -gt 0 ]] || return 0

    # Warm the cache here, not inside $(…), so every later lookup reuses it.
    if ! nvidia_supported_chips "${newest}" >/dev/null; then
        for i in "${!GPU_DEVID[@]}"; do
            GPU_NAME[i]="${GPU_LSPCI_NAME[i]:-NVIDIA device 10de:${GPU_DEVID[i]}}"
        done
        [[ ${#active[@]} -eq 0 ]] || info "Could not check GPU support — NVIDIA's supported-chip list is unreachable"
        return 0
    fi
    for i in "${!GPU_DEVID[@]}"; do
        GPU_NAME[i]="$(gpu_name "${i}")"
    done
    [[ ${#active[@]} -gt 0 ]] || return 0
    DETECTED_GPU_MODEL="${GPU_NAME[${active[0]}]}"

    # Which section of the newest list each active card sits in.
    local -A section=()
    local major best=""
    for i in "${active[@]}"; do
        section[${i}]="$(gpu_support "${newest}" "${i}")"
        [[ "${section[${i}]}" != "unlisted" ]] || GPU_UNLISTED+=("${GPU_NAME[i]}|${newest}")
        case "${section[${i}]}" in current|unlisted) continue ;; esac
        major="${section[${i}]%%.*}"
        [[ "${major}" =~ ^[0-9]+$ ]] || continue
        if (( major < NVIDIA_MIN_MAJOR )); then
            GPU_UNBUILDABLE+=("${GPU_NAME[i]}|${section[${i}]}")
        elif [[ -z "${best}" ]] || (( major < best )); then
            best="${major}"
        fi
    done

    if [[ -n "${best}" ]]; then
        GPU_RECOMMENDED_VERSION="$(nvidia_latest_in_series "${best}" "${NVIDIA_VERSIONS[@]}")" \
            || GPU_RECOMMENDED_VERSION=""
    fi
    if [[ -n "${GPU_RECOMMENDED_VERSION}" ]]; then
        local names="" existing=""
        for i in "${active[@]}"; do
            [[ "${section[${i}]%%.*}" == "${best}" ]] || continue
            [[ " and ${names} and " == *" and ${GPU_NAME[i]} and "* ]] && continue
            names="${names:+${names} and }${GPU_NAME[i]}"
        done
        existing="${NVIDIA_VERSION_TAGS[${GPU_RECOMMENDED_VERSION}]:-}"
        NVIDIA_VERSION_TAGS["${GPU_RECOMMENDED_VERSION}"]="★ Recommended for your ${names}${existing:+ · ${existing}}"
    fi

    local ver support
    for ver in "${NVIDIA_VERSIONS[@]}"; do
        [[ -n "${NVIDIA_VERSION_TAGS[${ver}]:-}" ]] || continue
        nvidia_supported_chips "${ver}" >/dev/null || continue
        for i in "${active[@]}"; do
            support="$(gpu_support "${ver}" "${i}")" || continue
            [[ "${support}" == "current" ]] && continue
            NVIDIA_VERSION_TAGS["${ver}"]+=" — does NOT support ${GPU_NAME[i]}"
            [[ "${ver}" != "${GPU_RECOMMENDED_VERSION}" ]] || GPU_FIT_CONFLICT=1
        done
    done
    return 0
}

# Warn when driver VERSION does not drive an active card. Advisory only — the
# user may be building for a different machine.
advise_gpu_branch_fit() {
    local version="$1" i support name branch
    [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 0
    local -a active=()
    for i in "${!GPU_DEVID[@]}"; do
        [[ "${GPU_RESERVED[i]:-0}" == "1" ]] || active+=("${i}")
    done
    [[ ${#active[@]} -gt 0 ]] || return 0

    if ! nvidia_supported_chips "${version}" >/dev/null; then
        info "Could not check GPU support for NVIDIA ${version}"
        return 0
    fi
    for i in "${active[@]}"; do
        support="$(gpu_support "${version}" "${i}")" || continue
        [[ "${support}" == "current" ]] && continue
        name="$(gpu_display_name "${i}")"
        if [[ "${support}" == "unlisted" ]]; then
            warn "${name} is newer than NVIDIA ${version} — it is not in that driver's supported list."
            continue
        fi
        warn "${name} is not supported by NVIDIA ${version}; NVIDIA lists it for the ${support}.xx legacy driver."
        branch="${support%%.*}"
        if [[ "${branch}" =~ ^[0-9]+$ ]] && (( branch < NVIDIA_MIN_MAJOR )); then
            warn "This tool can't build a driver for that card."
        fi
    done
    return 0
}

# Where the driver menu starts: the GPU-fit recommendation, else Production,
# else the first listed version that is not the Beta.
driver_menu_default() {
    local v
    if [[ -n "${GPU_RECOMMENDED_VERSION:-}" ]]; then
        printf '%s\n' "${GPU_RECOMMENDED_VERSION}"
        return 0
    fi
    if [[ -n "${NVIDIA_BRANCH_VERSION[PB]:-}" ]]; then
        printf '%s\n' "${NVIDIA_BRANCH_VERSION[PB]}"
        return 0
    fi
    for v in "${NVIDIA_VERSIONS[@]}"; do
        [[ "${v}" == "${NVIDIA_BRANCH_VERSION[BETA]:-}" ]] && continue
        printf '%s\n' "${v}"
        return 0
    done
    return 0
}

# Step 2 hint: the detected cards and what the fit check found.
show_gpu_fit_hint() {
    [[ ${#GPU_DEVID[@]} -gt 0 ]] || return 0
    local i entry
    for i in "${!GPU_DEVID[@]}"; do
        if [[ "${GPU_RESERVED[i]}" == "1" ]]; then
            echo -e "  ${GREEN}Detected GPU:${NC} $(gpu_display_name "${i}") ${DIM}— reserved for a VM — not checked${NC}"
        else
            echo -e "  ${GREEN}Detected GPU:${NC} $(gpu_display_name "${i}")"
        fi
    done
    if [[ ${GPU_FIT_CONFLICT:-0} -eq 1 ]]; then
        echo -e "  ${YELLOW}No single driver drives all of these GPUs: ${GPU_RECOMMENDED_VERSION} (★ Recommended) leaves one out — see the menu.${NC}"
    fi
    for entry in "${GPU_UNBUILDABLE[@]}"; do
        echo -e "  ${YELLOW}${entry%|*} needs the ${entry##*|}.xx legacy driver — this tool can't build a driver for that card.${NC}"
    done
    # With a recommendation, the conflict line above already covers these.
    if [[ -z "${GPU_RECOMMENDED_VERSION:-}" ]]; then
        for entry in "${GPU_UNLISTED[@]}"; do
            echo -e "  ${YELLOW}No listed driver version drives your ${entry%|*} — it is not in the supported list of NVIDIA ${entry##*|}, the newest one.${NC}"
        done
    fi
    if [[ -n "${GPU_RECOMMENDED_VERSION:-}" && ${GPU_FIT_CONFLICT:-0} -eq 0 ]]; then
        echo -e "  ${YELLOW}Newer branches dropped your GPU — pick ${GPU_RECOMMENDED_VERSION} (★ Recommended).${NC}"
    elif [[ -z "${GPU_RECOMMENDED_VERSION:-}" && ${#GPU_UNBUILDABLE[@]} -eq 0 && ${#GPU_UNLISTED[@]} -eq 0 ]]; then
        echo -e "  ${DIM}Tip: ★ Production Branch is recommended for most users.${NC}"
    fi
    echo ""
}

# Read existing .env file values for reconfigure mode
read_existing_config() {
    local env_file="$1"

    declare -g EXISTING_TRUENAS="" EXISTING_NVIDIA="" EXISTING_MODULE="" EXISTING_EMBED="" EXISTING_TRAIN="" EXISTING_PATCH_MODE=""
    declare -g EXISTING_RUN_URL="" EXISTING_RUN_FILE="" EXISTING_SKIP_GPU_CHECK=""

    [[ -f "${env_file}" ]] || return 1

    local legacy_codename=""
    # Source the .env file safely (only read KEY=VALUE lines, skip comments)
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "${key}" ]] && continue
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace
        key="$(echo "${key}" | tr -d '[:space:]')"
        value="$(echo "${value}" | tr -d '[:space:]')"
        case "${key}" in
            NVIDIA_VERSION)             EXISTING_NVIDIA="${value}" ;;
            TRUENAS_VERSION)            EXISTING_TRUENAS="${value}" ;;
            NVIDIA_KERNEL_MODULE_TYPE)  EXISTING_MODULE="${value}" ;;
            EMBED_NVIDIA_RAW_IN_UPDATE) EXISTING_EMBED="${value}" ;;
            TRUENAS_TRAIN)              EXISTING_TRAIN="${value}" ;;
            TRUENAS_CODENAME)           legacy_codename="${value}" ;;
            NVIDIA_PATCH_MODE)          EXISTING_PATCH_MODE="${value}" ;;
            NVIDIA_RUN_URL)             EXISTING_RUN_URL="${value}" ;;
            NVIDIA_RUN_FILE)            EXISTING_RUN_FILE="${value}" ;;
            SKIP_GPU_CHECK)             EXISTING_SKIP_GPU_CHECK="${value}" ;;
        esac
    done < "${env_file}"

    # Older files name the codename instead (spaces were already dropped
    # above): TRUENAS_CODENAME=Goldeye is the train TrueNAS-SCALE-Goldeye.
    if [[ -z "${EXISTING_TRAIN}" ]] && [[ -n "${legacy_codename}" ]]; then
        EXISTING_TRAIN="TrueNAS-SCALE-${legacy_codename}"
    fi
    if [[ -n "${EXISTING_TRAIN}" ]] && ! valid_train "${EXISTING_TRAIN}"; then
        warn "Ignoring the release folder in .env (${EXISTING_TRAIN}): not a folder name; the build will look it up."
        EXISTING_TRAIN=""
    fi

    return 0
}

# =============================================================================
# Hand off to the deployer
# =============================================================================

# True when this machine is the TrueNAS box the image is for. The build can just
# as easily run on a separate Docker host, in which case the image has to be
# copied to the NAS and offering to deploy here would be wrong.
running_on_truenas() {
    [[ -d /usr/share/truenas/sysext-extensions ]] || command -v midclt &>/dev/null
}

# After a successful build, offer to install what was just built. Declining is
# free — the command is printed either way.
offer_deployment() {
    local truenas_version="$1"
    local repo_dir=""
    repo_dir="$(config_repo_dir)"

    local image="${repo_dir}/output/${truenas_version}/nvidia.raw"
    local deployer="${repo_dir}/deploy-nvidia.sh"

    [[ -f "${image}" ]]    || return 0
    [[ -x "${deployer}" ]] || [[ -f "${deployer}" ]] || return 0

    if ! running_on_truenas; then
        echo ""
        info "Image ready: ${image}"
        info "This host isn't the TrueNAS system — copy it there together with"
        info "deploy-nvidia.sh, then run:  ./deploy-nvidia.sh nvidia.raw"
        echo ""
        return 0
    fi

    # Wording stays neutral: this is also reached when the build was skipped and
    # an image from an earlier run is already sitting in output/.
    if ! ui_yesno "Deploy Now?" \
        "Install this image as the system NVIDIA driver?\n\n  ${image}\n\nThe current driver is backed up first and restored automatically if anything fails."
    then
        echo ""
        info "Not deploying. When you're ready:"
        echo -e "    ${CYAN}./deploy-nvidia.sh output/${truenas_version}/nvidia.raw${NC}"
        echo -e "  or ${CYAN}./deploy-nvidia.sh${NC} for the deployment menu."
        echo ""
        return 0
    fi

    if [[ $(id -u) -ne 0 ]]; then
        echo ""
        warn "Deploying needs root. Run:"
        echo -e "    ${CYAN}sudo ./deploy-nvidia.sh output/${truenas_version}/nvidia.raw${NC}"
        echo ""
        return 0
    fi

    echo ""
    info "Handing over to deploy-nvidia.sh …"
    echo ""
    # exec: the deployer owns the terminal from here, keeps its own traps, and
    # its exit status becomes ours.
    exec bash "${deployer}" "${image}"
}

# =============================================================================
# Main Wizard
# =============================================================================

main() {
    banner "TrueNAS NVIDIA Driver Updater — Configuration Wizard"

    detect_ui_mode
    detect_fetch_cmd
    info "Using ${FETCH_CMD} to fetch version lists"

    # ── System auto-detection ────────────────────────────────────────────────
    detect_truenas_version
    detect_nvidia_gpu
    echo ""

    # ── Paths ────────────────────────────────────────────────────────────────
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local env_file="${script_dir}/.env"

    # ── Installer overrides ──────────────────────────────────────────────────
    if [[ -n "${CLI_RUN_URL}" ]] && [[ -n "${CLI_RUN_FILE}" ]]; then
        err "Use either --run-url or --custom-run, not both."
        exit 1
    fi
    if [[ -n "${CLI_RUN_FILE}" ]]; then
        CLI_RUN_FILE="$(host_path_to_container "${CLI_RUN_FILE}")" || exit 1
        warn "Custom installer: ${CLI_RUN_FILE} (inside the container)"
        warn "NVIDIA_VERSION is only a label in this mode — set it to the version"
        warn "this .run actually contains, or the compatibility checks will be wrong."
    fi
    if [[ -n "${CLI_RUN_URL}" ]]; then
        warn "Custom installer URL: ${CLI_RUN_URL}"
        warn "NVIDIA_VERSION is only a label in this mode — set it to the version"
        warn "that URL actually serves, or the compatibility checks will be wrong."
    fi

    # ── Non-interactive mode ─────────────────────────────────────────────────
    if [[ -n "${CLI_TRUENAS}" ]] && [[ -n "${CLI_NVIDIA}" ]]; then
        info "Running in non-interactive mode"

        require_supported_truenas "${CLI_TRUENAS}"
        if [[ -n "${CLI_TRAIN}" ]] && ! valid_train "${CLI_TRAIN}"; then
            err "Invalid --train '${CLI_TRAIN}' (expected a release folder such as TrueNAS-SCALE-Goldeye)"
            exit 1
        fi

        local selected_truenas="${CLI_TRUENAS}"
        local selected_nvidia="${CLI_NVIDIA}"
        local selected_module_type="${CLI_MODULE:-open}"
        local selected_embed="${CLI_EMBED:-false}"
        local selected_patch_mode="${CLI_PATCH:-auto}"
        local selected_cc=""

        # Validate enumerated flags up front so bad input fails loudly here
        # rather than deep inside the container build.
        case "${selected_module_type}" in
            open|proprietary) ;;
            *) err "Invalid --module '${selected_module_type}' (expected: open or proprietary)"; exit 1 ;;
        esac
        case "${selected_embed}" in
            true|false) ;;
            *) err "Invalid --embed '${selected_embed}' (expected: true or false)"; exit 1 ;;
        esac
        case "${selected_patch_mode}" in
            none|custom|predefined|auto) ;;
            *) err "Invalid --patch '${selected_patch_mode}' (expected: none, custom, predefined, or auto)"; exit 1 ;;
        esac
        # In non-interactive mode, fetch the predefined set now if requested.
        if [[ "${selected_patch_mode}" == "predefined" ]]; then
            fetch_predefined_patches "$(nvidia_major "${selected_nvidia}")" \
                || { err "Could not fetch predefined patches; aborting."; exit 1; }
        fi

        # Pre-515 drivers only ship proprietary modules; don't write a config
        # the build will just have to override.
        if ! nvidia_supports_module_type "${selected_nvidia}"; then
            if [[ "${selected_module_type}" != "proprietary" ]]; then
                warn "NVIDIA ${selected_nvidia} can't select the module flavor (--kernel-module-type needs ~555+); forcing --module proprietary"
            fi
            selected_module_type="proprietary"
        fi

        # The train: --train, else the download.truenas.com list or this
        # host's manifest. Nothing is asked here; left empty, the build finds it.
        local selected_train="${CLI_TRAIN}"
        if [[ -z "${selected_train}" ]]; then
            fetch_truenas_versions || true
            selected_train="$(resolve_selected_train "${selected_truenas}")"
            [[ -n "${selected_train}" ]] \
                || info "Release folder of TrueNAS ${selected_truenas} not found here — the build will look it up."
        fi

        ok "TrueNAS: ${selected_truenas}${selected_train:+ ($(truenas_train_display "${selected_train}"))}"
        announce_truenas_kernel "${selected_truenas}"
        ok "NVIDIA:  ${selected_nvidia}"
        ok "Module:  ${selected_module_type}"
        ok "Embed:   ${selected_embed}"

        ok "Patch:   ${selected_patch_mode}"

        advise_legacy_driver "${selected_nvidia}" "${selected_truenas}"

        # Same labels and fit advice as the wizard. A failed fetch only costs
        # the labels (and the fit lines then say they could not check).
        fetch_nvidia_versions || true
        advise_gpu_branch_fit "${selected_nvidia}"
        advise_patches "${selected_truenas}"

        generate_env_file \
            "${selected_nvidia}" \
            "${selected_truenas}" \
            "${selected_train}" \
            "${selected_module_type}" \
            "${selected_embed}" \
            "${selected_cc}" \
            "${env_file}" \
            "${selected_patch_mode}"

        ok ".env generated!"
        return 0
    fi

    # ── Reconfigure mode ─────────────────────────────────────────────────────
    if [[ "${CLI_RECONFIGURE}" == true ]]; then
        if ! read_existing_config "${env_file}"; then
            err "No .env found. Run without --reconfigure first."
            exit 1
        fi

        # --reconfigure changes one setting; it must not silently drop an
        # installer override the user set earlier. CLI flags still win.
        [[ -z "${CLI_RUN_URL}" ]]  && CLI_RUN_URL="${EXISTING_RUN_URL}"
        [[ -z "${CLI_RUN_FILE}" ]] && CLI_RUN_FILE="${EXISTING_RUN_FILE}"
        if [[ -n "${CLI_RUN_URL}${CLI_RUN_FILE}" ]]; then
            info "Keeping installer override: ${CLI_RUN_URL:-${CLI_RUN_FILE}}"
        fi

        echo -e "  ${YELLOW}Current configuration:${NC}"
        echo -e "    1) TrueNAS Version   : ${BOLD}${EXISTING_TRUENAS}${NC}"
        echo -e "    2) NVIDIA Driver     : ${BOLD}${EXISTING_NVIDIA}${NC}"
        echo -e "    3) Module Type       : ${BOLD}${EXISTING_MODULE}${NC}"
        echo -e "    4) Embed in .update  : ${BOLD}${EXISTING_EMBED}${NC}"
        echo ""

        local reconfigure_what=""
        if [[ "${UI_MODE}" == "whiptail" ]]; then
            wt_size
            reconfigure_what=$(whiptail --title "Reconfigure" \
                --menu "Which setting would you like to change?" \
                ${WT_HEIGHT} ${WT_WIDTH} 4 \
                "truenas" "TrueNAS Version (currently: ${EXISTING_TRUENAS})" \
                "nvidia" "NVIDIA Driver (currently: ${EXISTING_NVIDIA})" \
                "module" "Module Type (currently: ${EXISTING_MODULE})" \
                "embed" "Embed in .update (currently: ${EXISTING_EMBED})" \
                3>&1 1>&2 2>&3) || { info "Cancelled."; exit 0; }
        else
            local -a reconf_options=(
                "TrueNAS Version (${EXISTING_TRUENAS})"
                "NVIDIA Driver (${EXISTING_NVIDIA})"
                "Module Type (${EXISTING_MODULE})"
                "Embed in .update (${EXISTING_EMBED})"
            )
            PS3="  Change which? "
            select choice in "${reconf_options[@]}"; do
                case "${REPLY}" in
                    1) reconfigure_what="truenas"; break ;;
                    2) reconfigure_what="nvidia"; break ;;
                    3) reconfigure_what="module"; break ;;
                    4) reconfigure_what="embed"; break ;;
                    *) echo -e "  ${RED}Invalid selection.${NC}" ;;
                esac
            done
        fi

        local selected_truenas="${EXISTING_TRUENAS}"
        local selected_train="${EXISTING_TRAIN}"
        local selected_nvidia="${EXISTING_NVIDIA}"
        local selected_module_type="${EXISTING_MODULE}"
        local selected_embed="${EXISTING_EMBED}"
        local selected_patch_mode="${EXISTING_PATCH_MODE:-auto}"
        local selected_cc=""

        case "${reconfigure_what}" in
            truenas)
                if fetch_truenas_versions; then
                    local -a truenas_menu_args=()
                    for ver in "${TRUENAS_VERSIONS[@]}"; do
                        truenas_menu_args+=("${ver}" "$(truenas_menu_desc "${ver}")")
                    done
                    UI_MENU_DEFAULT="$(truenas_menu_default)"
                    ui_menu selected_truenas "TrueNAS Version" \
                        "Select new TrueNAS version:" "${truenas_menu_args[@]}"
                    if [[ "${selected_truenas}" != "${EXISTING_TRUENAS}" ]]; then
                        wizard_truenas_train selected_train "${selected_truenas}"
                        announce_truenas_kernel "${selected_truenas}"
                    elif [[ -z "${selected_train}" ]]; then
                        selected_train="$(resolve_selected_train "${selected_truenas}")"
                    fi
                fi
                ;;
            nvidia)
                if fetch_nvidia_versions; then
                    local -a nvidia_menu_args=()
                    for ver in "${NVIDIA_VERSIONS[@]}"; do
                        nvidia_menu_args+=("${ver}" "${NVIDIA_VERSION_TAGS[${ver}]:-}")
                    done
                    UI_MENU_DEFAULT="$(driver_menu_default)"
                    ui_menu selected_nvidia "NVIDIA Driver" \
                        "Select new NVIDIA driver:" "${nvidia_menu_args[@]}"
                    advise_legacy_driver "${selected_nvidia}" "${selected_truenas}"
                    advise_gpu_branch_fit "${selected_nvidia}"
                    advise_patches "${selected_truenas}"
                fi
                ;;
            module)
                if ! nvidia_supports_module_type "${selected_nvidia}"; then
                    selected_module_type="proprietary"
                    ui_msgbox "Module Type" \
                        "NVIDIA ${selected_nvidia} can't select the kernel module flavor (--kernel-module-type requires driver branch ~555+).\n\nThe build will use proprietary modules; setting module type to 'proprietary'."
                elif [[ "${UI_MODE}" == "whiptail" ]]; then
                    wt_size
                    selected_module_type=$(whiptail --title "Module Type" \
                        --menu "Select kernel module type:" \
                        ${WT_HEIGHT} ${WT_WIDTH} 2 \
                        "open" "Recommended — open GPU kernel modules" \
                        "proprietary" "Legacy closed-source kernel modules" \
                        3>&1 1>&2 2>&3) || true
                else
                    PS3="  #? "
                    select choice in "open (recommended)" "proprietary"; do
                        case "${choice}" in
                            "open"*) selected_module_type="open"; break ;;
                            "proprietary") selected_module_type="proprietary"; break ;;
                        esac
                    done
                fi
                ;;
            embed)
                if ui_yesno "Embed" "Embed nvidia.raw in truenas.update?"; then
                    selected_embed="true"
                else
                    selected_embed="false"
                fi
                ;;
        esac

        # Checked after the menu, so an old .env can still be moved to a new version.
        require_supported_truenas "${selected_truenas}"

        # Keep module type consistent with the (possibly just-changed) driver:
        # a switch to a pre-515 branch must drop back to proprietary.
        if ! nvidia_supports_module_type "${selected_nvidia}"; then
            if [[ "${selected_module_type}" != "proprietary" ]]; then
                warn "NVIDIA ${selected_nvidia} can't select the module flavor (--kernel-module-type needs ~555+); setting module type to proprietary."
            fi
            selected_module_type="proprietary"
        fi

        generate_env_file \
            "${selected_nvidia}" "${selected_truenas}" "${selected_train}" \
            "${selected_module_type}" "${selected_embed}" "${selected_cc}" \
            "${env_file}" "${selected_patch_mode}"
        ok ".env updated! (changed: ${reconfigure_what})"
        return 0
    fi

    # ── Check for existing config ────────────────────────────────────────────
    if [[ -f "${env_file}" ]]; then
        read_existing_config "${env_file}"
        if [[ -n "${EXISTING_NVIDIA}" ]] || [[ -n "${EXISTING_TRUENAS}" ]]; then
            echo -e "  ${YELLOW}Existing configuration found (.env):${NC}"
            [[ -n "${EXISTING_TRUENAS}" ]] && echo -e "    TrueNAS : ${BOLD}${EXISTING_TRUENAS}${NC}"
            [[ -n "${EXISTING_NVIDIA}" ]]  && echo -e "    NVIDIA  : ${BOLD}${EXISTING_NVIDIA}${NC}"
            echo -e "  ${DIM}Tip: use ${BOLD}--reconfigure${NC}${DIM} to quick-change a single setting.${NC}"
            echo ""
        fi
    fi

    # ── Step 1: TrueNAS Version ──────────────────────────────────────────────
    banner "Step 1: Select TrueNAS Version"

    local selected_truenas="" selected_train=""

    # Use auto-detected version if available
    if [[ -n "${DETECTED_TRUENAS_VERSION}" ]]; then
        echo -e "  ${GREEN}Auto-detected:${NC} ${BOLD}${DETECTED_TRUENAS_VERSION}${NC}"
        if ui_yesno "Auto-detect" \
            "TrueNAS version ${DETECTED_TRUENAS_VERSION} was auto-detected.\n\nUse this version?" "true"
        then
            selected_truenas="${DETECTED_TRUENAS_VERSION}"
        fi
    fi

    if [[ -z "${selected_truenas}" ]]; then
        if fetch_truenas_versions; then
            # Build tag/description pairs for ui_menu
            local -a truenas_menu_args=()
            for ver in "${TRUENAS_VERSIONS[@]}"; do
                truenas_menu_args+=("${ver}" "$(truenas_menu_desc "${ver}")")
            done

            local truenas_prompt="Select the TrueNAS version you are running:"
            [[ -n "${DETECTED_TRUENAS_VERSION}" ]] && \
                truenas_prompt="Auto-detected: ${DETECTED_TRUENAS_VERSION} (not confirmed)\nSelect version:"

            UI_MENU_DEFAULT="$(truenas_menu_default)"
            ui_menu selected_truenas \
                "Step 1: TrueNAS Version" \
                "${truenas_prompt}" \
                "${truenas_menu_args[@]}"
        else
            warn "Failed to fetch version list. Please enter manually."
            ui_inputbox selected_truenas \
                "TrueNAS Version" \
                "Enter TrueNAS version (e.g. 25.10.8):"
        fi
    fi

    [[ -n "${selected_truenas}" ]] || { err "No TrueNAS version selected. Aborting."; exit 1; }
    require_supported_truenas "${selected_truenas}"

    # Its train: from the list or this host's manifest; asked only when neither knows it.
    wizard_truenas_train selected_train "${selected_truenas}"

    if [[ -n "${selected_train}" ]]; then
        ok "Selected: ${selected_truenas} ($(truenas_train_display "${selected_train}"))"
    else
        ok "Selected: ${selected_truenas}"
    fi
    announce_truenas_kernel "${selected_truenas}"
    echo ""

    # ── Step 2: NVIDIA Driver Version ────────────────────────────────────────
    banner "Step 2: Select NVIDIA Driver Version"

    local selected_nvidia=""

    if fetch_nvidia_versions; then
        # The GPU hint comes after the fetch: the fit check runs inside it.
        show_gpu_fit_hint

        # Build tag/description pairs for ui_menu
        local -a nvidia_menu_args=()
        for ver in "${NVIDIA_VERSIONS[@]}"; do
            local tag="${NVIDIA_VERSION_TAGS[${ver}]:-}"
            nvidia_menu_args+=("${ver}" "${tag}")
        done

        local nvidia_prompt="Select the NVIDIA driver version to build:"
        [[ -n "${DETECTED_GPU_MODEL}" ]] && \
            nvidia_prompt="GPU: ${DETECTED_GPU_MODEL}\nSelect driver version:"

        UI_MENU_DEFAULT="$(driver_menu_default)"
        ui_menu selected_nvidia \
            "Step 2: NVIDIA Driver Version" \
            "${nvidia_prompt}" \
            "${nvidia_menu_args[@]}"
    else
        warn "Failed to fetch version list. Please enter manually."
        ui_inputbox selected_nvidia \
            "NVIDIA Driver" \
            "Enter NVIDIA driver version (e.g. 595.112.07):"
    fi

    [[ -n "${selected_nvidia}" ]] || { err "No NVIDIA version selected. Aborting."; exit 1; }
    ok "Selected: ${selected_nvidia}"
    advise_legacy_driver "${selected_nvidia}" "${selected_truenas}"
    advise_gpu_branch_fit "${selected_nvidia}"
    advise_patches "${selected_truenas}"
    echo ""

    # ── Step 3: Kernel Module Type ───────────────────────────────────────────
    banner "Step 3: Select Kernel Module Type"

    local selected_module_type=""

    if ! nvidia_supports_module_type "${selected_nvidia}"; then
        # Pre-515 drivers (e.g. 470.xx) have no open modules and reject
        # --kernel-module-type, so don't offer a choice that can't be honored.
        selected_module_type="proprietary"
        ui_msgbox "Step 3: Kernel Module Type" \
            "NVIDIA ${selected_nvidia} can't select the kernel module flavor: --kernel-module-type was added in the ~555 driver series (the 535/550 LTS lines lack it).\n\nThe build will use proprietary modules, so the module type is set to 'proprietary' automatically."
    elif [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        selected_module_type=$(whiptail --title "Step 3: Kernel Module Type" \
            --menu "'open' is recommended for most modern GPUs (Turing/Ampere/Ada and newer).\n'proprietary' uses legacy closed-source modules for older hardware." \
            ${WT_HEIGHT} ${WT_WIDTH} 2 \
            "open" "Recommended — open GPU kernel modules" \
            "proprietary" "Legacy closed-source kernel modules" \
            3>&1 1>&2 2>&3) || { err "Cancelled."; exit 1; }
    else
        echo -e "  ${DIM}The kernel module type determines which NVIDIA kernel modules are built.${NC}"
        echo -e "  ${DIM}'open' is recommended for most modern GPUs (Turing/Ampere/Ada and newer).${NC}"
        echo -e "  ${DIM}'proprietary' uses legacy closed-source modules for older hardware.${NC}"
        echo ""

        local -a module_options=("open (recommended)" "proprietary")
        PS3="  #? "
        select choice in "${module_options[@]}"; do
            case "${choice}" in
                "open (recommended)") selected_module_type="open"; break ;;
                "proprietary")        selected_module_type="proprietary"; break ;;
                *) echo -e "  ${RED}Invalid selection. Try again.${NC}" ;;
            esac
        done
    fi

    ok "Selected: ${selected_module_type}"
    echo ""

    # ── Step 4: Embed nvidia.raw in .update ──────────────────────────────────
    banner "Step 4: Embed nvidia.raw in truenas.update?"

    local selected_embed=""

    if ui_yesno \
        "Step 4: Embed in truenas.update?" \
        "When enabled, the build also produces a modified truenas.update file with the new nvidia.raw embedded.\n\nMost users only need nvidia.raw.\n\nEmbed nvidia.raw in truenas.update?"
    then
        selected_embed="true"
    else
        selected_embed="false"
    fi

    ok "Selected: ${selected_embed}"
    echo ""

    # ── Step 5: Compiler Override (optional, advanced) ───────────────────────
    local selected_cc=""
    # Auto-detect is the default, don't bother asking unless advanced mode

    # ── Kernel patches (only asked when the driver/kernel combo needs them) ──
    choose_patch_mode "${selected_nvidia}" "${selected_truenas}"
    local selected_patch_mode="${SELECTED_PATCH_MODE}"

    # ── Summary & Confirmation ───────────────────────────────────────────────
    banner "Configuration Summary"

    local summary=""
    summary+="  TrueNAS Version   : ${selected_truenas}"
    summary+="\n  Release Folder     : ${selected_train:-found by the build}"
    summary+="\n  NVIDIA Driver      : ${selected_nvidia}"
    summary+="\n  Module Type        : ${selected_module_type}"
    summary+="\n  Embed in .update   : ${selected_embed}"
    summary+="\n  Compiler Override  : ${selected_cc:-auto-detect}"
    [[ "${selected_patch_mode}" != "none" ]] && summary+="\n  Patch Mode         : ${selected_patch_mode}"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        ui_msgbox "Configuration Summary" "$(echo -e "${summary}")"
    else
        echo -e "  ${GREEN}►${NC} TrueNAS Version   : ${BOLD}${selected_truenas}${NC}"
        echo -e "  ${GREEN}►${NC} Release Folder     : ${BOLD}${selected_train:-found by the build}${NC}"
        echo -e "  ${GREEN}►${NC} NVIDIA Driver      : ${BOLD}${selected_nvidia}${NC}"
        echo -e "  ${GREEN}►${NC} Module Type        : ${BOLD}${selected_module_type}${NC}"
        echo -e "  ${GREEN}►${NC} Embed in .update   : ${BOLD}${selected_embed}${NC}"
        echo -e "  ${GREEN}►${NC} Compiler Override  : ${BOLD}${selected_cc:-auto-detect}${NC}"
        [[ "${selected_patch_mode}" != "none" ]] && \
            echo -e "  ${GREEN}►${NC} Patch Mode         : ${BOLD}${selected_patch_mode}${NC}"
        echo ""
    fi

    # ── Generate .env ────────────────────────────────────────────────────────
    if [[ -f "${env_file}" ]]; then
        if ! ui_yesno "Overwrite?" \
            ".env already exists.\n\nOverwrite with new configuration?"
        then
            info "Cancelled. .env was not modified."
            exit 0
        fi
    fi

    generate_env_file \
        "${selected_nvidia}" \
        "${selected_truenas}" \
        "${selected_train}" \
        "${selected_module_type}" \
        "${selected_embed}" \
        "${selected_cc}" \
        "${env_file}" \
        "${selected_patch_mode}"

    ok ".env generated!"
    echo ""

    # ── Next Steps ───────────────────────────────────────────────────────────
    local next_steps=""
    next_steps+="Build and run:\n\n"
    next_steps+="  docker compose build\n"
    next_steps+="  docker compose run --rm nvidia-builder\n\n"
    next_steps+="The build takes ~10-15 minutes. Output will be in:\n"
    next_steps+="  ./output/${selected_truenas}/nvidia.raw\n\n"
    next_steps+="Then deploy to TrueNAS:\n"
    next_steps+="  ./deploy-nvidia.sh output/${selected_truenas}/nvidia.raw"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        ui_msgbox "Next Steps" "$(echo -e "${next_steps}")"
    else
        banner "Next Steps"
        echo -e "  Build and run:"
        echo ""
        echo -e "    ${CYAN}docker compose build${NC}"
        echo -e "    ${CYAN}docker compose run --rm nvidia-builder${NC}"
        echo ""
        echo -e "  The build takes ~10–15 minutes. Output will be in:"
        echo -e "    ${BOLD}./output/${selected_truenas}/nvidia.raw${NC}"
        echo ""
        echo -e "  Then deploy to TrueNAS:"
        echo -e "    ${CYAN}./deploy-nvidia.sh output/${selected_truenas}/nvidia.raw${NC}"
        echo ""
    fi

    # ── Offer to start the build ─────────────────────────────────────────────
    if ui_yesno "Start Build?" \
        "Would you like to start building now?\n\nThis will run:\n  docker compose build && docker compose run --rm nvidia-builder"
    then
        echo ""
        info "Starting build …"
        echo ""
        # Not exec'd any more: control has to come back so the deployer can be
        # offered once the image exists.
        if docker compose build && docker compose run --rm nvidia-builder; then
            echo ""
            ok "Build finished."
            offer_deployment "${selected_truenas}"
            exit 0
        fi

        echo ""
        err "Build failed — see the output above. Nothing was deployed."
        exit 1
    else
        echo ""
        info "Ready when you are. Run the commands above to build."
        # An image for this version may already be sitting in output/ from an
        # earlier run — deploying that is still worth offering.
        offer_deployment "${selected_truenas}"
        echo ""
        exit 0
    fi
}

main "$@"
