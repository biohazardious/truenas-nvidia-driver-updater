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

# ── help ─────────────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
TrueNAS NVIDIA Driver Updater — Interactive Configuration Wizard

Usage:
  ./configure.sh              Launch the interactive wizard
  ./configure.sh --no-whiptail  Force plain bash menus (skip whiptail)
  ./configure.sh --help       Show this help message

The wizard will:
  1. Fetch available TrueNAS versions from download.truenas.com
  2. Fetch available NVIDIA driver versions from download.nvidia.com
  3. Let you select options from interactive menus
  4. Generate docker-compose.yaml with your choices

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

# ── parse arguments ──────────────────────────────────────────────────────────
for arg in "$@"; do
    case "${arg}" in
        --help|-h) show_help ;;
        --no-whiptail) FORCE_BASH=true ;;
    esac
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

# Known codename → major version mapping (fallback if page parsing fails)
declare -A CODENAME_MAP=(
    ["Goldeye"]="25.10"
    ["Fangtooth"]="25.04"
    ["ElectricEel"]="24.10"
    ["Electric Eel"]="24.10"
    ["Dragonfish"]="24.04"
    ["Cobia"]="23.10"
)

# Reverse: major version → codename
declare -A VERSION_TO_CODENAME=(
    ["25.10"]="Goldeye"
    ["25.04"]="Fangtooth"
    ["24.10"]="Electric Eel"
    ["24.04"]="Dragonfish"
    ["23.10"]="Cobia"
)

fetch_truenas_branch_info() {
    # Tag TrueNAS versions heuristically from the sorted version list.
    #
    # Tags:
    #   ★ Latest Stable      — newest version without -RC, -BETA, -ALPHA
    #   ★ Latest Pre-release  — newest RC/BETA if it's newer than the latest stable
    #   ★ Previous Stable     — latest stable in a different major line (YY.MM)
    #
    # Args: sorted version list (newest first)

    declare -gA TRUENAS_VERSION_TAGS=()
    local -a sorted=("$@")

    [[ ${#sorted[@]} -eq 0 ]] && return 1

    local latest_stable="" latest_prerelease="" previous_stable=""
    local latest_stable_major=""

    # Find latest stable and latest pre-release
    for ver in "${sorted[@]}"; do
        if [[ "${ver}" =~ -(RC|BETA|ALPHA|PRERELEASE) ]]; then
            # Pre-release version
            [[ -z "${latest_prerelease}" ]] && latest_prerelease="${ver}"
        else
            # Stable version
            if [[ -z "${latest_stable}" ]]; then
                latest_stable="${ver}"
                # Extract major line (e.g. "25.10" from "25.10.3.1")
                latest_stable_major="$(echo "${ver}" | grep -oP '^\d+\.\d+' || true)"
            fi
        fi

        # Stop early once we have both
        [[ -n "${latest_stable}" ]] && [[ -n "${latest_prerelease}" ]] && break
    done

    # Find previous stable (latest stable in a DIFFERENT major line)
    if [[ -n "${latest_stable_major}" ]]; then
        for ver in "${sorted[@]}"; do
            [[ "${ver}" =~ -(RC|BETA|ALPHA|PRERELEASE) ]] && continue
            local ver_major=""
            ver_major="$(echo "${ver}" | grep -oP '^\d+\.\d+' || true)"
            if [[ -n "${ver_major}" ]] && [[ "${ver_major}" != "${latest_stable_major}" ]]; then
                previous_stable="${ver}"
                break
            fi
        done
    fi

    # Assign tags
    [[ -n "${latest_stable}" ]] && TRUENAS_VERSION_TAGS["${latest_stable}"]="★ Latest Stable"

    # Only tag pre-release if it's actually NEWER than the latest stable
    # (i.e. it appears before the latest stable in the sorted list)
    if [[ -n "${latest_prerelease}" ]] && [[ "${latest_prerelease}" != "${latest_stable}" ]]; then
        # Check if pre-release is newer (appears before stable in sorted list)
        for ver in "${sorted[@]}"; do
            if [[ "${ver}" == "${latest_prerelease}" ]]; then
                TRUENAS_VERSION_TAGS["${latest_prerelease}"]="★ Latest Pre-release"
                break
            elif [[ "${ver}" == "${latest_stable}" ]]; then
                # Stable came first → pre-release is older, don't tag it
                break
            fi
        done
    fi

    if [[ -n "${previous_stable}" ]] && [[ "${previous_stable}" != "${latest_stable}" ]]; then
        TRUENAS_VERSION_TAGS["${previous_stable}"]="★ Previous Stable"
    fi

    local tag_count=${#TRUENAS_VERSION_TAGS[@]}
    if [[ ${tag_count} -gt 0 ]]; then
        ok "Identified ${tag_count} release tag(s)"
        for ver in "${!TRUENAS_VERSION_TAGS[@]}"; do
            info "  ${ver} → ${TRUENAS_VERSION_TAGS[${ver}]}"
        done
    fi
}

fetch_truenas_versions() {
    local html=""
    local -a versions=()

    info "Fetching TrueNAS versions from download.truenas.com …"

    html="$(fetch_url "https://download.truenas.com/" 2>/dev/null)" || {
        warn "Could not fetch TrueNAS version list from download.truenas.com"
        return 1
    }

    # Parse the HTML to extract version entries
    # The page structure has folders like:
    #   TrueNAS-SCALE-Goldeye/25.10.3.1/
    #   TrueNAS-26-BETA/26.0.0-BETA.1/
    #
    # We look for version-like directory names inside these parent folders.
    # The HTML contains href attributes like:
    #   href="TrueNAS-SCALE-Goldeye/25.10.3"
    #   href="TrueNAS-26-BETA/26.0.0-BETA.1"

    # Extract all versioned paths: "ParentDir/Version"
    local raw_versions=""
    raw_versions="$(echo "${html}" | grep -oP 'href="(TrueNAS-[^"]*?/[0-9][^"]*?)"' \
        | sed 's/href="//;s/"$//' \
        | grep -vE '\.(iso|gpg|sha256|mtree|update|deb|gz|xz|bz2)' \
        | grep -vE 'Nightlies|MASTER|packages' \
        | grep -E '/[0-9]+\.[0-9]+' \
        | sort -u)" || true

    if [[ -z "${raw_versions}" ]]; then
        warn "Could not parse TrueNAS versions from download page"
        return 1
    fi

    # Build associative arrays: version → codename, and ordered version list
    declare -gA TRUENAS_VERSION_CODENAMES=()
    declare -ga TRUENAS_VERSIONS=()

    local seen_versions=""
    while IFS= read -r entry; do
        local parent_dir="" version=""
        parent_dir="$(dirname "${entry}")"
        version="$(basename "${entry}")"

        # Skip non-version entries (e.g. GITMANIFEST from deeper paths)
        [[ "${version}" =~ ^[0-9] ]] || continue

        # Skip if we've already seen this version
        if echo "${seen_versions}" | grep -qF "|${version}|" 2>/dev/null; then
            continue
        fi
        seen_versions="${seen_versions}|${version}|"

        # Determine codename from parent directory
        local codename=""
        if [[ "${parent_dir}" =~ TrueNAS-SCALE-(.+) ]]; then
            codename="${BASH_REMATCH[1]}"
            # Normalize: "ElectricEel" → "Electric Eel"
            case "${codename}" in
                ElectricEel) codename="Electric Eel" ;;
            esac
        fi
        # TrueNAS 26+ doesn't use codenames

        TRUENAS_VERSION_CODENAMES["${version}"]="${codename}"
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

    # Tag versions (Latest Stable, Latest Pre-release, Previous Stable)
    fetch_truenas_branch_info "${sorted_arr[@]}"

    # Place tagged versions at the top, then the rest
    local -a tagged_order=()
    local -A tagged_seen=()

    # Insert in priority order: Latest Stable first, then Pre-release, then Previous
    for priority in "Latest Stable" "Latest Pre-release" "Previous Stable"; do
        for ver in "${sorted_arr[@]}"; do
            local tag="${TRUENAS_VERSION_TAGS[${ver}]:-}"
            if [[ -n "${tag}" ]] && [[ "${tag}" == *"${priority}"* ]] && [[ -z "${tagged_seen[${ver}]:-}" ]]; then
                tagged_order+=("${ver}")
                tagged_seen["${ver}"]=1
            fi
        done
    done

    # Build final list: tagged first, then all others
    TRUENAS_VERSIONS=("${tagged_order[@]}")
    for ver in "${sorted_arr[@]}"; do
        [[ -n "${tagged_seen[${ver}]:-}" ]] && continue
        TRUENAS_VERSIONS+=("${ver}")
    done

    ok "Found ${#TRUENAS_VERSIONS[@]} TrueNAS versions"
    return 0
}

# =============================================================================
# NVIDIA Driver Version Fetching
# =============================================================================

# Minimum driver version to show (older ones don't support modern TrueNAS kernels)
NVIDIA_MIN_MAJOR=470

# Extract major version prefix from a version string (e.g. "595.80" → "595")
nvidia_major() {
    [[ "$1" =~ ^([0-9]+)\. ]] && printf '%s' "${BASH_REMATCH[1]}"
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

fetch_nvidia_branch_info() {
    # Determine branch tags using a hybrid approach:
    #   1. Try nvidia.com/en-us/drivers/unix.md for branch series identification
    #   2. Cross-reference with the actual sorted version list for correct latest
    #   3. Detect stale .md data (newer major series exist)
    #   4. Fall back to pure heuristic if .md fails
    #
    # Args: sorted version list (newest first)

    declare -gA NVIDIA_VERSION_TAGS=()
    local -a sorted=("$@")

    [[ ${#sorted[@]} -eq 0 ]] && return 1

    local production="" feature="" legacy=""
    local newest_major=""
    newest_major="$(nvidia_major "${sorted[0]}")"

    # ── Strategy 1: Try .md endpoint for branch series identification ────────
    local md_content=""
    md_content="$(fetch_url "https://www.nvidia.com/en-us/drivers/unix.md" 2>/dev/null)" || true

    if [[ -n "${md_content}" ]]; then
        local md_production="" md_feature="" md_legacy=""

        md_production="$(echo "${md_content}" \
            | grep -ioP 'Production Branch Version:\s*\[?\K[0-9][0-9.]+' \
            | head -1)" || true
        md_feature="$(echo "${md_content}" \
            | grep -ioP 'New Feature Branch Version:\s*\[?\K[0-9][0-9.]+' \
            | head -1)" || true
        md_legacy="$(echo "${md_content}" \
            | grep -ioP 'Legacy GPU version[^:]*:\s*\[?\K[0-9][0-9.]+' \
            | head -1)" || true

        # Cross-reference: find actual latest in each .md series from our list
        if [[ -n "${md_production}" ]]; then
            local prod_major=""
            prod_major="$(nvidia_major "${md_production}")"
            production="$(nvidia_latest_in_series "${prod_major}" "${sorted[@]}")" || true
        fi

        if [[ -n "${md_feature}" ]]; then
            local feat_major=""
            feat_major="$(nvidia_major "${md_feature}")"

            # Detect stale .md: if our version list has a newer major series
            # than what .md reports as "New Feature", use the newer one instead
            if [[ -n "${newest_major}" ]] && [[ -n "${feat_major}" ]] \
               && [[ "${newest_major}" -gt "${feat_major}" ]] 2>/dev/null; then
                feature="$(nvidia_latest_in_series "${newest_major}" "${sorted[@]}")" || true
                info "Detected newer driver series (${newest_major}.xx) beyond .md data (${feat_major}.xx)"
            else
                feature="$(nvidia_latest_in_series "${feat_major}" "${sorted[@]}")" || true
            fi
        fi

        if [[ -n "${md_legacy}" ]]; then
            local legacy_major=""
            legacy_major="$(nvidia_major "${md_legacy}")"
            legacy="$(nvidia_latest_in_series "${legacy_major}" "${sorted[@]}")" || true
        fi
    fi

    # ── Strategy 2: Heuristic fallback if .md didn't provide data ────────────
    if [[ -z "${production}" ]] && [[ -z "${feature}" ]]; then
        info "Using heuristic branch detection from version list"

        # Newest version overall → New Feature Branch
        feature="${sorted[0]}"

        # Latest version in a DIFFERENT major series → Production Branch
        for ver in "${sorted[@]}"; do
            if [[ "$(nvidia_major "${ver}")" != "${newest_major}" ]]; then
                production="${ver}"
                break
            fi
        done
    fi

    # Legacy fallback: latest 470.xx from version list
    if [[ -z "${legacy}" ]]; then
        legacy="$(nvidia_latest_in_series "470" "${sorted[@]}")" || true
    fi

    # ── Assign tags (avoid duplicates) ───────────────────────────────────────
    [[ -n "${production}" ]] && NVIDIA_VERSION_TAGS["${production}"]="★ Production Branch"
    if [[ -n "${feature}" ]] && [[ "${feature}" != "${production}" ]]; then
        NVIDIA_VERSION_TAGS["${feature}"]="★ New Feature Branch"
    fi
    if [[ -n "${legacy}" ]] && [[ "${legacy}" != "${production}" ]] && [[ "${legacy}" != "${feature}" ]]; then
        NVIDIA_VERSION_TAGS["${legacy}"]="★ Legacy GPU (470.xx)"
    fi

    local tag_count=${#NVIDIA_VERSION_TAGS[@]}
    if [[ ${tag_count} -gt 0 ]]; then
        ok "Identified ${tag_count} driver branch(es)"
        for ver in "${!NVIDIA_VERSION_TAGS[@]}"; do
            info "  ${ver} → ${NVIDIA_VERSION_TAGS[${ver}]}"
        done
    fi
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

    # Now that we have the sorted list, fetch branch tags
    fetch_nvidia_branch_info "${sorted_arr[@]}"

    # Place tagged versions at the top, then the rest
    local -a tagged_order=()
    local -A tagged_seen=()

    # Insert in priority order: Production first, then New Feature, then Legacy
    for priority in "Production" "New Feature" "Legacy"; do
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
ui_menu() {
    local -n _ui_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift
    # Remaining args: tag1 desc1 tag2 desc2 ...

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        _ui_menu_whiptail _ui_result "${title}" "${prompt}" "$@"
    else
        _ui_menu_bash _ui_result "${title}" "${prompt}" "$@"
    fi
}

_ui_menu_whiptail() {
    local -n _wt_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift

    wt_size

    local choice=""
    choice=$(whiptail --title "${title}" --menu "${prompt}" \
        ${WT_HEIGHT} ${WT_WIDTH} ${WT_MENU_HEIGHT} \
        "$@" \
        "MANUAL" "✎ Enter version manually" \
        3>&1 1>&2 2>&3) || { _wt_result=""; return 1; }

    if [[ "${choice}" == "MANUAL" ]]; then
        choice=$(whiptail --title "${title}" --inputbox \
            "Enter version manually:" 8 ${WT_WIDTH} "" \
            3>&1 1>&2 2>&3) || { _wt_result=""; return 1; }
    fi

    _wt_result="${choice}"
}

_ui_menu_bash() {
    local -n _bash_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift

    # Build display items from tag/desc pairs
    local -a tags=() descs=() display=()
    while [[ $# -gt 0 ]]; do
        tags+=("$1")
        descs+=("${2:-}")
        local d="$1"
        [[ -n "${2:-}" ]] && d="${d}  ${2}"
        display+=("${d}")
        shift 2 || shift
    done

    local total=${#display[@]}
    local page_size=20
    local page=0
    local max_page=$(( (total - 1) / page_size ))

    while true; do
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

        # Navigation options
        if [[ ${page} -gt 0 ]]; then
            page_items+=("◀ Previous page")
            page_tags+=("__PREV__")
        fi
        if [[ ${page} -lt ${max_page} ]]; then
            page_items+=("▶ Next page  (showing $((start+1))–${end} of ${total})")
            page_tags+=("__NEXT__")
        fi
        page_items+=("✎ Enter manually")
        page_tags+=("__MANUAL__")

        echo -e "${DIM}  Page $((page+1)) of $((max_page+1)) — showing $((start+1))–${end} of ${total}${NC}"

        PS3="  #? "
        select choice in "${page_items[@]}"; do
            if [[ -z "${choice}" ]]; then
                echo -e "  ${RED}Invalid selection. Try again.${NC}"
                continue
            fi

            # Find the selected index
            local sel_idx=-1
            for (( i = 0; i < ${#page_items[@]}; i++ )); do
                if [[ "${page_items[$i]}" == "${choice}" ]]; then
                    sel_idx=$i
                    break
                fi
            done
            [[ ${sel_idx} -lt 0 ]] && continue

            local sel_tag="${page_tags[${sel_idx}]}"

            case "${sel_tag}" in
                __PREV__)   (( page-- )); break ;;
                __NEXT__)   (( page++ )); break ;;
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
# docker-compose.yaml Generator
# =============================================================================

generate_compose_yaml() {
    local nvidia_version="$1"
    local truenas_version="$2"
    local codename="$3"
    local module_type="$4"
    local embed_update="$5"
    local build_cc="$6"
    local output_file="$7"

    local codename_line=""
    if [[ -n "${codename}" ]]; then
        codename_line="      - TRUENAS_CODENAME=${codename}"
    else
        codename_line="      - TRUENAS_CODENAME="
    fi

    cat > "${output_file}" <<EOF
# Generated by configure.sh — $(date '+%Y-%m-%d %H:%M:%S')
# Re-run ./configure.sh to reconfigure.
services:
  nvidia-builder:
    build: .
    container_name: truenas-nvidia-builder
    environment:
      - NVIDIA_VERSION=${nvidia_version}
      # NVIDIA installer values:
      #   open         -> Open GPU kernel modules. Preferred for most newer GPUs on current TrueNAS releases.
      #   proprietary  -> Legacy closed-source kernel modules. Use when open modules are incompatible with your GPU/driver stack.
      - NVIDIA_KERNEL_MODULE_TYPE=${module_type}
      # Optional compiler override for the NVIDIA module build, e.g. gcc or gcc-14.
      # Leave unset/empty to let entrypoint auto-detect a suitable compiler.
      - NVIDIA_BUILD_CC=${build_cc}
      - TRUENAS_VERSION=${truenas_version}
      # Required for 25.x and earlier downloads. Leave empty for TrueNAS 26+.
${codename_line}
      # true/false — when enabled, also generate a new truenas.update with the
      # bundled /usr/share/truenas/sysext-extensions/nvidia.raw replaced.
      - EMBED_NVIDIA_RAW_IN_UPDATE=${embed_update}
    volumes:
      # If truenas.update exists here, it will be used instead of downloading
      - .:/workspace
      - ./output:/output
    privileged: true
EOF
}

# =============================================================================
# Main Wizard
# =============================================================================

main() {
    banner "TrueNAS NVIDIA Driver Updater — Configuration Wizard"

    detect_ui_mode
    detect_fetch_cmd
    info "Using ${FETCH_CMD} to fetch version lists"
    echo ""

    # ── Check for existing config ────────────────────────────────────────────
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local compose_file="${script_dir}/docker-compose.yaml"

    if [[ -f "${compose_file}" ]]; then
        # Show current config
        local current_nvidia current_truenas
        current_nvidia="$(grep 'NVIDIA_VERSION=' "${compose_file}" 2>/dev/null \
            | grep -v '#' | head -1 | sed 's/.*NVIDIA_VERSION=//' | tr -d '[:space:]')" || true
        current_truenas="$(grep 'TRUENAS_VERSION=' "${compose_file}" 2>/dev/null \
            | grep -v '#' | head -1 | sed 's/.*TRUENAS_VERSION=//' | tr -d '[:space:]')" || true

        if [[ -n "${current_nvidia}" ]] || [[ -n "${current_truenas}" ]]; then
            echo -e "  ${YELLOW}Existing configuration found:${NC}"
            [[ -n "${current_truenas}" ]] && echo -e "    TrueNAS : ${BOLD}${current_truenas}${NC}"
            [[ -n "${current_nvidia}" ]]  && echo -e "    NVIDIA  : ${BOLD}${current_nvidia}${NC}"
            echo ""
        fi
    fi

    # ── Step 1: TrueNAS Version ──────────────────────────────────────────────
    banner "Step 1: Select TrueNAS Version"

    local selected_truenas="" selected_codename=""

    if fetch_truenas_versions; then
        # Build tag/description pairs for ui_menu
        local -a truenas_menu_args=()
        for ver in "${TRUENAS_VERSIONS[@]}"; do
            local cn="${TRUENAS_VERSION_CODENAMES[${ver}]:-}"
            local tag="${TRUENAS_VERSION_TAGS[${ver}]:-}"
            local desc=""
            [[ -n "${cn}" ]] && desc="${cn}"
            [[ -n "${tag}" ]] && desc="${desc:+${desc}  }${tag}"
            truenas_menu_args+=("${ver}" "${desc}")
        done

        ui_menu selected_truenas \
            "Step 1: TrueNAS Version" \
            "Select the TrueNAS version you are running:" \
            "${truenas_menu_args[@]}"

        # Resolve codename
        if [[ -n "${selected_truenas}" ]]; then
            selected_codename="${TRUENAS_VERSION_CODENAMES[${selected_truenas}]:-}"
            # If manually entered, try auto-detecting codename
            if [[ -z "${selected_codename}" ]]; then
                local major_minor=""
                major_minor="$(echo "${selected_truenas}" | grep -oP '^\d+\.\d+' || true)"
                selected_codename="${VERSION_TO_CODENAME[${major_minor}]:-}"
                if [[ -z "${selected_codename}" ]]; then
                    ui_inputbox selected_codename \
                        "Codename" \
                        "Enter codename (leave empty for TrueNAS 26+):"
                fi
            fi
        fi
    else
        warn "Failed to fetch version list. Please enter manually."
        ui_inputbox selected_truenas \
            "TrueNAS Version" \
            "Enter TrueNAS version (e.g. 25.10.3.1):"
        local major_minor=""
        major_minor="$(echo "${selected_truenas}" | grep -oP '^\d+\.\d+' || true)"
        selected_codename="${VERSION_TO_CODENAME[${major_minor}]:-}"
        if [[ -z "${selected_codename}" ]]; then
            ui_inputbox selected_codename \
                "Codename" \
                "Enter codename (leave empty for TrueNAS 26+):"
        fi
    fi

    [[ -n "${selected_truenas}" ]] || { err "No TrueNAS version selected. Aborting."; exit 1; }

    if [[ -n "${selected_codename}" ]]; then
        ok "Selected: ${selected_truenas} (${selected_codename})"
    else
        ok "Selected: ${selected_truenas}"
    fi
    echo ""

    # ── Step 2: NVIDIA Driver Version ────────────────────────────────────────
    banner "Step 2: Select NVIDIA Driver Version"

    local selected_nvidia=""

    if fetch_nvidia_versions; then
        # Build tag/description pairs for ui_menu
        local -a nvidia_menu_args=()
        for ver in "${NVIDIA_VERSIONS[@]}"; do
            local tag="${NVIDIA_VERSION_TAGS[${ver}]:-}"
            nvidia_menu_args+=("${ver}" "${tag}")
        done

        ui_menu selected_nvidia \
            "Step 2: NVIDIA Driver Version" \
            "Select the NVIDIA driver version to build:" \
            "${nvidia_menu_args[@]}"
    else
        warn "Failed to fetch version list. Please enter manually."
        ui_inputbox selected_nvidia \
            "NVIDIA Driver" \
            "Enter NVIDIA driver version (e.g. 595.80):"
    fi

    [[ -n "${selected_nvidia}" ]] || { err "No NVIDIA version selected. Aborting."; exit 1; }
    ok "Selected: ${selected_nvidia}"
    echo ""

    # ── Step 3: Kernel Module Type ───────────────────────────────────────────
    banner "Step 3: Select Kernel Module Type"

    local selected_module_type=""

    if [[ "${UI_MODE}" == "whiptail" ]]; then
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

    # ── Summary & Confirmation ───────────────────────────────────────────────
    banner "Configuration Summary"

    local summary=""
    summary+="  TrueNAS Version   : ${selected_truenas}"
    [[ -n "${selected_codename}" ]] && summary+="\n  TrueNAS Codename  : ${selected_codename}"
    summary+="\n  NVIDIA Driver      : ${selected_nvidia}"
    summary+="\n  Module Type        : ${selected_module_type}"
    summary+="\n  Embed in .update   : ${selected_embed}"
    summary+="\n  Compiler Override  : ${selected_cc:-auto-detect}"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        # Show summary in a msgbox (need to strip ANSI for whiptail)
        ui_msgbox "Configuration Summary" "$(echo -e "${summary}")"
    else
        echo -e "  ${GREEN}►${NC} TrueNAS Version   : ${BOLD}${selected_truenas}${NC}"
        if [[ -n "${selected_codename}" ]]; then
            echo -e "  ${GREEN}►${NC} TrueNAS Codename  : ${BOLD}${selected_codename}${NC}"
        fi
        echo -e "  ${GREEN}►${NC} NVIDIA Driver      : ${BOLD}${selected_nvidia}${NC}"
        echo -e "  ${GREEN}►${NC} Module Type        : ${BOLD}${selected_module_type}${NC}"
        echo -e "  ${GREEN}►${NC} Embed in .update   : ${BOLD}${selected_embed}${NC}"
        echo -e "  ${GREEN}►${NC} Compiler Override  : ${BOLD}${selected_cc:-auto-detect}${NC}"
        echo ""
    fi

    # ── Generate docker-compose.yaml ─────────────────────────────────────────
    if [[ -f "${compose_file}" ]]; then
        if ! ui_yesno "Overwrite?" \
            "docker-compose.yaml already exists.\n\nOverwrite with new configuration?"
        then
            info "Cancelled. docker-compose.yaml was not modified."
            exit 0
        fi
    fi

    generate_compose_yaml \
        "${selected_nvidia}" \
        "${selected_truenas}" \
        "${selected_codename}" \
        "${selected_module_type}" \
        "${selected_embed}" \
        "${selected_cc}" \
        "${compose_file}"

    ok "docker-compose.yaml generated!"
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
        exec bash -c 'docker compose build && docker compose run --rm nvidia-builder'
    else
        echo ""
        info "Ready when you are. Run the commands above to build."
        echo ""
        exit 0
    fi
}

main "$@"
