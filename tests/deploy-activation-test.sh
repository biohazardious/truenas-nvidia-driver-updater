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

    # -cat serves files from ${SB}/image (the GPU metadata a test placed there),
    # whatever image it is asked about, and fails like the real one when absent.
    cat > "${bin}/unsquashfs" <<'STUB'
#!/bin/bash
if [[ "$1" == -cat ]]; then
    [[ -f "${SB}/image/$3" ]] || { echo "unsquashfs: $3 not found in $2" >&2; exit 1; }
    cat "${SB}/image/$3"
    exit 0
fi
[[ "$1" == -l ]] || exit 0
grep -q NOMODULES "$2" && exit 0
kernel="$(grep -oP 'KERNEL=\K\S+' "$2" || echo 6.12.1-test)"
driver="$(grep -oP 'DRIVER=\K\S+' "$2" || echo 595.1)"
echo "squashfs-root/usr/lib/modules/${kernel}/video/nvidia.ko"
echo "squashfs-root/usr/lib/x86_64-linux-gnu/libcuda.so.${driver}"
# Real listings outrun the pipe buffer, so a reader that stops early kills this.
seq 1 200000 | sed 's#^#squashfs-root/usr/share/filler/#'
STUB

    cat > "${bin}/rmmod" <<'STUB'
#!/bin/bash
echo "rmmod $1" >> "${SB}/events"
[[ -e "${SB}/busy" ]] && exit 1
sed -i "/^$1\$/d" "${SB}/modules"
STUB

    printf '#!/bin/bash\necho 0\n' > "${bin}/id"
    printf '#!/bin/bash\necho "ldconfig" >> "${SB}/events"\n' > "${bin}/ldconfig"
    printf '#!/bin/bash\ncat "${SB}/modules"\nseq 1 200000 | sed "s/^/filler_/"\n' > "${bin}/lsmod"
    printf '#!/bin/bash\necho 6.12.1-test\n' > "${bin}/uname"
    printf '#!/bin/bash\nexit 0\n' > "${bin}/nvidia-modprobe"
    printf '#!/bin/bash\ncat "${SB}/smi" 2>/dev/null\n' > "${bin}/nvidia-smi"
    printf '#!/bin/bash\nprintf "512\\t%%s\\n" "${@: -1}"\n' > "${bin}/du"
    # The host's GPUs: a copy of an lspci fixture, or none at all.
    printf '#!/bin/bash\ncat "${SB}/lspci" 2>/dev/null\nexit 0\n' > "${bin}/lspci"
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

sb="$(new_sandbox old-host-short true OLD)"
echo 24.04.2 > "${sb}/etc/version"
deploy "${sb}" NEW
check "24.04.2 is refused" nonzero "${RC}"
check "24.04.2 names the minimum" present "${sb}" "24.10"

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
for version in 24.10.2.4 25.04.2.6 25.10.8 25.10-RC.1 25.10-BETA.1 27.0.0-RC.1 TrueNAS-SCALE-25.10.8; do
    sb="$(new_sandbox "new-host-${version}" true OLD)"
    echo "${version}" > "${sb}/etc/version"
    deploy "${sb}" NEW
    check "${version} deploys" is "${RC}" 0
done

FIXTURES="${REPO}/tests/fixtures/nvidia"

# put_image <sandbox> <module>-<580|595> | none — the GPU metadata the unsquashfs
# stub serves for every image: NVIDIA's list plus build-info, or nothing.
put_image() {
    local dir="$1/image/usr/share/nvidia-sysext" kind="$2" version
    rm -rf "$1/image"
    [[ "${kind}" == none ]] && return 0
    case "${kind##*-}" in
        580) version=580.196.07 ;;
        595) version=595.112.07 ;;
    esac
    mkdir -p "${dir}"
    cp "${FIXTURES}/supported-gpus-${version}.json" "${dir}/supported-gpus.json"
    printf 'NVIDIA_VERSION=%s\nNVIDIA_KERNEL_MODULE_TYPE=%s\n' "${version}" "${kind%-*}" > "${dir}/build-info"
}

# gpu_sandbox <lspci fixture> <image metadata> [installed image text] — always at
# ${WORK}/gpu: the helpers below run inside $(…), so the path has to be known
# to the caller without coming back from the subshell.
gpu_sandbox() {
    rm -rf "${WORK}/gpu"
    local s; s="$(new_sandbox gpu true "${3:-OLD}")"
    cp "${FIXTURES}/$1" "${s}/lspci"
    put_image "${s}" "$2"
}

# deploy_with <lspci fixture> <image metadata> [flags] — output in <sb>/out
deploy_with() {
    local lspci="$1" image="$2"; shift 2
    gpu_sandbox "${lspci}" "${image}"
    echo NEW > "${WORK}/gpu/new.raw"
    SB="${WORK}/gpu" PATH="${WORK}/gpu/bin:${PATH}" \
        bash "${WORK}/gpu/deploy-nvidia.sh" "$@" "${WORK}/gpu/new.raw" > "${WORK}/gpu/out" 2>&1
    RC=$?
}

# uninstall_with <lspci fixture> — the stock image never carries GPU metadata
uninstall_with() {
    gpu_sandbox "$1" none
    echo STOCK > "${WORK}/gpu/nvidia.raw.stock"
    SB="${WORK}/gpu" PATH="${WORK}/gpu/bin:${PATH}" \
        bash "${WORK}/gpu/deploy-nvidia.sh" --uninstall > "${WORK}/gpu/out" 2>&1 </dev/null
    RC=$?
}

# menu_with <lspci fixture> <image metadata> <keystrokes> — drives the plain menu
# from inside the sandbox, so the loose ./nvidia.raw is the only image it finds.
menu_with() {
    gpu_sandbox "$1" "$2"
    echo NEW > "${WORK}/gpu/nvidia.raw"
    echo STOCK > "${WORK}/gpu/nvidia.raw.stock"
    ( cd "${WORK}/gpu" && printf '%b' "$3" | SB="${WORK}/gpu" PATH="${WORK}/gpu/bin:${PATH}" \
        timeout 20 bash "${WORK}/gpu/deploy-nvidia.sh" --no-whiptail > "${WORK}/gpu/out" 2>&1 )
    RC=$?
}

# check_with <lspci fixture> <image metadata> — --check of a healthy install of
# that image; output in <sb>/check-out
check_with() {
    gpu_sandbox "$1" "$2" "NEW DRIVER=580.196.07"
    load_modules "${WORK}/gpu"; loaded_driver "${WORK}/gpu" 580.196.07
    echo "580.196.07, Test GPU" > "${WORK}/gpu/smi"
    SB="${WORK}/gpu" PATH="${WORK}/gpu/bin:${PATH}" \
        bash "${WORK}/gpu/deploy-nvidia.sh" --check > "${WORK}/gpu/check-out" 2>&1
    RC=$?
}

count_in()    { grep -cF -- "$2" "$1"; }
has()         { grep -qF -- "$2" "$1"; }
lacks()       { ! grep -qF -- "$2" "$1"; }

# A PATH holding every host tool except one, to stand in for a TrueNAS box
# that lacks it.
path_without() {
    local dir="${WORK}/no-$1" f
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        for f in /usr/bin/* /bin/*; do
            [[ -x "${f}" ]] || continue
            case "$(basename "${f}")" in "$1"|"$1".*) continue ;; esac
            [[ -e "${dir}/$(basename "${f}")" ]] || ln -s "${f}" "${dir}/$(basename "${f}")"
        done
    fi
    printf '%s' "${dir}"
}

sb="${WORK}/gpu"
echo "deploy: GPU check"
check "open image + GTX 1080 host is refused" is "$(deploy_with lspci-gtx1080.txt open-580; echo $RC)" 1
check "nothing changed after the refusal"     is "$(installed "${sb}")" OLD
check "integration never touched"             is "$(grep -c docker.update "${sb}/events")" 0
check "nothing unmerged"                      is "$(grep -c 'systemd-sysext unmerge' "${sb}/events")" 0
check "names the card and the flavor it needs" has "${sb}/out" "NVIDIA GeForce GTX 1080 (10de:1b80) needs proprietary kernel modules"
check "points at the rebuild and --force-gpu" has "${sb}/out" "--force-gpu"
check "rebuild hint uses --reconfigure"       has "${sb}/out" "Rebuild with ./configure.sh --reconfigure (Module Type → proprietary) or NVIDIA_KERNEL_MODULE_TYPE=proprietary in .env"
check "no ignored --module hint"              lacks "${sb}/out" "configure.sh --module"
check "does not suggest SKIP_GPU_CHECK"       lacks "${sb}/out" "SKIP_GPU_CHECK"
check "--force-gpu deploys anyway"            is "$(deploy_with lspci-gtx1080.txt open-580 --force-gpu; installed "${sb}")" NEW
check "--force-gpu still says why"            has "${sb}/out" "needs proprietary kernel modules"
check "--dry-run runs the check too"          is "$(deploy_with lspci-gtx1080.txt open-580 --dry-run; echo $RC)" 1
check "dry run names the card"                has "${sb}/out" "NVIDIA GeForce GTX 1080 (10de:1b80)"
check "reserved T1000 is not checked, RTX PRO 2000 passes" is "$(deploy_with lspci-truenas-t1000-vfio-rtxpro2000.txt open-580; installed "${sb}")" NEW
check "says the T1000 was skipped"            grep -q "reserved for a VM (vfio-pci) — not checked" "${sb}/out"
check "the check runs exactly once"           is "$(count_in "${sb}/out" "reserved for a VM (vfio-pci) — not checked")" 1
check "confirms the RTX PRO 2000"             has "${sb}/out" "NVIDIA RTX PRO 2000 Blackwell (10de:2d30) is supported by NVIDIA 580.196.07 (open modules)"
check "proprietary image + GTX 1080 deploys"  is "$(deploy_with lspci-gtx1080.txt proprietary-580; installed "${sb}")" NEW
check "proprietary image + RTX 5080 is refused" is "$(deploy_with lspci-rtx5080-3d.txt proprietary-580; echo $RC)" 1
check "says the RTX 5080 needs open modules"  has "${sb}/out" "NVIDIA GeForce RTX 5080 (10de:2c02) needs open kernel modules"
check "legacy-only card is refused"           is "$(deploy_with lspci-gtx1080.txt open-595; echo $RC)" 1
check "names the legacy branch"               has "${sb}/out" "NVIDIA lists it for the 580.xx legacy driver"
check "unlisted card is refused"              is "$(deploy_with lspci-gtx480-fermi.txt open-580; echo $RC)" 1
check "says the card is not listed"           has "${sb}/out" "10de:06c0 is not in NVIDIA 580.196.07's supported list"
check "image without metadata deploys"        is "$(deploy_with lspci-gtx1080.txt none; installed "${sb}")" NEW
check "says why it skipped the check"         has "${sb}/out" "This image carries no GPU list (built before GPU checks, or the stock image) — skipping the GPU check"
check "--uninstall (stock image) is not blocked" is "$(uninstall_with lspci-gtx1080.txt; echo $RC)" 0
check "--uninstall installs the stock image"  is "$(installed "${sb}")" STOCK
check "--uninstall says why it skipped"       has "${sb}/out" "This image carries no GPU list"

rc="$(deploy_with lspci-gtx1080.txt open-580; echo $RC)"   # sets up the sandbox
SB="${sb}" PATH="${sb}/bin:$(path_without python3)" bash "${sb}/deploy-nvidia.sh" "${sb}/new.raw" > "${sb}/out" 2>&1
check "no python3: deploys anyway"            is "$?:$(installed "${sb}")" 0:NEW
check "no python3: says it could not check"   has "${sb}/out" "could not check"
rc="$(deploy_with lspci-gtx1080.txt open-580; echo $RC)"
rm -f "${sb}/bin/unsquashfs"
SB="${sb}" PATH="${sb}/bin:$(path_without unsquashfs)" bash "${sb}/deploy-nvidia.sh" "${sb}/new.raw" > "${sb}/out" 2>&1
check "no unsquashfs: deploys anyway"         is "$?:$(installed "${sb}")" 0:NEW
check "no unsquashfs: says it could not check" has "${sb}/out" "could not check"

echo "menu: GPU check"
check "menu deploy is refused"                is "$(menu_with lspci-gtx1080.txt open-580 '2\n1\n1\ny\n\n\n'; installed "${sb}")" OLD
check "menu deploy names the card once"       is "$(count_in "${sb}/out" "needs proprietary kernel modules")" 1
check "menu deploy of a fitting image works"  is "$(menu_with lspci-truenas-t1000-vfio-rtxpro2000.txt open-580 '2\n1\n1\ny\n\n\n'; installed "${sb}")" NEW
check "menu deploy checks once"               is "$(count_in "${sb}/out" "reserved for a VM (vfio-pci) — not checked")" 1
check "menu uninstall is not blocked"         is "$(menu_with lspci-gtx1080.txt none '4\ny\n\n\n'; installed "${sb}")" STOCK
check "menu uninstall says why, once"         is "$(count_in "${sb}/out" "This image carries no GPU list")" 1

echo "--check GPU section"
check_with lspci-truenas-t1000-vfio-rtxpro2000.txt open-580
check "lists the reserved card"  grep -q "T1000 8GB (0000:03:00.0): reserved for a VM (vfio-pci)" "${sb}/check-out"
check "lists the driven card"    grep -q "(0000:81:00.0): driven by nvidia" "${sb}/check-out"
check "names a card lspci can't from the image" has "${sb}/check-out" "NVIDIA RTX PRO 2000 Blackwell (0000:81:00.0): driven by nvidia"
check "the installed driver supports it" has "${sb}/check-out" "supported by the installed driver: yes"
check "a fitting GPU is no problem" is "$(check_with lspci-truenas-t1000-vfio-rtxpro2000.txt open-580; echo $RC)" 0
check "a card with no driver bound" is "$(check_with lspci-gtx1080.txt open-580; echo $RC)" 1
check "says no driver is bound"  has "${sb}/check-out" "GeForce GTX 1080 (0000:01:00.0): no driver bound"
check "says why it is unsupported" has "${sb}/check-out" "supported by the installed driver: no — needs proprietary kernel modules"
check "lists it under Problems"  has "${sb}/check-out" "does not drive"
check_with lspci-gtx1080.txt none
check "no metadata: no support line" lacks "${sb}/check-out" "supported by the installed driver"
check "no metadata: still lists the card" has "${sb}/check-out" "(0000:01:00.0): no driver bound"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
