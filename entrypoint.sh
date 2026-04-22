#!/bin/bash
# =============================================================================
# entrypoint.sh — Build a systemd-sysext nvidia.raw for TrueNAS SCALE
#
# Runs inside a privileged Debian 12 (Bookworm) container.
#
# Required environment variables:
#   NVIDIA_VERSION     — NVIDIA driver version (e.g. 595.58.03)
#   TRUENAS_VERSION    — TrueNAS SCALE version (e.g. 25.10.0)
#   TRUENAS_CODENAME   — TrueNAS SCALE codename (e.g. Goldeye)
#
# Optional:
#   /workspace/truenas.update — Pre-downloaded update file (skips download)
#   /output                   — Bind-mounted output directory
#
# Download URL pattern:
#   https://download.truenas.com/TrueNAS-SCALE-{CODENAME}/{VERSION}/
#   TrueNAS-SCALE-{VERSION}.update?download=1
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── colour helpers for log output ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
banner(){ echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}";
          echo -e "${BOLD}  $*${NC}";
          echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"; }

# ── sanity checks ────────────────────────────────────────────────────────────
banner "NVIDIA sysext builder for TrueNAS SCALE"

: "${NVIDIA_VERSION:?NVIDIA_VERSION environment variable is not set}"
: "${TRUENAS_VERSION:?TRUENAS_VERSION environment variable is not set}"
: "${TRUENAS_CODENAME:?TRUENAS_CODENAME environment variable is not set}"

[[ -d /output ]] \
    || die "/output directory not found. Ensure it is bind-mounted."

# ── Obtain the TrueNAS update file ──────────────────────────────────────────
UPDATE_FILE="/tmp/truenas.update"

if [[ -f /workspace/truenas.update ]]; then
    # Use pre-downloaded file from the workspace (avoids re-downloading ~1.8 GB)
    info "Using pre-existing /workspace/truenas.update"
    UPDATE_FILE="/workspace/truenas.update"
else
    DOWNLOAD_URL="https://download.truenas.com/TrueNAS-SCALE-${TRUENAS_CODENAME}/${TRUENAS_VERSION}/TrueNAS-SCALE-${TRUENAS_VERSION}.update?download=1"
    info "Downloading TrueNAS SCALE ${TRUENAS_VERSION} (${TRUENAS_CODENAME}) update file …"
    info "URL: ${DOWNLOAD_URL}"
    wget -q --show-progress -O "${UPDATE_FILE}" "${DOWNLOAD_URL}" \
        || die "Failed to download TrueNAS update file from ${DOWNLOAD_URL}"
    ok "Downloaded $(du -h "${UPDATE_FILE}" | cut -f1)"
fi

info "NVIDIA driver version : ${NVIDIA_VERSION}"
info "TrueNAS version       : ${TRUENAS_VERSION} (${TRUENAS_CODENAME})"
info "Update file           : ${UPDATE_FILE}"

# ── directory layout ─────────────────────────────────────────────────────────
STAGE1_DIR="/tmp/stage1"          # outer squashfs extraction
ROOTFS_DIR="/tmp/rootfs"          # inner rootfs extraction
BUILD_DIR="/tmp/nvidia_build"     # download + compile (avoids noexec on /workspace)
STAGING_DIR="/tmp/staging"        # final sysext tree

rm -rf "${STAGE1_DIR}" "${ROOTFS_DIR}" "${BUILD_DIR}" "${STAGING_DIR}"
mkdir -p "${STAGE1_DIR}" "${ROOTFS_DIR}" "${BUILD_DIR}" "${STAGING_DIR}"

# =============================================================================
# PHASE 1 — Extract the nested rootfs.squashfs from truenas.update
# =============================================================================
banner "Phase 1: Extracting rootfs.squashfs from truenas.update"

info "Unpacking outer squashfs to find rootfs.squashfs …"
unsquashfs -f -d "${STAGE1_DIR}" "${UPDATE_FILE}" rootfs.squashfs

INNER_SQUASHFS="${STAGE1_DIR}/rootfs.squashfs"
[[ -f "${INNER_SQUASHFS}" ]] \
    || die "rootfs.squashfs was not found inside truenas.update. Aborting."

ok "Found inner rootfs.squashfs ($(du -h "${INNER_SQUASHFS}" | cut -f1))"

# =============================================================================
# PHASE 2 — Extract kernel headers + modules from the inner rootfs
#
#   IMPORTANT — Debian 12 uses usrmerge:  /lib → /usr/lib
#   The ACTUAL module directories live under usr/lib/modules, NOT lib/modules.
#   We also grab usr/src for the kernel headers.
# =============================================================================
banner "Phase 2: Extracting kernel source & modules from rootfs"

info "Extracting usr/src and usr/lib/modules from rootfs.squashfs …"
unsquashfs -f -d "${ROOTFS_DIR}" "${INNER_SQUASHFS}" usr/src usr/lib/modules

# Free the large intermediate squashfs to reclaim disk inside the container
rm -f "${INNER_SQUASHFS}"
ok "Intermediate squashfs removed to save space"

# ── detect the REAL numerical kernel version ─────────────────────────────────
#    Directories inside usr/lib/modules are named with the actual version
#    string (e.g. 6.12.33-production+truenas).  depmod needs this value,
#    NOT the custom header directory name.
#
#    CRITICAL: TrueNAS ships BOTH debug and production kernels but boots
#    the PRODUCTION kernel by default.  Alphabetically "debug" sorts before
#    "production", so a naïve first-match picks the WRONG one and the
#    resulting modules won't load on the running system.
# ─────────────────────────────────────────────────────────────────────────────
info "Scanning for kernel versions in ${ROOTFS_DIR}/usr/lib/modules/ …"
ls -la "${ROOTFS_DIR}/usr/lib/modules/" 2>/dev/null \
    || die "usr/lib/modules is empty or missing"

ALL_KERNEL_VERSIONS=()
for d in "${ROOTFS_DIR}/usr/lib/modules/"*/; do
    kdir="$(basename "$d")"
    if [[ "${kdir}" =~ ^[0-9] ]]; then
        ALL_KERNEL_VERSIONS+=("${kdir}")
        info "  Found kernel: ${kdir}"
    fi
done

[[ ${#ALL_KERNEL_VERSIONS[@]} -gt 0 ]] \
    || die "No kernel version directories found under ${ROOTFS_DIR}/usr/lib/modules/"

# Prefer production kernel — it's what TrueNAS actually boots
KERNEL_VERSION=""
for ver in "${ALL_KERNEL_VERSIONS[@]}"; do
    if [[ "${ver}" != *"debug"* ]]; then
        KERNEL_VERSION="${ver}"
        break
    fi
done

# Fallback to first available if no production kernel found
if [[ -z "${KERNEL_VERSION}" ]]; then
    KERNEL_VERSION="${ALL_KERNEL_VERSIONS[0]}"
    warn "No production kernel found, falling back to: ${KERNEL_VERSION}"
fi

ok "Selected kernel version: ${KERNEL_VERSION}"

if [[ ${#ALL_KERNEL_VERSIONS[@]} -gt 1 ]]; then
    info "Note: ${#ALL_KERNEL_VERSIONS[@]} kernel versions available. Building for '${KERNEL_VERSION}'"
    for ver in "${ALL_KERNEL_VERSIONS[@]}"; do
        if [[ "${ver}" != "${KERNEL_VERSION}" ]]; then
            warn "  Skipping: ${ver}"
        fi
    done
fi

# ── detect kernel headers for the selected kernel ────────────────────────────
#    Strategy 1: Use the 'build' symlink inside the modules directory — this
#                is the canonical pointer to the headers that were used to
#                build the kernel and is always correct.
#    Strategy 2: Fallback — scan /usr/src/ for a matching headers directory
#                by correlating the kernel variant name.
# ─────────────────────────────────────────────────────────────────────────────
info "Scanning for kernel headers in ${ROOTFS_DIR}/usr/src/ …"
ls -la "${ROOTFS_DIR}/usr/src/" 2>/dev/null || die "usr/src is empty or missing"

KERNEL_HEADERS_PATH=""

# Strategy 1: Follow the modules/<ver>/build symlink
BUILD_LINK=$(readlink "${ROOTFS_DIR}/usr/lib/modules/${KERNEL_VERSION}/build" 2>/dev/null || true)
if [[ -n "${BUILD_LINK}" ]]; then
    # The symlink is absolute (e.g. /usr/src/linux-headers-...), prepend rootfs
    CANDIDATE="${ROOTFS_DIR}${BUILD_LINK}"
    if [[ -d "${CANDIDATE}" ]]; then
        KERNEL_HEADERS_PATH="${CANDIDATE}"
        ok "Headers found via modules/build symlink: $(basename "${KERNEL_HEADERS_PATH}")"
    else
        info "build symlink target '${BUILD_LINK}' does not exist in extraction"
    fi
fi

# Strategy 2: Fallback — match by kernel variant name
if [[ -z "${KERNEL_HEADERS_PATH}" ]]; then
    info "Falling back to name-based header matching …"

    # Extract the variant from kernel version (e.g. "production" from "6.12.33-production+truenas")
    KERNEL_VARIANT=""
    if [[ "${KERNEL_VERSION}" =~ -([a-zA-Z]+)\+ ]]; then
        KERNEL_VARIANT="${BASH_REMATCH[1]}"
        info "Kernel variant detected: '${KERNEL_VARIANT}'"
    fi

    # First pass: try to match variant name in headers dir name
    if [[ -n "${KERNEL_VARIANT}" ]]; then
        for d in "${ROOTFS_DIR}"/usr/src/linux-headers-*; do
            [[ -d "$d" ]] || continue
            [[ "$d" == *"-common" ]] && continue
            if [[ "$(basename "$d")" == *"${KERNEL_VARIANT}"* ]]; then
                KERNEL_HEADERS_PATH="$d"
                ok "Headers matched by variant '${KERNEL_VARIANT}': $(basename "$d")"
                break
            fi
        done
    fi

    # Second pass: if no variant match, pick first non-common, non-debug headers
    if [[ -z "${KERNEL_HEADERS_PATH}" ]]; then
        for d in "${ROOTFS_DIR}"/usr/src/linux-headers-*; do
            [[ -d "$d" ]] || continue
            [[ "$d" == *"-common" ]] && continue
            [[ "$d" == *"debug"* ]] && continue
            KERNEL_HEADERS_PATH="$d"
            break
        done
    fi

    # Third pass: last resort — any non-common headers
    if [[ -z "${KERNEL_HEADERS_PATH}" ]]; then
        for d in "${ROOTFS_DIR}"/usr/src/linux-headers-*; do
            [[ -d "$d" ]] || continue
            [[ "$d" == *"-common" ]] && continue
            KERNEL_HEADERS_PATH="$d"
            break
        done
    fi
fi

[[ -n "${KERNEL_HEADERS_PATH}" ]] \
    || die "No linux-headers-* directory found in ${ROOTFS_DIR}/usr/src/"

ok "Kernel headers path: ${KERNEL_HEADERS_PATH}"

ok "Detected kernel version: ${KERNEL_VERSION}"

# ── ensure the Module.symvers file exists ────────────────────────────────────
#    The NVIDIA installer needs Module.symvers to link against.
if [[ -f "${KERNEL_HEADERS_PATH}/Module.symvers" ]]; then
    ok "Module.symvers found in headers directory"
elif [[ -f "${ROOTFS_DIR}/usr/lib/modules/${KERNEL_VERSION}/build/Module.symvers" ]]; then
    warn "Module.symvers not at headers root; symlinking from modules/build"
    ln -sf "${ROOTFS_DIR}/usr/lib/modules/${KERNEL_VERSION}/build/Module.symvers" \
           "${KERNEL_HEADERS_PATH}/Module.symvers"
fi

# =============================================================================
# PHASE 3 — Download the NVIDIA .run installer
# =============================================================================
banner "Phase 3: Downloading NVIDIA ${NVIDIA_VERSION} driver"

cd "${BUILD_DIR}"

RUN_FILE="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}-no-compat32.run"
DOWNLOAD_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${RUN_FILE}"

if [[ -f "${RUN_FILE}" ]]; then
    info "Run file already present, skipping download"
else
    info "Downloading from ${DOWNLOAD_URL} …"
    wget -q --show-progress -c "${DOWNLOAD_URL}" \
        || die "Failed to download ${RUN_FILE}"
fi

chmod +x "${RUN_FILE}"
ok "NVIDIA installer ready: ${BUILD_DIR}/${RUN_FILE}"

# =============================================================================
# PHASE 4 — Snapshot the filesystem, then compile + install the NVIDIA driver
#
#   We take a BEFORE snapshot of every file under /usr and /etc, run the
#   installer, then take an AFTER snapshot.  The diff gives us every single
#   file NVIDIA placed — no glob patterns, no guesswork, nothing missed.
#
#   Installer flags rationale:
#     --silent                          non-interactive
#     --kernel-source-path              TrueNAS's custom-named headers
#     --kernel-name                     real numerical version for depmod
#     --kernel-module-type=open         open-source kernel modules bypass
#                                       MITIGATION_RETHUNK / naked-return
#                                       hard errors on hardened kernels
#     --allow-installation-with-running-driver
#                                       don't abort if host has nvidia.ko
#     --no-rebuild-initramfs            cross-compiling; don't touch initramfs
#     --skip-module-load                don't modprobe inside the container
#     --no-x-check                      no X server in a container
#     --no-nouveau-check                irrelevant inside build container
#     --no-systemd                      skip systemd unit installation
#     --no-backup                       no backup of "previous" driver files
#     --no-drm                          skip nvidia-drm.ko — TrueNAS kernel
#                                       lacks drm_fbdev_ttm_driver_fbdev_probe
#                                       causing "Unknown symbol" at load time
#                                       which cascades into Docker failures.
#                                       DRM/KMS is for display; irrelevant on
#                                       a headless NAS.
#     --install-libglvnd                include GLvnd dispatch libraries
# =============================================================================
banner "Phase 4: Compiling & installing NVIDIA driver"

export CC=gcc
export IGNORE_CC_MISMATCH=1

# ── 4a: BEFORE snapshot ─────────────────────────────────────────────────────
info "Taking pre-install filesystem snapshot …"
find /usr /etc -xdev \( -type f -o -type l \) 2>/dev/null \
    | LC_ALL=C sort > /tmp/fs_before.txt
BEFORE_COUNT=$(wc -l < /tmp/fs_before.txt)
ok "Snapshot captured: ${BEFORE_COUNT} files"

# ── 4b: Install nvidia-container-toolkit (required for Docker GPU support) ──
#    The official TrueNAS NVIDIA extension build installs these packages:
#      permanent_packages = ["libvulkan1", "nvidia-container-toolkit", "vulkan-validationlayers"]
#    nvidia-container-toolkit provides /usr/bin/nvidia-container-runtime which
#    Docker needs to pass GPUs to containers.
# ─────────────────────────────────────────────────────────────────────────────
info "Adding NVIDIA container toolkit APT repository …"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

echo 'deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

info "Installing nvidia-container-toolkit and Vulkan support …"
apt-get update
apt-get install -y --no-install-recommends \
    nvidia-container-toolkit \
    libvulkan1 \
    || die "Failed to install nvidia-container-toolkit"

ok "nvidia-container-toolkit installed"

# Verify the critical binary exists
if [[ -f /usr/bin/nvidia-container-runtime ]]; then
    ok "nvidia-container-runtime binary found"
else
    warn "nvidia-container-runtime not found at /usr/bin/ — checking alternatives"
    find /usr -name 'nvidia-container-runtime' -type f 2>/dev/null | head -5
fi

# ── 4c: Run the NVIDIA driver installer ─────────────────────────────────────
#    Flags closely match the official TrueNAS build:
#      --skip-module-load  --silent  --kernel-name=<ver>
#      --allow-installation-with-running-driver  --no-rebuild-initramfs
#      --kernel-module-type=open
#    Additional flags for our cross-compile container environment:
#      --kernel-source-path  --no-drm  --no-x-check  --no-nouveau-check
#      --no-systemd  --no-backup
# ─────────────────────────────────────────────────────────────────────────────
info "Running NVIDIA installer in silent cross-compile mode …"
"./${RUN_FILE}" \
    --silent \
    --kernel-source-path="${KERNEL_HEADERS_PATH}" \
    --kernel-name="${KERNEL_VERSION}" \
    --kernel-module-type=${NVIDIA_KERNEL_MODULE_TYPE} \
    --allow-installation-with-running-driver \
    --no-rebuild-initramfs \
    --skip-module-load \
    --no-x-check \
    --no-nouveau-check \
    --no-systemd \
    --no-backup \
    --no-drm \
    --install-libglvnd \
    || die "NVIDIA installer failed. Check output above for details."

ok "NVIDIA driver installed successfully"

# ── 4c: AFTER snapshot ──────────────────────────────────────────────────────
info "Taking post-install filesystem snapshot …"
find /usr /etc -xdev \( -type f -o -type l \) 2>/dev/null \
    | LC_ALL=C sort > /tmp/fs_after.txt
AFTER_COUNT=$(wc -l < /tmp/fs_after.txt)

# ── 4d: Compute diff — only NEW files ──────────────────────────────────────
LC_ALL=C comm -13 /tmp/fs_before.txt /tmp/fs_after.txt > /tmp/nvidia_new_files.txt
NEW_FILE_COUNT=$(wc -l < /tmp/nvidia_new_files.txt)

ok "Filesystem diff: ${NEW_FILE_COUNT} new files installed by NVIDIA"

if [[ ${NEW_FILE_COUNT} -eq 0 ]]; then
    die "NVIDIA installer produced zero new files. Something went very wrong."
fi

# Show a summary of what was installed, grouped by top-level directory
info "Installed file breakdown:"
awk -F/ '{
    if ($2 == "usr") {
        if ($3 == "lib" && $4 == "modules") print "  kernel-modules"
        else if ($3 == "lib" && $4 == "firmware") print "  firmware"
        else if ($3 == "lib") print "  libraries"
        else if ($3 == "bin") print "  binaries"
        else if ($3 == "share") print "  data/config"
        else print "  other-usr"
    } else if ($2 == "etc") print "  etc-config"
    else print "  other"
}' /tmp/nvidia_new_files.txt | sort | uniq -c | sort -rn

# =============================================================================
# PHASE 5 — Stage all NVIDIA files into the sysext directory tree
#
#   systemd-sysext merges ONLY /usr (and /opt).  Path translation:
#     /usr/...           → ${STAGING_DIR}/usr/...            (as-is)
#     /etc/OpenCL/...    → ${STAGING_DIR}/usr/share/...      (remap for sysext)
#     /etc/vulkan/...    → ${STAGING_DIR}/usr/share/vulkan/  (remap for sysext)
#     anything else      → logged + skipped
# =============================================================================
banner "Phase 5: Staging sysext directory tree"

STAGED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r src_file; do
    # ── Exclude paths that should NOT be in a runtime sysext image ────────
    #    /usr/src/nvidia-*    DKMS source — can trigger rebuild attempts on target
    #    /usr/share/doc/*     Documentation — unnecessary bloat
    #    /usr/share/man/*     Man pages — unnecessary bloat
    #    *.manifest           NVIDIA installer manifests
    #    /usr/share/licenses  License files — not needed at runtime
    if [[ "${src_file}" == /usr/src/nvidia-* ]] \
    || [[ "${src_file}" == /usr/share/doc/* ]] \
    || [[ "${src_file}" == /usr/share/man/* ]] \
    || [[ "${src_file}" == /usr/share/licenses/* ]] \
    || [[ "${src_file}" == *.manifest ]]; then
        (( SKIPPED_COUNT++ )) || true
        continue
    fi

    # Determine destination path within the staging tree
    dest_path=""

    if [[ "${src_file}" == /usr/* ]]; then
        # /usr/... → staging/usr/... (direct mapping)
        dest_path="${STAGING_DIR}${src_file}"

    elif [[ "${src_file}" == /etc/OpenCL/* ]]; then
        # /etc/OpenCL/vendors/nvidia.icd → staging/usr/share/OpenCL/vendors/nvidia.icd
        # (sysext can't merge /etc, remap to /usr/share)
        relative="${src_file#/etc/}"
        dest_path="${STAGING_DIR}/usr/share/${relative}"

    elif [[ "${src_file}" == /etc/vulkan/* ]]; then
        # /etc/vulkan/... → staging/usr/share/vulkan/...
        relative="${src_file#/etc/}"
        dest_path="${STAGING_DIR}/usr/share/${relative}"

    elif [[ "${src_file}" == /etc/vulkansc/* ]]; then
        # /etc/vulkansc/... → staging/usr/share/vulkansc/...
        relative="${src_file#/etc/}"
        dest_path="${STAGING_DIR}/usr/share/${relative}"

    elif [[ "${src_file}" == /etc/nvidia-container-runtime/* ]]; then
        # nvidia-container-runtime config → /usr/share/nvidia-container-runtime/
        relative="${src_file#/etc/}"
        dest_path="${STAGING_DIR}/usr/share/${relative}"

    elif [[ "${src_file}" == /etc/nvidia-container-toolkit/* ]]; then
        # nvidia-container-toolkit config → /usr/share/nvidia-container-toolkit/
        relative="${src_file#/etc/}"
        dest_path="${STAGING_DIR}/usr/share/${relative}"

    elif [[ "${src_file}" == /etc/systemd/system/* ]]; then
        # systemd units → /usr/lib/systemd/system/ (the correct sysext-mergeable path)
        relative="${src_file#/etc/systemd/system/}"
        dest_path="${STAGING_DIR}/usr/lib/systemd/system/${relative}"

    elif [[ "${src_file}" == /etc/apt/* ]]; then
        # apt repo config — build artifact, not needed on target; skip silently
        (( SKIPPED_COUNT++ )) || true
        continue

    elif [[ "${src_file}" == /etc/* ]]; then
        # Unknown /etc files — log and skip (sysext can only merge /usr)
        info "Skipping /etc file (not needed in sysext): ${src_file}"
        (( SKIPPED_COUNT++ )) || true
        continue

    else
        warn "Unexpected path, skipping: ${src_file}"
        (( SKIPPED_COUNT++ )) || true
        continue
    fi

    # Create parent directory and copy (preserving symlinks)
    dest_dir="$(dirname "${dest_path}")"
    mkdir -p "${dest_dir}"

    if [[ -L "${src_file}" ]]; then
        # Preserve symbolic links as-is
        cp -av "${src_file}" "${dest_path}" 2>/dev/null || true
    elif [[ -f "${src_file}" ]]; then
        cp -av "${src_file}" "${dest_path}" 2>/dev/null || true
    fi

    (( STAGED_COUNT++ )) || true

done < /tmp/nvidia_new_files.txt

ok "Staged ${STAGED_COUNT} files (skipped ${SKIPPED_COUNT})"

# ── 5a: Verify kernel modules were captured ─────────────────────────────────
MODULES_DEST="${STAGING_DIR}/usr/lib/modules/${KERNEL_VERSION}"
KO_COUNT=$(find "${STAGING_DIR}" -name '*.ko' -type f 2>/dev/null | wc -l)

if [[ ${KO_COUNT} -eq 0 ]]; then
    # Fallback: maybe modules went to a different path inside the container
    warn "No .ko files found via diff staging. Searching container filesystem …"
    for search_root in "/lib/modules/${KERNEL_VERSION}" "/usr/lib/modules/${KERNEL_VERSION}"; do
        if [[ -d "${search_root}" ]]; then
            mkdir -p "${MODULES_DEST}/updates/dkms"
            find "${search_root}" -name '*.ko' -type f -exec \
                cp -v {} "${MODULES_DEST}/updates/dkms/" \;
            KO_COUNT=$(find "${MODULES_DEST}" -name '*.ko' -type f | wc -l)
        fi
    done
fi

[[ ${KO_COUNT} -gt 0 ]] \
    || die "No .ko kernel modules found anywhere. Build failed."

ok "Kernel modules present: ${KO_COUNT} .ko file(s)"
info "Module list:"
find "${STAGING_DIR}" -name '*.ko' -type f -exec basename {} \; | sort | sed 's/^/  /'

# ── 5b: Build COMBINED modules.dep (system + nvidia) ────────────────────────
#    PROBLEM: The TrueNAS filesystem is read-only after sysext merge, so
#    running 'depmod -a' on the target is not possible.  But we can't ship
#    a modules.dep that only lists nvidia modules either, because the
#    overlayfs would replace the system's complete module database.
#
#    SOLUTION: We already extracted the FULL usr/lib/modules/<ver>/ tree
#    from the TrueNAS rootfs in Phase 2 (it includes ALL system .ko files).
#    We copy our nvidia .ko files into that tree, run depmod against the
#    COMBINED tree, then ship the resulting modules.* metadata in the sysext.
#
#    The sysext will contain:
#      - modules.dep etc. listing ALL modules (system + nvidia)
#      - nvidia .ko files only (system .ko files come from the base OS layer)
#    When overlayfs merges: modules.dep is comprehensive, system .ko files
#    remain visible from the lower layer, nvidia .ko files from the upper.
# ─────────────────────────────────────────────────────────────────────────────
info "Building combined module database (system + nvidia) …"

# First, remove any nvidia-only modules.* that the before/after diff captured
find "${STAGING_DIR}/usr/lib/modules/" -maxdepth 2 -name 'modules.*' -type f -delete 2>/dev/null || true

# Copy our nvidia .ko files into the extracted rootfs module tree
ROOTFS_MODULES="${ROOTFS_DIR}/usr/lib/modules/${KERNEL_VERSION}"
mkdir -p "${ROOTFS_MODULES}/video"
info "Copying nvidia .ko files into extracted rootfs module tree …"
find "${STAGING_DIR}" -name '*.ko' -type f -exec cp -v {} "${ROOTFS_MODULES}/video/" \;

# Count total modules in the combined tree
SYSTEM_KO_COUNT=$(find "${ROOTFS_MODULES}" -name '*.ko' -type f 2>/dev/null | wc -l)
info "Combined module tree: ${SYSTEM_KO_COUNT} total .ko files (system + nvidia)"

# Run depmod against the COMBINED tree
info "Running depmod against combined module tree …"
if depmod -b "${ROOTFS_DIR}/usr" "${KERNEL_VERSION}"; then
    ok "depmod succeeded"
else
    warn "depmod -b ${ROOTFS_DIR}/usr failed, trying alternate base path …"
    depmod -b "${ROOTFS_DIR}" "${KERNEL_VERSION}" \
        || die "depmod failed against combined module tree"
fi

# Copy the comprehensive modules.* files to staging
STAGING_MODULES="${STAGING_DIR}/usr/lib/modules/${KERNEL_VERSION}"
mkdir -p "${STAGING_MODULES}"
info "Copying combined modules.* metadata to staging …"
for mfile in "${ROOTFS_MODULES}"/modules.*; do
    if [[ -f "${mfile}" ]]; then
        cp -v "${mfile}" "${STAGING_MODULES}/"
    fi
done

MODFILES_COUNT=$(find "${STAGING_MODULES}" -name 'modules.*' -type f | wc -l)
ok "Combined module database shipped (${MODFILES_COUNT} metadata files, covers all ${SYSTEM_KO_COUNT} modules)"

# ── 5c: Verify critical files are present ────────────────────────────────────
info "Verifying critical files …"

check_file() {
    local label="$1" pattern="$2"
    local count
    count=$(find "${STAGING_DIR}" -path "${pattern}" 2>/dev/null | wc -l)
    if [[ ${count} -gt 0 ]]; then
        ok "  ${label} (${count} file(s))"
    else
        warn "  ${label} — NOT FOUND (pattern: ${pattern})"
    fi
}

check_file "nvidia-smi binary"       "*/usr/bin/nvidia-smi"
check_file "libcuda.so"              "*/libcuda.so*"
check_file "libnvidia-ml.so (NVML)"  "*/libnvidia-ml.so*"
check_file "libnvidia-encode (NVENC)" "*/libnvidia-encode.so*"
check_file "libvdpau_nvidia (VDPAU)" "*/libvdpau_nvidia.so*"
check_file "libEGL_nvidia (EGL)"     "*/libEGL_nvidia.so*"
check_file "libGLX_nvidia (GLX)"     "*/libGLX_nvidia.so*"
check_file "libnvcuvid (video dec)"  "*/libnvcuvid.so*"
check_file "Vulkan ICD JSON"         "*/nvidia_icd.json"
check_file "GSP firmware"            "*/firmware/nvidia/*/gsp_*"
check_file "nvidia.ko (MAIN)"       "*/nvidia.ko"
check_file "nvidia-modeset.ko"      "*/nvidia-modeset.ko"
check_file "nvidia-uvm.ko"          "*/nvidia-uvm.ko"
check_file "nvidia-peermem.ko"      "*/nvidia-peermem.ko"
info "  nvidia-drm.ko — intentionally excluded (--no-drm; TrueNAS kernel lacks DRM TTM fbdev)"
check_file "nvidia-container-runtime (Docker GPU)" "*/usr/bin/nvidia-container-runtime"
check_file "nvidia-container-cli"    "*/usr/bin/nvidia-container-cli"
check_file "nvidia-ctk"             "*/usr/bin/nvidia-ctk"
check_file "libnvidia-container.so"  "*/libnvidia-container.so*"

# Hard-fail if the main nvidia.ko module is missing — nothing works without it
MAIN_MODULE=$(find "${STAGING_DIR}" -name 'nvidia.ko' -not -name 'nvidia-*.ko' -type f 2>/dev/null | head -1)
if [[ -z "${MAIN_MODULE}" ]]; then
    die "CRITICAL: nvidia.ko (the main kernel module) is MISSING from the staged image. nvidia-smi will fail."
fi
ok "Main nvidia.ko module confirmed at: ${MAIN_MODULE}"

# ── 5d: Write extension-release metadata ────────────────────────────────────
EXT_RELEASE_DIR="${STAGING_DIR}/usr/lib/extension-release.d"
mkdir -p "${EXT_RELEASE_DIR}"

info "Writing extension-release.nvidia metadata …"
cat <<EOF > "${EXT_RELEASE_DIR}/extension-release.nvidia"
ID=debian
VERSION_ID="12"
EOF
ok "extension-release.nvidia written"

# =============================================================================
# PHASE 6 — Build the final squashfs image
# =============================================================================
banner "Phase 6: Creating nvidia.raw squashfs image"

# Build a descriptive output filename
# e.g. nvidia_595.58.03_6.12.33-production+truenas.raw
OUTPUT_FILENAME="nvidia_${NVIDIA_VERSION}_${KERNEL_VERSION}.raw"
OUTPUT_PATH="/output/${OUTPUT_FILENAME}"

# Show staging tree size
STAGING_SIZE=$(du -sh "${STAGING_DIR}" | cut -f1)
STAGING_FILE_COUNT=$(find "${STAGING_DIR}" -type f | wc -l)
STAGING_LINK_COUNT=$(find "${STAGING_DIR}" -type l | wc -l)
info "Staging tree: ${STAGING_SIZE} — ${STAGING_FILE_COUNT} files, ${STAGING_LINK_COUNT} symlinks"

info "Top-level staging layout:"
du -sh "${STAGING_DIR}"/usr/*/ 2>/dev/null | sed 's/^/  /'

# Use gzip compression (the squashfs default) to match TrueNAS's own image
# convention.  Note: zstd level 19 compressed this same content to 381 MB
# (37% ratio) but the reference manual build used gzip (~42% ratio → 438 MB).
# The content is identical; only compression efficiency differs.
info "Building squashfs with gzip compression (matching TrueNAS convention) …"
mksquashfs "${STAGING_DIR}" "${OUTPUT_PATH}" \
    -comp gzip \
    -all-root \
    -noappend \
    || die "mksquashfs failed"

FINAL_SIZE=$(du -h "${OUTPUT_PATH}" | cut -f1)
FINAL_BYTES=$(stat -c%s "${OUTPUT_PATH}" 2>/dev/null || echo "unknown")
ok "${OUTPUT_FILENAME} created successfully"

# =============================================================================
# Done — Summary
# =============================================================================
banner "Build complete!"

echo -e "  ${GREEN}►${NC} Output     : /output/${OUTPUT_FILENAME}"
echo -e "  ${GREEN}►${NC} Image size : ${FINAL_SIZE} (${FINAL_BYTES} bytes)"
echo -e "  ${GREEN}►${NC} Driver     : NVIDIA ${NVIDIA_VERSION}"
echo -e "  ${GREEN}►${NC} Kernel     : ${KERNEL_VERSION}"
echo -e "  ${GREEN}►${NC} Modules    : ${KO_COUNT} .ko file(s)"
echo -e "  ${GREEN}►${NC} Staged     : ${STAGED_COUNT} total files"
echo ""

# Size sanity check against the known-good manual build (~438 MB with gzip)
if [[ "${FINAL_BYTES}" != "unknown" ]] && [[ ${FINAL_BYTES} -lt 420000000 ]]; then
    warn "Image is under 420 MB — this may indicate missing components."
    warn "Expected ~430-450 MB based on manual builds (gzip compression)."
    warn "Review the 'Verifying critical files' section above for clues."
elif [[ "${FINAL_BYTES}" != "unknown" ]]; then
    ok "Image size looks healthy (≥420 MB)"
fi

echo ""
echo -e "  Deploy to TrueNAS:"
echo -e "    ${CYAN}./deploy-nvidia.sh output/${OUTPUT_FILENAME}${NC}"
echo ""

