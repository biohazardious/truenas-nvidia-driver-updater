#!/bin/bash
# =============================================================================
# deploy-nvidia.sh — Deploy nvidia.raw sysext to TrueNAS
#
# Usage:  ./deploy-nvidia.sh                        interactive manager (menu)
#         ./deploy-nvidia.sh <path-to-nvidia.raw>   deploy an image
#         ./deploy-nvidia.sh --check                report the current state only
#         ./deploy-nvidia.sh --dry-run <image>      show every step, change nothing
#         ./deploy-nvidia.sh --uninstall            restore the stock driver
#
# Run with no arguments it offers a menu to inspect the current state, deploy
# an image, or roll back to a previous one; the menu re-invokes this script to
# do the actual work, so every path below is shared.
#
# Deploying an image:
#   1. Turns off TrueNAS's own Docker NVIDIA integration while the swap runs
#   2. Unmerges any active sysext extensions
#   3. Unlocks the read-only /usr ZFS dataset
#   4. Backs up the existing nvidia.raw alongside this script
#   5. Copies the new nvidia.raw into place
#   6. Re-locks /usr and merges extensions
#   7. Re-enables the Docker NVIDIA integration
#   8. Verifies the activation symlink and refreshes the linker cache
#   9. Unloads the running NVIDIA kernel modules so the new ones can load
#
# On any failure — including Ctrl-C mid-way — the EXIT trap restores the
# previous nvidia.raw, re-locks /usr, re-merges, and turns the Docker NVIDIA
# integration back on, so the system is never left half-deployed.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
NVIDIA_RAW="${SYSEXT_DIR}/nvidia.raw"

# Backup directory — same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
# Absolute path to this script; the manager re-invokes it to deploy.
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# ── Deployment state (read by the EXIT trap) ────────────────────────────────
USR_DATASET=""          # set once /usr has been unlocked; empty = never touched
BACKUP=""               # previous nvidia.raw, empty on a fresh install
UNMERGED=0              # 1 once sysext extensions have been unmerged
ROLLED_BACK=0           # 1 once a rollback has already run (don't repeat it)
NVIDIA_INTEGRATION_OFF=0  # 1 while TrueNAS's Docker NVIDIA support is disabled
REBOOT_REQUIRED=0       # 1 when old modules could not be unloaded
DEPLOY_COMPLETE=0       # 1 once everything succeeded

# ── Modes ───────────────────────────────────────────────────────────────────
DRY_RUN=0               # 1 = log every mutating command instead of running it
CHECK_ONLY=0            # 1 = report the current state and exit
UNINSTALL=0             # 1 = deploy the stock image instead of a given one
PERSIST_ACTION=""       # "on"/"off" = set up / remove update-persistence

# ── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage:
  $0                         Interactive manager (menu)
  $0 <path-to-nvidia.raw>    Deploy the image
  $0 --dry-run <image>       Walk the whole flow, change nothing
  $0 --check                 Report the current driver/sysext state and exit
  $0 --uninstall             Restore the driver this TrueNAS release shipped
  $0 --persist               Keep the driver across TrueNAS updates (PREINIT)
  $0 --unpersist             Stop restoring it after updates
  $0 --no-whiptail           Force plain menus instead of TUI dialogs
  $0 --help                  Show this help

With no arguments it opens a menu to inspect the current state, deploy an
image, or roll back to a previous one.

--check is read-only and also works without root, reporting less where a call
needs privileges. It exits non-zero when it finds a problem.
EOF
}

# =============================================================================
# Minimal UI layer
#
# Deliberately duplicated rather than shared with configure.sh: this script is
# copied to the TrueNAS box on its own, so it has to stay a single file. Only
# the four dialogs this script actually needs are implemented.
# =============================================================================
UI_MODE="bash"
FORCE_BASH=false

detect_ui_mode() {
    if [[ "${FORCE_BASH}" == true ]]; then
        UI_MODE="bash"
    elif command -v whiptail &>/dev/null && [[ -t 0 ]]; then
        UI_MODE="whiptail"
    else
        UI_MODE="bash"
    fi
}

# Size dialogs from the terminal, clamped to something readable.
wt_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)

    WT_HEIGHT=$((rows - 4))
    WT_WIDTH=$((cols - 8))
    [[ ${WT_HEIGHT} -gt 30 ]] && WT_HEIGHT=30
    [[ ${WT_HEIGHT} -lt 12 ]] && WT_HEIGHT=12
    [[ ${WT_WIDTH} -gt 100 ]] && WT_WIDTH=100
    [[ ${WT_WIDTH} -lt 60 ]] && WT_WIDTH=60
    WT_MENU_HEIGHT=$((WT_HEIGHT - 9))
    [[ ${WT_MENU_HEIGHT} -lt 3 ]] && WT_MENU_HEIGHT=3
}

# ui_menu RESULT_VAR "title" "prompt" tag1 desc1 tag2 desc2 …
# Returns non-zero when the user cancels.
ui_menu() {
    local -n _menu_result=$1; shift
    local title="$1"; shift
    local prompt="$1"; shift
    local -a items=("$@")

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        _menu_result="$(whiptail --title "${title}" --menu "${prompt}" \
            "${WT_HEIGHT}" "${WT_WIDTH}" "${WT_MENU_HEIGHT}" \
            "${items[@]}" 3>&1 1>&2 2>&3)" || { _menu_result=""; return 1; }
        return 0
    fi

    echo ""
    echo -e "${BOLD}${title}${NC}"
    echo -e "${prompt}"
    echo ""
    local i=1 idx
    for ((idx = 0; idx < ${#items[@]}; idx += 2)); do
        if [[ "${items[idx]}" == /* ]]; then
            # A path would blow the column alignment — describe it, then show
            # the path underneath.
            printf "   %2d) %s\n       %s\n" "${i}" "${items[idx + 1]}" "${items[idx]}"
        else
            printf "   %2d) %-22s %s\n" "${i}" "${items[idx]}" "${items[idx + 1]}"
        fi
        i=$((i + 1))
    done
    echo ""

    local count=$(( ${#items[@]} / 2 )) reply=""
    read -r -p "  Select [1-${count}] (empty to cancel): " reply
    [[ -n "${reply}" ]] || { _menu_result=""; return 1; }
    [[ "${reply}" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= count )) || {
        warn "Invalid selection: ${reply}"; _menu_result=""; return 1
    }
    _menu_result="${items[$(( (reply - 1) * 2 ))]}"
    return 0
}

# ui_yesno "title" "prompt" [default_yes]
ui_yesno() {
    local title="$1" prompt="$2" default_yes="${3:-false}"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size
        local -a extra=()
        [[ "${default_yes}" != "true" ]] && extra+=(--defaultno)
        whiptail --title "${title}" --yesno "${prompt}" \
            $((WT_HEIGHT / 2)) "${WT_WIDTH}" "${extra[@]}" 3>&1 1>&2 2>&3
        return $?
    fi

    echo ""
    echo -e "${prompt}"
    local suffix="[y/N]" reply=""
    [[ "${default_yes}" == "true" ]] && suffix="[Y/n]"
    read -r -p "  Continue? ${suffix} " reply
    if [[ "${default_yes}" == "true" ]]; then
        [[ ! "${reply}" =~ ^[Nn] ]]
    else
        [[ "${reply}" =~ ^[Yy] ]]
    fi
}

# ui_textbox "title" "body" — shows a scrollable report.
ui_textbox() {
    local title="$1" body="$2"

    if [[ "${UI_MODE}" == "whiptail" ]]; then
        wt_size

        # The body goes through a real file, never a pipe. `--textbox /dev/stdin`
        # renders an empty box: whiptail reads the content from stdin and then
        # has no stdin left to take keypresses from, so the dialog never draws.
        local tmp=""
        tmp="$(mktemp 2>/dev/null)" || { echo -e "${body}"; return 0; }
        # Also cleaned on the way out of the function, so quitting the dialog
        # early doesn't leave the file behind.
        trap 'rm -f "${tmp}"' RETURN

        # %b expands the \n escapes callers write (whiptail's --msgbox
        # interprets them, but --textbox shows file content verbatim), and the
        # sed drops ANSI colours, which would otherwise appear as raw escapes.
        printf '%b\n' "${body}" | sed 's/\x1b\[[0-9;]*m//g' > "${tmp}"
        whiptail --title "${title}" --scrolltext \
            --textbox "${tmp}" "${WT_HEIGHT}" "${WT_WIDTH}"
        rm -f "${tmp}"
        return 0
    fi

    echo ""
    # echo -e, not printf '%s': callers write "\n" escapes for whiptail, which
    # would otherwise be printed literally in plain-text mode.
    echo -e "${body}"
    echo ""
    read -r -p "  Press Enter to continue … " _ || true
}

# Every mutating command goes through this. In --dry-run it is only printed, so
# the flow, its ordering and its guards can be inspected on a live system
# without touching anything.
run_cmd() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo -e "${YELLOW}[DRY]${NC}   $*"
        return 0
    fi
    "$@"
}

# Same as run_cmd, but silences the command in a real run. Redirecting the
# run_cmd call itself would swallow the [DRY] line too, hiding the command from
# the dry-run output — which is the one thing it exists to show.
run_cmd_quiet() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo -e "${YELLOW}[DRY]${NC}   $*"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

# Read a boolean field from a JSON document on stdin, printing "true"/"false"
# (or nothing if it can't be read). TrueNAS does not ship jq but always ships
# python3 (middleware runs on it), so python3 is the primary path here.
json_bool_field() {
    local field="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
try:
    v = json.load(sys.stdin).get('${field}')
except Exception:
    sys.exit(0)
if v is not None:
    print(str(v).lower())
" 2>/dev/null || true
    elif command -v jq >/dev/null 2>&1; then
        jq -r --arg f "${field}" 'if has($f) then (.[$f] | tostring) else empty end' 2>/dev/null || true
    fi
}

# TrueNAS manages the NVIDIA runtime for Docker itself (Electric Eel and newer).
# Leaving it enabled while nvidia.raw is swapped means middleware is still
# pointing at driver files that are about to disappear, so turn it off first and
# restore it afterwards. Older releases have no docker.config — skip silently.
disable_nvidia_integration() {
    command -v midclt >/dev/null 2>&1 || {
        warn "midclt not found — skipping TrueNAS Docker NVIDIA integration handling"
        return 0
    }

    # `|| true` guards both halves: an unsupported release makes midclt exit
    # non-zero, and `set -o pipefail` would turn that into a hard abort.
    local state
    state="$( { midclt call docker.config 2>/dev/null || true; } | json_bool_field nvidia )" || true

    if [[ -z "${state}" ]]; then
        info "TrueNAS Docker NVIDIA integration not exposed on this release — skipping"
        return 0
    fi
    if [[ "${state}" != "true" ]]; then
        info "TrueNAS Docker NVIDIA integration already disabled — leaving it as is"
        return 0
    fi

    info "Disabling TrueNAS Docker NVIDIA integration for the swap …"
    if run_cmd_quiet midclt call -j docker.update '{"nvidia": false}'; then
        NVIDIA_INTEGRATION_OFF=1
        ok "Docker NVIDIA integration disabled (will be re-enabled at the end)"
    else
        warn "Could not disable Docker NVIDIA integration — continuing anyway"
    fi
}

restore_nvidia_integration() {
    [[ ${NVIDIA_INTEGRATION_OFF} -eq 1 ]] || return 0

    info "Re-enabling TrueNAS Docker NVIDIA integration …"
    if run_cmd_quiet midclt call -j docker.update '{"nvidia": true}'; then
        NVIDIA_INTEGRATION_OFF=0
        ok "Docker NVIDIA integration re-enabled"
    else
        warn "Failed to re-enable Docker NVIDIA integration — run:"
        warn "  midclt call -j docker.update '{\"nvidia\": true}'"
    fi
}

# Drop the modules the *old* driver left in memory. Without this the kernel
# keeps serving the previous driver until the next reboot and nvidia-smi
# reports a version/module mismatch against the freshly merged image.
unload_nvidia_modules() {
    # Dependency order: consumers first, core module last.
    local candidates=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
    local loaded=() m

    for m in "${candidates[@]}"; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "${m}"; then
            loaded+=("${m}")
        fi
    done

    if [[ ${#loaded[@]} -eq 0 ]]; then
        info "No NVIDIA kernel modules loaded — nothing to unload"
        return 0
    fi

    info "Unloading NVIDIA kernel modules: ${loaded[*]}"
    for m in "${loaded[@]}"; do
        if run_cmd rmmod "${m}" 2>/dev/null; then
            ok "  Unloaded ${m}"
        else
            warn "  ${m} is still in use (running container, VM passthrough, or display)"
            REBOOT_REQUIRED=1
        fi
    done

    if [[ ${REBOOT_REQUIRED} -eq 1 ]]; then
        warn "Some modules stayed loaded — reboot to activate the new driver"
    else
        ok "Old NVIDIA modules unloaded — running nvidia-smi loads the new ones"
    fi
}

# /usr/share/truenas/sysext-extensions/ is only a storage location — it is NOT
# a systemd-sysext search path. An extension is activated by a symlink in
# /etc/extensions (persistent dataset) or /run/extensions (tmpfs). TrueNAS's
# middleware creates that symlink for its own nvidia.raw, so replacing the file
# in place is normally enough — but if NVIDIA support has never been enabled,
# the image would sit there merged into nothing.
ensure_extension_activated() {
    local dir
    for dir in /etc/extensions /run/extensions; do
        if [[ -e "${dir}/nvidia.raw" ]]; then
            ok "Extension is activated via ${dir}/nvidia.raw"
            return 0
        fi
    done

    warn "nvidia.raw is installed but not activated — no symlink in /etc/extensions or /run/extensions"
    info "Creating a transient activation symlink in /run/extensions …"

    if run_cmd mkdir -p /run/extensions && run_cmd ln -sf "${NVIDIA_RAW}" /run/extensions/nvidia.raw; then
        run_cmd systemd-sysext refresh || warn "systemd-sysext refresh failed"
        ok "Extension activated for this boot"
        warn "/run is a tmpfs — this symlink is gone after a reboot. Enable NVIDIA support"
        warn "in the TrueNAS UI (Apps → Settings) so middleware manages the symlink persistently."
    else
        warn "Could not create /run/extensions/nvidia.raw — the driver will not be active"
    fi
}

# Merging a sysext adds new shared libraries (libnvidia-*.so, libcuda.so …) to
# /usr/lib; without refreshing the linker cache they stay invisible to already
# running processes and to anything that resolves libraries via ld.so.cache.
refresh_linker_cache() {
    command -v ldconfig >/dev/null 2>&1 || return 0
    info "Refreshing the dynamic linker cache (ldconfig) …"
    run_cmd ldconfig || warn "ldconfig failed — new NVIDIA libraries may not resolve until reboot"
}

print_sysext_diagnostics() {
    local raw_path="$1"

    echo ""
    warn "systemd-sysext reported an incompatible image. Collecting diagnostics …"

    echo ""
    echo -e "${BOLD}--- Host /usr/lib/os-release ---${NC}"
    if [[ -f /usr/lib/os-release ]]; then
        cat /usr/lib/os-release
    else
        warn "/usr/lib/os-release not found"
    fi

    echo ""
    echo -e "${BOLD}--- Embedded extension-release metadata ---${NC}"
    if command -v unsquashfs >/dev/null 2>&1; then
        if ! unsquashfs -cat "${raw_path}" usr/lib/extension-release.d/extension-release.nvidia 2>/dev/null; then
            warn "Could not read usr/lib/extension-release.d/extension-release.nvidia from ${raw_path}"
        fi
    else
        warn "unsquashfs is not available; cannot inspect extension-release metadata inside ${raw_path}"
    fi

    echo ""
    echo -e "${BOLD}--- systemd-sysext status ---${NC}"
    systemd-sysext status || true

    echo ""
    echo -e "${BOLD}--- SYSTEMD_LOG_LEVEL=debug systemd-sysext refresh ---${NC}"
    SYSTEMD_LOG_LEVEL=debug systemd-sysext refresh || true
}

# Restore the system to its prior working state after a failed merge.
#   - If a backup exists, put the previous nvidia.raw back.
#   - Otherwise (fresh install) remove the rejected image entirely.
# Then re-lock /usr and re-merge so the box isn't left broken.
#
# Every step is best-effort: a failure here must never skip the ones after it,
# or the dataset would be left writable and the extensions unmerged.
rollback_to_previous_state() {
    local backup="${1:-}"   # previous nvidia.raw, empty on a fresh install
    local failed=0

    ROLLED_BACK=1

    echo ""
    warn "Rolling back to the previous working state …"

    run_cmd systemd-sysext unmerge 2>/dev/null || true

    if run_cmd run_cmd zfs set readonly=off "${USR_DATASET}" 2>/dev/null; then
        if [[ -n "${backup}" ]] && [[ -f "${backup}" ]]; then
            info "Restoring previous nvidia.raw from $(basename "${backup}")"
            if run_cmd cp "${backup}" "${NVIDIA_RAW}" && run_cmd chmod 644 "${NVIDIA_RAW}"; then
                :
            else
                warn "Could not restore ${NVIDIA_RAW} from ${backup}"
                failed=1
            fi
        else
            info "No previous nvidia.raw to restore (fresh install) — removing the rejected image"
            run_cmd rm -f "${NVIDIA_RAW}" || { warn "Could not remove ${NVIDIA_RAW}"; failed=1; }
        fi
    else
        warn "Could not unlock ${USR_DATASET} — leaving ${NVIDIA_RAW} untouched"
        failed=1
    fi

    run_cmd run_cmd zfs set readonly=on "${USR_DATASET}" 2>/dev/null \
        || { warn "Failed to re-lock ${USR_DATASET}"; failed=1; }

    run_cmd systemd-sysext merge || { warn "Rollback merge failed"; failed=1; }

    if [[ ${failed} -eq 0 ]]; then
        ok "Rollback complete — system restored to its previous state"
    else
        warn "Rollback was incomplete — check the warnings above; manual recovery may be needed"
        warn "  zfs set readonly=on ${USR_DATASET} && systemd-sysext merge"
    fi
}

# =============================================================================
# --check — read-only state report
#
# A driver can be installed, merged and still not work: the image may target a
# different kernel than the one running (after a TrueNAS update), or it may
# never have been activated. Both are silent — nvidia-smi just fails — so this
# reports them explicitly instead of making the user piece it together.
# =============================================================================

# The kernel an image was built for, read from the module path inside it
# (usr/lib/modules/<release>/…). Cheap: the listing is not extracted.
image_target_kernel() {
    local raw="$1"
    command -v unsquashfs >/dev/null 2>&1 || return 0
    unsquashfs -l "${raw}" 2>/dev/null \
        | grep -m1 -oP 'usr/lib/modules/\K[^/]+' || true
}

# The driver version an image ships, taken from the versioned library name.
image_driver_version() {
    local raw="$1"
    command -v unsquashfs >/dev/null 2>&1 || return 0
    unsquashfs -l "${raw}" 2>/dev/null \
        | grep -m1 -oP 'libcuda\.so\.\K[0-9]+\.[0-9.]+' || true
}

report_state() {
    local problems=0
    local host_kernel; host_kernel="$(uname -r)"

    echo ""
    echo -e "${BOLD}── Installed image ─────────────────────────────────────────${NC}"
    if [[ -f "${NVIDIA_RAW}" ]]; then
        echo "  path            ${NVIDIA_RAW}"
        echo "  size            $(du -h "${NVIDIA_RAW}" 2>/dev/null | cut -f1)"
        echo "  modified        $(date -r "${NVIDIA_RAW}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"

        local img_driver img_kernel
        img_driver="$(image_driver_version "${NVIDIA_RAW}")"
        img_kernel="$(image_target_kernel "${NVIDIA_RAW}")"
        echo "  driver version  ${img_driver:-<could not read>}"
        echo "  built for       ${img_kernel:-<could not read>}"

        if [[ -n "${img_kernel}" ]] && [[ "${img_kernel}" != "${host_kernel}" ]]; then
            problems=$((problems + 1))
            IMAGE_KERNEL_MISMATCH="${img_kernel}"
        fi
    else
        echo "  none installed at ${NVIDIA_RAW}"
        problems=$((problems + 1))
        NO_IMAGE=1
    fi

    echo ""
    echo -e "${BOLD}── Host ────────────────────────────────────────────────────${NC}"
    echo "  kernel          ${host_kernel}"

    local loaded
    loaded="$(lsmod 2>/dev/null | awk '{print $1}' | grep -E '^nvidia' | tr '\n' ' ' || true)"
    echo "  loaded modules  ${loaded:-<none>}"

    if command -v nvidia-smi >/dev/null 2>&1; then
        local smi
        smi="$(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null | head -2 | tr '\n' ';' || true)"
        echo "  nvidia-smi      ${smi:-<no devices / driver not responding>}"
        [[ -z "${smi}" ]] && problems=$((problems + 1))
    else
        echo "  nvidia-smi      <not present>"
    fi

    echo ""
    echo -e "${BOLD}── Activation ──────────────────────────────────────────────${NC}"
    local activated=0 dir
    for dir in /etc/extensions /run/extensions; do
        if [[ -e "${dir}/nvidia.raw" ]]; then
            echo "  ${dir}/nvidia.raw → $(readlink -f "${dir}/nvidia.raw" 2>/dev/null || echo '<not a symlink>')"
            activated=1
        fi
    done
    if [[ ${activated} -eq 0 ]]; then
        echo "  no symlink in /etc/extensions or /run/extensions"
        problems=$((problems + 1))
        NOT_ACTIVATED=1
    fi
    echo "  systemd-sysext status:"
    systemd-sysext status 2>&1 | sed 's/^/    /' || true

    echo ""
    echo -e "${BOLD}── Middleware ──────────────────────────────────────────────${NC}"
    if command -v midclt >/dev/null 2>&1; then
        local state
        state="$( { midclt call docker.config 2>/dev/null || true; } | json_bool_field nvidia )" || true
        case "${state}" in
            true)  echo "  Docker NVIDIA integration: enabled" ;;
            false) echo "  Docker NVIDIA integration: disabled" ;;
            *)     echo "  Docker NVIDIA integration: not exposed on this release (or needs root)" ;;
        esac
    else
        echo "  midclt not available"
    fi

    echo ""
    echo -e "${BOLD}── Update persistence ──────────────────────────────────────${NC}"
    local persist_cmd=""
    if persist_cmd="$(persist_status)"; then
        echo "  PREINIT script:  ${persist_cmd}"
        local saved="$(dirname "${persist_cmd}")/nvidia.raw"
        if [[ -f "${saved}" ]]; then
            local saved_kernel
            saved_kernel="$(image_target_kernel "${saved}")"
            echo "  saved copy:      ${saved} ($(du -h "${saved}" 2>/dev/null | cut -f1))"
            echo "  saved built for: ${saved_kernel:-<could not read>}"
            if [[ -n "${saved_kernel}" ]] && [[ "${saved_kernel}" != "${host_kernel}" ]]; then
                problems=$((problems + 1))
                PERSIST_STALE="${saved_kernel}"
            fi
        else
            echo "  saved copy:      MISSING at ${saved}"
            problems=$((problems + 1))
            PERSIST_BROKEN=1
        fi
    else
        echo "  not configured — a TrueNAS update will restore the stock driver"
    fi

    echo ""
    echo -e "${BOLD}── Backups ─────────────────────────────────────────────────${NC}"
    if [[ -d "${BACKUP_DIR}" ]]; then
        local list
        list="$(ls -1 "${BACKUP_DIR}"/nvidia.raw.backup_* 2>/dev/null | sort -r || true)"
        if [[ -n "${list}" ]]; then
            echo "${list}" | while read -r b; do
                echo "  $(basename "${b}")  ($(du -h "${b}" 2>/dev/null | cut -f1))"
            done
        else
            echo "  none in ${BACKUP_DIR}"
        fi
    else
        echo "  none (${BACKUP_DIR} does not exist)"
    fi

    echo ""
    if [[ ${problems} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}  ✓ No problems detected${NC}"
        echo ""
        return 0
    fi

    echo -e "${YELLOW}${BOLD}── Problems ────────────────────────────────────────────────${NC}"
    [[ -n "${NO_IMAGE:-}" ]] && \
        warn "No nvidia.raw installed — TrueNAS is running its stock driver (or none)."
    if [[ -n "${IMAGE_KERNEL_MISMATCH:-}" ]]; then
        warn "The installed image was built for kernel ${IMAGE_KERNEL_MISMATCH},"
        warn "but this host runs ${host_kernel}. The modules will not load — this is"
        warn "what a TrueNAS update does. Rebuild against ${host_kernel} and redeploy."
    fi
    [[ -n "${NOT_ACTIVATED:-}" ]] && \
        warn "The image is not activated: no symlink in /etc/extensions or /run/extensions."
    if [[ -n "${PERSIST_STALE:-}" ]]; then
        warn "The copy saved for update-persistence was built for kernel ${PERSIST_STALE},"
        warn "not the running ${host_kernel} — it will be refused at boot rather than"
        warn "restored. Rebuild, redeploy, then re-run the persistence setup."
    fi
    [[ -n "${PERSIST_BROKEN:-}" ]] && \
        warn "A PREINIT entry is registered but its saved image is missing — it will do nothing."
    echo ""
    return 1
}

# Runs on every exit path. A successful deployment has already cleaned up after
# itself; anything else (error, Ctrl-C, failed copy) is undone here so /usr is
# never left writable and the Docker NVIDIA integration never stays off.
cleanup() {
    local rc=$?
    trap - EXIT

    if [[ ${DEPLOY_COMPLETE} -eq 1 ]]; then
        exit "${rc}"
    fi

    # A dry run never changed anything, so there is nothing to undo.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo ""
        warn "Dry run stopped early (exit code ${rc}) — nothing was changed"
        exit "${rc}"
    fi

    echo ""
    warn "Deployment did not complete (exit code ${rc}) — restoring previous state …"

    if [[ -n "${USR_DATASET}" ]]; then
        # We got as far as unlocking /usr, so the image may have been touched.
        [[ ${ROLLED_BACK} -eq 1 ]] || rollback_to_previous_state "${BACKUP}"
    elif [[ ${UNMERGED} -eq 1 ]]; then
        # Extensions were unmerged but nothing was modified — just merge back.
        info "Re-merging sysext extensions …"
        run_cmd systemd-sysext merge || warn "Re-merge failed — run 'systemd-sysext merge' manually"
    fi

    restore_nvidia_integration
    exit "${rc}"
}

# =============================================================================
# Interactive manager (shown when the script is run with no arguments)
#
# The menu never deploys inline: it re-invokes this same script with the chosen
# image, so a menu-driven deployment runs the exact same code path — and the
# same EXIT trap and rollback — as the command-line one. Nothing about the
# deployment is duplicated here.
# =============================================================================

human_size() { du -h "$1" 2>/dev/null | cut -f1; }

# The driver the running TrueNAS release originally shipped. The build writes it
# next to each built image as nvidia.raw.stock, so restoring the factory driver
# needs no backup — handy once backups have rotated away.
find_stock_image() {
    local f
    for f in "${SCRIPT_DIR}"/output/*/nvidia.raw.stock \
             "${SCRIPT_DIR}"/nvidia.raw.stock \
             "${PWD}"/nvidia.raw.stock; do
        [[ -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
    done
    return 1
}

# Candidate images near the script: build outputs first, then loose files.
# Prints "<path>\t<label>" rows.
discover_images() {
    # Both loops must feed the same sort — piping only the second one would
    # leave the build outputs in raw glob order.
    {
        local f
        for f in "${SCRIPT_DIR}"/output/*/nvidia.raw; do
            [[ -f "${f}" ]] || continue
            local version
            version="$(basename "$(dirname "${f}")")"
            printf '%s\t%s\n' "${f}" "TrueNAS ${version} · $(human_size "${f}")"
        done
        for f in "${SCRIPT_DIR}"/nvidia.raw "${PWD}"/nvidia.raw; do
            [[ -f "${f}" ]] || continue
            printf '%s\t%s\n' "${f}" "loose file · $(human_size "${f}")"
        done
    } | sort -Vru   # version sort, reversed: newest TrueNAS release first
}

action_status() {
    local body="" rc=0
    body="$(report_state 2>&1)" || rc=$?
    ui_textbox "Current state" "${body}"
    return "${rc}"
}

# Hand an image to a fresh run of this script. Keeping this as a child process
# means the deployment keeps its own traps, so an interrupted deploy still rolls
# itself back without the menu having to know anything about it.
launch_deployment() {
    local image="$1" mode="${2:-apply}"
    local -a cmd=("${SELF}")
    [[ "${mode}" == "dry" ]] && cmd+=(--dry-run)
    cmd+=("${image}")

    echo ""
    "${cmd[@]}" && return 0 || return $?
}

action_deploy() {
    local -a rows=() menu=()
    mapfile -t rows < <(discover_images)

    local row path label
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r path label <<< "${row}"
        menu+=("${path}" "${label}")
    done
    menu+=("MANUAL" "Enter a path manually")

    local choice=""
    ui_menu choice "Deploy an image" \
        "Select the nvidia.raw to install:" "${menu[@]}" || return 0

    if [[ "${choice}" == "MANUAL" ]]; then
        if [[ "${UI_MODE}" == "whiptail" ]]; then
            wt_size
            choice="$(whiptail --title "Deploy an image" --inputbox \
                "Full path to nvidia.raw:" $((WT_HEIGHT / 2)) "${WT_WIDTH}" "" \
                3>&1 1>&2 2>&3)" || return 0
        else
            read -r -p "  Full path to nvidia.raw: " choice
        fi
    fi

    [[ -n "${choice}" ]] || return 0
    [[ -f "${choice}" ]] || { ui_textbox "Not found" "No such file:\n  ${choice}"; return 0; }

    # Show the full path: every candidate is called nvidia.raw, so the basename
    # alone would not say which one is about to be installed.
    local mode=""
    ui_menu mode "Deploy an image" \
        "${choice}  ($(human_size "${choice}"))\n\nWhat should happen?" \
        "apply" "Deploy it now" \
        "dry"   "Dry run — show every step, change nothing" || return 0

    if [[ "${mode}" == "apply" ]]; then
        [[ $(id -u) -eq 0 ]] || {
            ui_textbox "Root required" "Deploying needs root. Re-run this script with sudo."
            return 0
        }
        ui_yesno "Confirm deployment" \
            "Install this image as the system NVIDIA driver?\n\n  ${choice}\n\nThe current image is backed up first and restored automatically if anything fails." \
            || return 0
    fi

    launch_deployment "${choice}" "${mode}" || true
    echo ""
    read -r -p "  Press Enter to return to the menu … " _ || true
}

action_rollback() {
    local -a backups=()
    # Sorted by the timestamp in the filename, not mtime: copying a backup
    # around changes its mtime but not when it was actually taken.
    mapfile -t backups < <(ls -1 "${BACKUP_DIR}"/nvidia.raw.backup_* 2>/dev/null | sort -r || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        ui_textbox "No backups" \
            "No backups in:\n  ${BACKUP_DIR}\n\nA backup of the current image is taken automatically on every deployment."
        return 0
    fi

    local -a menu=()
    local b stamp
    for b in "${backups[@]}"; do
        # nvidia.raw.backup_20260724_160428 → 2026-07-24 16:04:28
        stamp="$(basename "${b}" | sed -E 's/^nvidia\.raw\.backup_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$/\1-\2-\3 \4:\5:\6/')"
        menu+=("${b}" "${stamp} · $(human_size "${b}")")
    done

    local choice=""
    ui_menu choice "Roll back" \
        "Backups are listed newest first:" "${menu[@]}" || return 0
    [[ -n "${choice}" ]] || return 0

    [[ $(id -u) -eq 0 ]] || {
        ui_textbox "Root required" "Rolling back needs root. Re-run this script with sudo."
        return 0
    }

    ui_yesno "Confirm rollback" \
        "Restore this backup as the system NVIDIA driver?\n\n  $(basename "${choice}")\n\nThe image currently installed is backed up first." \
        || return 0

    launch_deployment "${choice}" "apply" || true
    echo ""
    read -r -p "  Press Enter to return to the menu … " _ || true
}

# =============================================================================
# Surviving TrueNAS updates
#
# An update replaces the whole /usr dataset, so the custom nvidia.raw is gone
# and the stock driver is back. /etc is recreated too, so nothing there can be
# relied on either. What does survive is (a) the data pools and (b) middleware's
# own database — so a copy of the image lives on a pool and a PREINIT init
# script, registered through midclt, puts it back on every boot.
#
# The important subtlety: a TrueNAS update usually changes the KERNEL too, and
# the modules inside the image are built for one exact kernel release. Blindly
# restoring would merge modules with the wrong vermagic — they simply refuse to
# load, and the failure is opaque. So the boot script compares kernels first and
# refuses to restore on a mismatch, logging that a rebuild is needed instead.
# =============================================================================

PERSIST_MARKER="truenas-nvidia-driver-updater"
PERSIST_SUBDIR=".config/${PERSIST_MARKER}"

# Datasets mounted directly under /mnt are the pools available to store on.
list_data_pools() {
    zfs list -H -o name,mountpoint 2>/dev/null \
        | awk -F'\t' '$2 ~ /^\/mnt\/[^\/]+$/ { print $2 }' \
        | sed 's|^/mnt/||' | sort -u
}

# Query middleware for our registered PREINIT entry; prints "<id>\t<command>".
# The script comes in on a quoted heredoc and the data through argv: inside a
# single-quoted `python3 -c '…'` the shell keeps backslashes literal, so any
# \" escape reaches Python verbatim and it dies on a syntax error.
find_persist_entry() {
    command -v midclt >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    # Named entry_json, not rows: `rows` is an array in action_deploy and the
    # shadowing reads as a bug even though the locals are independent.
    local entry_json=""
    entry_json="$( { midclt call initshutdownscript.query 2>/dev/null || true; } )" || true
    [[ -n "${entry_json}" ]] || return 1

    local found=""
    found="$(python3 - "${entry_json}" "${PERSIST_MARKER}" <<'PY' 2>/dev/null || true
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
marker = sys.argv[2]
for r in rows if isinstance(rows, list) else []:
    haystack = "{} {}".format(r.get("comment", ""), r.get("command", ""))
    if marker in haystack:
        print("{}\t{}".format(r.get("id"), r.get("command", "")))
PY
)"

    [[ -n "${found}" ]] || return 1
    printf '%s' "${found}"
}

persist_status() {
    local entry=""
    entry="$(find_persist_entry)" || true
    [[ -n "${entry}" ]] || { printf 'not configured'; return 1; }
    printf '%s' "${entry#*$'\t'}"
}

# Write the boot script. It is standalone on purpose: after an update the only
# thing guaranteed to still exist is this directory on the pool.
write_preinit_script() {
    local dir="$1" target_kernel="$2" driver="$3"

    cat > "${dir}/preinit.sh" <<PREINIT
#!/bin/bash
# Generated by deploy-nvidia.sh — restores the custom NVIDIA driver after a
# TrueNAS update wipes /usr. Registered as a PREINIT init script; the entry
# lives in the middleware database, which survives updates.
#
# Driver:        ${driver}
# Built for:     ${target_kernel}
set -uo pipefail

CONFIG_DIR="${dir}"
IMAGE="\${CONFIG_DIR}/nvidia.raw"
TARGET_KERNEL="${target_kernel}"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
SYSEXT="\${SYSEXT_DIR}/nvidia.raw"

log() { logger -t nvidia-persist -- "\$*" 2>/dev/null; echo "nvidia-persist: \$*"; }

# PREINIT runs after the pools are mounted, so a missing image means the pool
# is gone or the copy was deleted — nothing to do either way.
[[ -f "\${IMAGE}" ]] || { log "no image at \${IMAGE} — nothing to restore"; exit 0; }

# Refuse to install anything that isn't a squashfs. A truncated or corrupted
# copy would otherwise be merged at boot, which fails in confusing ways.
if [[ "\$(head -c 4 "\${IMAGE}" 2>/dev/null)" != "hsqs" ]]; then
    log "\${IMAGE} is not a squashfs image (bad magic) — refusing to restore it"
    exit 1
fi

RUNNING_KERNEL="\$(uname -r)"
if [[ "\${RUNNING_KERNEL}" != "\${TARGET_KERNEL}" ]]; then
    log "kernel is now \${RUNNING_KERNEL} but the saved driver was built for \${TARGET_KERNEL}."
    log "NOT restoring: the modules would not load. Rebuild the driver for \${RUNNING_KERNEL}"
    log "and redeploy, then re-run 'deploy-nvidia.sh --persist'."
    exit 0
fi

# Size first: these images are a few hundred MB, and after an update the stock
# driver that replaced ours almost never matches in size — so the common case
# costs a stat instead of reading both files end to end.
NEEDS_RESTORE=1
if [[ -f "\${SYSEXT}" ]]; then
    if [[ "\$(stat -c%s "\${IMAGE}" 2>/dev/null)" == "\$(stat -c%s "\${SYSEXT}" 2>/dev/null)" ]] \\
        && cmp -s "\${IMAGE}" "\${SYSEXT}"; then
        NEEDS_RESTORE=0
    fi
fi

if [[ \${NEEDS_RESTORE} -eq 0 ]]; then
    log "custom driver already in place"
else
    log "restoring custom driver into \${SYSEXT}"
    USR_DATASET="\$(zfs list -H -o name /usr 2>/dev/null)"
    [[ -n "\${USR_DATASET}" ]] || { log "could not resolve the /usr dataset — aborting"; exit 1; }

    systemd-sysext unmerge 2>/dev/null || true
    if ! zfs set readonly=off "\${USR_DATASET}"; then
        log "could not unlock \${USR_DATASET} — aborting"
        systemd-sysext merge 2>/dev/null || true
        exit 1
    fi
    mkdir -p "\${SYSEXT_DIR}"
    cp "\${IMAGE}" "\${SYSEXT}" && chmod 644 "\${SYSEXT}" || log "copy failed"
    zfs set readonly=on "\${USR_DATASET}" || log "failed to re-lock \${USR_DATASET}"
fi

# /usr/share/truenas/sysext-extensions is storage only — activation is a symlink
# in a search path. /etc is recreated by an update, so re-create it if missing.
if [[ ! -e /etc/extensions/nvidia.raw ]] && [[ ! -e /run/extensions/nvidia.raw ]]; then
    mkdir -p /run/extensions && ln -sf "\${SYSEXT}" /run/extensions/nvidia.raw
    log "created activation symlink in /run/extensions"
fi

systemd-sysext merge 2>/dev/null || systemd-sysext refresh 2>/dev/null || log "merge/refresh failed"
ldconfig 2>/dev/null || true
modprobe nvidia 2>/dev/null || true
log "done"
PREINIT

    chmod +x "${dir}/preinit.sh"
}

action_persist() {
    command -v midclt >/dev/null 2>&1 || {
        ui_textbox "Not available" "midclt isn't present — this only works on a TrueNAS system."
        return 0
    }
    [[ $(id -u) -eq 0 ]] || {
        ui_textbox "Root required" "Setting this up needs root. Re-run this script with sudo."
        return 0
    }
    [[ -f "${NVIDIA_RAW}" ]] || {
        ui_textbox "Nothing installed" "There is no ${NVIDIA_RAW} to protect. Deploy an image first."
        return 0
    }

    local target_kernel driver
    target_kernel="$(image_target_kernel "${NVIDIA_RAW}")"
    driver="$(image_driver_version "${NVIDIA_RAW}")"
    if [[ -z "${target_kernel}" ]]; then
        ui_textbox "Cannot read the image" \
            "Couldn't determine which kernel ${NVIDIA_RAW} was built for, so the boot script would have no way to tell a rebuild is needed. Refusing to set this up."
        return 0
    fi

    # ── Pick a pool ─────────────────────────────────────────────────────────
    local -a pools=()
    mapfile -t pools < <(list_data_pools)
    if [[ ${#pools[@]} -eq 0 ]]; then
        ui_textbox "No data pool" \
            "No ZFS pool is mounted under /mnt. The image has to live on a data pool to survive an update — the boot pool is replaced."
        return 0
    fi

    local pool=""
    if [[ ${#pools[@]} -eq 1 ]]; then
        pool="${pools[0]}"
    else
        local -a menu=() p
        for p in "${pools[@]}"; do menu+=("${p}" "/mnt/${p}"); done
        ui_menu pool "Where to store it" \
            "Which pool should hold the rescue copy?" "${menu[@]}" || return 0
    fi
    [[ -n "${pool}" ]] || return 0

    local dir="/mnt/${pool}/${PERSIST_SUBDIR}"

    ui_yesno "Survive TrueNAS updates" \
        "A copy of the running driver will be kept at:\n  ${dir}\n\nand a PREINIT script registered with middleware to put it back after an update wipes /usr.\n\nDriver ${driver:-unknown}, built for ${target_kernel}.\n\nIf an update also changes the kernel, the script deliberately does NOT restore — it logs that a rebuild is needed instead." \
        || return 0

    mkdir -p "${dir}" || { ui_textbox "Failed" "Could not create ${dir}"; return 0; }
    cp "${NVIDIA_RAW}" "${dir}/nvidia.raw" \
        || { ui_textbox "Failed" "Could not copy the image to ${dir}"; return 0; }
    write_preinit_script "${dir}" "${target_kernel}" "${driver:-unknown}"

    # Replace any entry we registered before, so re-running just updates it.
    local existing=""
    existing="$(find_persist_entry)" || true
    if [[ -n "${existing}" ]]; then
        local old_id="${existing%%$'\t'*}"
        midclt call initshutdownscript.delete "${old_id}" >/dev/null 2>&1 || true
    fi

    local payload
    payload="$(python3 -c '
import json, sys
print(json.dumps({
    "type": "COMMAND",
    "command": sys.argv[1],
    "when": "PREINIT",
    "enabled": True,
    "timeout": 300,
    "comment": sys.argv[2],
}))' "${dir}/preinit.sh" "Restore custom NVIDIA driver (${PERSIST_MARKER})")"

    if midclt call -j initshutdownscript.create "${payload}" >/dev/null 2>&1; then
        ui_textbox "Set up" \
            "The driver will be restored automatically after a TrueNAS update.\n\n  copy:   ${dir}/nvidia.raw\n  script: ${dir}/preinit.sh\n  driver: ${driver:-unknown} (kernel ${target_kernel})\n\nAfter an update that changes the kernel, rebuild for the new kernel, redeploy, then run this again to refresh the saved copy.\n\nBoot messages appear under: journalctl -t nvidia-persist"
    else
        ui_textbox "Registration failed" \
            "The files were written to ${dir} but registering the PREINIT script with middleware failed.\n\nRegister it by hand in the UI: System → Advanced → Init/Shutdown Scripts, type Command, when PREINIT:\n  ${dir}/preinit.sh"
    fi
}

action_unpersist() {
    local entry=""
    entry="$(find_persist_entry)" || true

    if [[ -z "${entry}" ]]; then
        ui_textbox "Not configured" "No update-persistence entry is registered."
        return 0
    fi
    [[ $(id -u) -eq 0 ]] || {
        ui_textbox "Root required" "Removing this needs root. Re-run this script with sudo."
        return 0
    }

    # entry_cmd, not cmd: launch_deployment uses `cmd` as an array.
    local id="${entry%%$'\t'*}" entry_cmd="${entry#*$'\t'}"
    ui_yesno "Stop surviving updates" \
        "Remove the PREINIT entry so the driver is NOT restored after a TrueNAS update?\n\n  ${entry_cmd}\n\nThe saved copy on the pool is left in place." \
        || return 0

    if midclt call initshutdownscript.delete "${id}" >/dev/null 2>&1; then
        ui_textbox "Removed" "The PREINIT entry is gone. The saved copy is still at:\n  $(dirname "${entry_cmd}")\n\nDelete that directory yourself if you don't want it."
    else
        ui_textbox "Failed" "Could not remove the entry (id ${id}). Remove it in System → Advanced → Init/Shutdown Scripts."
    fi
}

action_uninstall() {
    local stock=""
    if ! stock="$(find_stock_image)"; then
        ui_textbox "No stock image" \
            "Couldn't find a nvidia.raw.stock next to this script or under output/.\n\nIt is written by the build, alongside the image it produces. Run a build for this TrueNAS version to obtain one, or roll back to a backup instead."
        return 0
    fi

    [[ $(id -u) -eq 0 ]] || {
        ui_textbox "Root required" "Restoring the stock driver needs root. Re-run this script with sudo."
        return 0
    }

    ui_yesno "Restore the stock driver" \
        "Put the driver this TrueNAS release originally shipped back in place?\n\n  ${stock}\n\nThe image currently installed is backed up first, so this is reversible." \
        || return 0

    launch_deployment "${stock}" "apply" || true
    echo ""
    read -r -p "  Press Enter to return to the menu … " _ || true
}

run_manager() {
    detect_ui_mode

    if [[ "${UI_MODE}" != "whiptail" ]]; then
        echo ""
        echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  TrueNAS NVIDIA Driver Manager${NC}"
        echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    fi

    while true; do
        # Re-read each pass: the label has to follow what the last action did.
        local persist_state="off" persist_label="Survive TrueNAS updates (off)"
        if persist_status >/dev/null 2>&1; then
            persist_state="on"
            persist_label="Survive TrueNAS updates (ON — select to turn off)"
        fi

        local action=""
        ui_menu action "TrueNAS NVIDIA Driver Manager" \
            "What would you like to do?" \
            "status"    "Show the current driver / sysext state" \
            "deploy"    "Deploy an nvidia.raw image" \
            "rollback"  "Roll back to a previous image" \
            "uninstall" "Restore the driver TrueNAS shipped with" \
            "persist"   "${persist_label}" \
            "quit"      "Exit" \
            || return 0

        case "${action}" in
            status)    action_status || true ;;
            deploy)    action_deploy ;;
            rollback)  action_rollback ;;
            uninstall) action_uninstall ;;
            persist)   if [[ "${persist_state}" == "on" ]]; then
                           action_unpersist
                       else
                           action_persist
                       fi ;;
            quit|"")   return 0 ;;
        esac
    done
}

# ── Parse arguments ─────────────────────────────────────────────────────────
NEW_RAW=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        --check)        CHECK_ONLY=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
        --persist)      PERSIST_ACTION="on"; shift ;;
        --unpersist)    PERSIST_ACTION="off"; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --no-whiptail)  FORCE_BASH=true; shift ;;
        -*)             die "Unknown option: $1 (see --help)" ;;
        *)
            [[ -z "${NEW_RAW}" ]] || die "Only one image can be given (got '${NEW_RAW}' and '$1')"
            NEW_RAW="$1"; shift ;;
    esac
done

# The mode flags each own the whole run, so combining them is always a mistake —
# say so instead of silently honouring whichever is checked first.
MODE_COUNT=$(( CHECK_ONLY + UNINSTALL ))
[[ -n "${PERSIST_ACTION}" ]] && MODE_COUNT=$(( MODE_COUNT + 1 ))
[[ ${MODE_COUNT} -le 1 ]] || die "Use only one of --check, --uninstall, --persist, --unpersist"

# --check mutates nothing, so it does not demand root — it just reports less.
if [[ ${CHECK_ONLY} -eq 1 ]]; then
    [[ -z "${NEW_RAW}" ]] || die "--check takes no image argument"
    [[ $(id -u) -eq 0 ]] || warn "Not running as root — some values may be unavailable"
    report_state
    exit $?
fi

# Persistence setup mutates nothing about the installed driver, so it runs on
# its own and exits — the same code the menu entry uses.
if [[ -n "${PERSIST_ACTION}" ]]; then
    [[ -z "${NEW_RAW}" ]] || die "--persist/--unpersist take no image argument"
    detect_ui_mode
    if [[ "${PERSIST_ACTION}" == "on" ]]; then
        action_persist
    else
        action_unpersist
    fi
    exit 0
fi

# --uninstall is an ordinary deployment of the stock image, so it inherits the
# backup, rollback and trap behaviour rather than being a separate code path.
if [[ ${UNINSTALL} -eq 1 ]]; then
    [[ -z "${NEW_RAW}" ]] || die "--uninstall takes no image argument"
    NEW_RAW="$(find_stock_image)" || die \
"No nvidia.raw.stock found next to this script or under output/.
It is written by the build alongside the image it produces — run a build for
this TrueNAS version to obtain one, or roll back to a backup instead."
    info "Restoring the driver this TrueNAS release shipped: ${NEW_RAW}"
fi

# No image and nothing else to do → interactive manager.
if [[ -z "${NEW_RAW}" ]] && [[ ${DRY_RUN} -eq 0 ]]; then
    [[ $(id -u) -eq 0 ]] || warn "Not running as root — the menu can inspect, but not deploy"
    run_manager
    exit 0
fi

# ── Validate input ──────────────────────────────────────────────────────────
[[ -n "${NEW_RAW}" ]] || { usage >&2; die "--dry-run needs an image path"; }
[[ $(id -u) -eq 0 ]] || die "This script must be run as root."
[[ -f "${NEW_RAW}" ]] || die "File not found: ${NEW_RAW}"

if [[ ${DRY_RUN} -eq 1 ]]; then
    echo ""
    warn "DRY RUN — every mutating command below is printed, not executed"
    echo ""
fi

NEW_SIZE=$(stat -c%s "${NEW_RAW}" 2>/dev/null || echo "unknown")
info "New image: ${NEW_RAW} (${NEW_SIZE} bytes)"
info "Will install as: ${NVIDIA_RAW}"
info "Backup dir: ${BACKUP_DIR}"

# Arm the safety net only once the arguments are known to be sane — nothing
# before this point has modified the system.
trap cleanup EXIT
trap 'echo ""; warn "Interrupted"; exit 130' INT TERM

# ── Step 1: Disable TrueNAS's Docker NVIDIA integration ─────────────────────
disable_nvidia_integration

# ── Step 2: Unmerge active sysext ───────────────────────────────────────────
info "Unmerging active sysext extensions …"
run_cmd systemd-sysext unmerge
UNMERGED=1
ok "Extensions unmerged"

# ── Step 3: Unlock /usr ZFS dataset ─────────────────────────────────────────
USR_DATASET="$(zfs list -H -o name /usr)"
info "Unlocking ZFS dataset: ${USR_DATASET}"
run_cmd zfs set readonly=off "${USR_DATASET}"
ok "Dataset unlocked (readonly=off)"

# ── Step 4: Backup existing nvidia.raw ──────────────────────────────────────
if [[ -f "${NVIDIA_RAW}" ]]; then
    run_cmd mkdir -p "${BACKUP_DIR}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP="${BACKUP_DIR}/nvidia.raw.backup_${TIMESTAMP}"

    # The timestamp only has second resolution, so two deployments in the same
    # second would land on the same filename. That silently destroys the older
    # backup — and when rolling back, the file being restored lives in this very
    # directory, so the backup step could overwrite its own source before the
    # copy reads it. Never reuse an existing name.
    if [[ -e "${BACKUP}" ]]; then
        BACKUP_SEQ=2
        while [[ -e "${BACKUP}_${BACKUP_SEQ}" ]]; do
            BACKUP_SEQ=$((BACKUP_SEQ + 1))
        done
        BACKUP="${BACKUP}_${BACKUP_SEQ}"
    fi

    info "Backing up existing nvidia.raw → ${BACKUP}"
    run_cmd cp "${NVIDIA_RAW}" "${BACKUP}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        ok "Backup would be saved: ${BACKUP}"
    else
        ok "Backup saved: ${BACKUP} ($(du -h "${BACKUP}" | cut -f1))"
    fi

    # Keep only the 5 most recent backups
    # ls exits non-zero when the glob matches nothing (first-ever deploy), and
    # pipefail would propagate that — swallow it so the count is just 0.
    BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/nvidia.raw.backup_* 2>/dev/null | wc -l || true)
    if [[ ${BACKUP_COUNT} -gt 5 ]]; then
        info "Cleaning old backups (keeping 5 most recent) …"
        ls -1 "${BACKUP_DIR}"/nvidia.raw.backup_* | sort -r | tail -n +6 | while read -r old; do
            info "  Removing: $(basename "${old}")"
            run_cmd rm -f "${old}"
        done
    fi
else
    warn "No existing nvidia.raw found — fresh install"
fi

# ── Step 5: Copy new nvidia.raw ────────────────────────────────────────────
info "Installing new nvidia.raw …"
run_cmd cp "${NEW_RAW}" "${NVIDIA_RAW}"
run_cmd chmod 644 "${NVIDIA_RAW}"
if [[ ${DRY_RUN} -eq 1 ]]; then
    ok "Would install: ${NVIDIA_RAW}"
else
    ok "Installed: ${NVIDIA_RAW} ($(stat -c%s "${NVIDIA_RAW}") bytes)"
fi

# ── Step 6: Re-lock /usr and merge ──────────────────────────────────────────
info "Locking ZFS dataset: ${USR_DATASET}"
run_cmd zfs set readonly=on "${USR_DATASET}"
ok "Dataset locked (readonly=on)"

info "Merging sysext extensions …"
if ! run_cmd systemd-sysext merge; then
    print_sysext_diagnostics "${NVIDIA_RAW}"
    rollback_to_previous_state "${BACKUP}"
    die "systemd-sysext merge failed — the new nvidia.raw was rejected. The previous state has been restored; see diagnostics above."
fi
ok "Extensions merged"

# The image is in place, so /usr is consistent again — from here on a failure
# must not roll the new driver back out.
USR_DATASET=""
UNMERGED=0

# ── Step 7: Re-enable TrueNAS's Docker NVIDIA integration ───────────────────
# Done before the activation check: middleware recreates its own /etc/extensions
# symlink here, so only a genuinely unmanaged system needs the /run fallback.
restore_nvidia_integration

# ── Step 8: Make sure the extension is activated and its libraries visible ──
ensure_extension_activated
refresh_linker_cache

# ── Step 9: Unload the old driver's kernel modules ──────────────────────────
unload_nvidia_modules

DEPLOY_COMPLETE=1

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [[ ${DRY_RUN} -eq 1 ]]; then
    echo -e "${GREEN}${BOLD}  ✓ Dry run complete — nothing was changed${NC}"
    echo ""
    echo -e "  Re-run without ${CYAN}--dry-run${NC} to apply, or ${CYAN}--check${NC} to inspect the current state."
    echo ""
    exit 0
fi
echo -e "${GREEN}${BOLD}  ✓ nvidia.raw deployed successfully${NC}"
echo ""
if [[ ${REBOOT_REQUIRED} -eq 1 ]]; then
    echo -e "  ${YELLOW}Reboot required${NC} — the old NVIDIA modules are still in use."
else
    echo -e "  Verify with:  ${CYAN}nvidia-smi${NC}   (loads the new modules on first run)"
fi
echo ""

# List current backups
BACKUP_LIST=$(ls -1 "${BACKUP_DIR}"/nvidia.raw.backup_* 2>/dev/null | sort -r || true)
if [[ -n "${BACKUP_LIST}" ]]; then
    echo -e "  ${BOLD}Available rollback backups:${NC}"
    echo "${BACKUP_LIST}" | while read -r b; do
        SIZE=$(du -h "${b}" | cut -f1)
        echo -e "    $(basename "${b}")  (${SIZE})"
    done
    echo ""
    echo -e "  To rollback:  ${CYAN}$0 ${BACKUP_DIR}/nvidia.raw.backup_YYYYMMDD_HHMMSS${NC}"
    echo ""
fi
