#!/bin/bash
# =============================================================================
# entrypoint.sh — Build a systemd-sysext nvidia.raw for TrueNAS
#
# Runs inside a privileged Debian 12 (Bookworm) container.
#
# Required environment variables:
#   NVIDIA_VERSION     — NVIDIA driver version (e.g. 595.58.03)
#   TRUENAS_VERSION    — TrueNAS version (e.g. 25.10.3 or 26.0.0-BETA.1)
#
# Optional:
#   NVIDIA_KERNEL_MODULE_TYPE
#                       — Passed to the NVIDIA installer as
#                         --kernel-module-type=<value>
#                         Supported values commonly used here:
#                           open        -> Open GPU kernel modules
#                           proprietary -> Legacy closed-source modules
#                         Only honored when the installer supports the flag
#                         (~555 and newer). On older branches the flavor can't
#                         be selected and the installer's default (proprietary)
#                         is built. Installer flags in general are gated by what
#                         the extracted installer actually supports, so building
#                         older drivers (e.g. 470) won't fail on unknown options.
#   NVIDIA_BUILD_CC     — Optional compiler override for NVIDIA kernel module
#                         builds (for example: gcc-12, gcc-14). By default the
#                         script matches the GCC major the target kernel was
#                         built with (from CONFIG_CC_VERSION_TEXT); building with
#                         a much newer GCC breaks NVIDIA's conftest detection.
#   NVIDIA_INSTALL_DRM  — true/false. When true, build/install nvidia-drm.ko
#                         so hosts can create /dev/dri after modprobe
#                         nvidia_drm modeset=1.
#   TRUENAS_CODENAME   — Required for 25.x and earlier download URLs
#                         (e.g. Goldeye). Not used for TrueNAS 26+.
#   SKIP_KERNEL_COMPAT_CHECK
#                       — true/false (default false). When false, the build
#                         aborts early if the chosen driver branch is known to
#                         be incompatible with the target kernel (e.g. legacy
#                         470 on kernel 6.10+). Set true to attempt anyway.
#   /patches (or NVIDIA_PATCH_DIR, or /workspace/patches)
#                       — Optional source patches applied to the extracted NVIDIA
#                         source before compiling — e.g. community patches to
#                         build an EOL driver (470) on a newer kernel. Put them in
#                         a kernel-keyed subdir matching the target kernel, e.g.
#                         /patches/6.12/*.patch (a flat /patches/*.patch acts as a
#                         generic fallback). Their presence relaxes the early
#                         driver/kernel compatibility abort.
#   /workspace/truenas.update — Pre-downloaded update file (skips download)
#   /output                   — Bind-mounted output directory
#   EMBED_NVIDIA_RAW_IN_UPDATE=true
#                            — Repack truenas.update by replacing the bundled
#                              /usr/share/truenas/sysext-extensions/nvidia.raw
#                              with the newly built image, then write a new
#                              .update artifact to /output
#
# Download URL patterns:
#   TrueNAS 25.x and earlier:
#     https://download.truenas.com/TrueNAS-SCALE-{CODENAME}/{VERSION}/
#     TrueNAS-SCALE-{VERSION}.update?download=1
#   TrueNAS 26+:
#     https://update-public.sys.truenas.net/TrueNAS-26-BETA/TrueNAS-{VERSION}.update
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

# Persist nvidia-installer's log out of the (ephemeral) container to the mounted
# /output directory, echo its tail inline so the real failure is visible without
# digging out the file, then abort.
NVIDIA_INSTALLER_LOG="/var/log/nvidia-installer.log"
save_installer_log_and_die() {
    local message="$1"
    if [[ -f "${NVIDIA_INSTALLER_LOG}" ]]; then
        if [[ -d /output ]] && cp -f "${NVIDIA_INSTALLER_LOG}" /output/nvidia-installer.log 2>/dev/null; then
            warn "Full installer log saved to ./output/nvidia-installer.log"
        fi
        echo -e "${YELLOW}──── last 40 lines of ${NVIDIA_INSTALLER_LOG} ────${NC}" >&2
        tail -n 40 "${NVIDIA_INSTALLER_LOG}" >&2 || true
        echo -e "${YELLOW}────────────────────────────────────────────────────────${NC}" >&2
    else
        warn "No ${NVIDIA_INSTALLER_LOG} was produced to save."
    fi
    die "${message}"
}

# Probe a URL after a failed download so the reason is visible (404 → wrong
# version/codename, 403, DNS/connection error, …). wget -q hides this otherwise.
report_url_status() {
    local url="$1"
    warn "Probing the URL to diagnose the failure …"
    wget --spider -S -T 15 -t 1 "${url}" 2>&1 \
        | grep -iE 'HTTP/|not found|forbidden|moved|redirect|length:|resolve|refused|timed out|unable' \
        | sed 's/^[[:space:]]*/    /' \
        || warn "    (no diagnostic detail available)"
}

env_is_true() {
    local value="${1:-}"
    case "${value,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# Returns 0 (true) when the extracted nvidia-installer recognizes a given long
# option. Older driver branches lack many flags that newer ones added, and the
# installer aborts on the FIRST unrecognized option, so we cannot hardcode a
# version→flag matrix (LTS branches like 535/550 even lag the feature branches).
# Instead we grep the option name out of the installer binary itself — each
# option's long name is a string literal compiled into the binary — which is
# authoritative for whatever version we happen to be building.
#
# Requires NVIDIA_INSTALLER_BIN to be set (see Phase 3 extraction step).
installer_supports_option() {
    local name="${1#--}"          # strip leading --
    name="${name%%=*}"            # strip any =value
    # Explicit option name present verbatim (e.g. "no-drm", "skip-module-load").
    if LC_ALL=C grep -aqF -- "${name}" "${NVIDIA_INSTALLER_BIN}"; then
        return 0
    fi
    # Boolean options are stored only by their positive name; the "--no-" form is
    # synthesized by nvgetopt. So "--no-rebuild-initramfs" is supported when the
    # binary contains "rebuild-initramfs".
    if [[ "${name}" == no-* ]] \
       && LC_ALL=C grep -aqF -- "${name#no-}" "${NVIDIA_INSTALLER_BIN}"; then
        return 0
    fi
    return 1
}

# Highest Linux kernel (MAJOR.MINOR) each EOL/legacy NVIDIA branch can still
# build its kernel modules against. Newer kernels remove/altered APIs the old
# module source relies on, so the build fails late, deep in the compile. We use
# this to fail FAST with a clear message instead. Only branches with a hard,
# well-documented ceiling are listed; modern branches receive ongoing kernel
# support and are treated as unrestricted (no entry → no limit).
#
# Extend as new ceilings become known. Sources: NVIDIA Linux forums / distro
# bug trackers + testing. Built with the kernel's own GCC (see
# select_nvidia_build_cc), the stock 470 .run compiles cleanly through kernel
# 6.6 (verified: TrueNAS 24.04/24.10) and breaks at 6.10 when follow_pfn was
# removed — so its last patch-free kernel is 6.9. Newer needs source patches
# (supply them via the patch dir; see NVIDIA_PATCH_DIR).
declare -A NVIDIA_BRANCH_MAX_KERNEL=(
    [390]="5.15"
    [470]="6.9"
)

# Returns 0 when version $1 is strictly greater than $2 (both "MAJOR.MINOR").
kernel_version_gt() {
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# Warn (and by default abort) when the selected driver branch is known to be
# incompatible with the target kernel — before the long download + compile.
# Set SKIP_KERNEL_COMPAT_CHECK=true to attempt anyway (e.g. with patched source).
check_driver_kernel_compatibility() {
    local driver_major="${NVIDIA_VERSION%%.*}"
    local max="${NVIDIA_BRANCH_MAX_KERNEL[${driver_major}]:-}"
    [[ -z "${max}" ]] && return 0          # no known ceiling for this branch

    local kernel_mm=""
    [[ "${KERNEL_VERSION}" =~ ^([0-9]+\.[0-9]+) ]] && kernel_mm="${BASH_REMATCH[1]}"
    [[ -z "${kernel_mm}" ]] && return 0     # couldn't parse kernel → don't guess

    kernel_version_gt "${kernel_mm}" "${max}" || return 0   # within supported range

    # Patches supplied → the user is providing the kernel-API fix themselves.
    if [[ ${#PATCH_FILES[@]} -gt 0 ]]; then
        info "NVIDIA ${NVIDIA_VERSION} predates kernel ${kernel_mm}, but ${#PATCH_FILES[@]} source patch(es) were supplied — proceeding."
        return 0
    fi

    banner "Driver / kernel compatibility check"
    warn "NVIDIA ${NVIDIA_VERSION} (legacy ${driver_major} branch) builds only against Linux"
    warn "kernels up to ~${max}, but this TrueNAS image uses kernel ${KERNEL_VERSION} (${kernel_mm})."
    warn "The ${driver_major} branch is end-of-life; its kernel modules will almost certainly"
    warn "FAIL to compile against this kernel (newer kernels drop/changed APIs it relies on)."
    warn ""
    warn "Fix: pick a current driver branch that supports kernel ${kernel_mm} (run ./configure.sh,"
    warn "or set a newer NVIDIA_VERSION such as 535/550/560+). Use the ${driver_major} branch only"
    warn "for older GPUs on an older TrueNAS release (older kernel)."

    warn "Or supply community source patches (./patches → /patches) to make it build,"
    warn "or set SKIP_KERNEL_COMPAT_CHECK=true to attempt the unpatched build anyway."

    if env_is_true "${SKIP_KERNEL_COMPAT_CHECK:-false}"; then
        warn "SKIP_KERNEL_COMPAT_CHECK=true — attempting the build anyway."
        return 0
    fi
    die "Aborting before download/compile."
}

# Populate PATCH_FILES with the source patches to apply, chosen by
# NVIDIA_PATCH_MODE (default "auto"):
#   none        — never patch.
#   predefined  — use the curated set shipped in the repo at
#                 /workspace/predefined-patches/<driver-major>/ (fetched by
#                 ./configure.sh from PATCHES.list).
#   custom|auto — user-supplied patches, preferring the kernel-specific subdir
#                 then a generic flat dir:
#                   <dir>/<MAJOR.MINOR>/   e.g. patches/6.12/   (per-kernel)
#                   <dir>/                 e.g. patches/        (generic)
#                 where <dir> is $NVIDIA_PATCH_DIR (default /patches) and
#                 /workspace/patches. (auto = same as custom; backward compatible.)
# Must run AFTER KERNEL_VERSION is known. Sets PATCH_SOURCE_DESC for messages.
detect_patch_files() {
    PATCH_FILES=()
    PATCH_SOURCE_DESC=""
    local mode="${NVIDIA_PATCH_MODE:-auto}"; mode="${mode,,}"
    local _p

    case "${mode}" in
        none)
            return 0
            ;;
        predefined)
            local driver_major="${NVIDIA_VERSION%%.*}"
            local pdir="/workspace/predefined-patches/${driver_major}"
            while IFS= read -r _p; do
                [[ -n "${_p}" ]] && PATCH_FILES+=("${_p}")
            done < <(find "${pdir}" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | LC_ALL=C sort)
            if [[ ${#PATCH_FILES[@]} -gt 0 ]]; then
                PATCH_SOURCE_DESC="predefined set for NVIDIA ${driver_major}"
            else
                warn "NVIDIA_PATCH_MODE=predefined but no patches found in predefined-patches/${driver_major}/."
                warn "Run ./configure.sh and pick the predefined option to fetch them, or add them manually."
            fi
            return 0
            ;;
        custom|auto|*)
            local kernel_mm=""
            [[ "${KERNEL_VERSION}" =~ ^([0-9]+\.[0-9]+) ]] && kernel_mm="${BASH_REMATCH[1]}"
            local -a kernel_dirs=() flat_dirs=()
            local base
            for base in "${NVIDIA_PATCH_DIR:-/patches}" "/workspace/patches"; do
                [[ -n "${kernel_mm}" ]] && kernel_dirs+=("${base}/${kernel_mm}")
                flat_dirs+=("${base}")
            done
            # kernel-specific patches take precedence over a generic flat dir
            if [[ ${#kernel_dirs[@]} -gt 0 ]]; then
                while IFS= read -r _p; do
                    [[ -n "${_p}" ]] && PATCH_FILES+=("${_p}")
                done < <(find "${kernel_dirs[@]}" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | LC_ALL=C sort)
                if [[ ${#PATCH_FILES[@]} -gt 0 ]]; then
                    PATCH_SOURCE_DESC="kernel ${kernel_mm}"
                    return 0
                fi
            fi
            while IFS= read -r _p; do
                [[ -n "${_p}" ]] && PATCH_FILES+=("${_p}")
            done < <(find "${flat_dirs[@]}" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null | LC_ALL=C sort)
            [[ ${#PATCH_FILES[@]} -gt 0 ]] && PATCH_SOURCE_DESC="generic patches dir"
            return 0
            ;;
    esac
}

resolve_embedded_nvidia_raw_path() {
    local extracted_rootfs_dir="$1"
    local default_path="${extracted_rootfs_dir}/usr/share/truenas/sysext-extensions/nvidia.raw"

    if [[ -f "${default_path}" ]]; then
        printf '%s\n' "${default_path}"
        return 0
    fi

    mapfile -t matches < <(find "${extracted_rootfs_dir}" -type f -name 'nvidia.raw' 2>/dev/null)

    if [[ ${#matches[@]} -eq 1 ]]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        warn "Found multiple candidate nvidia.raw files inside extracted update:"
        printf '  %s\n' "${matches[@]}"
    fi

    return 1
}

write_truenas_extension_release() {
    local output_path="$1"
    # TrueNAS's official sysext build writes ID=_any for extensions,
    # including the bundled NVIDIA extension. Matching that behavior avoids
    # host-version-specific compatibility rejections from systemd-sysext.
    printf 'ID=_any\n' > "${output_path}"
}

build_squashfs_image() {
    local source_dir="$1"
    local output_path="$2"
    local label="$3"

    info "Building ${label} with gzip compression (matching TrueNAS convention) …"
    mksquashfs "${source_dir}" "${output_path}" \
        -comp gzip \
        -all-root \
        -noappend \
        || die "Failed to build ${label}"
}

build_release_artifact() {
    local source_dir="$1"
    local output_path="$2"
    local label="$3"

    build_squashfs_image "${source_dir}" "${output_path}" "${label}"
    write_sha256_file "${output_path}"
}

write_sha256_file() {
    local target_path="$1"
    local checksum_path="${target_path}.sha256"
    local checksum=""

    [[ -f "${target_path}" ]] || die "Cannot write checksum: file not found: ${target_path}"

    checksum="$(sha256sum "${target_path}" | awk '{print $1}')"
    [[ -n "${checksum}" ]] || die "Failed to calculate SHA256 for ${target_path}"

    printf '%s\n' "${checksum}" > "${checksum_path}"
    ok "SHA256 written: ${checksum_path}"
}

print_artifact_summary_line() {
    local label="$1"
    local display_path="$2"
    # Optional: actual container path for file checks (defaults to display_path)
    local check_path="${3:-${display_path}}"

    echo -e "  ${GREEN}►${NC} ${label} : ${display_path}"
    if [[ -f "${check_path}.sha256" ]]; then
        echo -e "  ${GREEN}►${NC} ${label} SHA256 : ${display_path}.sha256"
    fi
}

update_repacked_update_manifest() {
    local update_dir="$1"
    local rootfs_path="${update_dir}/rootfs.squashfs"
    local manifest_path=""
    local rootfs_sha1=""

    for candidate in "${update_dir}/MANIFEST" "${update_dir}/manifest.json"; do
        if [[ -f "${candidate}" ]]; then
            manifest_path="${candidate}"
            break
        fi
    done

    [[ -n "${manifest_path}" ]] || die "Repack failed: no MANIFEST file found in extracted truenas.update"
    [[ -f "${rootfs_path}" ]] || die "Repack failed: rootfs.squashfs missing when updating MANIFEST"

    rootfs_sha1="$(sha1sum "${rootfs_path}" | awk '{print $1}')"
    [[ -n "${rootfs_sha1}" ]] || die "Failed to calculate SHA1 for rebuilt rootfs.squashfs"

    info "Updating MANIFEST checksum for rootfs.squashfs → ${rootfs_sha1}"
    grep -q '"checksums"' "${manifest_path}" \
        || die "MANIFEST does not contain a checksums object"
    grep -q '"rootfs.squashfs"' "${manifest_path}" \
        || die "MANIFEST checksums missing rootfs.squashfs entry"
    ROOTFS_SHA1="${rootfs_sha1}" perl -0pi -e 's/("rootfs\.squashfs"\s*:\s*")[^"]+(")/$1.$ENV{ROOTFS_SHA1}.$2/ge' "${manifest_path}" \
        || die "Failed to rewrite rootfs.squashfs checksum in MANIFEST"

    if [[ -f "${update_dir}/MANIFEST.sig" ]]; then
        warn "Removing stale MANIFEST.sig after MANIFEST rewrite"
        rm -f "${update_dir}/MANIFEST.sig"
    fi
}

build_truenas_update_url() {
    local version="$1"
    local codename="${2:-}"
    local update_filename=""

    update_filename="$(build_truenas_update_filename "${version}")"

    if [[ "${version}" =~ ^26\..*BETA ]]; then
        printf 'https://update-public.sys.truenas.net/TrueNAS-26-BETA/%s\n' "${update_filename}"
        return 0
    fi

    [[ -n "${codename}" ]] || return 1

    # The download path segment has no spaces (e.g. "Electric Eel" is the display
    # name, but the directory is "TrueNAS-SCALE-ElectricEel"). Strip spaces so a
    # human-friendly codename from .env still produces a valid URL.
    codename="${codename// /}"

    printf 'https://download.truenas.com/TrueNAS-SCALE-%s/%s/%s?download=1\n' \
        "${codename}" "${version}" "${update_filename}"
}

build_truenas_update_filename() {
    local version="$1"

    if [[ "${version}" =~ ^26\..*BETA ]]; then
        printf 'TrueNAS-%s.update\n' "${version}"
    else
        printf 'TrueNAS-SCALE-%s.update\n' "${version}"
    fi
}

# Detect the GCC major version the target kernel was compiled with, read from
# CONFIG_CC_VERSION_TEXT in the extracted kernel config. Returns e.g. "12".
detect_kernel_build_gcc_major() {
    local cfg line
    for cfg in "${KERNEL_HEADERS_PATH}/.config" \
               "${KERNEL_HEADERS_PATH}/include/config/auto.conf" \
               "${ROOTFS_DIR}/boot/config-${KERNEL_VERSION}"; do
        [[ -f "${cfg}" ]] || continue
        line="$(grep -m1 '^CONFIG_CC_VERSION_TEXT=' "${cfg}" 2>/dev/null)" || true
        [[ -n "${line}" ]] || continue
        [[ "${line}" == *[Gg][Cc][Cc]* ]] || continue          # gcc toolchains only
        # The value ends with the full compiler version, e.g.
        #   CONFIG_CC_VERSION_TEXT="gcc-12 (Debian 12.2.0-14) 12.2.0"
        if [[ "${line}" =~ ([0-9]+)\.[0-9]+\.[0-9]+\"?[[:space:]]*$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 1
}

select_nvidia_build_cc() {
    local override="${NVIDIA_BUILD_CC:-}"
    local detected_cc=""

    if [[ -n "${override}" ]]; then
        command -v "${override}" >/dev/null 2>&1 \
            || die "NVIDIA_BUILD_CC override not found in PATH: ${override}"
        printf '%s\n' "${override}"
        return 0
    fi

    # Best: match the GCC the kernel itself was built with. Compiling a module
    # with a much newer GCC than the kernel used breaks NVIDIA's conftest API
    # detection — notably GCC 14, which makes implicit-declaration a hard error
    # and yields bogus "implicit declaration of dma_is_direct/phys_to_dma"
    # failures on kernels (6.1/6.6 etc.) that build fine with their own GCC.
    local kgcc=""
    kgcc="$(detect_kernel_build_gcc_major)" || true
    if [[ -n "${kgcc}" ]]; then
        if command -v "gcc-${kgcc}" >/dev/null 2>&1; then
            info "Kernel was built with GCC ${kgcc}; matching it (gcc-${kgcc})" >&2
            printf 'gcc-%s\n' "${kgcc}"
            return 0
        fi
        warn "Kernel was built with GCC ${kgcc}, but gcc-${kgcc} is not installed — falling back to auto-detect (set NVIDIA_BUILD_CC to override)" >&2
    fi

    # Fallback: pick a gcc that at least understands the kernel's build flags.
    if command -v gcc >/dev/null 2>&1; then
        if printf 'int main(void) { return 0; }\n' | gcc -fmin-function-alignment=16 -x c - -o /tmp/gcc-flag-check >/dev/null 2>&1; then
            detected_cc="gcc"
        elif command -v gcc-14 >/dev/null 2>&1; then
            detected_cc="gcc-14"
        else
            detected_cc="gcc"
        fi
        rm -f /tmp/gcc-flag-check
    elif command -v gcc-14 >/dev/null 2>&1; then
        detected_cc="gcc-14"
    fi

    [[ -n "${detected_cc}" ]] || die "No suitable GCC compiler found in the container"
    printf '%s\n' "${detected_cc}"
}

# ── sanity checks ────────────────────────────────────────────────────────────
banner "NVIDIA sysext builder for TrueNAS"

: "${NVIDIA_VERSION:?NVIDIA_VERSION environment variable is not set}"
: "${TRUENAS_VERSION:?TRUENAS_VERSION environment variable is not set}"

NVIDIA_KERNEL_MODULE_TYPE="${NVIDIA_KERNEL_MODULE_TYPE:-open}"
NVIDIA_INSTALL_DRM="${NVIDIA_INSTALL_DRM:-true}"
TRUENAS_CODENAME="${TRUENAS_CODENAME:-}"
EMBED_NVIDIA_RAW_IN_UPDATE="${EMBED_NVIDIA_RAW_IN_UPDATE:-false}"

# Which installer flags are actually available depends on the exact driver
# version, so it's resolved in Phase 4 after the installer is extracted and its
# real option set can be probed (see installer_supports_option). In particular
# --kernel-module-type only exists on recent branches (~555+); on older ones the
# flavor can't be selected and proprietary is built.

[[ -d /output ]] \
    || die "/output directory not found. Ensure it is bind-mounted."

# ── Persistent download cache (optional) ─────────────────────────────────────
#    When a /cache volume is mounted (see docker-compose.yaml), the large
#    TrueNAS update (~1.8 GB) and the NVIDIA .run (~300 MB) are stored there and
#    reused across runs (wget -c resumes partial files). Without the mount,
#    downloads go to ephemeral /tmp and are re-fetched on every run.
CACHE_DIR="/cache"
if [[ -d "${CACHE_DIR}" ]] && [[ -w "${CACHE_DIR}" ]]; then
    info "Persistent download cache enabled: ${CACHE_DIR}"
else
    CACHE_DIR=""
    info "No writable /cache volume mounted — downloads will not be cached across runs"
fi

# Source patches are discovered later (Phase 2), once the target kernel version
# is known, so we can pick the kernel-specific patch set. Declared empty here so
# the compatibility check can safely reference it under `set -u`.
declare -a PATCH_FILES=()
PATCH_SOURCE_DESC=""

# ── Obtain the TrueNAS update file ──────────────────────────────────────────
UPDATE_FILE="/tmp/truenas.update"

if [[ -f /workspace/truenas.update ]]; then
    # Use pre-downloaded file from the workspace (avoids re-downloading ~1.8 GB)
    info "Using pre-existing /workspace/truenas.update"
    UPDATE_FILE="/workspace/truenas.update"
else
    DOWNLOAD_URL="$(build_truenas_update_url "${TRUENAS_VERSION}" "${TRUENAS_CODENAME}")" \
        || die "Unable to determine download URL for TRUENAS_VERSION=${TRUENAS_VERSION}. Set /workspace/truenas.update or provide a compatible TRUENAS_CODENAME."

    # Cache the update under its real filename so different versions coexist.
    if [[ -n "${CACHE_DIR}" ]]; then
        UPDATE_FILE="${CACHE_DIR}/$(build_truenas_update_filename "${TRUENAS_VERSION}")"
        if [[ -s "${UPDATE_FILE}" ]]; then
            info "Found cached update: ${UPDATE_FILE} ($(du -h "${UPDATE_FILE}" | cut -f1)) — resuming/validating (delete to force fresh download)"
        fi
    fi

    if [[ -n "${TRUENAS_CODENAME}" ]]; then
        info "Downloading TrueNAS ${TRUENAS_VERSION} (${TRUENAS_CODENAME}) update file …"
    else
        info "Downloading TrueNAS ${TRUENAS_VERSION} update file …"
    fi
    info "URL: ${DOWNLOAD_URL}"
    wget -q --show-progress -c -O "${UPDATE_FILE}" "${DOWNLOAD_URL}" || {
        report_url_status "${DOWNLOAD_URL}"
        die "Failed to download TrueNAS update file from ${DOWNLOAD_URL}"
    }
    ok "Downloaded $(du -h "${UPDATE_FILE}" | cut -f1)"
fi

info "NVIDIA driver version : ${NVIDIA_VERSION}"
if [[ -n "${TRUENAS_CODENAME}" ]]; then
    info "TrueNAS version       : ${TRUENAS_VERSION} (${TRUENAS_CODENAME})"
else
    info "TrueNAS version       : ${TRUENAS_VERSION}"
fi
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

# Now that the real target kernel is known, discover any (kernel-specific)
# source patches, then fail fast on a known driver/kernel incompatibility unless
# patches are supplied to make it build.
detect_patch_files
if [[ ${#PATCH_FILES[@]} -gt 0 ]]; then
    banner "Driver source will be PATCHED"
    warn "Applying ${#PATCH_FILES[@]} source patch(es) (${PATCH_SOURCE_DESC}) to NVIDIA ${NVIDIA_VERSION} before compiling:"
    printf '  %s\n' "${PATCH_FILES[@]##*/}" >&2
    warn "This produces a COMMUNITY-PATCHED, non-standard driver build — unsupported by NVIDIA."
    warn "You are responsible for the patches' correctness. Continuing in 5s (Ctrl-C to abort) …"
    sleep 5 || true
fi
check_driver_kernel_compatibility

# =============================================================================
# PHASE 3 — Download the NVIDIA .run installer
# =============================================================================
banner "Phase 3: Downloading NVIDIA ${NVIDIA_VERSION} driver"

# Stay in BUILD_DIR: the NVIDIA installer self-extracts into a subdir of the
# CWD, so we keep that ephemeral while the .run itself may live in the cache.
cd "${BUILD_DIR}"

RUN_FILE="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}-no-compat32.run"
DOWNLOAD_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${RUN_FILE}"

# Cache the installer across runs when a /cache volume is mounted; otherwise
# download into the ephemeral BUILD_DIR.
if [[ -n "${CACHE_DIR}" ]]; then
    RUN_FILE_PATH="${CACHE_DIR}/${RUN_FILE}"
else
    RUN_FILE_PATH="${BUILD_DIR}/${RUN_FILE}"
fi

if [[ -s "${RUN_FILE_PATH}" ]] && [[ -n "${CACHE_DIR}" ]]; then
    info "Found cached installer: ${RUN_FILE_PATH} — resuming/validating"
fi
info "Downloading from ${DOWNLOAD_URL} … (resumes if partially cached)"
wget -q --show-progress -c -O "${RUN_FILE_PATH}" "${DOWNLOAD_URL}" || {
    report_url_status "${DOWNLOAD_URL}"
    die "Failed to download ${RUN_FILE} from ${DOWNLOAD_URL}"
}

chmod +x "${RUN_FILE_PATH}"
ok "NVIDIA installer ready: ${RUN_FILE_PATH}"

# ── Extract the installer once, for option probing (and patching) ────────────
#    nvidia-installer aborts on the first unrecognized option and the set of
#    options varies widely by driver version, so we extract the package and read
#    the supported options straight from the nvidia-installer binary. The same
#    extraction is reused when source patches are supplied (we then run this
#    extracted nvidia-installer instead of the .run). It's isolated in its own
#    directory (its own CWD) and lands in /tmp, outside the snapshot scope.
INSTALLER_EXTRACT_DIR="${BUILD_DIR}/installer-src"
rm -rf "${INSTALLER_EXTRACT_DIR}"
mkdir -p "${INSTALLER_EXTRACT_DIR}"
info "Extracting installer to detect supported options …"
( cd "${INSTALLER_EXTRACT_DIR}" && "${RUN_FILE_PATH}" --extract-only >/dev/null 2>&1 ) \
    || die "Failed to extract NVIDIA installer for option probing"

NVIDIA_INSTALLER_BIN="$(find "${INSTALLER_EXTRACT_DIR}" -maxdepth 2 -name nvidia-installer -type f 2>/dev/null | head -1)"
[[ -n "${NVIDIA_INSTALLER_BIN}" ]] \
    || die "nvidia-installer binary not found after extraction — cannot determine supported options"
NVIDIA_SRC_ROOT="$(dirname "${NVIDIA_INSTALLER_BIN}")"
chmod +x "${NVIDIA_INSTALLER_BIN}" 2>/dev/null || true   # in case we run it directly
ok "Installer option probe ready: ${NVIDIA_INSTALLER_BIN}"

# ── Apply user-supplied source patches into the extracted tree ───────────────
USE_EXTRACTED_TREE=false
if [[ ${#PATCH_FILES[@]} -gt 0 ]]; then
    banner "Applying ${#PATCH_FILES[@]} source patch(es)"
    for _patch in "${PATCH_FILES[@]}"; do
        info "Applying $(basename "${_patch}") …"
        # Patches may be written relative to the package root (paths like
        # kernel/nvidia-drm/...) or to the kernel module dir (nvidia-drm/...),
        # so try both directories. Dry-run each combination FIRST and only apply
        # the one that applies cleanly, so a wrong target can't half-apply and
        # corrupt the tree.
        _applied=false
        for _dir in "${NVIDIA_SRC_ROOT}" "${NVIDIA_SRC_ROOT}/kernel"; do
            [[ -d "${_dir}" ]] || continue
            for _plevel in 1 0 2; do
                if patch -d "${_dir}" -p"${_plevel}" --dry-run -f < "${_patch}" >/dev/null 2>&1; then
                    patch -d "${_dir}" -p"${_plevel}" --no-backup-if-mismatch -f < "${_patch}" >/dev/null 2>&1
                    ok "Applied: $(basename "${_patch}") (${_dir##*/}/ -p${_plevel})"
                    _applied=true
                    break 2
                fi
            done
        done
        ${_applied} || die "Patch failed to apply: ${_patch}. Ensure it matches NVIDIA ${NVIDIA_VERSION} and uses kernel/-relative or package-root paths."
    done
    # Build from the patched tree (run this nvidia-installer, not the pristine .run).
    USE_EXTRACTED_TREE=true
    ok "Source patched; the build will use the patched tree"
fi

# Run the installer with the given args. Without patches we run the .run, which
# self-extracts a FRESH copy each invocation. With patches we must run our
# patched tree — but nvidia-installer mutates its working dir as it installs, so
# running the same tree twice (the two-pass install) breaks the 2nd pass
# ("Unable to open 'kernel/dkms.conf'"). Mirror the .run's behavior: copy the
# pristine patched tree to a throwaway dir per invocation and run there.
run_nvidia_installer() {
    if env_is_true "${USE_EXTRACTED_TREE}"; then
        local work rc=0
        work="$(mktemp -d "${BUILD_DIR}/installer-run.XXXXXX")"
        cp -a "${NVIDIA_SRC_ROOT}/." "${work}/"
        if ( cd "${work}" && ./nvidia-installer "$@" ); then rc=0; else rc=$?; fi
        rm -rf "${work}"
        return ${rc}
    fi
    "${RUN_FILE_PATH}" "$@"
}

# =============================================================================
# PHASE 4 — Snapshot the filesystem, then compile + install the NVIDIA driver
#
#   We take a BEFORE snapshot of every file under /usr and /etc, run the
#   installer, then take an AFTER snapshot.  The diff gives us every single
#   file NVIDIA placed — no glob patterns, no guesswork, nothing missed.
#
#   Installer flags rationale (flags marked † are version-gated — only passed
#   when the extracted installer recognizes them; see installer_supports_option):
#     --silent                          non-interactive
#     --kernel-source-path              TrueNAS's custom-named headers
#     --kernel-name                     real numerical version for depmod
#     --no-x-check                      no X server in a container
#     --no-nouveau-check                irrelevant inside build container
#     --no-systemd                      skip systemd unit installation
#     --no-backup                       no backup of "previous" driver files
#     --install-libglvnd                include GLvnd dispatch libraries
#   † --allow-installation-with-running-driver
#                                       don't abort if host has nvidia.ko (545+).
#                                       On older drivers that lack it, a two-pass
#                                       --no-kernel-module then --kernel-module-only
#                                       install is used instead (see 4c).
#   † --skip-module-load                don't modprobe inside the container (550+)
#   † --no-rebuild-initramfs            cross-compiling; don't touch initramfs (550+)
#   † --kernel-module-type=<value>      selects NVIDIA kernel module flavor (~555+)
#                                       open        -> open GPU kernel modules
#                                       proprietary -> legacy closed-source modules
#                                       'open' avoids MITIGATION_RETHUNK /
#                                       naked-return hard errors on hardened
#                                       TrueNAS kernels for many modern GPUs.
#                                       When unavailable, the installer builds
#                                       its default (proprietary) flavor.
#   † --no-drm                          optional escape hatch when a target
#                                       kernel cannot load nvidia-drm.ko.
#                                       By default DRM is installed so /dev/dri
#                                       can exist for TrueNAS Apps that map it.
# =============================================================================
banner "Phase 4: Compiling & installing NVIDIA driver"

NVIDIA_BUILD_CC="$(select_nvidia_build_cc)"
info "Using compiler for NVIDIA kernel modules: ${NVIDIA_BUILD_CC}"
export CC="${NVIDIA_BUILD_CC}"
export HOSTCC="${NVIDIA_BUILD_CC}"
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
#    Core flags are passed on every version; version-varying flags are added
#    only when the probed installer supports them (older branches reject them
#    outright, and nvidia-installer aborts on the first unrecognized option).
# ─────────────────────────────────────────────────────────────────────────────
info "Running NVIDIA installer in silent cross-compile mode …"

# Core flags present in every supported branch (470+). These must always be
# passed, so they are not gated.
NVIDIA_INSTALLER_ARGS=(
    --silent
    --kernel-source-path="${KERNEL_HEADERS_PATH}"
    --kernel-name="${KERNEL_VERSION}"
    --no-x-check
    --no-nouveau-check
    --no-backup
    --no-systemd
    --install-libglvnd
)

# Append a flag only if this installer version recognizes it; otherwise warn and
# skip so the installer doesn't abort on an "unrecognized option".
add_optional_flag() {
    local flag="$1"
    if installer_supports_option "${flag}"; then
        NVIDIA_INSTALLER_ARGS+=("${flag}")
    else
        warn "Installer for NVIDIA ${NVIDIA_VERSION} does not support ${flag%%=*} — skipping it"
    fi
}

# Version-varying flags (introduced across 545–555; LTS branches lag). Gated by
# what the extracted installer actually supports rather than by version number.
# (--allow-installation-with-running-driver is handled separately below, as it
# decides single- vs two-pass install.)
add_optional_flag "--skip-module-load"                        # 550+
add_optional_flag "--no-rebuild-initramfs"                    # 550+

# Kernel module flavor selection (--kernel-module-type) only exists on ~555+.
# When unavailable, the installer builds its default (proprietary) flavor and
# the requested type cannot be honored — reflect that in logs and the summary.
if installer_supports_option "--kernel-module-type"; then
    info "NVIDIA kernel module flavor: ${NVIDIA_KERNEL_MODULE_TYPE} (via --kernel-module-type)"
    NVIDIA_INSTALLER_ARGS+=(--kernel-module-type="${NVIDIA_KERNEL_MODULE_TYPE}")
else
    if [[ "${NVIDIA_KERNEL_MODULE_TYPE,,}" != "proprietary" ]]; then
        warn "NVIDIA ${NVIDIA_VERSION} predates --kernel-module-type; cannot select '${NVIDIA_KERNEL_MODULE_TYPE}' modules."
        warn "Building the installer's default (proprietary) modules instead."
    fi
    NVIDIA_KERNEL_MODULE_TYPE="proprietary"
    info "NVIDIA kernel module flavor: proprietary (installer default; --kernel-module-type unavailable)"
fi

if env_is_true "${NVIDIA_INSTALL_DRM}"; then
    info "NVIDIA DRM module install: enabled"
else
    info "NVIDIA DRM module install: disabled (--no-drm)"
    add_optional_flag "--no-drm"
fi

# The build container shares the host kernel, so the host's loaded NVIDIA modules
# (nvidia, nvidia-drm, …) are visible to the installer. nvidia-installer aborts
# on this ("An NVIDIA kernel module appears to already be loaded") unless told to
# tolerate it. Two strategies, picked by what the installer supports:
#
#   • 545+  : pass --allow-installation-with-running-driver and install in one go.
#   • <545  : that flag doesn't exist, but the loaded-module check is skipped both
#             when building NO kernel module (--no-kernel-module) and when building
#             ONLY the kernel module for a non-running kernel (--kernel-module-only
#             with --kernel-name, which we always set). So we install in two passes
#             — userspace FIRST, because --kernel-module-only refuses to run unless
#             a driver is already installed, then the kernel module on top.
#
# Resolve the strategy now, while the probe binary still exists.
if installer_supports_option "--allow-installation-with-running-driver"; then
    ALLOW_RUNNING_DRIVER=true
else
    ALLOW_RUNNING_DRIVER=false
fi

# Reclaim the extraction before the installer self-extracts, so peak disk usage
# isn't doubled — UNLESS we're building from the (patched) extracted tree.
if ! env_is_true "${USE_EXTRACTED_TREE}"; then
    rm -rf "${INSTALLER_EXTRACT_DIR}"
fi

if env_is_true "${ALLOW_RUNNING_DRIVER}"; then
    NVIDIA_INSTALLER_ARGS+=(--allow-installation-with-running-driver)
    info "Installing in a single pass (host's running driver tolerated via --allow-installation-with-running-driver) …"
    run_nvidia_installer "${NVIDIA_INSTALLER_ARGS[@]}" \
        || save_installer_log_and_die "NVIDIA installer failed. Check output above for details."
else
    warn "Installer lacks --allow-installation-with-running-driver; using a two-pass install so the host's loaded NVIDIA modules don't abort it"
    info "Pass 1/2: userspace components (--no-kernel-module) …"
    run_nvidia_installer "${NVIDIA_INSTALLER_ARGS[@]}" --no-kernel-module \
        || save_installer_log_and_die "NVIDIA installer failed during the userspace pass. Check output above for details."
    info "Pass 2/2: kernel modules on top of it (--kernel-module-only) …"
    run_nvidia_installer "${NVIDIA_INSTALLER_ARGS[@]}" --kernel-module-only \
        || save_installer_log_and_die "NVIDIA installer failed during the kernel-module pass. Check output above for details."
fi

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

# Count critical components that are missing, so the size summary below can key
# off what's actually absent instead of an absolute (driver-version-specific)
# byte threshold. Pass a third arg "optional" for components that legitimately
# vary by driver branch (their absence is reported as info, not a warning).
MISSING_CRITICAL=0
check_file() {
    local label="$1" pattern="$2" criticality="${3:-critical}"
    local count
    count=$(find "${STAGING_DIR}" -path "${pattern}" 2>/dev/null | wc -l)
    if [[ ${count} -gt 0 ]]; then
        ok "  ${label} (${count} file(s))"
    elif [[ "${criticality}" == "optional" ]]; then
        info "  ${label} — not present (optional / branch-dependent)"
    else
        warn "  ${label} — NOT FOUND (pattern: ${pattern})"
        (( MISSING_CRITICAL++ )) || true
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
# GSP firmware ships only on GSP-era drivers (~515+, Turing+ GPUs); legacy
# branches like 470 have none, so don't flag its absence there.
if (( ${NVIDIA_VERSION%%.*} >= 515 )); then
    check_file "GSP firmware"        "*/firmware/nvidia/*/gsp_*"
else
    info "  GSP firmware — not applicable (NVIDIA ${NVIDIA_VERSION} predates GSP firmware)"
fi
check_file "nvidia.ko (MAIN)"       "*/nvidia.ko"
check_file "nvidia-modeset.ko"      "*/nvidia-modeset.ko"
check_file "nvidia-uvm.ko"          "*/nvidia-uvm.ko"
check_file "nvidia-peermem.ko"      "*/nvidia-peermem.ko"
if env_is_true "${NVIDIA_INSTALL_DRM}"; then
    check_file "nvidia-drm.ko"      "*/nvidia-drm.ko"
else
    info "  nvidia-drm.ko — intentionally excluded (NVIDIA_INSTALL_DRM=${NVIDIA_INSTALL_DRM})"
fi
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

if env_is_true "${NVIDIA_INSTALL_DRM}"; then
    DRM_MODULE=$(find "${STAGING_DIR}" -name 'nvidia-drm.ko' -type f 2>/dev/null | head -1)
    if [[ -z "${DRM_MODULE}" ]]; then
        die "CRITICAL: NVIDIA_INSTALL_DRM=true but nvidia-drm.ko is MISSING from the staged image. /dev/dri will not be created."
    fi
    ok "nvidia-drm.ko module confirmed at: ${DRM_MODULE}"
fi

# ── 5d: Write extension-release metadata ────────────────────────────────────
EXT_RELEASE_DIR="${STAGING_DIR}/usr/lib/extension-release.d"
mkdir -p "${EXT_RELEASE_DIR}"

info "Writing extension-release.nvidia metadata …"
write_truenas_extension_release "${EXT_RELEASE_DIR}/extension-release.nvidia"
ok "extension-release.nvidia written"

# =============================================================================
# PHASE 6 — Build the final squashfs image
# =============================================================================
banner "Phase 6: Creating nvidia.raw squashfs image"

OUTPUT_DIR="/output/${TRUENAS_VERSION}"
OUTPUT_FILENAME="nvidia.raw"
OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_FILENAME}"
OFFICIAL_UPDATE_FILENAME="$(build_truenas_update_filename "${TRUENAS_VERSION}")"

mkdir -p "${OUTPUT_DIR}"

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
build_release_artifact "${STAGING_DIR}" "${OUTPUT_PATH}" "nvidia.raw"

FINAL_SIZE=$(du -h "${OUTPUT_PATH}" | cut -f1)
FINAL_BYTES=$(stat -c%s "${OUTPUT_PATH}" 2>/dev/null || echo "unknown")
ok "${OUTPUT_FILENAME} created successfully"

UPDATED_TRUENAS_UPDATE_PATH=""
UPDATED_TRUENAS_UPDATE_FILENAME=""

if env_is_true "${EMBED_NVIDIA_RAW_IN_UPDATE}"; then
    # =========================================================================
    # PHASE 7 — Repack truenas.update with the newly built nvidia.raw
    # =========================================================================
    banner "Phase 7: Repacking truenas.update with the new nvidia.raw"

    UPDATE_REPACK_DIR="/tmp/update_repack"
    UPDATE_ROOTFS_REPACK_DIR="/tmp/update_rootfs_repack"
    UPDATED_ROOTFS_SQUASHFS="/tmp/rootfs.updated.squashfs"
    UPDATED_TRUENAS_UPDATE_FILENAME="${OFFICIAL_UPDATE_FILENAME}"
    UPDATED_TRUENAS_UPDATE_PATH="${OUTPUT_DIR}/${UPDATED_TRUENAS_UPDATE_FILENAME}"

    rm -rf "${UPDATE_REPACK_DIR}" "${UPDATE_ROOTFS_REPACK_DIR}" "${UPDATED_ROOTFS_SQUASHFS}"
    mkdir -p "${UPDATE_REPACK_DIR}" "${UPDATE_ROOTFS_REPACK_DIR}"

    info "Extracting full truenas.update for repacking …"
    unsquashfs -f -d "${UPDATE_REPACK_DIR}" "${UPDATE_FILE}" \
        || die "Failed to extract truenas.update for repacking"

    [[ -f "${UPDATE_REPACK_DIR}/rootfs.squashfs" ]] \
        || die "Repack failed: rootfs.squashfs missing from extracted truenas.update"

    info "Extracting full rootfs.squashfs for nvidia.raw replacement …"
    unsquashfs -f -d "${UPDATE_ROOTFS_REPACK_DIR}" "${UPDATE_REPACK_DIR}/rootfs.squashfs" \
        || die "Failed to extract rootfs.squashfs for repacking"

    EMBEDDED_NVIDIA_RAW_PATH="$(resolve_embedded_nvidia_raw_path "${UPDATE_ROOTFS_REPACK_DIR}")" \
        || die "Unable to locate the bundled nvidia.raw inside truenas.update"

    info "Replacing bundled nvidia.raw at: ${EMBEDDED_NVIDIA_RAW_PATH}"
    cp -f "${OUTPUT_PATH}" "${EMBEDDED_NVIDIA_RAW_PATH}" \
        || die "Failed to replace bundled nvidia.raw"

    info "Rebuilding rootfs.squashfs …"
    rm -f "${UPDATE_REPACK_DIR}/rootfs.squashfs"
    build_squashfs_image "${UPDATE_ROOTFS_REPACK_DIR}" "${UPDATED_ROOTFS_SQUASHFS}" "rootfs.squashfs"
    mv "${UPDATED_ROOTFS_SQUASHFS}" "${UPDATE_REPACK_DIR}/rootfs.squashfs"
    update_repacked_update_manifest "${UPDATE_REPACK_DIR}"

    info "Building updated truenas.update …"
    rm -f "${UPDATED_TRUENAS_UPDATE_PATH}"
    build_release_artifact "${UPDATE_REPACK_DIR}" "${UPDATED_TRUENAS_UPDATE_PATH}" "truenas.update"

    ok "Updated truenas.update created: ${UPDATED_TRUENAS_UPDATE_PATH}"
fi

# =============================================================================
# Done — Summary
# =============================================================================
banner "Build complete!"

# Convert container paths (/output/...) to host-relative paths (./output/...)
HOST_OUTPUT_PATH="./output/${TRUENAS_VERSION}/${OUTPUT_FILENAME}"

print_artifact_summary_line "Output" "${HOST_OUTPUT_PATH}" "${OUTPUT_PATH}"
echo -e "  ${GREEN}►${NC} Image size : ${FINAL_SIZE} (${FINAL_BYTES} bytes)"
echo -e "  ${GREEN}►${NC} Driver     : NVIDIA ${NVIDIA_VERSION} (${NVIDIA_KERNEL_MODULE_TYPE})"
echo -e "  ${GREEN}►${NC} Kernel     : ${KERNEL_VERSION}"
echo -e "  ${GREEN}►${NC} Modules    : ${KO_COUNT} .ko file(s)"
echo -e "  ${GREEN}►${NC} DRM        : ${NVIDIA_INSTALL_DRM}"
echo -e "  ${GREEN}►${NC} Staged     : ${STAGED_COUNT} total files"

if [[ -n "${UPDATED_TRUENAS_UPDATE_PATH}" ]]; then
    HOST_UPDATE_PATH="$(echo "${UPDATED_TRUENAS_UPDATE_PATH}" | sed 's|^/output/|./output/|')"
    print_artifact_summary_line "Update" "${HOST_UPDATE_PATH}" "${UPDATED_TRUENAS_UPDATE_PATH}"
fi

echo ""

# Image-completeness check. We DON'T compare to a fixed "expected" size — that
# varies a lot by driver branch (legacy 470 is ~300 MB with no GSP firmware;
# modern 535/560+ are ~440 MB), and a hardcoded threshold cried wolf on smaller
# legacy builds. Instead trust the explicit component verification above, and use
# size only as a floor to catch a catastrophically truncated image.
MIN_PLAUSIBLE_BYTES=100000000   # 100 MB — even legacy builds are well above this
if [[ ${MISSING_CRITICAL} -gt 0 ]]; then
    warn "${MISSING_CRITICAL} expected component(s) were NOT found — review the 'Verifying critical files' section above."
elif [[ "${FINAL_BYTES}" != "unknown" ]] && [[ ${FINAL_BYTES} -lt ${MIN_PLAUSIBLE_BYTES} ]]; then
    warn "Image is only ${FINAL_SIZE} — implausibly small; some components may be missing despite passing checks."
elif [[ "${FINAL_BYTES}" != "unknown" ]]; then
    ok "Image complete: all expected components present (${FINAL_SIZE})."
    info "Image size varies by driver branch — e.g. legacy 470 ~300 MB (no GSP firmware) vs 535/560+ ~440 MB."
fi

echo ""
echo -e "  Deploy to TrueNAS:"
echo -e "    ${CYAN}./deploy-nvidia.sh ./output/${TRUENAS_VERSION}/${OUTPUT_FILENAME}${NC}"
echo ""
