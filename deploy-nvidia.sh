#!/bin/bash
# =============================================================================
# deploy-nvidia.sh — Deploy nvidia.raw sysext to TrueNAS
#
# Usage:  ./deploy-nvidia.sh <path-to-nvidia.raw>
#
# This script:
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

# ── Deployment state (read by the EXIT trap) ────────────────────────────────
USR_DATASET=""          # set once /usr has been unlocked; empty = never touched
BACKUP=""               # previous nvidia.raw, empty on a fresh install
UNMERGED=0              # 1 once sysext extensions have been unmerged
ROLLED_BACK=0           # 1 once a rollback has already run (don't repeat it)
NVIDIA_INTEGRATION_OFF=0  # 1 while TrueNAS's Docker NVIDIA support is disabled
REBOOT_REQUIRED=0       # 1 when old modules could not be unloaded
DEPLOY_COMPLETE=0       # 1 once everything succeeded

# ── Helpers ─────────────────────────────────────────────────────────────────

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
    if midclt call -j docker.update '{"nvidia": false}' >/dev/null 2>&1; then
        NVIDIA_INTEGRATION_OFF=1
        ok "Docker NVIDIA integration disabled (will be re-enabled at the end)"
    else
        warn "Could not disable Docker NVIDIA integration — continuing anyway"
    fi
}

restore_nvidia_integration() {
    [[ ${NVIDIA_INTEGRATION_OFF} -eq 1 ]] || return 0

    info "Re-enabling TrueNAS Docker NVIDIA integration …"
    if midclt call -j docker.update '{"nvidia": true}' >/dev/null 2>&1; then
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
        if rmmod "${m}" 2>/dev/null; then
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

    if mkdir -p /run/extensions && ln -sf "${NVIDIA_RAW}" /run/extensions/nvidia.raw; then
        systemd-sysext refresh || warn "systemd-sysext refresh failed"
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
    ldconfig || warn "ldconfig failed — new NVIDIA libraries may not resolve until reboot"
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

    systemd-sysext unmerge 2>/dev/null || true

    if zfs set readonly=off "${USR_DATASET}" 2>/dev/null; then
        if [[ -n "${backup}" ]] && [[ -f "${backup}" ]]; then
            info "Restoring previous nvidia.raw from $(basename "${backup}")"
            if cp "${backup}" "${NVIDIA_RAW}" && chmod 644 "${NVIDIA_RAW}"; then
                :
            else
                warn "Could not restore ${NVIDIA_RAW} from ${backup}"
                failed=1
            fi
        else
            info "No previous nvidia.raw to restore (fresh install) — removing the rejected image"
            rm -f "${NVIDIA_RAW}" || { warn "Could not remove ${NVIDIA_RAW}"; failed=1; }
        fi
    else
        warn "Could not unlock ${USR_DATASET} — leaving ${NVIDIA_RAW} untouched"
        failed=1
    fi

    zfs set readonly=on "${USR_DATASET}" 2>/dev/null \
        || { warn "Failed to re-lock ${USR_DATASET}"; failed=1; }

    systemd-sysext merge || { warn "Rollback merge failed"; failed=1; }

    if [[ ${failed} -eq 0 ]]; then
        ok "Rollback complete — system restored to its previous state"
    else
        warn "Rollback was incomplete — check the warnings above; manual recovery may be needed"
        warn "  zfs set readonly=on ${USR_DATASET} && systemd-sysext merge"
    fi
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

    echo ""
    warn "Deployment did not complete (exit code ${rc}) — restoring previous state …"

    if [[ -n "${USR_DATASET}" ]]; then
        # We got as far as unlocking /usr, so the image may have been touched.
        [[ ${ROLLED_BACK} -eq 1 ]] || rollback_to_previous_state "${BACKUP}"
    elif [[ ${UNMERGED} -eq 1 ]]; then
        # Extensions were unmerged but nothing was modified — just merge back.
        info "Re-merging sysext extensions …"
        systemd-sysext merge || warn "Re-merge failed — run 'systemd-sysext merge' manually"
    fi

    restore_nvidia_integration
    exit "${rc}"
}

# ── Validate input ──────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || die "Usage: $0 <path-to-nvidia.raw>"
[[ $(id -u) -eq 0 ]] || die "This script must be run as root."

NEW_RAW="$1"
[[ -f "${NEW_RAW}" ]] || die "File not found: ${NEW_RAW}"

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
systemd-sysext unmerge
UNMERGED=1
ok "Extensions unmerged"

# ── Step 3: Unlock /usr ZFS dataset ─────────────────────────────────────────
USR_DATASET="$(zfs list -H -o name /usr)"
info "Unlocking ZFS dataset: ${USR_DATASET}"
zfs set readonly=off "${USR_DATASET}"
ok "Dataset unlocked (readonly=off)"

# ── Step 4: Backup existing nvidia.raw ──────────────────────────────────────
if [[ -f "${NVIDIA_RAW}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP="${BACKUP_DIR}/nvidia.raw.backup_${TIMESTAMP}"
    info "Backing up existing nvidia.raw → ${BACKUP}"
    cp "${NVIDIA_RAW}" "${BACKUP}"
    ok "Backup saved: ${BACKUP} ($(du -h "${BACKUP}" | cut -f1))"

    # Keep only the 5 most recent backups
    # ls exits non-zero when the glob matches nothing (first-ever deploy), and
    # pipefail would propagate that — swallow it so the count is just 0.
    BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/nvidia.raw.backup_* 2>/dev/null | wc -l || true)
    if [[ ${BACKUP_COUNT} -gt 5 ]]; then
        info "Cleaning old backups (keeping 5 most recent) …"
        ls -1t "${BACKUP_DIR}"/nvidia.raw.backup_* | tail -n +6 | while read -r old; do
            info "  Removing: $(basename "${old}")"
            rm -f "${old}"
        done
    fi
else
    warn "No existing nvidia.raw found — fresh install"
fi

# ── Step 5: Copy new nvidia.raw ────────────────────────────────────────────
info "Installing new nvidia.raw …"
cp "${NEW_RAW}" "${NVIDIA_RAW}"
chmod 644 "${NVIDIA_RAW}"
ok "Installed: ${NVIDIA_RAW} ($(stat -c%s "${NVIDIA_RAW}") bytes)"

# ── Step 6: Re-lock /usr and merge ──────────────────────────────────────────
info "Locking ZFS dataset: ${USR_DATASET}"
zfs set readonly=on "${USR_DATASET}"
ok "Dataset locked (readonly=on)"

info "Merging sysext extensions …"
if ! systemd-sysext merge; then
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
echo -e "${GREEN}${BOLD}  ✓ nvidia.raw deployed successfully${NC}"
echo ""
if [[ ${REBOOT_REQUIRED} -eq 1 ]]; then
    echo -e "  ${YELLOW}Reboot required${NC} — the old NVIDIA modules are still in use."
else
    echo -e "  Verify with:  ${CYAN}nvidia-smi${NC}   (loads the new modules on first run)"
fi
echo ""

# List current backups
BACKUP_LIST=$(ls -1t "${BACKUP_DIR}"/nvidia.raw.backup_* 2>/dev/null || true)
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
