# TrueNAS NVIDIA Driver Updater

Build and deploy **any** NVIDIA driver as a `systemd-sysext` image (`nvidia.raw`) for **TrueNAS 23/24/25/26** — fully automated via Docker.

TrueNAS ships with a specific NVIDIA driver version baked into its immutable root filesystem. This tool lets you compile and package a different driver version (newer or older) without modifying the base OS, using the `systemd-sysext` overlay mechanism that TrueNAS natively supports.

---

## Features

- **Interactive wizard** — `configure.sh` fetches real version lists with smart tagging (★ Latest Stable, ★ Production Branch, etc.) and guides you through setup. Uses whiptail TUI dialogs when available (TrueNAS has it), with bash `select` menus as fallback
- **GPU-aware driver recommendation** — detects the GPU architecture from the chip codename and points Kepler/Maxwell/Pascal/Volta owners at the last branch that still supports their card, warning before a build that would install cleanly and then not drive the GPU
- **Fully automated** — downloads TrueNAS update file, extracts kernel headers, compiles the driver, packages everything
- **TrueNAS 23/24/25/26 aware** — supports 23.x, 24.x, 25.x codename-based downloads and TrueNAS 26 update URLs
- **Production-kernel aware** — correctly selects the production kernel over debug variants
- **Complete module database** — ships a combined `modules.dep` covering all system + NVIDIA modules (no `depmod -a` needed on read-only target)
- **nvidia-container-toolkit included** — Docker GPU passthrough works out of the box
- **Optional update repack** — can also emit a rebuilt `truenas.update` with the new `nvidia.raw` embedded
- **Before/after filesystem diff** — captures 100% of NVIDIA installer output, no fragile glob patterns
- **Backup & rollback** — deployment script preserves previous images with timestamps and restores them on any failure (including `Ctrl-C`)
- **Reboot-free driver swap** — deploy script pauses TrueNAS's Docker NVIDIA integration and unloads the old kernel modules, so the new driver is live as soon as `nvidia-smi` runs
- **Auto sysext diagnostics** — deployment script prints host/image metadata when `systemd-sysext merge` rejects the image
- **`--check` and `--dry-run`** — inspect what is installed (driver version, target kernel, activation, middleware state) or rehearse a deployment without touching anything

## Quick Start

### 1. Configure

Run the interactive wizard — it auto-detects your system, fetches version lists, and generates `.env`:

```bash
chmod +x configure.sh
./configure.sh
```

The wizard auto-detects your TrueNAS version and GPU, then walks you through 4 steps. Key versions are tagged so you don't need to look anything up:

```
[OK]    Detected TrueNAS version: 25.10.3.1
[OK]    Detected GPU: NVIDIA AD102 [GeForce RTX 4090] (rev a1)
[OK]      Architecture: Ada — supported by current driver branches

  Step 1: TrueNAS Version  →  Auto-detected! Confirm or pick another.

  Step 2: Select NVIDIA Driver Version
   GPU: NVIDIA GeForce RTX 4090
   1) 595.80  ★ Production Branch
   2) 610.43.02  ★ New Feature Branch
   3) 470.256.02  ★ Legacy GPU (470.xx)
   4) 595.44.01
   ...
   95) 🔍 Filter versions          ← type to search (e.g. "595" or "production")
   96) ✎ Enter manually
   #? 1

  Step 3: Select Kernel Module Type      →  open / proprietary
  Step 4: Embed nvidia.raw in .update?   →  yes / no
```

After the last step, `.env` is generated — Docker Compose reads it automatically. `docker-compose.yaml` is a git-tracked template and never modified.

> **Adaptive UI** — auto-detects `whiptail` for full TUI dialog boxes (available on TrueNAS). Falls back to plain bash menus if whiptail isn't found. Use `--no-whiptail` to force bash mode.

<details>
<summary><b>Non-interactive mode (CI / automation)</b></summary>

Skip the wizard entirely by passing CLI flags:

```bash
./configure.sh --truenas 25.10.3.1 --nvidia 595.80
./configure.sh --truenas 25.10.3.1 --nvidia 595.80 --module open --embed false
```

| Flag | Default | Description |
|------|---------|-------------|
| `--truenas VERSION` | (required) | TrueNAS version |
| `--nvidia VERSION` | (required) | NVIDIA driver version |
| `--module TYPE` | `open` | `open` or `proprietary` |
| `--embed true\|false` | `false` | Embed nvidia.raw in truenas.update |
</details>

<details>
<summary><b>Quick-change a single setting</b></summary>

Already configured but want to change just one thing? Use `--reconfigure`:

```bash
./configure.sh --reconfigure
```

It reads the existing `.env`, lets you pick which setting to change, and regenerates the file — no need to re-run the full wizard.
</details>

<details>
<summary><b>Manual configuration</b></summary>

Copy `.env.example` to `.env` and edit:

```bash
cp .env.example .env
```

```ini
# .env
NVIDIA_VERSION=595.80
TRUENAS_VERSION=25.10.3.1
NVIDIA_KERNEL_MODULE_TYPE=open
TRUENAS_CODENAME=Goldeye
NVIDIA_BUILD_CC=
NVIDIA_INSTALL_DRM=true
EMBED_NVIDIA_RAW_IN_UPDATE=false
```

`docker-compose.yaml` is a git-tracked template — it reads values from `.env` automatically. Never edit `docker-compose.yaml` directly.
</details>

### 2. Build

```bash
docker compose build
docker compose run --rm nvidia-builder
```

The build takes ~10-15 minutes (mostly kernel module compilation). By default artifacts are grouped under `./output/<TRUENAS_VERSION>/`.

The large downloads — the TrueNAS update (~1.8 GB) and the NVIDIA `.run` (~300 MB) — are cached in `./cache/` (mounted at `/cache`) and reused across runs. Delete a file there to force a fresh download.

If `EMBED_NVIDIA_RAW_IN_UPDATE=true`, the build will also unpack the source `truenas.update`, replace the bundled `/usr/share/truenas/sysext-extensions/nvidia.raw`, and write a new `.update` image to `./output/`.

For each generated artifact, the script also writes a sibling `.sha256` file containing the raw SHA256 hash only:

- `./output/<TRUENAS_VERSION>/nvidia.raw.sha256`
- `./output/<TRUENAS_VERSION>/<official update filename>.sha256` (when repack is enabled)

Output naming follows the TrueNAS version:

| TrueNAS version | Output directory | Update filename |
|---|---|---|
| `26.0.0-BETA.1` | `output/26.0.0-BETA.1/` | `TrueNAS-26.0.0-BETA.1.update` |
| `25.10.3` | `output/25.10.3/` | `TrueNAS-SCALE-25.10.3.update` |

`NVIDIA_KERNEL_MODULE_TYPE` is passed through to the NVIDIA installer as `--kernel-module-type=<value>`.

| Value | When to use | Notes |
|-------|-------------|-------|
| `open` | Default choice for most newer GPUs and current TrueNAS releases | Best starting point for Turing / Ampere / Ada / newer platforms |
| `proprietary` | If the open modules fail to build, fail to load, or are known to be unsupported for your hardware/workload | Uses the legacy closed-source kernel modules shipped by NVIDIA |

> **Note:** `nvidia-installer` gained `--kernel-module-type` only in the **~555** driver series — older branches (including the **535** and **550** LTS lines, and legacy **470**) don't accept it. The build **probes each installer for the options it actually supports** and only passes the flags it recognizes, so older drivers build successfully instead of failing on an unknown option. When `--kernel-module-type` isn't available, the installer's default (proprietary) modules are built regardless of this setting. See [Driver-version flag support](#driver-version-flag-support) below.

`NVIDIA_BUILD_CC` lets you override the compiler used for the NVIDIA kernel module build:

- leave it empty (default) to **match the GCC the target kernel was built with** — read from `CONFIG_CC_VERSION_TEXT`. This matters: building with a *much newer* GCC (e.g. GCC 14, which makes implicit-declaration a hard error) breaks NVIDIA's `conftest` API detection and causes bogus `implicit declaration of 'dma_is_direct'/'phys_to_dma'` failures on kernels that otherwise build fine.
- set `NVIDIA_BUILD_CC=gcc-12` (or `gcc-13`/`gcc-14`) to force a specific compiler. The image ships gcc-12/13/14.

`NVIDIA_INSTALL_DRM=true` installs `nvidia-drm.ko` by default. This lets the TrueNAS host load `nvidia_drm` and create `/dev/dri`, which official apps such as Steam Headless may map when GPU support is detected.

Set `NVIDIA_INSTALL_DRM=false` only if your target TrueNAS kernel cannot load `nvidia_drm`; the script will pass `--no-drm` to the NVIDIA installer in that case.

### 3. Deploy to TrueNAS

Copy the generated `output/<TRUENAS_VERSION>/nvidia.raw` and `deploy-nvidia.sh` to your TrueNAS system, then:

```bash
chmod +x deploy-nvidia.sh
./deploy-nvidia.sh nvidia.raw
```

The deploy script handles everything:
- Turns off TrueNAS's own Docker NVIDIA integration for the duration of the swap (`midclt call -j docker.update '{"nvidia": false}'`) and turns it back on afterwards, so middleware never points at driver files that are being replaced
- Unmerges active sysext extensions
- Unlocks the read-only `/usr` ZFS dataset
- Backs up the existing `nvidia.raw` (timestamped)
- Installs the new image
- Re-locks the dataset and merges extensions
- Verifies the extension is actually **activated** — `/usr/share/truenas/sysext-extensions/` is only a storage location, not a `systemd-sysext` search path; activation is a symlink in `/etc/extensions` (persistent) or `/run/extensions` (tmpfs). TrueNAS middleware manages that symlink; if none exists, the script creates a transient one in `/run/extensions` and tells you to enable NVIDIA support properly
- Refreshes the dynamic linker cache (`ldconfig`) so the newly merged `libnvidia-*.so` / `libcuda.so` are resolvable
- Unloads the old driver's kernel modules (`nvidia_drm` → `nvidia_modeset` → `nvidia_uvm` → `nvidia`) so `nvidia-smi` loads the new ones **without a reboot**. If a module is still in use (running container, VM passthrough), it says so and asks for a reboot instead
- If the merge fails, prints `systemd-sysext` compatibility diagnostics automatically
- Restores the previous state on **any** failure — including `Ctrl-C` mid-run — via an `EXIT` trap, so `/usr` is never left writable and the Docker NVIDIA integration is never left disabled

> Releases older than Electric Eel have no `docker.config` middleware namespace; the script detects that and skips the integration step instead of failing.

#### Inspecting before (and after) deploying

```bash
./deploy-nvidia.sh --check              # read-only state report, no root needed
./deploy-nvidia.sh --dry-run nvidia.raw # walk the whole flow, change nothing
```

`--check` answers the two questions that fail silently — *is the installed image built for the kernel I'm running*, and *is it actually activated* — instead of leaving you to piece it together from `nvidia-smi` errors:

```
── Installed image ─────────────────────────────────────────
  path            /usr/share/truenas/sysext-extensions/nvidia.raw
  size            412M
  modified        2026-07-24 17:22:16
  driver version  595.80
  built for       6.12.15-production+truenas

── Host ────────────────────────────────────────────────────
  kernel          6.14.2-production+truenas
  loaded modules  nvidia_drm nvidia
  nvidia-smi      <no devices / driver not responding>

── Problems ────────────────────────────────────────────────
[WARN]  The installed image was built for kernel 6.12.15-production+truenas,
[WARN]  but this host runs 6.14.2-production+truenas. The modules will not load — this is
[WARN]  what a TrueNAS update does. Rebuild against 6.14.2-production+truenas and redeploy.
```

It reads the driver version and target kernel out of the image itself (from the squashfs listing — nothing is extracted), reports the activation symlinks, `systemd-sysext status`, the middleware integration state and available backups, and **exits non-zero when it finds a problem** so it can be used in a health check.

`--dry-run` prints every mutating command it would run — `[DRY] zfs set readonly=off …`, `[DRY] cp …`, `[DRY] systemd-sysext merge` — in the real order, with all the same guards, and touches nothing.

### 4. Verify

```bash
nvidia-smi
modinfo nvidia_drm
modprobe nvidia_drm modeset=1
ls -la /dev/dri
```

---

## TrueNAS Version Reference

| TrueNAS Version | Codename     |
|------------------------|--------------|
| 26.x                   | not used     |
| 25.10.x                | Goldeye      |
| 25.04.x                | Fangtooth    |
| 24.10.x                | Electric Eel |
| 24.04.x                | Dragonfish   |
| 23.10.x                | Cobia        |

> `TRUENAS_CODENAME` is only needed for 25.x and earlier download URLs. For TrueNAS 26+, leave it empty.

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                   Docker Build Container                │
│                                                         │
│  1. Load local truenas.update or download one           │
│  2. Extract nested rootfs → kernel headers + modules    │
│  3. Detect the production kernel and matching headers   │
│  4. Download the NVIDIA .run installer                  │
│  5. Take a BEFORE snapshot of /usr and /etc             │
│  6. Install toolkit deps + compile NVIDIA modules       │
│  7. Take an AFTER snapshot and diff new files           │
│  8. Stage runtime files into the sysext tree            │
│  9. Build combined modules.dep (system + nvidia)        │
│ 10. Write extension-release metadata                    │
│ 11. Package nvidia.raw and write nvidia.raw.sha256      │
│ 12. Optional: replace bundled nvidia.raw in             │
│      truenas.update, rebuild MANIFEST, and emit         │
│      a new .update plus .update.sha256                  │
└─────────────────────────────────────────────────────────┘
```

### Why systemd-sysext?

TrueNAS 25/26 uses an immutable root filesystem. `systemd-sysext` provides a supported overlay mechanism that merges the contents of `/usr` from extension images on top of the base OS — without modifying it. This means:

- **Survives reboots** — extensions are re-merged on boot
- **Clean rollback** — `systemd-sysext unmerge` restores the original state

> **A TrueNAS update reverts the driver.** The `/usr` dataset (and with it `/usr/share/truenas/sysext-extensions/nvidia.raw`) is replaced wholesale by every TrueNAS update, so the stock driver comes back and the new kernel needs freshly compiled modules anyway. Rebuild against the new TrueNAS version and re-run `deploy-nvidia.sh` after each update. Nothing on `/usr` — and no activation symlink in `/etc/extensions` — is guaranteed to survive.

### Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| `--kernel-module-type=open` (when supported) | Uses the open GPU kernel modules; the recommended default here, avoiding `MITIGATION_RETHUNK` / naked-return hard errors on hardened TrueNAS kernels for many modern GPUs. Only passed when the installer supports it (see [Driver-version flag support](#driver-version-flag-support)) |
| Probe installer options instead of hardcoding them | `nvidia-installer` aborts on the first unrecognized option, and the available flags differ by driver version (LTS branches even lag feature branches). The build extracts the installer and reads the option set from the binary, passing only recognized flags — so any supported driver (down to 470) builds without flag-mismatch failures |
| Match the kernel's build GCC (`CONFIG_CC_VERSION_TEXT`), with optional `NVIDIA_BUILD_CC` override | Compiling modules with a much newer GCC than the kernel used corrupts NVIDIA's `conftest` API detection (GCC 14 makes implicit-declaration an error), producing bogus build failures. The image ships gcc-12/13/14 so it can match the kernel (e.g. 6.1/6.6 → gcc-12/13, 6.12 → gcc-14) |
| `NVIDIA_INSTALL_DRM=true` by default | Ships `nvidia-drm.ko` so the host can create `/dev/dri` for apps that require DRM device mapping. Set `NVIDIA_INSTALL_DRM=false` to pass `--no-drm` when a target kernel cannot load `nvidia_drm` |
| Production kernel preference | TrueNAS ships both debug and production kernels; the production kernel is what actually boots. Alphabetical sorting would pick the wrong one |
| Combined `modules.dep` | The sysext's `modules.dep` overlays the system's via overlayfs. Shipping an nvidia-only `modules.dep` would make all other kernel modules (nf_tables, bridge, etc.) invisible, breaking Docker and networking |
| `extension-release.nvidia` → `ID=_any` | Matches TrueNAS's own sysext packaging behavior and avoids host-version compatibility rejection during `systemd-sysext merge` |
| Write sibling `.sha256` files for generated artifacts | Keeps `nvidia.raw` and optional `.update` outputs easy to verify in simple release directories and mirrors the user's existing artifact layout |
| Rebuild `MANIFEST` checksums when repacking `truenas.update` | Replacing the bundled `nvidia.raw` changes `rootfs.squashfs`; the update manifest must be rewritten or TrueNAS rejects the repacked `.update` |
| gzip compression | Matches TrueNAS's own squashfs convention for consistent image sizes |
| Pause the Docker NVIDIA integration during deployment | TrueNAS middleware manages the NVIDIA container runtime itself; swapping `nvidia.raw` underneath it leaves the runtime configured against files that no longer exist. Disabling it for the swap and restoring it afterwards keeps middleware and the image in sync |
| Unload the old kernel modules after merging | The previous driver stays resident in the kernel until unloaded, so `nvidia-smi` would keep reporting the old version (or a module/driver mismatch) until the next reboot |
| `EXIT` trap around the whole deployment | The window between `zfs set readonly=off` and the final merge leaves `/usr` writable and the extensions unmerged. A trap guarantees that state is undone on error, `die`, or `Ctrl-C` — not only on a failed merge |

### Driver-version flag support

`nvidia-installer` rejects unknown options (aborting the whole build), and the option set has grown over time — so the same flag list does **not** work across all driver branches. The build handles this automatically by probing each installer for the options it actually supports and passing only those; the table below documents which flags are gated and when they appeared (verified against the [`NVIDIA/nvidia-installer`](https://github.com/NVIDIA/nvidia-installer) option tables).

| Installer flag | First available | 470 | 535 LTS | 550 LTS | 555 | 560+ |
|----------------|-----------------|:---:|:------:|:------:|:---:|:----:|
| `--silent`, `--kernel-source-path`, `--kernel-name`, `--no-x-check`, `--no-nouveau-check`, `--no-systemd`, `--no-backup`, `--install-libglvnd`, `--no-drm` | always (≤470) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `--allow-installation-with-running-driver` | R545 | ❌ | ❌¹ | ✅ | ✅ | ✅ |
| `--skip-module-load` | R550 | ❌ | ❌ | ✅ | ✅ | ✅ |
| `--no-rebuild-initramfs` | R550 | ❌ | ❌ | ✅ | ✅ | ✅ |
| `--kernel-module-type=<open\|proprietary>` | R555 | ❌ | ❌ | ❌ | ✅ | ✅ |

¹ The 535 LTS branch may backport some flags in later point releases; the build detects the real support per download rather than assuming.

**Consequences when a flag is unavailable:**

- The flag is silently dropped (with a `[WARN]` line) instead of aborting the build.
- For drivers older than ~555, `--kernel-module-type` can't be passed, so the installer builds its **default (proprietary)** modules — `NVIDIA_KERNEL_MODULE_TYPE=open` cannot be honored on those branches.
- The interactive wizard reflects this: picking a pre-555 driver forces the module type to `proprietary`.

**Running-driver handling.** The build container shares the host kernel, so if the build host itself has NVIDIA modules loaded, the installer would normally refuse ("An NVIDIA kernel module appears to already be loaded"). Drivers 545+ are told to tolerate this with `--allow-installation-with-running-driver`. Older drivers (e.g. 470) lack that flag, so the build instead splits into **two passes** — `--no-kernel-module` (userspace) first, then `--kernel-module-only` (kernel modules) on top — each of which the installer allows even with a running driver. (Userspace goes first because `--kernel-module-only` refuses to run unless a driver is already installed.) Either way you can build on a machine that's actively using its GPU.

### Driver / kernel compatibility check

Legacy/EOL NVIDIA branches only build against kernels up to a certain point — e.g. the stock **470 `.run` breaks at kernel 6.10** (when `follow_pfn` was removed). Built with the kernel's own GCC, it compiles cleanly through **6.9** (verified on TrueNAS 24.04/24.10, kernel 6.6), but TrueNAS 25.x (kernel 6.12) needs source patches. To avoid a ~10-minute build that's doomed to fail at the compile step, the builder checks the **real kernel version** (read from the downloaded TrueNAS image) against a small table of known branch ceilings **before** downloading or compiling:

| Branch | Builds against kernels up to | TrueNAS coverage |
|--------|------------------------------|------------------|
| `390`  | ~5.15 | none current |
| `470`  | **6.9** | ✅ 23.10 / 24.04 / 24.10 (≤6.6); ❌ 25.x (6.12) — needs patches |
| 535 / 550 / 560+ | current kernels (no fixed ceiling) | all |

If the target kernel is newer than the branch supports, the build **aborts immediately** with an explanation. The interactive wizard also shows an early heads-up when you select a legacy branch. To build anyway, either supply [source patches](#building-eol-drivers-on-newer-kernels-patches) (which also relaxes this check) or set `SKIP_KERNEL_COMPAT_CHECK=true`.

> **Kepler note:** if your GPU is *only* supported by the 470 branch (Kepler — GeForce 600/700 series), it works out of the box up to TrueNAS 24.10. For TrueNAS 25.x (kernel 6.12) you'll need community kernel patches (see below). Newer GPUs (Maxwell/Pascal/Turing/Ampere/Ada+) should use a current branch (535/550/560+), which builds cleanly everywhere.

### Does the driver actually support your GPU?

A driver can compile, package and merge perfectly and still not drive your card — NVIDIA removes older architectures from newer branches, and `nvidia-smi` then just reports `No devices were found`. The wizard reads the chip codename from `lspci` (e.g. `GP102 [GeForce GTX 1080 Ti]`, which is unambiguous where marketing names are not — a GTX 750 Ti is Maxwell while the rest of the 7xx series is Kepler), maps it to an architecture, and both **tags the right driver** in the list and **warns before you build** if the selection doesn't fit:

| Architecture | Cards | Last supporting branch |
|---|---|---|
| Kepler | GeForce 600/700, Quadro K, Tesla K | **470.xx** (needs patches on kernel 6.10+) |
| Maxwell / Pascal / Volta | GTX 750 Ti, GTX 900/10-series, TITAN X/Xp/V, Quadro M/P, Tesla M/P/V | **580.xx** |
| Turing and newer | RTX 20/30/40/50-series, GTX 16-series, A/L/B-series | current branches |
| Fermi | GeForce 400/500 | 390.xx — **cannot be built for any TrueNAS kernel** |

Newer cards have a floor too: Blackwell (RTX 50-series) needs 570.xx or newer, Ada 520+, Ampere 450+, Turing 410+. Picking below that gets the same silent failure, so it's flagged as well.

```
[OK]    Detected GPU: NVIDIA GP102 [GeForce GTX 1080 Ti] (rev a1)
[OK]      Architecture: Pascal — last supporting driver branch: 580.xx

   1) 580.142  ★ Recommended for your Pascal GPU
   2) 610.43.02  ★ New Feature Branch
   3) 595.80  ★ Production Branch
```

The check is **advisory** — you can still pick anything (e.g. when building for a different machine), and it stays silent when the GPU can't be identified rather than guessing.

### Building EOL drivers on newer kernels (patches)

When a legacy driver needs source fixes to build on a newer kernel (e.g. 470 on TrueNAS 25.x / kernel 6.12), the builder can patch the NVIDIA source before compiling. The behavior is set by **`NVIDIA_PATCH_MODE`** (`./configure.sh` asks you when the chosen driver/kernel combo needs it):

| Mode | What it does |
|------|--------------|
| `none` | Never patch (build will fail if the driver can't compile on that kernel). |
| `predefined` | Apply the **curated set we ship** for that driver branch — `predefined-patches/<driver>/` — fetched from a known community project. The easy button. |
| `custom` | Apply **your own** patches from `patches/<kernel>/` (e.g. `patches/6.12/`). |
| `auto` (default) | Apply `patches/<kernel>/` if present, else build stock. Backward-compatible. |

**Easiest path — predefined (NVIDIA 470 on TrueNAS 25.x):** run `./configure.sh`, pick the 470 driver and a 25.x TrueNAS version, and when prompted choose **"Download curated community patches."** It downloads the curated set into `predefined-patches/470/` and sets `NVIDIA_PATCH_MODE=predefined`. Non-interactively:

```bash
./configure.sh --truenas 25.10.3.1 --nvidia 470.256.02 --patch predefined
docker compose run --rm nvidia-builder
```

**Own patches — custom:** drop patch files into a kernel-keyed subdir `patches/<MAJOR.MINOR>/` and set `NVIDIA_PATCH_MODE=custom`:

```bash
mkdir -p patches/6.12
base=https://raw.githubusercontent.com/joanbm/nvidia-470xx-linux-mainline/master/patches
curl -L -o patches/6.12/10-kernel-6.10.patch "$base/kernel-6.10.patch"
curl -L -o patches/6.12/12-kernel-6.12.patch "$base/kernel-6.12.patch"
```

When any patches are applied, **both `./configure.sh` and the build warn you** it's a community-patched, non-standard build, and the build pauses briefly before continuing.

**Where the curated set comes from / where to find your own** (you vet them — they're version- and kernel-specific):

| Source | What it is |
|--------|-----------|
| [joanbm/nvidia-470xx-linux-mainline](https://github.com/joanbm/nvidia-470xx-linux-mainline/tree/master/patches) | The project our **predefined 470 set** is curated from (`predefined-patches/470/PATCHES.list`). Maintained patches for mainline kernels through 6.1x/7.x. |
| [AUR `nvidia-470xx-dkms`](https://aur.archlinux.org/packages/nvidia-470xx-dkms) | Arch package carrying the same family of 470xx kernel-compat patches. |
| [Frogging-Family/nvidia-all](https://github.com/Frogging-Family/nvidia-all) | Broad NVIDIA driver patch collection (many branches). |
| Distro source packages | Debian/Ubuntu `nvidia-graphics-drivers-470` carry `debian/patches/`. |

How it works:

- `predefined` reads `predefined-patches/<driver-major>/`; `custom`/`auto` read `patches/<kernel>/` (kernel-specific, chosen by the **real image kernel**) with a flat `patches/*.patch` fallback.
- Each patch is **dry-run first** to find the right target (NVIDIA package root *or* its `kernel/` subdir) and strip level (`-p1`/`-p0`/`-p2`), then applied — so a mismatched patch can't half-apply. One that won't apply **aborts the build** with the filename.
- Patches apply in **sorted filename order** (the predefined fetch numbers them to preserve the upstream apply order); many fixes are cumulative.
- Applying patches automatically **relaxes the driver/kernel compatibility abort** — you've provided the fix.
- Patches must match your exact `NVIDIA_VERSION`. The predefined 470 set targets `470.256.02`; a different driver version may need different patches.
- The predefined set is **community-sourced and not tested/endorsed by this project** — verify your build. To update it, edit `predefined-patches/<driver>/PATCHES.list`.

---

## Advanced Usage

### Common Build Variants

**Use a pre-downloaded update file** to avoid re-downloading the ~1.8 GB TrueNAS update on every build:

```bash
# Download once
wget -O truenas.update "https://update-public.sys.truenas.net/TrueNAS-26-BETA/TrueNAS-26.0.0-BETA.1.update"

# Build — the script detects the local file and skips download
docker compose run --rm nvidia-builder
```

**Also generate an updated `truenas.update`** with the new `nvidia.raw` embedded:

```bash
docker compose run --rm \
  -e EMBED_NVIDIA_RAW_IN_UPDATE=true \
  nvidia-builder
```

This still generates the standalone `nvidia.raw`, and additionally writes:

- `output/<TRUENAS_VERSION>/<official update filename>`
- `output/<TRUENAS_VERSION>/<official update filename>.sha256`

### When `systemd-sysext` Rejects the Image

If deployment fails with an error such as:

```text
No suitable extensions found (1 ignored due to incompatible image(s)).
```

re-run the normal deploy command:

```bash
./deploy-nvidia.sh output/<TRUENAS_VERSION>/nvidia.raw
```

The script now prints:

- host `/usr/lib/os-release`
- embedded `usr/lib/extension-release.d/extension-release.nvidia`
- `systemd-sysext status`
- `SYSTEMD_LOG_LEVEL=debug systemd-sysext refresh`

### After a TrueNAS Update

When TrueNAS updates its kernel, you need to rebuild:

1. Update `TRUENAS_VERSION` in `docker-compose.yaml`
2. Remove any cached `truenas.update` file
3. Run `docker compose build && docker compose run --rm nvidia-builder`
4. Deploy the new `nvidia.raw`

### Rollback to Previous Driver

If `systemd-sysext merge` rejects a freshly deployed image, the deploy script automatically restores the previous `nvidia.raw` (or removes it on a fresh install) and re-merges, so the system is left in its prior working state rather than broken.

To roll back manually, the deploy script saves backups in a `backups/` directory alongside itself (keeps the 5 most recent):

```bash
# List available backups
ls -la backups/

# Rollback
./deploy-nvidia.sh backups/nvidia.raw.backup_20260422_160428
```

---

## File Structure

```
.
├── configure.sh            # Interactive setup wizard (generates docker-compose.yaml)
├── Dockerfile              # Debian 12 build container
├── docker-compose.yaml     # Build configuration (auto-generated or manual)
├── entrypoint.sh           # Main build script
├── deploy-nvidia.sh        # TrueNAS deployment script
├── output/                 # Build outputs organized by TrueNAS version
├── cache/                  # Cached TrueNAS update + NVIDIA installer downloads
├── backups/                # Previous nvidia.raw backups (auto-managed)
├── LICENSE
└── README.md
```

## Requirements

- **Build machine**: Docker with `docker compose`
- **Configuration wizard**: `curl` or `wget` (for fetching version lists)
- **TrueNAS**: 24.04+ / 25.x / 26.x (systemd-sysext support)
- **GPU**: Any NVIDIA GPU supported by the target driver version

## Troubleshooting

### `nvidia-smi` fails with "couldn't communicate with the NVIDIA driver"

The kernel modules were compiled for the wrong kernel version. Verify with:
```bash
uname -r                    # running kernel
modinfo nvidia | grep vermagic  # module's target kernel
```
These must match. Rebuild with the correct `TRUENAS_VERSION`.

### Docker fails with "iptables: Failed to initialize nft"

The sysext's `modules.dep` is overriding the system's module database. This was a bug in early versions — ensure you're using the latest build script which ships a combined `modules.dep`.

### A systemd unit shipped inside the sysext never starts

Units merged from a sysext that rely on `[Install] WantedBy=multi-user.target` are silently skipped at boot on TrueNAS — no journal entry, no error. Start them explicitly (`systemctl start <unit>`) or from a PREINIT init/shutdown script instead of relying on `enable`.

### Docker warns "nvidia-container-runtime: no such file or directory"

The `nvidia-container-toolkit` package is missing from the sysext. Ensure you're using the latest build script which installs it via apt.

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- Inspired by the official [TrueNAS SCALE extension build system](https://github.com/truenas/scale-build)
- NVIDIA driver installer from [NVIDIA's official download site](https://www.nvidia.com/Download/index.aspx)
- nvidia-container-toolkit from [NVIDIA's container toolkit repo](https://github.com/NVIDIA/nvidia-container-toolkit)
- Legacy 470-on-mainline-kernel patches by [**joanbm**'s nvidia-470xx-linux-mainline](https://github.com/joanbm/nvidia-470xx-linux-mainline) — the curated set used by the `predefined` patch mode to build the EOL 470 branch on kernel 6.10+
- [**truenas-community-sysexts** — Building Sysexts for TrueNAS SCALE](https://github.com/truenas-community-sysexts/.github/blob/main/docs/sysext-guide.md) — community reference for sysext activation paths, `/etc` → `/usr` remapping, the `modules.dep` overlay problem, and update-persistence patterns
