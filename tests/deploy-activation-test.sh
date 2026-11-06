#!/bin/bash
# =============================================================================
# deploy-activation-test.sh — offline regression test for deploy-nvidia.sh
#
# Usage:  tests/deploy-activation-test.sh
#
# Runs a path-rewritten copy of the deploy script in a sandbox, with stubs for
# everything that touches the host. The midclt stub follows the real
# docker.configure_nvidia (middlewared/plugins/docker/update.py, stable/goldeye):
#   nvidia=false unlinks /run/extensions/nvidia.raw and runs a refresh
#   nvidia=true  creates that link only if missing, and refreshes only then
#   a failed refresh fails the job (check=True)
# The du stub answers 512 for everything, as ZFS does for a just-written file.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

write_stubs() {
    local bin="$1"
    mkdir -p "${bin}"

    cat > "${bin}/systemd-sysext" <<'STUB'
#!/bin/bash
echo "systemd-sysext $*" >> "${SB}/events"
do_merge() {
    local link="" d
    for d in "${SB}/etc/extensions" "${SB}/run/extensions"; do
        [[ -e "${d}/nvidia.raw" ]] && link="${d}/nvidia.raw"
    done
    if [[ -z "${link}" ]]; then echo "No extensions found."; return 0; fi
    if [[ -s "${SB}/merged" ]]; then
        echo "Hierarchy '/usr' is already merged." >&2; return 1
    fi
    case "$(cat "${link}")" in
        *BAD*)    echo "Extension rejected." >&2; return 1 ;;
        *SILENT*) return 0 ;;
    esac
    cat "${link}" > "${SB}/merged"
    mkdir -p "${SB}/usr/lib/extension-release.d"
    echo "ID=_any" > "${SB}/usr/lib/extension-release.d/extension-release.nvidia"
}
do_unmerge() {
    : > "${SB}/merged"
    rm -f "${SB}/usr/lib/extension-release.d/extension-release.nvidia"
}
case "$1" in
    merge)   do_merge ;;
    unmerge) do_unmerge ;;
    refresh) do_unmerge; do_merge ;;
esac
STUB

    cat > "${bin}/midclt" <<'STUB'
#!/bin/bash
echo "midclt $*" >> "${SB}/events"
link="${SB}/run/extensions/nvidia.raw"
if [[ "$*" == *docker.config* ]]; then
    echo "{\"nvidia\": $(cat "${SB}/integration")}"
    exit 0
fi
if [[ "$*" == *docker.update* ]]; then
    refresh=0
    if [[ "$*" == *'"nvidia": true'* ]]; then
        echo true > "${SB}/integration"
        if [[ ! -e "${link}" ]]; then
            mkdir -p "$(dirname "${link}")"
            ln -sf "${SB}/usr/share/truenas/sysext-extensions/nvidia.raw" "${link}"
            refresh=1
        fi
    else
        echo false > "${SB}/integration"
        if [[ -e "${link}" ]]; then rm -f "${link}"; refresh=1; fi
    fi
    if [[ ${refresh} -eq 1 ]]; then
        systemd-sysext refresh >/dev/null 2>&1 || exit 1
        ldconfig
    fi
    exit 0
fi
exit 1
STUB

    cat > "${bin}/zfs" <<'STUB'
#!/bin/bash
echo "zfs $*" >> "${SB}/events"
if [[ "$1" == list ]]; then echo "boot-pool/ROOT/test/usr"; exit 0; fi
if [[ "$1" == set ]]; then
    echo "$2" > "${SB}/readonly"
    n=$(( $(cat "${SB}/zfs_sets" 2>/dev/null || echo 0) + 1 ))
    echo "${n}" > "${SB}/zfs_sets"
    if grep -qx "${n}" "${SB}/signal_on_set" 2>/dev/null; then kill -TERM "${PPID}"; fi
fi
STUB

    cat > "${bin}/unsquashfs" <<'STUB'
#!/bin/bash
[[ "$1" == -l ]] || exit 0
grep -q NOMODULES "$2" && exit 0
kernel="$(grep -oP 'KERNEL=\K\S+' "$2" || echo 6.12.1-test)"
driver="$(grep -oP 'DRIVER=\K\S+' "$2" || echo 595.1)"
echo "squashfs-root/usr/lib/modules/${kernel}/video/nvidia.ko"
echo "squashfs-root/usr/lib/x86_64-linux-gnu/libcuda.so.${driver}"
STUB

    cat > "${bin}/rmmod" <<'STUB'
#!/bin/bash
echo "rmmod $1" >> "${SB}/events"
[[ -e "${SB}/busy" ]] && exit 1
sed -i "/^$1\$/d" "${SB}/modules"
STUB

    printf '#!/bin/bash\necho 0\n' > "${bin}/id"
    printf '#!/bin/bash\necho "ldconfig" >> "${SB}/events"\n' > "${bin}/ldconfig"
    printf '#!/bin/bash\ncat "${SB}/modules"\n' > "${bin}/lsmod"
    printf '#!/bin/bash\necho 6.12.1-test\n' > "${bin}/uname"
    printf '#!/bin/bash\nexit 0\n' > "${bin}/nvidia-modprobe"
    printf '#!/bin/bash\ncat "${SB}/smi" 2>/dev/null\n' > "${bin}/nvidia-smi"
    printf '#!/bin/bash\nprintf "512\\t%%s\\n" "${@: -1}"\n' > "${bin}/du"
    chmod +x "${bin}"/*
}

# new_sandbox <name> <integration true|false> <installed image text, or empty>
new_sandbox() {
    local sb="${WORK}/$1" integration="$2" installed="$3"
    mkdir -p "${sb}/usr/share/truenas/sysext-extensions" "${sb}/run/extensions" "${sb}/etc/extensions"
    write_stubs "${sb}/bin"
    sed -e "s#/usr/share/truenas#${sb}/usr/share/truenas#g" \
        -e "s#/run/extensions#${sb}/run/extensions#g" \
        -e "s#/etc/extensions#${sb}/etc/extensions#g" \
        -e "s#/usr/lib/extension-release.d#${sb}/usr/lib/extension-release.d#g" \
        -e "s#/sys/module/nvidia/version#${sb}/sys/module/nvidia/version#g" \
        -e "s#/etc/version#${sb}/etc/version#g" \
        "${REPO}/deploy-nvidia.sh" > "${sb}/deploy-nvidia.sh"
    chmod +x "${sb}/deploy-nvidia.sh"
    echo "${integration}" > "${sb}/integration"
    : > "${sb}/events"; : > "${sb}/merged"; : > "${sb}/modules"; echo on > "${sb}/readonly"
    if [[ -n "${installed}" ]]; then
        echo "${installed}" > "${sb}/usr/share/truenas/sysext-extensions/nvidia.raw"
        if [[ "${integration}" == true ]]; then
            ln -sf "${sb}/usr/share/truenas/sysext-extensions/nvidia.raw" "${sb}/run/extensions/nvidia.raw"
            echo "${installed}" > "${sb}/merged"
            mkdir -p "${sb}/usr/lib/extension-release.d"
            echo "ID=_any" > "${sb}/usr/lib/extension-release.d/extension-release.nvidia"
        fi
    fi
    echo "${sb}"
}

# deploy <sandbox> <image text> [extra args] — sets RC, leaves output in <sb>/log
deploy() {
    local sb="$1" image="$2"; shift 2
    echo "${image}" > "${sb}/new.raw"
    SB="${sb}" PATH="${sb}/bin:${PATH}" bash "${sb}/deploy-nvidia.sh" "$@" "${sb}/new.raw" > "${sb}/log" 2>&1
    RC=$?
}

# check_state <sandbox> — runs --check, sets RC, leaves output in <sb>/log
check_state() {
    SB="$1" PATH="$1/bin:${PATH}" bash "$1/deploy-nvidia.sh" --check > "$1/log" 2>&1
    RC=$?
}

load_modules() { printf '%s\n' nvidia_drm nvidia_modeset nvidia_uvm nvidia > "$1/modules"; }
loaded_driver() { mkdir -p "$1/sys/module/nvidia"; echo "$2" > "$1/sys/module/nvidia/version"; }
nonzero()     { [[ "$1" -ne 0 ]]; }

installed()   { cat "$1/usr/share/truenas/sysext-extensions/nvidia.raw" 2>/dev/null; }
merged()      { cat "$1/merged"; }
line_of()     { grep -n -m1 -F "$2" "$1/events" | cut -d: -f1; }
is()          { [[ "$1" == "$2" ]]; }
before()      { [[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]; }
absent()      { ! grep -qF "$2" "$1/log"; }
present()     { grep -qF "$2" "$1/log"; }
no_link()     { [[ ! -e "$1/run/extensions/nvidia.raw" && ! -L "$1/run/extensions/nvidia.raw" ]]; }

echo "integration on, good image"
sb="$(new_sandbox on-good true OLD)"
deploy "${sb}" NEW
check "exits 0" is "${RC}" 0
check "merge step sees the extension" absent "${sb}" "No extensions found"
check "new image ends up merged" is "$(merged "${sb}")" NEW
check "integration is back on" is "$(cat "${sb}/integration")" true
check "/usr is locked" is "$(cat "${sb}/readonly")" readonly=on
enable="$(line_of "${sb}" '"nvidia": true')"
merge="$(line_of "${sb}" 'systemd-sysext merge')"
linker="$(grep -n '^ldconfig$' "${sb}/events" | cut -d: -f1 | awk -v m="${merge}" '$1 > m' | head -1)"
check "merge happens before docker comes back" before "${merge}" "${enable}"
check "ldconfig runs between the merge and docker coming back" before "${linker}" "${enable}"

echo "integration on, rejected image"
sb="$(new_sandbox on-bad true OLD)"
deploy "${sb}" BAD
check "exits non-zero" is "$([[ ${RC} -ne 0 ]] && echo yes)" yes
check "previous image restored" is "$(installed "${sb}")" OLD
check "previous image merged" is "$(merged "${sb}")" OLD
check "integration is back on" is "$(cat "${sb}/integration")" true
check "/usr is locked" is "$(cat "${sb}/readonly")" readonly=on

echo "integration on, merge exits 0 without merging anything"
sb="$(new_sandbox on-silent true OLD)"
deploy "${sb}" SILENT
check "exits non-zero" is "$([[ ${RC} -ne 0 ]] && echo yes)" yes
check "previous image restored" is "$(installed "${sb}")" OLD
check "previous image merged" is "$(merged "${sb}")" OLD

echo "integration off, good image"
sb="$(new_sandbox off-good false OLD)"
deploy "${sb}" NEW
check "exits 0" is "${RC}" 0
check "new image ends up merged" is "$(merged "${sb}")" NEW
check "integration stays off" is "$(cat "${sb}/integration")" false
check "warns the activation is transient" present "${sb}" "gone after a reboot"

echo "integration off, rejected image"
sb="$(new_sandbox off-bad false OLD)"
deploy "${sb}" BAD
check "exits non-zero" is "$([[ ${RC} -ne 0 ]] && echo yes)" yes
check "previous image restored" is "$(installed "${sb}")" OLD
check "activation link removed again" no_link "${sb}"

echo "fresh install, rejected image"
sb="$(new_sandbox fresh-bad false '')"
deploy "${sb}" BAD
check "exits non-zero" is "$([[ ${RC} -ne 0 ]] && echo yes)" yes
check "rejected image removed" is "$(installed "${sb}")" ""
check "no dangling activation link" no_link "${sb}"

echo "dry run"
sb="$(new_sandbox dry true OLD)"
deploy "${sb}" NEW --dry-run
check "exits 0" is "${RC}" 0
check "installed image untouched" is "$(installed "${sb}")" OLD
check "merged state untouched" is "$(merged "${sb}")" OLD
check "integration untouched" is "$(cat "${sb}/integration")" true

echo "size reporting"
sb="$(new_sandbox sizes true OLD)"
head -c 2000000 /dev/zero > "${sb}/usr/share/truenas/sysext-extensions/nvidia.raw"
deploy "${sb}" NEW
check "backup size is not the du value" absent "${sb}" "(512)"
check "backup size comes from the file length" present "${sb}" "(2.0MB)"
check "entrypoint.sh reports no file size through du -h" is "$(grep -c 'du -h ' "${REPO}/entrypoint.sh")" 0
check "deploy-nvidia.sh reports no file size through du -h" is "$(grep -c 'du -h ' "${REPO}/deploy-nvidia.sh")" 0

echo "image built for another kernel"
sb="$(new_sandbox wrong-kernel true OLD)"
deploy "${sb}" "NEW KERNEL=6.1.0-old"
check "refuses to deploy" nonzero "${RC}"
check "names the kernel it was built for" present "${sb}" "6.1.0-old"
check "installed image untouched" is "$(installed "${sb}")" OLD
check "integration never touched" is "$(grep -c docker.update "${sb}/events")" 0

sb="$(new_sandbox wrong-kernel-dry true OLD)"
deploy "${sb}" "NEW KERNEL=6.1.0-old" --dry-run
check "dry run reports the same refusal" nonzero "${RC}"

sb="$(new_sandbox wrong-kernel-force true OLD)"
deploy "${sb}" "NEW KERNEL=6.1.0-old" --force-kernel
check "--force-kernel deploys anyway" is "${RC}" 0
check "--force-kernel installs the image" is "$(merged "${sb}")" "NEW KERNEL=6.1.0-old"

sb="$(new_sandbox unreadable-kernel true OLD)"
deploy "${sb}" "NEW NOMODULES"
check "unreadable kernel does not block" is "${RC}" 0
check "unreadable kernel warns" present "${sb}" "Could not read which kernel"

sb="$(new_sandbox rollback-menu true OLD)"
mkdir -p "${sb}/backups"
echo "OLD KERNEL=6.1.0-old" > "${sb}/backups/nvidia.raw.backup_20260101_000000"
printf '3\n\n\n' | SB="${sb}" PATH="${sb}/bin:${PATH}" timeout 20 bash "${sb}/deploy-nvidia.sh" --no-whiptail > "${sb}/log" 2>&1
check "rollback menu flags a backup for another kernel" present "${sb}" "built for 6.1.0-old"

echo "module unload order"
sb="$(new_sandbox modules true OLD)"
load_modules "${sb}"
deploy "${sb}" NEW
check "exits 0" is "${RC}" 0
check "core module unloads before docker comes back" before "$(line_of "${sb}" 'rmmod nvidia')" "$(line_of "${sb}" '"nvidia": true')"
check "no reboot needed" absent "${sb}" "Reboot required"

sb="$(new_sandbox modules-busy true OLD)"
load_modules "${sb}"; touch "${sb}/busy"
deploy "${sb}" NEW
check "busy module does not fail the deploy" is "${RC}" 0
check "busy module asks for a reboot" present "${sb}" "Reboot required"
check "integration still comes back" is "$(cat "${sb}/integration")" true

echo "signals during rollback"
# zfs set calls in order: 1 unlock, 2 re-lock, 3 rollback unlock, 4 rollback re-lock
sb="$(new_sandbox signal-rollback true OLD)"
echo 3 > "${sb}/signal_on_set"
deploy "${sb}" BAD
check "exits non-zero" nonzero "${RC}"
check "previous image restored" is "$(installed "${sb}")" OLD
check "previous image merged" is "$(merged "${sb}")" OLD
check "/usr is locked" is "$(cat "${sb}/readonly")" readonly=on
check "integration is back on" is "$(cat "${sb}/integration")" true

sb="$(new_sandbox signal-twice true OLD)"
printf '2\n3\n' > "${sb}/signal_on_set"
deploy "${sb}" NEW
check "exits non-zero" nonzero "${RC}"
check "previous image restored" is "$(installed "${sb}")" OLD
check "/usr is locked" is "$(cat "${sb}/readonly")" readonly=on
check "integration is back on" is "$(cat "${sb}/integration")" true

echo "interrupted before the image was replaced"
sb="$(new_sandbox signal-early true OLD)"
echo 1 > "${sb}/signal_on_set"
deploy "${sb}" NEW
check "exits non-zero" nonzero "${RC}"
check "installed image survives" is "$(installed "${sb}")" OLD
check "installed image merged again" is "$(merged "${sb}")" OLD

echo "--check after a swap that kept the old module loaded"
sb="$(new_sandbox check-pending true "NEW DRIVER=595.112.07")"
load_modules "${sb}"; loaded_driver "${sb}" 595.91.07
echo "Failed to initialize NVML: Driver/library version mismatch" > "${sb}/smi"
check_state "${sb}"
check "pending reboot is not a problem" is "${RC}" 0
check "names both versions" present "${sb}" "595.91.07"
check "says a reboot is pending" present "${sb}" "Reboot pending"
check "does not print the NVML error as a driver" absent "${sb}" "nvidia-smi      Failed"

echo "--check with matching versions"
sb="$(new_sandbox check-same true "NEW DRIVER=595.112.07")"
load_modules "${sb}"; loaded_driver "${sb}" 595.112.07
echo "595.112.07, Test GPU" > "${sb}/smi"
check_state "${sb}"
check "exits 0" is "${RC}" 0
check "no reboot note" absent "${sb}" "Reboot pending"

echo "--check with a failing driver and no version difference"
sb="$(new_sandbox check-broken true "NEW DRIVER=595.112.07")"
load_modules "${sb}"; loaded_driver "${sb}" 595.112.07
echo "Failed to initialize NVML: Unknown Error" > "${sb}/smi"
check_state "${sb}"
check "counts as a problem" nonzero "${RC}"

echo "--check when a TrueNAS update changed the kernel"
sb="$(new_sandbox check-kernel true "NEW DRIVER=595.112.07 KERNEL=6.1.0-old")"
load_modules "${sb}"; loaded_driver "${sb}" 570.1
check_state "${sb}"
check "counts as a problem" nonzero "${RC}"
check "a reboot would not help, so none is suggested" absent "${sb}" "Reboot pending"

echo "host older than the minimum TrueNAS version"
sb="$(new_sandbox old-host true OLD)"
echo 24.04.2.5 > "${sb}/etc/version"
deploy "${sb}" NEW
check "deploy is refused" nonzero "${RC}"
check "names the minimum" present "${sb}" "24.10"
check "installed image untouched" is "$(installed "${sb}")" OLD
check "integration never touched" is "$(grep -c docker.update "${sb}/events")" 0

sb="$(new_sandbox old-host-dry true OLD)"
echo 24.04.2.5 > "${sb}/etc/version"
deploy "${sb}" NEW --dry-run
check "dry run is refused" nonzero "${RC}"

for mode in --uninstall --persist --unpersist --persist-uvm --unpersist-uvm; do
    sb="$(new_sandbox "old-host${mode}" true OLD)"
    echo 24.04.2.5 > "${sb}/etc/version"
    SB="${sb}" PATH="${sb}/bin:${PATH}" timeout 20 bash "${sb}/deploy-nvidia.sh" --no-whiptail "${mode}" > "${sb}/log" 2>&1 </dev/null
    check "${mode} is refused" nonzero "$?"
    check "${mode} names the minimum" present "${sb}" "24.10"
done

sb="$(new_sandbox old-host-menu true OLD)"
echo 23.10.2 > "${sb}/etc/version"
SB="${sb}" PATH="${sb}/bin:${PATH}" timeout 20 bash "${sb}/deploy-nvidia.sh" --no-whiptail > "${sb}/log" 2>&1 </dev/null
check "the manager is refused" nonzero "$?"
check "the manager names the minimum" present "${sb}" "24.10"

sb="$(new_sandbox old-host-check true "NEW DRIVER=595.112.07")"
echo 24.04.2.5 > "${sb}/etc/version"
load_modules "${sb}"; loaded_driver "${sb}" 595.112.07
echo "595.112.07, Test GPU" > "${sb}/smi"
check_state "${sb}"
check "--check still reports" present "${sb}" "Installed image"
check "--check counts it as a problem" nonzero "${RC}"
check "--check names the minimum" present "${sb}" "24.10"

echo "host at or above the minimum TrueNAS version"
for version in 24.10.2.4 25.04.2.6 25.10.8 27.0.0-RC.1 TrueNAS-SCALE-25.10.8; do
    sb="$(new_sandbox "new-host-${version}" true OLD)"
    echo "${version}" > "${sb}/etc/version"
    deploy "${sb}" NEW
    check "${version} deploys" is "${RC}" 0
done

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
