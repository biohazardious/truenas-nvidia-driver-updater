#!/bin/bash
# =============================================================================
# configure-test.sh — offline regression test for configure.sh
#
# Usage:  tests/configure-test.sh
#
# configure.sh is an interactive wizard, so the version discovery is lifted out
# of it and fed a fake download page.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }
is()       { [[ "$1" == "$2" ]]; }
listed()   { grep -qx "$1" "${WORK}/versions"; }
unlisted() { ! grep -qx "$1" "${WORK}/versions"; }

{
    echo 'info() { :; }; warn() { :; }; ok() { :; }'
    echo 'fetch_truenas_branch_info() { :; }'
    cat <<'PAGE'
fetch_url() {
    cat <<'HTML'
<a href="TrueNAS-SCALE-Bluefin/22.12.4.2">x</a>
<a href="TrueNAS-SCALE-Cobia/23.10.2">x</a>
<a href="TrueNAS-SCALE-Dragonfish/24.04.2.5">x</a>
<a href="TrueNAS-SCALE-ElectricEel/24.10.2.4">x</a>
<a href="TrueNAS-SCALE-Fangtooth/25.04.2.6">x</a>
<a href="TrueNAS-SCALE-Goldeye/25.10.8">x</a>
<a href="TrueNAS-27-RC/27.0.0-RC.1">x</a>
HTML
}
PAGE
    sed -n '/^valid_train() {/,/^}/p' "${REPO}/configure.sh"
    sed -n '/^truenas_version_supported() {/,/^}/p' "${REPO}/configure.sh"
    sed -n '/^fetch_truenas_versions() {/,/^}/p' "${REPO}/configure.sh"
    echo 'fetch_truenas_versions'
    echo 'printf "%s\n" "${TRUENAS_VERSIONS[@]}"'
} > "${WORK}/run.sh"
bash "${WORK}/run.sh" > "${WORK}/versions" 2>"${WORK}/errors"

echo "TrueNAS version discovery"
check "25.10 is listed" listed 25.10.8
check "25.04 is listed" listed 25.04.2.6
check "24.10 is listed" listed 24.10.2.4
check "24.04 is dropped" unlisted 24.04.2.5
check "27 RC is listed" listed 27.0.0-RC.1
check "23.x is dropped" unlisted 23.10.2
check "22.x is dropped" unlisted 22.12.4.2

echo "supported releases"
check "the codename tables start at Electric Eel" is "$(grep -cE 'Cobia|Dragonfish' "${REPO}/configure.sh")" 0
check "the kernel table starts at 24.10" is "$(grep -cE '"(23\.10|24\.04)"' "${REPO}/configure.sh")" 0

# Runs a copy, so nothing here can touch the project's real .env. curl and wget
# fail on purpose: the wizard then falls back to asking for the version.
setup_copy() {
    SB="$(mktemp -d "${WORK}/copy.XXXXXX")"
    cp "${REPO}/configure.sh" "${REPO}/docker-compose.yaml" "${SB}/"
    mkdir "${SB}/bin"
    printf '#!/bin/bash\nexit 1\n' > "${SB}/bin/curl"
    printf '#!/bin/bash\nexit 1\n' > "${SB}/bin/wget"
    printf '#!/bin/bash\nexit 0\n' > "${SB}/bin/lspci"
    chmod +x "${SB}/bin/"*
}
configure() { PATH="${SB}/bin:${PATH}" timeout 30 bash "${SB}/configure.sh" "$@" > "${SB}/log" 2>&1; RC=$?; }
nonzero() { [[ "$1" -ne 0 ]]; }
says()    { grep -qF "$1" "${SB}/log"; }
no_env()  { [[ ! -e "${SB}/.env" ]]; }
env_has() { grep -qx "$1" "${SB}/.env"; }

echo "--truenas with an unsupported version"
for version in 24.04.2.5 23.10.2 not-a-version; do
    setup_copy
    configure --truenas "${version}" --nvidia 595.112.07 </dev/null
    check "${version} is refused" nonzero "${RC}"
    check "${version} names the minimum" says "24.10"
    check "${version} writes no .env" no_env
done

echo "--truenas with a supported version"
for version in 24.10.2.4 25.04.2.6 25.10.8 27.0.0-RC.1; do
    setup_copy
    configure --truenas "${version}" --nvidia 595.112.07 </dev/null
    check "${version} is accepted" is "${RC}" 0
    check "${version} reaches .env" env_has "TRUENAS_VERSION=${version}"
done

echo "--truenas with a malformed version"
for version in '25.10.8/../x' '25.10.8 x' '25.10.8;true'; do
    setup_copy
    configure --truenas "${version}" --nvidia 595.112.07 </dev/null
    check "'${version}' is refused" nonzero "${RC}"
    check "'${version}' is named invalid" says "is not a valid TrueNAS version"
    check "'${version}' writes no .env" no_env
done

echo "a malformed version typed into the wizard"
setup_copy
configure --no-whiptail < <(printf '25.10.8/../x\n25.10.8\n\n\n\n\n')
check "it is named invalid" says "is not a valid TrueNAS version"
# read -p shows no prompt without a terminal: the second answer being taken is
# what shows the wizard asked again.
check "the wizard asks again and takes the retyped version" grep -qE 'Selected: 25\.10\.8( |$)' "${SB}/log"

echo "typed into the wizard"
setup_copy
configure --no-whiptail < <(printf '24.04.2.5\n\n\n\n\n')
check "24.04 is refused" nonzero "${RC}"
check "it names the minimum" says "24.10"
check "no .env is written" no_env

echo "auto-detected on the box"
setup_copy
cat > "${SB}/bin/midclt" <<'STUB'
#!/bin/bash
echo '"24.04.2.5"'
STUB
chmod +x "${SB}/bin/midclt"
configure --no-whiptail < <(printf '1\n\n\n\n\n')
check "24.04 is refused" nonzero "${RC}"
check "it names the minimum" says "24.10"
check "no .env is written" no_env

echo "version read from middleware instead of /etc/version"
setup_copy
cat > "${SB}/bin/midclt" <<'STUB'
#!/bin/bash
echo '"TrueNAS-SCALE-25.10.8"'
STUB
chmod +x "${SB}/bin/midclt"
configure --no-whiptail < <(printf '2\n\n\n\n\n')
check "the product prefix is dropped" says "Detected TrueNAS version: 25.10.8"

echo "--reconfigure with an unsupported version in .env"
setup_copy
cat > "${SB}/.env" <<'ENV'
NVIDIA_VERSION=595.112.07
TRUENAS_VERSION=24.04.2.5
NVIDIA_KERNEL_MODULE_TYPE=open
TRUENAS_CODENAME=Dragonfish
EMBED_NVIDIA_RAW_IN_UPDATE=false
ENV
before="$(cat "${SB}/.env")"
configure --reconfigure --no-whiptail < <(printf '4\n1\n\n\n')
check "changing another setting is refused" nonzero "${RC}"
check "it names the minimum" says "24.10"
check ".env is left as it was" is "$(cat "${SB}/.env")" "${before}"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
