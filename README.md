# TrueNAS NVIDIA Driver Updater

Build and deploy **any** NVIDIA driver as a `systemd-sysext` image (`nvidia.raw`) for **TrueNAS 24.10 and newer** — fully automated via Docker.

TrueNAS ships with a specific NVIDIA driver version baked into its immutable root filesystem. This tool lets you compile and package a different driver version (newer or older) without modifying the base OS, using the `systemd-sysext` overlay mechanism that TrueNAS natively supports.

> **Current landscape (November 2026)** — examples throughout this README use the versions that are current today. Nothing is hardcoded: `configure.sh` fetches the live TrueNAS and NVIDIA version lists every run, so newer releases show up on their own.
>
> | | Version | Notes |
> |---|---|---|
> | TrueNAS | **25.10.8** (Goldeye) | kernel 6.12.113 |
> | TrueNAS pre-release | **27.0.0-RC.1** | kernel 6.18.52; 26 was renamed 27 at RC.1. Downloads work, building against it is untested |
> | NVIDIA — New Feature Branch | **620.70.06** | newest, Turing and newer |
> | NVIDIA — Production Branch | **595.112.07** | the safe default for most users |
> | NVIDIA — Maxwell to Volta | **580.196.07** | last branch for these cards |
> | NVIDIA — Legacy | **470.256.02** | Kepler only; needs [patches](#building-eol-drivers-on-newer-kernels-patches) on kernel 6.10+ |

---

## Features

- **Interactive wizard** — `configure.sh` fetches real version lists with smart tagging (★ Latest Stable, ★ Production Branch, etc.) and guides you through setup. Uses whiptail TUI dialogs when available (TrueNAS has it), with bash `select` menus as fallback
- **GPU-aware driver recommendation** — detects the GPU architecture from the chip codename and points Kepler/Maxwell/Pascal/Volta owners at the last branch that still supports their card, warning before a build that would install cleanly and then not drive the GPU
- **Fully automated** — downloads TrueNAS update file, extracts kernel headers, compiles the driver, packages everything
- **TrueNAS 24.10 and newer** — supports 24.10 and 25.x codename-based downloads and the BETA and RC update URLs of TrueNAS 26 and later (26 was renamed 27 at RC.1). A 27 stable release has no known URL yet, so supply `truenas.update` yourself; building against 27 has not been tested
- **Verified downloads** — the TrueNAS update and NVIDIA installer are checked against the SHA256 published next to them, including cached copies. A mismatch stops the build and deletes the file
- **Build logs that outlive the container** — each build leaves its console output and `nvidia-installer` log in `./output/logs/`, on failure as well as success (newest 3 of each are kept)
- **Production-kernel aware** — correctly selects the production kernel over debug variants
- **Complete module database** — ships a combined `modules.dep` covering all system + NVIDIA modules (no `depmod -a` needed on read-only target)
- **nvidia-container-toolkit included** — Docker GPU passthrough works out of the box
- **Optional update repack** — can also emit a rebuilt `truenas.update` with the new `nvidia.raw` embedded
- **Before/after filesystem diff** — captures 100% of NVIDIA installer output, no fragile glob patterns
- **Backup & rollback** — deployment script preserves previous images with timestamps and restores them on any failure, including `Ctrl-C`. A second `Ctrl-C` can't interrupt the restore
- **Reboot-free driver swap** — deploy script pauses TrueNAS's Docker NVIDIA integration and unloads the old kernel modules while Docker is down, so the new driver is live without a reboot
- **Deploy checks that mean something** — refuses an image built for a different kernel, and confirms the image really merged instead of trusting `systemd-sysext merge`, which exits 0 even when it merged nothing
- **Auto sysext diagnostics** — deployment script prints host/image metadata when `systemd-sysext merge` rejects the image
- **Interactive deploy manager** — `deploy-nvidia.sh` with no arguments opens a menu to inspect state, deploy a built image, roll back, restore the stock driver, make the driver survive TrueNAS updates, or keep CUDA working across reboots
- **CUDA actually works after a reboot** — TrueNAS loads `nvidia`, `nvidia_drm` and `nvidia_modeset` at boot but never `nvidia_uvm`, so `/dev/nvidia-uvm` is missing and every CUDA workload fails until something creates it. The deploy script puts the node back after a swap, `--check` reports when it's absent, and `--persist-uvm` registers a boot-time entry that fixes it for good
- **Survives TrueNAS updates** — an opt-in PREINIT script (registered in the middleware database, which updates don't touch) restores the driver after an update wipes `/usr`; it refuses to restore when the update also changed the kernel, telling you to rebuild instead of silently loading modules that can't work
- **Stock-driver rescue image** — every build also emits `nvidia.raw.stock`, the driver that TrueNAS release shipped, so `--uninstall` gets you back to factory even with no backups left
- **Bring your own installer** — `--run-url` / `--custom-run` build from an arbitrary `.run` (betas, archived versions, self-patched installers)
- **End-to-end in one run** — when run on the TrueNAS box, `configure.sh` offers to start the build and then to deploy the result, so configure → build → deploy needs no manual handoff
- **`--check` and `--dry-run`** — inspect what is installed (driver version, target kernel, activation, middleware state, pending reboot) or rehearse a deployment without touching anything

## Quick Start

### 1. Configure

Run the interactive wizard — it auto-detects your system, fetches version lists, and generates `.env`:

```bash
chmod +x configure.sh
./configure.sh
```

The wizard auto-detects your TrueNAS version and GPU, then walks you through 4 steps. Key versions are tagged so you don't need to look anything up:

```
[OK]    Detected TrueNAS version: 25.10.8
[OK]    Detected GPU: NVIDIA AD102 [GeForce RTX 4090] (rev a1)
[OK]      Architecture: Ada — supported by current driver branches

  Step 1: TrueNAS Version  →  Auto-detected! Confirm or pick another.

  Step 2: Select NVIDIA Driver Version
   GPU: NVIDIA GeForce RTX 4090
   1) 595.112.07  ★ Production Branch
   2) 620.70.06  ★ New Feature Branch
   3) 470.256.02  ★ Legacy GPU (470.xx)
   4) 595.99.02
   ...
   95) 🔍 Filter versions          ← type to search (e.g. "595" or "production")
   96) ✎ Enter manually
   #? 1

  Step 3: Select Kernel Module Type      →  open / proprietary
  Step 4: Embed nvidia.raw in .update?   →  yes / no
```

The wizard offers to start the build when it's done, and — if you're running it **on the TrueNAS box itself** — offers to deploy the finished image straight away, so configure → build → deploy is one uninterrupted run. Both prompts are opt-in; decline and it prints the commands instead. On a separate build host it skips the deploy offer and reminds you to copy the image over.

After the last step, `.env` is generated — Docker Compose reads it automatically. `docker-compose.yaml` is a git-tracked template and never modified.

> **Adaptive UI** — auto-detects `whiptail` for full TUI dialog boxes (available on TrueNAS). Falls back to plain bash menus if whiptail isn't found. Use `--no-whiptail` to force bash mode.

<details>
<summary><b>Non-interactive mode (CI / automation)</b></summary>

Skip the wizard entirely by passing CLI flags:

```bash
./configure.sh --truenas 25.10.8 --nvidia 595.112.07
./configure.sh --truenas 25.10.8 --nvidia 595.112.07 --module open --embed false
```

| Flag | Default | Description |
|------|---------|-------------|
| `--truenas VERSION` | (required) | TrueNAS version |
| `--nvidia VERSION` | (required) | NVIDIA driver version |
| `--module TYPE` | `open` | `open` or `proprietary` |
| `--embed true\|false` | `false` | Embed nvidia.raw in truenas.update |
| `--patch MODE` | `auto` | Source-patch mode: `none`, `custom`, `predefined` or `auto` |
| `--run-url URL` | | Build from a `.run` at this URL |
| `--custom-run PATH` | | Build from a `.run` inside the project directory |
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
NVIDIA_VERSION=595.112.07
TRUENAS_VERSION=25.10.8
NVIDIA_KERNEL_MODULE_TYPE=open
TRUENAS_CODENAME=Goldeye
NVIDIA_BUILD_CC=
NVIDIA_INSTALL_DRM=true
EMBED_NVIDIA_RAW_IN_UPDATE=false
SKIP_KERNEL_COMPAT_CHECK=false
NVIDIA_PATCH_MODE=auto
```

`docker-compose.yaml` is a git-tracked template — it reads values from `.env` automatically. Never edit `docker-compose.yaml` directly.
</details>

### 2. Build

```bash
docker compose build
docker compose run --rm nvidia-builder
```

The build takes ~10-15 minutes (mostly kernel module compilation). By default artifacts are grouped under `./output/<TRUENAS_VERSION>/`.

Run `docker compose build` again after pulling changes: `entrypoint.sh` is copied into the image, so the container otherwise keeps running the old script.

The large downloads — the TrueNAS update (~2 GB) and the NVIDIA `.run` (~300 MB) — are cached in `./cache/` (mounted at `/cache`) and reused across runs. Delete a file there to force a fresh download.

Every download is checked against the SHA256 its server publishes, and so is a cached copy on the next run. On a mismatch the build deletes the file and stops; run it again to download a fresh copy. If the server publishes no checksum, which happens with some older NVIDIA releases, the build warns and continues. Files you supply yourself (`truenas.update`, `--custom-run`) are not checked.

Each run also leaves two logs in `./output/logs/`, whether it worked or not: `build-<timestamp>.log` with the console output, and `nvidia-installer-<timestamp>.log`. The newest 3 of each are kept.

If `EMBED_NVIDIA_RAW_IN_UPDATE=true`, the build will also unpack the source `truenas.update`, replace the bundled `/usr/share/truenas/sysext-extensions/nvidia.raw`, and write a new `.update` image to `./output/`.

For each generated artifact, the script also writes a sibling `.sha256` file containing the raw SHA256 hash only:

- `./output/<TRUENAS_VERSION>/nvidia.raw.sha256`
- `./output/<TRUENAS_VERSION>/nvidia.raw.stock.sha256`
- `./output/<TRUENAS_VERSION>/<official update filename>.sha256` (when repack is enabled)

Output naming follows the TrueNAS version:

| TrueNAS version | Output directory | Update filename |
|---|---|---|
| `27.0.0-RC.1` | `output/27.0.0-RC.1/` | `TrueNAS-27.0.0-RC.1.update` |
| `26.0.0-BETA.1` | `output/26.0.0-BETA.1/` | `TrueNAS-26.0.0-BETA.1.update` |
| `25.10.8` | `output/25.10.8/` | `TrueNAS-SCALE-25.10.8.update` |

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

Copy the generated `output/<TRUENAS_VERSION>/nvidia.raw` and `deploy-nvidia.sh` to your TrueNAS system, then either run the **manager** and pick from a menu:

```bash
chmod +x deploy-nvidia.sh
./deploy-nvidia.sh
```

```
  TrueNAS NVIDIA Driver Manager

   1) status      Show the current driver / sysext state
   2) deploy      Deploy an nvidia.raw image
   3) rollback    Roll back to a previous image
   4) uninstall   Restore the driver TrueNAS shipped with
   5) persist     Survive TrueNAS updates (off)
   6) uvm         Load nvidia_uvm at boot for CUDA (off)
   7) quit        Exit
```

…or name the image directly:

```bash
./deploy-nvidia.sh nvidia.raw
```

The manager finds built images under `output/*/nvidia.raw` (newest TrueNAS release first) and lists rollback points from `backups/` with the timestamp each was taken, marking any built for a different kernel. It uses the same whiptail TUI as `configure.sh` when available, with plain numbered menus as fallback (`--no-whiptail` forces those). Picking an image offers **Deploy** or **Dry run**, and deployment asks for confirmation first.

> The menu never deploys inline — it re-invokes this same script with the image you chose, so a menu-driven deployment runs the identical code path, EXIT trap and rollback as the command-line one.

The deploy script handles everything:
- Refuses an image built for a different kernel than the running one, because it would merge and then fail to load. `--force-kernel` overrides this
- Turns off TrueNAS's own Docker NVIDIA integration for the duration of the swap (`midclt call -j docker.update '{"nvidia": false}'`) and turns it back on afterwards, so middleware never points at driver files that are being replaced
- Unmerges active sysext extensions
- Unlocks the read-only `/usr` ZFS dataset
- Backs up the existing `nvidia.raw` (timestamped)
- Installs the new image
- Re-locks the dataset and makes sure the extension is **activated** — `/usr/share/truenas/sysext-extensions/` is only a storage location, not a `systemd-sysext` search path; activation is a symlink in `/etc/extensions` (persistent) or `/run/extensions` (tmpfs). Turning the integration off removes TrueNAS's own link, so the script puts one back at the same path before merging. If the integration was already off, that link is transient and the script tells you to enable NVIDIA support properly
- Merges extensions and confirms the image really merged, because `systemd-sysext merge` exits 0 even when it finds nothing. A rejected image is rolled back here, before the integration comes back
- Refreshes the dynamic linker cache (`ldconfig`) so the newly merged `libnvidia-*.so` / `libcuda.so` are resolvable
- Unloads the old driver's kernel modules while Docker is still down (`nvidia_drm` → `nvidia_modeset` → `nvidia_uvm` → `nvidia`) so `nvidia-smi` loads the new ones **without a reboot**. If a module is still in use (running container, VM passthrough), it says so and asks for a reboot instead
- Re-enables TrueNAS's Docker NVIDIA integration, which loads the new modules. Doing this after the unload keeps Apps from starting on the old module with the new libraries, unless a module was too busy to unload
- Recreates the CUDA device nodes (`nvidia-modprobe -u -c 0`). Nothing on TrueNAS does this by itself, so without it the swap would leave `/dev/nvidia-uvm` gone and every CUDA workload broken until the node happened to be recreated — see [CUDA / `/dev/nvidia-uvm`](#cuda-apps-fail-devnvidia-uvm-is-missing) below
- If the merge fails, prints `systemd-sysext` compatibility diagnostics automatically
- Restores the previous state on **any** failure — including `Ctrl-C` mid-run — via an `EXIT` trap, so `/usr` is never left writable and the Docker NVIDIA integration is never left disabled. Signals are ignored while the restore runs, so it always finishes

#### Inspecting before (and after) deploying

```bash
./deploy-nvidia.sh --check              # read-only state report, no root needed
./deploy-nvidia.sh --dry-run nvidia.raw # walk the whole flow, change nothing
./deploy-nvidia.sh --force-kernel nvidia.raw # deploy for another kernel anyway
```

`--check` answers the two questions that fail silently — *is the installed image built for the kernel I'm running*, and *is it actually activated* — instead of leaving you to piece it together from `nvidia-smi` errors:

```
── Installed image ─────────────────────────────────────────
  path            /usr/share/truenas/sysext-extensions/nvidia.raw
  size            439MB
  modified        2026-11-06 15:48:33
  driver version  595.112.07
  built for       6.12.113-production+truenas

── Host ────────────────────────────────────────────────────
  kernel          6.18.52-production+truenas
  TrueNAS         27.0.0-RC.1
  loaded modules  <none>
  CUDA nodes      /dev/nvidia-uvm MISSING (nvidia_uvm not loaded)
  nvidia-smi      <no devices / driver not responding>

── Problems ────────────────────────────────────────────────
[WARN]  The installed image was built for kernel 6.12.113-production+truenas,
[WARN]  but this host runs 6.18.52-production+truenas. The modules will not load — this is
[WARN]  what a TrueNAS update does. Rebuild against 6.18.52-production+truenas and redeploy.
```

It reads the driver version and target kernel out of the image itself (from the squashfs listing — nothing is extracted), reports the activation symlinks, `systemd-sysext status`, the middleware integration state and available backups, and **exits non-zero when it finds a problem** so it can be used in a health check. A missing `/dev/nvidia-uvm` is reported with a note rather than counted as a problem — a box that only transcodes never needs it, so it must not flip the exit status of a health check.

A pending reboot gets a note too. If the loaded kernel module differs from the driver in the image, `--check` names both versions and doesn't count it as a problem, because it clears by itself. It stays quiet when the image was built for a different kernel, since a reboot wouldn't help there.

`--dry-run` prints every mutating command it would run — `[DRY] zfs set readonly=off …`, `[DRY] cp …`, `[DRY] systemd-sysext merge` — in the real order, with all the same guards, and touches nothing.

### 4. Verify

```bash
./deploy-nvidia.sh --check
nvidia-smi
modinfo nvidia_drm
modprobe nvidia_drm modeset=1
ls -la /dev/dri
```

---

## TrueNAS Version Reference

| TrueNAS Version | Codename     |
|------------------------|--------------|
| 27.x (26 until RC.1)   | not used     |
| 26.x                   | not used     |
| 25.10.x                | Goldeye      |
| 25.04.x                | Fangtooth    |
| 24.10.x                | Electric Eel |

> `TRUENAS_CODENAME` is only needed for 25.x and earlier download URLs. For TrueNAS 26+, leave it empty. BETA and RC builds of 26+ download automatically. A stable 27 release has no known URL yet, so put its update file in the project directory as `truenas.update`.

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                   Docker Build Container                │
│                                                         │
│  1. Load local truenas.update or download and verify    │
│  2. Extract nested rootfs → kernel headers + modules    │
│  3. Detect the production kernel and matching headers   │
│  4. Download and verify the NVIDIA .run installer       │
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
│ 13. Save the build and installer logs to output/logs/   │
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
| Match the kernel's build GCC (`CONFIG_CC_VERSION_TEXT`), with optional `NVIDIA_BUILD_CC` override | Compiling modules with a much newer GCC than the kernel used corrupts NVIDIA's `conftest` API detection (GCC 14 makes implicit-declaration an error), producing bogus build failures. The image ships gcc-12/13/14 so it can match the kernel (e.g. TrueNAS 25.10 → gcc-12) |
| `NVIDIA_INSTALL_DRM=true` by default | Ships `nvidia-drm.ko` so the host can create `/dev/dri` for apps that require DRM device mapping. Set `NVIDIA_INSTALL_DRM=false` to pass `--no-drm` when a target kernel cannot load `nvidia_drm` |
| Production kernel preference | TrueNAS ships both debug and production kernels; the production kernel is what actually boots. Alphabetical sorting would pick the wrong one |
| Combined `modules.dep` | The sysext's `modules.dep` overlays the system's via overlayfs. Shipping an nvidia-only `modules.dep` would make all other kernel modules (nf_tables, bridge, etc.) invisible, breaking Docker and networking |
| `extension-release.nvidia` → `ID=_any` | Matches TrueNAS's own sysext packaging behavior and avoids host-version compatibility rejection during `systemd-sysext merge` |
| Write sibling `.sha256` files for generated artifacts | Keeps `nvidia.raw` and optional `.update` outputs easy to verify in simple release directories and mirrors the user's existing artifact layout |
| Rebuild `MANIFEST` checksums when repacking `truenas.update` | Replacing the bundled `nvidia.raw` changes `rootfs.squashfs`; the update manifest must be rewritten or TrueNAS rejects the repacked `.update` |
| Debian bookworm container, gcc-13/14 from trixie | `libvulkan1` from the container is copied into the image. TrueNAS 24.10 to 25.10 are bookworm-based with glibc 2.36, and trixie's `libvulkan1` needs 2.38, so a trixie base would ship a library those hosts can't load |
| gzip compression | Matches TrueNAS's own squashfs convention for consistent image sizes |
| Pause the Docker NVIDIA integration during deployment | TrueNAS middleware manages the NVIDIA container runtime itself; swapping `nvidia.raw` underneath it leaves the runtime configured against files that no longer exist. Disabling it for the swap and restoring it afterwards keeps middleware and the image in sync |
| Unload the old kernel modules before Docker comes back | The previous driver stays resident in the kernel until unloaded, so `nvidia-smi` would keep reporting the old version (or a module/driver mismatch) until the next reboot. Doing it while Docker is down means no container holds the modules, and Apps don't start on the old module with the new libraries |
| Recreate the activation link before merging | Turning the integration off removes `/run/extensions/nvidia.raw`. Without a link the merge finds nothing, so a bad image would only surface after the point where rollback is still possible. The link uses middleware's own path, so middleware leaves it alone when the integration comes back |
| Confirm the merge through `extension-release.nvidia` | `systemd-sysext merge` exits 0 with "No extensions found", so its exit status proves nothing. This file has to be in every sysext and only appears under `/usr` while the image is merged |
| Refuse an image built for another kernel | It merges without complaint and then the modules won't load, which is easy to walk into when restoring a backup taken before a TrueNAS update |
| `EXIT` trap around the whole deployment | The window between `zfs set readonly=off` and the final merge leaves `/usr` writable and the extensions unmerged. A trap guarantees that state is undone on error, `die`, or `Ctrl-C` — not only on a failed merge. The rollback ignores further signals, and leaves the installed image alone if the copy never started |
| Delete a download that fails its checksum | `wget -c` would otherwise treat the bad file as complete on every later run |
| Report sizes with `stat`, not `du` | `du` counts allocated blocks, and on ZFS those lag far behind a file that was just written. A finished 439 MB image could show as `151M`, and a fresh copy as `512` |

### Driver-version flag support

`nvidia-installer` rejects unknown options (aborting the whole build), and the option set has grown over time — so the same flag list does **not** work across all driver branches. The build handles this automatically by probing each installer for the options it actually supports and passing only those; the table below documents which flags are gated and when they appeared (verified against the [`NVIDIA/nvidia-installer`](https://github.com/NVIDIA/nvidia-installer) option tables).

| Installer flag | First available | 470 | 535 LTS | 550 LTS | 555 | 560 – 620 |
|----------------|-----------------|:---:|:------:|:------:|:---:|:---------:|
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

Legacy/EOL NVIDIA branches only build against kernels up to a certain point — e.g. the stock **470 `.run` breaks at kernel 6.10** (when `follow_pfn` was removed). Built with the kernel's own GCC, it compiles cleanly through **6.9** (verified on TrueNAS 24.10, kernel 6.6), but TrueNAS 25.x (kernel 6.12) needs source patches. To avoid a ~10-minute build that's doomed to fail at the compile step, the builder checks the **real kernel version** (read from the downloaded TrueNAS image) against a small table of known branch ceilings **before** downloading or compiling:

| Branch | Builds against kernels up to | TrueNAS coverage |
|--------|------------------------------|------------------|
| `390`  | ~5.15 | none current |
| `470`  | **6.9** | ✅ 24.10 (6.6); ❌ 25.x (6.12) — needs patches |
| 535 / 550 / 580 / 595 / 620 | current kernels (no fixed ceiling) | all |

If the target kernel is newer than the branch supports, the build **aborts immediately** with an explanation. The interactive wizard also shows an early heads-up when you select a legacy branch. To build anyway, either supply [source patches](#building-eol-drivers-on-newer-kernels-patches) (which also relaxes this check) or set `SKIP_KERNEL_COMPAT_CHECK=true`.

> **Kepler note:** if your GPU is *only* supported by the 470 branch (Kepler — GeForce 600/700 series), it works out of the box up to TrueNAS 24.10. For TrueNAS 25.x (kernel 6.12) you'll need community kernel patches (see below). Newer GPUs (Maxwell/Pascal/Turing/Ampere/Ada+) should use a current branch (580 for Maxwell–Volta, 595/620 for Turing and newer), which builds cleanly everywhere.

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

   1) 580.196.07  ★ Recommended for your Pascal GPU
   2) 620.70.06  ★ New Feature Branch
   3) 595.112.07  ★ Production Branch
```

**More than one GPU?** Every NVIDIA card is read, not just the first, and the wizard works out the branch window that serves *all* of them — the lowest ceiling and the highest floor:

```
[OK]    Detected GPU: NVIDIA TU117GL [T1000 8GB] (rev a1)
[OK]      Architecture: Turing — supported by current driver branches
[OK]    Detected GPU: NVIDIA GB206 [RTX PRO 2000 Blackwell] (rev a1)
[OK]      Architecture: Blackwell — supported by current driver branches
[OK]    2 NVIDIA GPUs — a driver must be 570.xx or newer to serve all of them
```

When the window is empty — say a Kepler GT 710 (≤470) next to an RTX 5090 (≥570) — it says so plainly instead of recommending a branch that leaves one card dead:

```
[WARN]  The installed GPUs cannot be served by one driver:
[WARN]    GK208B [GeForce GT 710] (Kepler) needs 470.xx or older
[WARN]    GB202 [GeForce RTX 5090] (Blackwell) needs 570.xx or newer
[WARN]  Whichever branch you build, the other card will not be driven.
```

**Card too new to be named?** A GPU missing from the local `pci.ids` database shows up as `Device 2c05` with no chip codename. That card is reported as unidentified and excluded from the recommendation — the other cards are still checked normally, and the summary says the check doesn't cover everything.

The check is **advisory** — you can still pick anything (e.g. when building for a different machine), and it stays silent rather than guessing.

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
./configure.sh --truenas 25.10.8 --nvidia 470.256.02 --patch predefined
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

### Building from a different installer

The build normally downloads the official installer for `NVIDIA_VERSION`. Two overrides cover the cases where that file isn't there — betas, archived releases, or an installer you patched yourself:

```bash
# Fetch from an arbitrary URL
./configure.sh --truenas 25.10.8 --nvidia 621.10 \
    --run-url https://developer.nvidia.com/.../NVIDIA-Linux-x86_64-621.10.run

# Or use a .run you already have (must sit inside the project directory,
# because that is what gets mounted into the build container)
cp ~/Downloads/NVIDIA-Linux-x86_64-621.10.run .
./configure.sh --truenas 25.10.8 --nvidia 621.10 --custom-run ./NVIDIA-Linux-x86_64-621.10.run
```

In both modes `NVIDIA_VERSION` is only a **label** — it names the output and drives the driver/kernel compatibility checks, but nothing verifies it against the installer. Set it to the version the `.run` actually contains, or those checks will be reasoning about the wrong driver. The build prints a warning either way. `--reconfigure` keeps the override rather than dropping it. A `--run-url` download is verified when a `.sha256sum` file sits next to it; a `--custom-run` file is not verified.

### Common Build Variants

**Use a pre-downloaded update file** when the build can't fetch one itself, such as a stable 27 release. Downloads are already cached between builds, and a file you supply this way is not checksum-verified:

```bash
# Download once
wget -O truenas.update "https://update-public.sys.truenas.net/TrueNAS-27-RC/TrueNAS-27.0.0-RC.1.update"

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

The script prints:

- host `/usr/lib/os-release`
- embedded `usr/lib/extension-release.d/extension-release.nvidia`
- `systemd-sysext status`
- `SYSTEMD_LOG_LEVEL=debug systemd-sysext refresh`

### After a TrueNAS Update

A TrueNAS update replaces the entire `/usr` dataset, so the custom driver is gone and the stock one is back. `/etc` is recreated too (only `hostid` and `machine-id` carry over), so activation symlinks don't survive either.

**If the update did not change the kernel**, the driver can be put back automatically. Turn it on once:

```bash
./deploy-nvidia.sh --persist        # or the manager's "persist" entry
```

This copies the running image to `/mnt/<pool>/.config/truenas-nvidia-driver-updater/` and registers a **PREINIT** init script through `midclt`. The registration lives in the middleware database, which updates don't touch, and the copy lives on a data pool rather than the boot pool — so both sides survive. On every boot the script waits for middleware, compares the installed image with the saved one, and restores it if they differ.

> **It deliberately refuses to restore when the kernel changed.** The modules inside the image are built for one exact kernel release; restoring them onto a new kernel produces a `vermagic` mismatch and they simply won't load — an opaque failure. Instead the script logs what happened and stops. Check it with `journalctl -t nvidia-persist`, and `./deploy-nvidia.sh --check` will also flag a saved copy that has gone stale.

**When the update did change the kernel**, rebuild:

1. Re-run `./configure.sh` (it auto-detects the new version) or update `TRUENAS_VERSION` in `.env`
2. Remove any `truenas.update` you placed in the project directory (downloads in `./cache/` are kept per version and can stay)
3. Run `docker compose build && docker compose run --rm nvidia-builder`
4. Deploy the new `nvidia.raw`
5. Re-run `./deploy-nvidia.sh --persist` so the saved copy matches the new kernel

Turn it all off again with `./deploy-nvidia.sh --unpersist` (the saved copy is left in place for you to delete).

### Back to the driver TrueNAS shipped

Every build writes `output/<TRUENAS_VERSION>/nvidia.raw.stock` — the driver that release originally shipped, lifted straight out of the official update file. Deploying it undoes the swap completely, and unlike a rollback it doesn't depend on a backup still existing:

```bash
./deploy-nvidia.sh --uninstall
```

It's an ordinary deployment, so the image it replaces is backed up first and you can go back again.

### Rollback to Previous Driver

If `systemd-sysext merge` rejects a freshly deployed image, or the image doesn't end up merged, the deploy script automatically restores the previous `nvidia.raw` (or removes it on a fresh install) and re-merges, so the system is left in its prior working state rather than broken.

To roll back manually, the deploy script saves backups in a `backups/` directory alongside itself (keeps the 5 most recent). Easiest is the manager's **rollback** entry, which lists them with the date each was taken:

```bash
./deploy-nvidia.sh          # → 3) rollback
```

Or name one directly:

```bash
# List available backups
ls -la backups/

# Rollback
./deploy-nvidia.sh backups/nvidia.raw.backup_20260422_160428
```

Rolling back is an ordinary deployment, so the image being replaced is itself backed up first — you can always go back the other way. It also goes through the same kernel check: a backup from before a TrueNAS update that changed the kernel is refused, because its modules can't load. Rebuild instead, or use `--uninstall` with an image from the current release.

---

## File Structure

```
.
├── configure.sh            # Interactive setup wizard (generates .env)
├── Dockerfile              # Debian 12 build container
├── docker-compose.yaml     # Build configuration template (reads .env, never edited)
├── entrypoint.sh           # Main build script
├── deploy-nvidia.sh        # TrueNAS deployment script
├── tests/                  # Offline regression tests
├── predefined-patches/     # Curated patch lists for EOL drivers
├── patches/                # Your own source patches, by kernel
├── output/                 # Build outputs by TrueNAS version, build logs in output/logs/
├── cache/                  # Cached TrueNAS update + NVIDIA installer downloads
├── backups/                # Previous nvidia.raw backups (auto-managed)
├── LICENSE
└── README.md
```

### Running the tests

```bash
tests/deploy-activation-test.sh
tests/entrypoint-test.sh
tests/configure-test.sh
```

All three run offline and need no root, Docker or TrueNAS. The deploy test runs `deploy-nvidia.sh` in a sandbox with stubs for every host command, including a `midclt` that follows the real `docker.configure_nvidia`. The build test exercises the download, checksum and log helpers from `entrypoint.sh`, and the configure test covers version discovery. None of them replaces a real build and deploy.

## Requirements

- **Build machine**: Docker with `docker compose`
- **Configuration wizard**: `curl` or `wget` (for fetching version lists)
- **TrueNAS**: 24.10+ / 25.x / 26.x. 24.04 and older are not supported, because they ship the driver as ordinary packages rather than a sysext. `configure.sh`, the build and `deploy-nvidia.sh` all refuse them, and `--check` reports one as a problem. 27 pre-releases download, but building against them is untested
- **GPU**: Any NVIDIA GPU supported by the target driver version

## Troubleshooting

### `nvidia-smi` fails with "couldn't communicate with the NVIDIA driver"

The kernel modules were compiled for the wrong kernel version. Verify with:
```bash
uname -r                    # running kernel
modinfo nvidia | grep vermagic  # module's target kernel
```
These must match. Rebuild with the correct `TRUENAS_VERSION`.

### `nvidia-smi` fails with "Driver/library version mismatch"

The new libraries are merged but the old kernel module is still loaded, usually because something held it during the deploy. Run `./deploy-nvidia.sh --check`: if it reports a pending reboot, reboot. Until then, Apps may fail to start as well.

### Deploy refuses the image: "built for kernel …"

The image's modules were built for a different kernel than the one running, so they wouldn't load. This is expected for a backup or image from before a TrueNAS update. Rebuild for the current version. `--force-kernel` installs it anyway, which only makes sense if you're about to boot that kernel.

### Build stops with "SHA256 mismatch"

The download doesn't match the checksum its server publishes, usually because the transfer was cut off or corrupted. The build has already deleted the file, so run it again. If it keeps failing, check for a proxy between you and the server.

### A build failed and the container is gone

Look in `./output/logs/`. `build-<timestamp>.log` has the console output and `nvidia-installer-<timestamp>.log` has the installer's own log, which is where compile errors end up.

### `du` shows a much smaller image than expected

`du` counts allocated blocks, and on ZFS those trail behind a file that was just written, so a finished image can briefly look far too small. Use `stat -c%s nvidia.raw` for the real size. The scripts report sizes this way.

### Docker fails with "iptables: Failed to initialize nft"

The sysext's `modules.dep` is overriding the system's module database. This was a bug in early versions — ensure you're using the latest build script which ships a combined `modules.dep`.

### A systemd unit shipped inside the sysext never starts

Units merged from a sysext that rely on `[Install] WantedBy=multi-user.target` are silently skipped at boot on TrueNAS — no journal entry, no error. Start them explicitly (`systemctl start <unit>`) or from a PREINIT init/shutdown script instead of relying on `enable`.

### CUDA apps fail, `/dev/nvidia-uvm` is missing

Transcoding works, `nvidia-smi` works, but anything CUDA-based (PyTorch, whisper, ollama, …) fails — and `sudo nvidia-modprobe -u -c 0` fixes it until the next reboot.

This is TrueNAS behavior, not something the custom driver causes. Middleware loads the driver at boot in `docker.configure_nvidia`:

```python
subprocess.run(['modprobe', '-a', 'nvidia', 'nvidia_drm', 'nvidia_modeset'], ...)
```

`nvidia_uvm` is deliberately not in that list — upstream expects the setuid `nvidia-modprobe` helper to be called on demand by the CUDA runtime, or by `nvidia-container-cli --load-kmods` when Docker starts a container with a GPU allocated. Neither the stock `nvidia.raw` nor this project's ships the Debian `71-nvidia.rules` udev rule that would otherwise create the node, so when nothing triggers that helper, `/dev/nvidia-uvm` never appears.

Fix it for good:

```bash
./deploy-nvidia.sh --persist-uvm      # or the manager's "uvm" entry
```

That registers a POSTINIT command with middleware — the registration lives in the middleware database and calls a binary the driver image provides, so it survives TrueNAS updates and works with the stock driver too. `--unpersist-uvm` removes it again. The command is retried for half a minute at boot, because POSTINIT can start before middleware has merged the sysext; if it ever gives up it says so in `journalctl -t nvidia-uvm`.

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
- [**truenas-community-sysexts/nvidia-driver-support**](https://github.com/truenas-community-sysexts/nvidia-driver-support) — a sibling project built on this one's extraction pipeline, whose hardware findings fed back into the deploy checks, download verification and TrueNAS 27 support here
- [**truenas-community-sysexts** — Building Sysexts for TrueNAS SCALE](https://github.com/truenas-community-sysexts/.github/blob/main/docs/sysext-guide.md) — community reference for sysext activation paths, `/etc` → `/usr` remapping, the `modules.dep` overlay problem, and update-persistence patterns
